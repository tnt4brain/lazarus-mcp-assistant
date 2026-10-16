# ADR-011 — No IDE Modals in MCP-Driven Sessions

**Status:** Accepted (v0.8)  
**Date:** 2026-10-14

## Context

Every MCP tool runs inside the IDE process, and IDE-API work runs on the main thread
via `TThread.Synchronize`. When the IDE shows a modal dialog, two things happen:

- The main thread sits in the dialog's modal loop. Every later `Synchronize` call
  still runs (the modal loop processes them), but the IDE is in a state the
  assistant can't see.
- Worse, some IDE paths **wait for the answer**. For example,
  `TDebugManager.DoRunProject` won't start a new session until the
  "Execution stopped" dialog of the previous one is closed. Until then,
  `debug_run` silently reported `state=stopped`.

The assistant can't see or click dialogs. Often nobody is at the keyboard either,
because the user is away and the assistant works unattended. This rules out any
dialog that waits for a click.

Modals that turned up in practice:

| Dialog | Trigger | Shown by |
|---|---|---|
| "Execution stopped" / exit code | debuggee ends or `debug_stop` | `TDebugManager` after `dsStop` |
| Exception dialog (`TIDEExceptionDlg`) | debuggee raises | debugger `OnException` → IDE handler |
| Debugger feedback ("Failed to modify value", warnings) | debugger errors | debugger `OnFeedback` → IDE handler |
| "Some files have changed on disk" (`TDiskDiffsDlg`) | an agent wrote files the IDE has open | IDE focus/timer check |

## Decision

### 1. Prevent the dialog, don't click it

Clicking a visible dialog from code was tried first: posting `BM_CLICK`, then
mouse messages to the TaskDialog's button. It works, but it is fragile:

- the timing depends on the modal loop
- the window class depends on the widgetset
- the dialog is already showing by the time we react

So the primary mechanism is to make the IDE never decide to show the dialog. For the
debugger, `McpDebugGuard.pas` does this:

- **State-change handler.** `DebugBoss.RegisterStateChangeHandler`. Our handler
  is registered after the IDE's own, but it is called before `TDebugManager`
  decides whether to show "Execution stopped". On `dsStop` it calls
  `SetSkipStopMessage`.
- **Event wrapping.** It wraps the debugger's `OnException`, `OnFeedback`,
  `OnConsoleOutput` and `OnDbgOutput`. The IDE re-assigns these each time it
  initialises a debugger, so the wrap is re-checked on every state change
  rather than installed once.
  - Exception: recorded in `GMcpLastExc` (class, message, file, line, address,
    function, sequence number). `AContinue := False`, so the debuggee breaks at
    the raise and no dialog appears. `debug_run` and `debug_step_*` return
    `reason: "exception"` with the record inline, and `debug_get_exception`
    re-reads it. The IDE's ignore list still applies: ignored exception classes
    never reach the handler.
  - Feedback: answered `frOk`, or `frStop` if OK isn't offered. The text is
    returned once as `debugger_message` on the next debugger tool response.
  - Console and debugger output: appended to capped buffers (2000 lines) for
    `debug_get_output`, then forwarded to the IDE unchanged.

### 2. Only for sessions MCP drives

`GMcpDriven` decides between suppressing a dialog and forwarding it:

- It is set on the main thread by every MCP debugger command that runs, steps
  or stops the debuggee (`McpMarkDebugDriven`).
- It is cleared when the session ends.
- Sessions the user starts with F9 and drives by hand keep the IDE's normal
  dialogs. A person at the keyboard expects them, and suppressing them would hide
  information from that person.
- Exceptions and output are *recorded* in every session, so an assistant can still
  inspect a session the user started.

This choice was confirmed with the user over the alternative of suppressing the
dialogs IDE-wide.

### 3. Fallback for the dialogs we can't prevent: answer them during a tool call

`McpIdeListeners.pas` watches `Screen.OnActiveFormChanged`.

