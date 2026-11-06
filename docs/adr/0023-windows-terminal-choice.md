# ADR-023 — The terminal Claude Code starts in on Windows is a setting

**Status:** Accepted and implemented (2026-11-06, v1.3.0)  
**Date:** 2026-11-06

## Context

"Launch MCP Assistant" on Windows started `claude.exe` directly with `poNewConsole`
(ADR-002, Option C). Windows decides which window hosts it: the console host, or Windows
Terminal when that is the system's default terminal, and the plugin has no say. Linux and
macOS have a terminal command with auto-detection (`TerminalCommand`); Windows had nothing.
People want a particular host: PowerShell or `cmd` for their profile and PATH, Windows
Terminal for tabs, profiles and a real clipboard (Ctrl+C and Ctrl+V; the legacy console wants
Mark and Paste from its menu), Git Bash (Claude Code itself uses it on Windows), or their
own. ADR-002 deferred an embedded terminal; this is the cheap alternative (issue #8).

## Decision

1. **A Terminal setting on the options page, Windows only.** Stored in
   `mcpassistantoptions.xml` as `Claude/WinTerminal` (`default`, `cmd`, `powershell`, `wt`,
   `gitbash`, `custom`) and `Claude/WinTerminalCustom`. `default` is today's behaviour and
   the value of a settings file that has none. The page lists Default, Custom and the hosts
   found installed: `cmd` (`%ComSpec%`), `pwsh.exe` (`Program Files\PowerShell\7`, or on
   PATH) else `powershell.exe`, `wt.exe` (the App Execution Alias in
   `%LOCALAPPDATA%\Microsoft\WindowsApps`, looked at first: `ExeSearch` may not see it), and
   Git for Windows (its registry key, then `Program Files\Git`). A saved choice whose host
   is gone shows as Default. Linux and macOS keep `TerminalCommand`.
2. **Every choice but Default runs a generated script, not a composed command line.** Nested
   quoting through `cmd /k`, `-Command` and `wt` is where this would break: paths with
   spaces (`D:\Program Files`, a user name) and the `--mcp-config` and extra-argument
   values. Each host gets a file in the temp folder and is told to run it:
   - Command Prompt: `lazarus-mcp-launch.cmd` (CRLF, `chcp 65001`, `%` doubled),
     `cmd.exe /k <script>`.
   - PowerShell: `.ps1` (UTF-8 with a BOM, or non-ASCII paths break in Windows PowerShell),
     `-NoExit -ExecutionPolicy Bypass -File <script>`.
   - Windows Terminal: the `.cmd`, `wt.exe [--pos x,y] [-d <dir>] cmd.exe /c <script>`.
     `/c`, so the tab closes when Claude exits; a failure keeps it open by `wt`'s own
     default.
   - Git Bash: the existing `sh` script with `/c/...` paths, `bash.exe --login <script>`.
   The `claude.exe` lookup and `--mcp-config` and `--strict-mcp-config` stay as they were;
   only the host changes.
3. **Custom is an executable plus an argument template.** Placeholders: `{dir}`, `{script}`
   (the `.cmd`), and `{cmd}`: as a whole argument it becomes `cmd.exe`, `/c`, the script
   (three arguments); inside a longer argument, the same text on one line. `"Double quotes"`
   group an argument. An empty template is an error, not a guess.
4. **Settings-only.** The choice and the custom command are read and written on the
   options page; no MCP tool may touch them: the custom one is an arbitrary executable
   started on a menu click.
5. **The terminal opens on the IDE's monitor.** At the top-left of the work area of the
   monitor the IDE's main window is on, plus 60 px. Console hosts and Custom get it from
   `TProcess` (`suoUsePosition`, the Windows startup info); checked: a window asked for
   2100,150 came out at 2100,150. Windows Terminal ignores the startup info and opens where
   it was last, so it gets its own `--pos x,y`.

## Known limit (left as it is: YAGNI)

`wt --pos` takes no negative coordinates. Tried with `-100,60` and `--pos=-100,60`: the
window opens at the primary monitor's corner, y reset too. So with the IDE on a monitor left
of or above the primary one, Windows Terminal opens on the primary monitor. Not tried on such
a monitor: none was at hand. Checked fine on the monitor right of the primary one and on the
one below that. If someone needs it: start `wt`, find its new
`CASCADIA_HOSTING_WINDOW_CLASS` window and move it with `SetWindowPos`, which takes any
coordinates.

## Rejected

- **An embedded terminal** (ADR-002): still the larger job.
- **Composing one command line per host:** the quoting problem above.
- **Picking the host without a setting:** the user's profile, PATH and clipboard habits
  differ; Default stays what it was.
- **Exposing the setting to MCP tools:** see 4.

## Tests

`TTestLauncher` covers the three scripts, `McpWinToBashPath`, the argv of every choice
(including `--pos` and the custom templates) and the placeholder substitution, all pure
functions; `TTestSettingsFile` the keys and the default. Opening each terminal needs a
manual check on Windows: done for PowerShell through the plugin's menu, and for Command
Prompt, Git Bash and Windows Terminal with the same `TProcess` calls in a harness.
