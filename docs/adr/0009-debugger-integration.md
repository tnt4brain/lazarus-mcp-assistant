# ADR-009 — Debugger Integration

**Status:** Accepted. Implemented in 19bdf1b and 4d4951a (2026-10-06), revised for v0.8.  
**Date:** 2026-10-06 (proposal), 2026-10-14 (as built)

> The sections up to *Consequences* are the original proposal, kept as written.
> Where the implementation differs, [As built (v0.8)](#as-built-v08) at the end
> is what the code does. Tool names here are the pre-v0.8 ones; see the mapping
> there and [ADR-010](0010-tool-naming-scheme.md).

## Context

The current 35 tools cover source editing, navigation, building, package management,
and project lifecycle.  There are zero debugger tools.  ADR-006 explicitly deferred
"Breakpoints / debugger — separate ADR (significantly larger scope)."

Why tackle it now:

- Self-hosted development increasingly hits runtime bugs where `WriteLn`/`get_messages`
  is insufficient.  The AI needs to set breakpoints, run to them, and inspect state.
- CPUView was added to the knowledge base (134cfa2): it shows the FpDebug/DebuggerIntf
  surface area is accessible and well-structured under the IDE hood.
- The async-vs-sync impedance mismatch (main problem, see below) has a clean solution
  once it is named explicitly.

### The fundamental problem: debugger is async, MCP is sync

Every MCP tool call is a synchronous request → response.  The Lazarus debugger is
event-driven: `run_debugger` fires the process, then some time later an event
(`dbpePause`, `dbpeFinished`) arrives.  Step operations similarly complete
asynchronously.

If we model debugger control as fire-and-forget, the AI has no way to know where
the program stopped, what locals are, or whether it hit an exception.

**Resolution: blocking tools with timeout.**

All session-control tools (`run_debugger`, `continue`, `step_over`, `step_into`,
`step_out`, `run_to_line`) block until the next pause event fires — or until
a configurable timeout (default 30 s).  On pause they return the full "debug state"
snapshot (file, line, reason, call stack head).  The AI gets a single synchronous
round-trip: "step_over → paused at UnitFoo.pas:47, reason=breakpoint".

This is the **checkpoint model**: the AI drives the debugger checkpoint-by-checkpoint.
Each tool is atomic: fire → wait for pause → return state.  Infinite-loop detection
is the timeout.

Implementation: the MCP worker thread posts the debugger command via
`TThread.Synchronize`, then waits on an `RTLEvent` (or `TSimpleEvent`) that the
main thread signals when `TDebugManager` fires its `OnState` / `OnCurrent` callback.

---

## Lazarus debugger API surface

All in `IdeDebuggerIntf` / `Debugger` units (IDE, not LCL).

```pascal
uses IdeDebuggerIntf, Debugger, DebuggerIntf, IdeDebuggerWatchResult;

// Global manager — available after IDE startup
DebugBoss : TDebugManager;   // declared in Debugger unit

// Debugger state
TDBGState = (dsNone, dsIdle, dsStop, dsPause, dsInit, dsRun, dsError, dsDestroying);
DebugBoss.State : TDBGState

// Breakpoints
DebugBoss.BreakPoints : TIDEBreakPoints;
TIDEBreakPoint — Source, Line, Enabled, Valid, HitCount
DebugBoss.BreakPoints.Add(Source, Line) : TIDEBreakPoint

// Run control (must call from main thread)
DebugBoss.RunDebugger;                    // F9 equivalent (run or continue)
DebugBoss.DoPauseProject;                 // pause
DebugBoss.DoStopProject;                  // stop session
DebugBoss.DoStepIntoProject;              // F7
DebugBoss.DoStepOverProject;              // F8
DebugBoss.DoStepOutProject;               // Shift+F8
DebugBoss.DoRunToCursor;                  // F4 (uses active editor position)

// Location
TDebuggerCurrentLine — UnitName, Line (published via OnCurrent callback)

// Locals / call stack / watches
DebugBoss.Watches : TIDEWatches
DebugBoss.CallStack : TIdeCallStack (per-thread, TIdeCallStackEntry per frame)
DebugBoss.Locals : TLocals (per-frame)

// Evaluate expression in current context
DebugBoss.Evaluate(AExpression, AResult, ATypeInfo, EvalFlags)
```

`DebugBoss.OnState` callback fires on state transitions; `DebugBoss.OnCurrent`
fires when the current source line changes (after step/breakpoint).  Both run on
the main thread.

---

## Proposed tools

### Group 1 — Breakpoints (no session required)

#### `set_breakpoint`

Add a source line breakpoint.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `file_path` | string | yes | Absolute path to the `.pas` file |
| `line` | integer | yes | 1-based line number |
| `enabled` | boolean | no | Default `true` |

Returns: `{"id": N, "file": "...", "line": N, "enabled": true}`

Implementation: `DebugBoss.BreakPoints.Add(FilePath, Line)`.

#### `remove_breakpoint`

Remove a breakpoint by file + line.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `file_path` | string | yes | |
| `line` | integer | yes | |

Implementation: find `TIDEBreakPoint` where `.Source = FilePath` and `.Line = Line`;
call `.ReleaseReference` / `.Free`.

Returns: `{"removed": true}` or `{"removed": false, "reason": "not found"}`.

#### `list_breakpoints`

Return all current breakpoints.

No parameters.

Returns:
```json
[{"id": 1, "file": "UnitFoo.pas", "line": 42, "enabled": true,
  "hit_count": 3, "valid": true}]
```

---

### Group 2 — State query (non-blocking, always works)

#### `get_debug_state`

Return the current debugger state and location.  Works in **any** debugger state —
`dsRun`, `dsPause`, `dsStop`, `dsNone`.  No blocking, no event wait.

No parameters.

Returns the **debug state** object:

```json
{
  "state": "paused",
  "file": "UnitFoo.pas",
  "line": 47,
  "reason": "breakpoint",
  "function": "TMyClass.DoSomething"
}
```

`state` values: `"paused"`, `"running"`, `"stopped"`, `"idle"`, `"error"`.

This is the escape hatch for recovery after a timed-out blocking tool.  If
`step_over` returns `{"state": "timeout"}`, the session is still live; call
`get_debug_state` to confirm, then decide between `pause_debugger` and
`stop_debugger`.

---

### Group 3 — Session control (blocking, return debug state)

All tools in this group block until the next pause event or timeout, then return
a debug state object (same shape as `get_debug_state`).

`state` values in returns: `"paused"`, `"running"`, `"stopped"`, `"error"`, `"timeout"`.

#### `run_debugger`

Start or continue a debug session.  Equivalent to F9.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `timeout_s` | integer | no | Seconds to wait for pause; default 30 |

If the session is already `dsPause` (paused), this continues.  If `dsStop`/`dsNone`,
starts a new session.  If the program runs to completion without pausing, returns
`{"state": "stopped"}`.

#### `pause_debugger`

Pause a running debug session.

No parameters.

Implementation: `DebugBoss.DoPauseProject`.  Blocks until `dsPause`.
Returns: debug state.

#### `stop_debugger`

Stop the debug session.  **Non-blocking** — does not wait for a pause event;
terminates unconditionally.  Safe to call in any state, including after a timeout.

No parameters.

Returns: `{"state": "stopped"}`.

#### `step_over`

Step over the current line (F8).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `timeout_s` | integer | no | Default 10 |

Returns: debug state at the new line.

#### `step_into`

Step into the current call (F7).

Same parameters as `step_over`.

#### `step_out`

Step out of the current procedure (Shift+F8).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `timeout_s` | integer | no | Default 30 |

#### `run_to_line`

Run to a specific line in a file (like F4 but targeting an explicit location).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `file_path` | string | yes | |
| `line` | integer | yes | |
| `timeout_s` | integer | no | Default 30 |

Implementation: set a temporary breakpoint at `(file, line)`, call `RunDebugger`,
remove the temporary breakpoint on pause.  Cleaner than repositioning the cursor
for `DoRunToCursor`.

---

### Group 4 — State inspection (session must be paused)

All tools return an error if `DebugBoss.State <> dsPause`.

#### `get_call_stack`

Return the call stack for the current thread.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `max_frames` | integer | no | Default 20 |

Returns:
```json
[{"index": 0, "function": "TMyClass.DoSomething",
  "file": "UnitFoo.pas", "line": 47},
 {"index": 1, "function": "TMyClass.Run",
  "file": "UnitFoo.pas", "line": 88}]
```

#### `evaluate_expression`

Evaluate a Pascal expression in the current debug context.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `expression` | string | yes | Pascal expression, e.g. `Self.FCount` or `Arr[I]` |

Implementation: `DebugBoss.Evaluate(Expression, ResultStr, TypeInfo, [defFullTypeInfo])`.

Returns: `{"expression": "Self.FCount", "value": "42", "type": "Integer"}`.

#### `get_local_variables`

Return local variables and parameters in the current stack frame.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `frame` | integer | no | Call stack index; default 0 (current frame) |

Implementation: `DebugBoss.Locals` for the selected frame.

Returns:
```json
[{"name": "I", "value": "3", "type": "Integer"},
 {"name": "Self", "value": "{TMyClass}", "type": "TMyClass"}]
```

---

## Out of scope for this ADR

- **Conditional breakpoints** — `TIDEBreakPoint.Condition` exists; deferred until
  the basic set is proven in production.
- **Watchpoints** (data breakpoints) — FpDebug supports them on some platforms;
  too platform-specific for the first pass.
- **Multi-thread debugging** — `DebugBoss.Threads` gives thread list; deferred.
- **Exception breakpoints** — `DebugBoss.Exceptions` collection; deferred.
- **CPUView** — a pure UI layer; no MCP-accessible API surface. Nothing to integrate.
  Its presence in the knowledge base is sufficient for user reference.
- **Remote debugging** — out of scope entirely.
- **Watch management** — `TIDEWatches.Add` / persisted watches; lower value than
  `evaluate_expression` for AI use. Deferred.

---

## Implementation notes

### New unit: `McpToolsDebugger.pas`

Follows the same group-dispatch pattern as all other tool units.  Registers via
`initialization`:

```pascal
initialization
  RegisterMcpGroup(@DispatchDebuggerTool);
  RegisterMcpSchemas(@RegisterDebuggerSchemas);
```

### Why blocking on the worker thread is safe

The MCP server runs tool handlers on `TMcpServerThread` — a worker thread separate
from the IDE main thread.  When a blocking tool calls `RTLEventWaitFor`, it parks
the worker thread only.  The main thread remains free to pump the LCL message loop,
receive `DebugBoss.OnState` / `OnCurrent` callbacks from FpDebug, and signal the
event.  No deadlock is possible.

### Blocking synchronization

```pascal
var
  GDebugEvent : PRTLEvent;   // unit-level; created in initialization

procedure OnDebugStateChanged(AState: TDBGState);
begin
  if AState in [dsPause, dsStop, dsError] then
    RTLEventSetEvent(GDebugEvent);
end;

function WaitForPause(TimeoutMs: Integer): TDBGState;
begin
  { Reset BEFORE issuing the command — not after — so a late-arriving
    signal from a previous timed-out call cannot fire into this wait. }
  RTLEventResetEvent(GDebugEvent);
  // caller issues the command via TThread.Synchronize here
  RTLEventWaitFor(GDebugEvent, TimeoutMs);
  Result := DebugBoss.State;
end;
```

**Stale-event hazard and why reset-before-command fixes it.**  If `step_over`
times out (worker gives up), the program may still pause a moment later and fire
`GDebugEvent` with no waiter.  If the AI then calls `pause_debugger`, a reset
done *after* issuing the command would race against that late signal: the event
could fire between the command and the reset, and the wait would then block
forever.  Resetting *before* the command means the late signal is discarded
cleanly before the new command goes out, so the sequence

```
step_over (timeout) → pause_debugger
```

is always safe regardless of when the step's deferred pause arrives.

Hook `OnDebugStateChanged` into `DebugBoss.OnState` in the tool unit's
`initialization`.  The event is unit-global (only one debug session at a time).

### Annotation

All breakpoint tools: `MCP_ANN_WRITE` (non-destructive write — breakpoints do not
modify source).  
Session-control tools: `MCP_ANN_WRITE` (they modify program state, not source
files).  
State inspection tools: `MCP_ANN_RO`.

---

## Consequences

- Tool count rises from 35 to ~48 (13 new tools across 4 groups).
- AI-driven debugging becomes possible: set breakpoints, run to them, inspect
  locals, step through logic, evaluate expressions.
- The blocking model keeps the AI's mental model simple: every tool returns where
  the program is *right now* after the operation.
- Timeout on step tools surfaces infinite loops as `{"state": "timeout"}` rather
  than hanging the MCP session.
- No existing tools are modified.
- `McpToolsDebugger.pas` is a new compilation unit; add to `lazmcpassistant.lpk`.

---

## As built (v0.8)

### Tools

| Proposed | Built |
|---|---|
| `set_breakpoint` / `remove_breakpoint` / `list_breakpoints` | `debug_set_breakpoint` / `debug_remove_breakpoint` / `debug_list_breakpoints` |
| `get_debug_state` | `debug_get_state` (also reports the session lease, ADR-012) |
| `run_debugger`, `pause_debugger`, `stop_debugger` | `debug_run`, `debug_pause`, `debug_stop` |
| `step_over` / `step_into` / `step_out` / `run_to_line` | `debug_step_over` / `debug_step_into` / `debug_step_out` / `debug_run_to_line` |
| `get_call_stack`, `evaluate_expression`, `get_local_variables` | `debug_get_call_stack`, `debug_evaluate`, `debug_get_locals` |

Added beyond the proposal:
- `debug_set_variable`
- `debug_add_watch`, `debug_remove_watch`, `debug_list_watches`
- `debug_list_threads`
- `debug_get_output`: the program's console output and debugger output
- `debug_get_exception`

From the out-of-scope list, watch management and a read-only thread list were
built. Conditional breakpoints, data breakpoints, address breakpoints, frame/thread
selection, disassembly, registers and memory are planned for v0.9 (README,
*Planned*).

### Waiting: polling, not an event

The proposal had the worker thread wait on an `RTLEvent` set from
`DebugBoss.OnState`. The built tools poll instead:

1. One `TThread.Synchronize` issues the command (`DoIssueCmd`).
2. The worker thread then calls `Synchronize` every 100 ms to read
   `DebugBoss.State` (`PollForPause`). It stops at `dsPause`, `dsStop`,
   `dsError`, `dsNone`, `dsIdle` or `dsDestroying`, or at the timeout.

Why:
- A state-change handler sees transient states. `dsInternalPause`, for example,
  is a pause the IDE resumes by itself. Reading the settled state is simpler than
  filtering events.
- No event has to be reset at the right moment, so the stale-signal hazard
  described above cannot happen.
- A poll costs one short main-thread call; 100 ms is far below how fast an
  assistant reacts.

**Rule that came out of debugging this: never wait inside a `Synchronize`
callback.** The callback runs on the main thread, and while it waits the main
thread delivers no debugger callbacks, so the wait can never end. Every wait
happens on the worker thread, between short `Synchronize` calls.

### Starting a session

`debug_run` and `debug_run_to_line` start through
`LazarusIDE.DoRunProjectWithDebug` (the F9 path), not `DebugBoss.RunDebugger`.
Only the F9 path initializes the debugger backend when no session exists.

`WaitForLaunch` then waits up to 10 s for an *active* state (`dsInit`, `dsRun`,
`dsPause`, `dsInternalPause`). The first version waited for "not idle", which
returned immediately after a previous session: `dsStop` is not idle either (fixed
in 4d4951a).

### Timeouts and results

| Tool | Timeout |
|---|---|
| `debug_run`, `debug_step_out`, `debug_run_to_line` | 30 s (`timeout_s`) |
| `debug_step_over`, `debug_step_into` | 10 s (`timeout_s`) |
| `debug_pause` | 5 s |
| `debug_evaluate` | 5 s |
| `debug_get_call_stack` | 10 s |
| `debug_get_locals`, `debug_list_watches`, `debug_list_threads` | 5 s |

A tool that times out while the program is running returns `reason: "timeout"`;
the session stays live. `file`/`line` in a paused state are the editor position
the IDE jumped to.

### Data that loads asynchronously

Call stack, locals, watch values and threads are loaded by the debugger in the
background. Each of these tools works in two steps:
1. One main-thread call requests the data, once.
2. Read-only polls collect it when nothing is pending any more (`ddsRequested`,
   `ddsEvaluating`).

The first `get_call_stack` returned `[]` or a single frame (fixed in 263bedf):
- It waited for `CountValidity`, which stays unknown unless the backend happened
  to read every frame. It now also accepts "at least `max_frames` + 1 frames".
- It read the frames right away and stopped at the first one still loading. It
  now waits until no frame is pending.

Structured values (objects, records) are printed with the IDE's own watch printer
(`HintWatchPrinter`), as hints and the Watches window show them, and cut at
2000 characters.

`debug_evaluate` starts `DebugBoss.Evaluate` with a callback in one `Synchronize`
and returns at once. The worker thread then polls a flag the callback sets. The
main loop delivers the callback through the async call queue.

### Hang caused by socket inheritance

Early versions hung on the first tool call after starting the debuggee. It looked
like "evaluate fails for locals", but the debugger was not involved. The cause:
1. `fphttpserver` (FPC 3.2.2) serves one request per connection and closes the
   socket without sending `Connection: close`, so the client keeps the
   connection for its next request.
2. The debuggee inherited the server's sockets, as a process the IDE starts
   inherits handles, including that connection.
3. After the server closed its handle, the debuggee's copy kept the TCP
   connection open, so the client never saw it close.
4. The client sent its next request on that connection and waited forever for a
   reply nobody would read.

Fixed in 263bedf: the listening socket and every accepted socket are made
non-inheritable (`SetHandleInformation` on Windows, `FD_CLOEXEC` on Unix), and
every response carries `Connection: close`.

### Covered by later ADRs

- **No IDE modals in sessions these tools drive**: [ADR-011](0011-no-ide-modals-in-mcp-sessions.md).
  Exceptions pause the program and come back as `reason: "exception"`; debugger
  messages come back as `debugger_message`.
- **Several clients**: [ADR-012](0012-multiple-clients.md). The first client that drives the
  debugger owns the session, other clients are refused until it ends, and only
  one debugger call runs at a time. That lock is also what makes the single
  shared `TDbgSyncHelper` instance safe.
- **Tool names**: [ADR-010](0010-tool-naming-scheme.md).

### Known issue

**`debug_evaluate` after a timeout.** The callback of an evaluation that timed
out can still arrive later. It then sets the flag and result fields of the shared
helper, and the next `debug_evaluate` can report it as its own result. Never seen
in testing, since the 5 s timeout has not fired since the socket fix. The fix is a
per-call object, or a sequence number the callback checks.