`GMcpToolCallsActive` counts the `tools/call` requests that are running, using
interlocked increment and decrement in `HandleRPC`. While it is above zero, an MCP
request is in flight, so nobody can be expected to answer a dialog. These known
dialogs are then answered with a deferred `ModalResult`:

- `TDiskDiffsDlg` gets OK. Only files without unsaved editor changes are
  pre-checked, so this reloads exactly the files an agent changed and keeps
  the user's unsaved edits.
- `TIDEExceptionDlg` gets Break (`mrOK`), but only when `GMcpDriven` is set. This
  dialog should no longer appear, because of decision 1.

The answer is queued with `Application.QueueAsyncCall`. The form activates before
its modal loop starts, and `ShowModal` would reset a `ModalResult` set any earlier.

The fallback is matched on class name. Unknown dialogs aren't answered: guessing
"OK" on an unknown question is worse than blocking.

## Alternatives considered

- **Suppress the dialogs IDE-wide.** That is simpler, but it changes the IDE for the
  human user, who never asked for it.
- **Click the dialog from a watchdog.** Rejected for the reasons in decision 1. It was
  kept only as a manual testing aid (see the project memory notes).
- **Change the IDE's environment options**, such as "show exit-code message". That is
  global and persistent, it isn't restored if the IDE crashes, and there is no
  option for every dialog.
- **Run the debugger out of process (own gdb/FpDebug instance).** That would bypass
  the IDE completely, but lose breakpoints, watches and the source editor
  integration the user sees, which are the point of an in-IDE assistant.

## Consequences

- MCP-driven sessions run without dialogs. Verified: an exception at the raise line
  was reported inline, and `debug_stop` showed no "Execution stopped".
- Wrapping the debugger events depends on IDE internals: `SetSkipStopMessage`, the
  order of `RegisterStateChangeHandler`, and the IDE re-assigning the events.
  When upgrading Lazarus, re-check `TDebugManager.DebuggerChangeState`.
- Not yet verified live:
  - the `TIDEExceptionDlg` fallback (decision 1 prevents the dialog first)
  - the disk-diffs auto-answer
  - console capture for a console debuggee
- Other startup modals aren't handled, for example "project has no debug info,
  change options?" or "Stop the running session?" when `project_build` runs during
  a session. The second one is one reason for the debug session lease (ADR-012),
  which keeps other clients from building while a session is live.

## Amendment (2026-10-17): dialogs we can't prevent are reported, not answered

Decision 3 answers a few known dialogs and leaves the rest blocking. A tool call
waiting behind such a dialog hung with nobody told why (a "Broken dependency" box
made every later build return `success: false, errors: []`; "project has no debug
info" made `debug_run` return `idle`). Answering unknown dialogs is still ruled out.
What changed is that they are now **seen and reported**:

- **`McpDialogWatch`** wraps `LazMessageWorker`/`LazQuestionWorker`, the two hooks all
  `IDEMessageDialog`/`IDEQuestionDialog`/`MessageDlg` calls pass through (cross-platform).
  While such a dialog is up it is listed with caption, text and buttons. On Windows it
  also lists `#32770` dialog windows of the main thread that the hooks did not see
  (a `TTaskDialog`, a plain `MessageBox`), with their title and readable control text.
  It reads from any thread, because the main thread is the one that is stuck.
- **Main-thread tool calls are queued and waited for**, not synchronized. If a dialog
  stays open for 2 s while a call is pending, the call returns an error that names
  the dialog and says it may still complete once the dialog is closed. `project_build`,
  `project_run`, `project_create`, `project_open` and the IDE side of `package_compile`
  are refused up front when a dialog is already open ("Not started").
- **`debug_run`/`debug_run_to_line` check first** what the IDE would ask about
  (the debugger needs DWARF debug info, or an external/internal symbol file) and refuse
  with the setting to change (`project_set_settings` `debug_info`).
- **A session that ends during a debugger command** is reported as `reason: "exited"`
  with `exit_code` instead of `idle`.

Not done: reading a `TTaskDialog`'s text (it lives in DirectUI controls that
`GetWindowText` can't read; the dialog's own Ctrl+C copies it). Its title and buttons
are reported.
