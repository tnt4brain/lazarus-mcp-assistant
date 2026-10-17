# ADR-019 — debug_attach: the IDE's attach path without its dialog

**Status:** Accepted (v1.0)  
**Date:** 2026-10-17

## Context

`project_run` (ADR-016) starts the program on pipes, with no debugger. For a program that
hangs, loops or fails in a way its output does not explain, the assistant had to stop it
and start over under `debug_run`, losing the state it wanted to look at. ADR-016 planned
attaching the debugger to the process that is already running.

The IDE has Run > Attach. `ecAttach` in `main.pp` does three things: `DebugBoss.InitDebugger
([difInitForAttach])`, a process list dialog (`GetPidForAttach`), then `ToolStatus :=
itDebugger` and `DebugBoss.Attach(pid)`. FpDebug supports `dcAttach` on Windows and Linux.

## Decision

1. **`debug_attach {pid, timeout_s}`** repeats the IDE's three steps on the main thread
   without the dialog (`TDbgSyncHelper.AttachStart`): refuse unless `ToolStatus = itNone`,
   `InitDebugger([difInitForAttach])`, `ToolStatus := itDebugger`, `Attach(pid)`. The
   debug manager attaches from its own timer, so the tool, a blocking one on the worker
   thread, polls the state as `debug_run` does and answers with it (`paused`, or
   `timeout` while the program still runs after attaching: `debug_pause` follows).
2. **The pid comes from the caller.** `project_run` answers with it. Any other process
   the IDE's user may debug can be named; the debugger decides.
3. **Windows: the main thread is made current**, as for `debug_pause`: the same
   `MoveToMainThread` helper, and the answer carries `thread`, `thread_function` and a note.
4. **`debug_stop {detach: true}`** calls `DebugBoss.Detach`, so the program keeps running.
   A plain `debug_stop` ends an attached program, as it ends any debugged one: on Windows
   the debugger does it, on Linux FpDebug lets the process go on, so the tool sends SIGKILL
   to the pid it attached to.
5. **A failed attach is an error, not a state.** Nothing started within 10 s (wrong or
   dead pid, no permission, no debug information): the tool puts the IDE's tool status
   back (`DoStopProject`) and says so, with the debugger's own message when it gave one.
6. Debug leasing (ADR-012) applies as for every `debug_*` tool: one session, one owner.

## Alternatives considered

- **Attach inside `project_run`** (a flag): the program starts before anyone knows it
  will misbehave; attaching later is the useful case.
- **Our own `TProcess` handed to the debugger** (start under the debugger from the
  beginning): that is `debug_run`, with the IDE's own console handling.
- **Driving the IDE's process list dialog:** modal dialogs are never answered by us
  (ADR-011).

## Consequences

- The program needs debug information, as for `debug_run`; without it the attach works
  but the stack has no source lines.
- On Linux the kernel must allow ptrace of the target (a child of the IDE does, which
  covers `project_run`; other processes depend on `kernel.yama.ptrace_scope`).
- Attaching leaves the program in `running` after the attach on Windows (observed); a
  `debug_pause` then stops it. Output the program wrote before is still in
  `project_run_output`.
- Tests: `TTestProjectRuns.TestAttach` (Windows and Linux): wrong pid, missing pid,
  attach, pause, stack reaches the program's own file, one session at a time, detach keeps
  it running, attach again, plain stop ends it.
