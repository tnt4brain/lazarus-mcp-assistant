# ADR-036 — Progress notifications and cancellation of running tool calls

**Status:** Accepted (2026-11-25), for 1.9.0. Timings (5 s, 15 s) and the debugger-wait rule confirmed by the maintainer.
**Date:** 2026-11-25

## Context

Some calls take minutes: `project_build`, `package_compile`, `ide_run_tests`, `project_run`, `debug_run`
and `debug_step` (they wait for the program to pause), the git verbs that talk to a remote, `git_clone`. Today
the client sees nothing until the end, and it cannot stop one: an interrupt in the client only abandons its side,
and the IDE keeps building.

What the client does (measured 2026-11-25 with Claude Code 2.1.330 against a throw-away server, see the memory note
and `PLAN_2.0.md` section 3):

- It puts `_meta.progressToken` on every `tools/call`.
- It accepts an answer to the POST that is `text/event-stream`: `notifications/progress` events, then the result.
- On interrupt it sends a **separate** POST `notifications/cancelled` `{requestId, reason}` and does **not** close
  the connection of the call. A server that ignores the notification keeps streaming.
- Its docs: progress resets the idle timeout only; the per-server wall-clock `timeout` is not extended.
- A first call on connect, `server/discover` (protocol 2026-07-28), is answered today with `-32601` and an id: fine.

What the server can do: `fphttpserver` streams (spike of 2026-11-24, `tools/spike_stream`): `Threaded := True`
gives every connection its own thread, and a handler can set `text/event-stream`, call `SendHeaders` and write
frames to the connection socket. So the HTTP layer stays, and the cancel notification arrives on a thread of its
own while the call is still running.

Measured 2026-11-25 (the `nested:` line of the session log, commit 04c5d6d): while the main thread is inside an IDE
call that pumps messages (a build), the next queued call runs inside it. That is what makes a cancel of a build
possible, and it is also why a cancel must not be a tool the client calls.

## Decision

### 1. Progress is lazy and generic first

A helper thread of the call (`McpProgress`) does the streaming; the request thread cannot, because
the blocking tools (git, lazbuild) occupy it. Only one thread writes to the socket at a time: the helper until the call ends, then the request thread (the last event):

- If the client sent a `progressToken` **and** `Accept` allows `text/event-stream`, and the call has run for
  **5 s**, the helper answers with `Content-Type: text/event-stream` (`Connection: close`, no length) and from then
  on sends a `notifications/progress` event about every **15 s** (the first one the moment the stream starts): `progress` = seconds elapsed (a number that only
  grows, as the spec asks), no `total`, `message` = "still running" plus the last line the tool reported (item 2).
- A call that ends before 5 s, or a client without a token, gets today's plain JSON answer, byte for byte.
  Nothing changes for them.
- The result goes out as the last event (`event: message`), then the connection closes.
- The token is cloned and echoed as it came (integer or string).

The heartbeat needs no support from any tool and is what keeps a client's idle timeout from firing.

### 2. A tool may say what it is doing

