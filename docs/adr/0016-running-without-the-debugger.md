# ADR-016 — Running a Program Without the Debugger: Output, Exit Code, Later Attach

**Status:** Accepted (v1.0); decisions 5 and 6 are planned, not built  
**Date:** 2026-10-17

## Context

`project_run` called `DoRunProjectWithoutDebug` and answered `{success}`: the build
succeeded and the IDE started *something*. A client could not learn what the program
printed, whether it crashed, or when it ended. `debug_get_output` needs a debug session,
which is the wrong tool for "run it and tell me what it said".

What the IDE does (`TMainIDE.DoRunProjectWithoutDebug`, `main.pp`):

1. builds the project (`DoBuildProject`);
2. calls `DoCallRunWithoutDebugInit(Handled)`, the `lihtRunWithoutDebugInit` handler
   list, and **returns if a handler set `Handled`**;
3. starts a `TProcessWithRedirect` on a `TNotifyProcessEnd` thread, which frees the
   process when it ends. The exit code is discarded; the "run finished" hook carries
   neither code nor output.

The only output capture the IDE offers is the run parameters' "redirect to file", which
means editing the user's settings, and it gives no exit code and no way to stop the
program. The process object is a local variable, so it cannot be wrapped from outside.

## Decision

1. **We launch the program ourselves, from the IDE's own hook.** `project_run` arms a
   handler registered with `LazarusIDE.AddHandlerOnRunWithoutDebugInit`, then calls
   `DoRunProjectWithoutDebug`. The IDE builds as before; the handler starts the target
   with our own `TProcess` (stdout and stderr on pipes, one reader thread polling both) and sets
   `Handled`, so the IDE starts nothing. The handler acts **only while a `project_run`
   call has armed it**: the user's Run menu behaves exactly as before.
2. **The result carries what happened.** `project_run` waits up to `wait_seconds`
   (default 10) and answers `{success, running, pid, exit_code, stdout, stderr}`. A
   program that is still running (a GUI program, a server) comes back with
   `running: true` and the output so far.
3. **One follow-up tool, `project_run_output`.** It returns the output written since the
   last read, and `exit_code` once the program has ended; `wait_seconds` waits for more
   or for the end; `stop: true` terminates the program. One program per IDE at a time:
   `project_run` while ours is still running is refused with its pid, as the debugger
   allows one session (ADR-012). Output is kept in memory, capped (oldest dropped, with a
   `truncated` flag).
4. **Settings taken from the run parameters, the rest left out.** Command-line arguments,
   working directory and environment come from the project's run parameters, so the
   program runs as the IDE would run it. Not ported: `HideIDEOnRun`, the launching
   application, macOS app bundles and the console window position and size. The tool
   description says so. A program with a pipe has no console window of its own.
5. **Later attach (planned).** The IDE has `TDebugManager.Attach(pid)` and FpDebug
   supports `dcAttach`/`dcDetach` on Windows and Linux. A `debug_attach` tool would let a
   client break into a program started by `project_run` that hangs, then use the
   existing debug tools. It needs DWARF info (as `debug_run` does), the debug lease
   (ADR-012), and `debug_stop` must detach rather than kill. Not built until it has been
   shown to work on a piped process; it cannot catch startup crashes (use `debug_run`).
6. **A pseudo console is an opt-in mode (planned).** On Windows 10 1809+ `CreatePseudoConsole`
   gives the program a real terminal (`isatty`, colors, interactive `Readln`, input
   we can send, `Ctrl+C`). It has no window, and the output is a VT stream that would
   need stripping or interpreting. FPC 3.2.2 has no declarations for it (dynamic loading
   from `kernel32`, `STARTUPINFOEX`), and Linux would need `openpty`. It would be a
   `tty: true` option behind the same tools. A visible mirror console would need a
   helper process and is not planned.

## Alternatives considered

- **Keep the IDE's launch, set redirect-to-file temporarily:** smaller, keeps every IDE
  behaviour, but no exit code, no stop, and it edits the user's run parameters while
  the program starts.
- **Call `DoBuildProject` and launch without the hook:** same launcher, but the build
  bookkeeping and dialog checks of `DoRunProjectWithoutDebug` would be ours to copy.
- **Handler always on:** would also capture the user's own menu runs and take away their
  console window. Rejected (decision 1).
- **Pseudo console first:** the better terminal, but a much larger first step with a
  Windows-only core. Pipes cover most programs and are the base for decision 6.

## Consequences

- `project_run` changes from "started" to "started, and here is the outcome so far";
  clients that ignored the answer are unaffected.
- We own a child process and a reader thread; the plugin kills the program when it is
  unloaded (IDE shutdown). Rebuilding the target while it still runs fails to link on
  Windows, as it does for the IDE's own run; `project_run_output stop=true` ends it.
- The IDE no longer sees the program as its run process, so its own "run finished"
  handlers do not fire for runs started by us; we call `DoCallRunFinishedHandler`
  ourselves when the process ends.
- Tests: `TTestWindows.TestRunOutput` (opt-in suite) generates a console program that
  prints to both streams, takes an argument, exits with 3 or sleeps, and checks output,
  exit code, "still running", the one-at-a-time refusal and `stop`.