`McpProgressSay(AMessage)` (McpProgress, on the call's own thread, so a tool needs no parameter) stores the latest message under a lock;
the helper picks it up at its next heartbeat. Only the last message counts; nothing queues without bound.
Built: the process runner (the last output line of the child). Not built (heartbeat only): the IDE build's
Messages line, the test name of `ide_run_tests`. A tool that does not call it still gets the
heartbeat.

### 3. Cancellation: a registry, a flag, and rules per kind of tool

- Every running `tools/call` is entered in a registry under a lock: session id, JSON-RPC request id, tool name,
  a cancel flag (`LongInt`, set with `InterlockedExchange`), and the request thread's wake event.
- `notifications/cancelled` is handled on its own request thread: it finds the entry with the **same session** and
  the same request id (a cancel from another session is ignored and logged), sets the flag, logs
  `cancel: <tool> after N s (<reason>)`, answers 202. An unknown id, or a call that already ended, is ignored: the
  spec says so.
- A tool looks at the flag where it already waits (on the main thread through a copy the request thread makes every 250 ms). What cancelling means depends on the tool; **nothing that changes
  files is ever stopped half way**:

| Kind | Tools | Cancel does |
|---|---|---|
| Child process | git verbs, `git_clone`, lazbuild, instantfpc, the tests exe | `McpRunCapture` gets an optional flag pointer; it terminates the child as for a timeout and returns `reCancelled` with the output so far |
| IDE build | `project_build`, `package_compile`, the build step of `ide_run_tests` | the request thread queues `LazarusIDE.AbortBuild` to the main thread; it runs inside the build (measured above) and ends the external tools; the tool returns "build cancelled" |
| Program run | `project_run`, `project_run_output` | ends the **wait** only; the program keeps running (`project_run_output stop=true` ends it), the answer says so |
| Wait for the debuggee | `debug_run`, `debug_step`, `debug_run_to_line`, `debug_attach` | ends the **wait** only (`reason: "cancelled"`); the program keeps running (stopping it is `debug_pause` / `debug_stop`, the client's choice) |
| Long search | `code_find_references` (the other searches have no chunks to stop between) | checked between the 25-file chunks that max_seconds already needs (1.9.0): returns what it has with `truncated: true` |
| Everything else | edits, saves, renames, form tools, `ide_rebuild`, `package_install` | ignored; the log says "cancel ignored: <tool> cannot be cancelled" |

- What the cancelled call answers: a normal result with `isError: true` and the text
  "Cancelled by the client after N s: ..." plus what was done. The client has usually gone, but a client that has
  not (Claude Code keeps the connection) gets an answer instead of a hang.
- A write to the socket that fails (the client closed the connection) is the same as a cancel.

### 4. What stays as it is

- No new tool, no change of any schema or description, no new capability in `initialize` (progress and cancel
  are in the base protocol).
- The 20-second warning of `CallOnMain`, the dialog watch and the "abandoned call" path stay; the registry entry is
  removed on every way out of the wait.
- Auth, Origin and session checks run before any of this, unchanged.
- `Connection: close` stays (the end of a stream is the close).

## Consequences

- One real change to the transport (the answer of one method can be a stream) and a small change to
  `McpRunCapture` (an optional flag), none to the tool schemas.
- A client without a token, and Claude Code for quick calls, see no difference.
- Whether the interactive Claude Code shows the progress is **not known** (the `-p` mode shows nothing); the
  heartbeat is worth having for the idle timeout alone.
- The wall-clock `timeout` of Claude Code is not extended by progress; for builds longer than that, its own
  setting has to be raised. Noted in `docs/tools.md`.
- Cancelling a build relies on the nested call; if a future IDE stops running queued calls inside a build, the
  cancel of a build degrades to "ignored" (a test pins the behaviour).

## Tests

All over HTTP, with a test-only tool behind `MCP_TEST_HOOKS` that sleeps for N seconds, reports a message and
honours the flag (the real tools are exercised in the second group):

1. No token: plain JSON, identical to today.
2. Token, a 7 s call: `text/event-stream`, at least one `notifications/progress` with the same token, the result
   last; `progress` grows.
3. Token, a call of 1 s: plain JSON.
4. Cancel on a second connection ends the 30 s call within 1 s and the answer says "Cancelled".
5. Cancel from another session, an unknown id, and a late cancel change nothing.
6. No call is left in the registry after calls ended (a closed stream is not tested: the heartbeat finds out only
   on its next write, 15 s later).
7. `server/discover` answers `-32601` with its id.
8. Cancel reaches a tool on the main thread (`__test_slow_main__`), and a clean build of the plugin package
   (`package_compile`, opt-in with `MCP_DEBUG_TESTS=1`) is aborted. A child process is cancelled in
   `tmcpprocess.pas`. Not tested automatically: `git_fetch` against a stalled remote, the debugger waits,
   `project_run`, `code_find_references`.

The matrix of three Lazarus versions on Windows and Linux runs them all; the build cancel is the part to watch on 5.0.

## Not done here

Tasks (long jobs polled later), `listChanged` and subscriptions need a GET stream; they build on this transport
but are their own ADRs. A `total` for builds (the compiler does not know it). Progress for `ide_rebuild` (the
IDE restarts).
