# ADR-022 — A tool-call log (`mcp-tools.log`) as evidence for bug reports

**Status:** Proposed (2026-11-05)
**Date:** 2026-11-05

## Context

When a session goes wrong, people argue from memory. `mcp-sessions.log` (ADR-012) shows how
sessions come and go, not what a client asked the IDE to do; a successful call leaves no
trace but its effect. We want a record good enough to say what was asked, in what order, with
what outcome. It can hold code, paths and secrets, and logs get pasted into issues; a call
must never fail or slow down because of it; and it must not depend on the session id, which
protocol revision 2026-07-28 drops (issue #5).

## Decision

1. **Own file, off by default:** `mcp-tools.log` in the config folder. Not
   `mcp-sessions.log` (200 KB; a line per call would push the connection history out within
   minutes). Not the Messages pane yet: `McpCompilerMessages` takes the last view as the
   compiler's, `ide_get_messages` returns every view, `project_open` clears the pane.
2. **JSON Lines, one object per finished call:** `t`, `seq`, `caller` (`client` as
   "name version", `token` name, `session` short id if any), `tool`, `ms`, `ok`, `project`
   (file name or empty), `args_hash`, the error text on failure, and at Replay `args` and
   `result`. A `session` record at each `initialize`: plugin version, protocol settled on and
   asked for, Lazarus, FPC, OS.
3. **Levels:** Off (default), Calls (all of the above except `args` and `result`), Replay
   (adds them). Calls first: no privacy cost. Replay in a later change, once the redaction
   below has tests.
4. **`args_hash`:** first 12 hex characters of the SHA-1 (the `sha1` unit, as ADR-021) of the
   canonical JSON of the `arguments` object alone: keys sorted, no insignificant whitespace,
   values as received, so `a/b` and `a\b` differ (different inputs). Not hashed: `seq`, time,
   session, JSON-RPC `id`, tool name, `_meta`. Computed after redaction, so it cannot confirm
   a guessed secret.
5. **Hook:** `TMcpServerThread.CallOnMain`, which every call passes: refused calls, calls the
   caller gave up on (logged when they finish, with the real duration), normal ones. The
   project name is read on the main thread (in `Run`). Own lock, append and close per line
   like `McpLogSession`, never raises.
6. **Redaction and limits (Replay):** never the `Authorization` header or a token; argument
   keys matching `token|password|secret|authorization|key` become `"<redacted>"`; URL
   user-info removed; `project_run_input`'s stdin not recorded; strings over 2 KB cut, keeping
   their length and hash; error text up to 8 KB.
7. **Rotation:** at 4 MB `mcp-tools.log` becomes `.1`, `.1` becomes `.2`, `.2` becomes `.3`,
   the old `.3` is dropped (16 MB at most).
8. **Setting:** the level, in `mcpassistantoptions.xml` and on the options page; effective at
   the next call. No limit by listen address (ADR-020): the file is on the IDE's machine
   either way, as exposed as the sources it describes.

## Later

Messages-pane view (after testing the interference above); a command that bundles both logs
and the versions, redacted, for an issue; replay tooling (needs the project and open files
recorded).

## Consequences

A report can carry the last calls, and runs can be compared. Costs: a small append per call
when enabled, and redaction rules to maintain when a tool gains an argument that can hold a
secret. Keyed on tool calls, not on the envelope or the session, so it survives #5.

Related: ADR-012, ADR-020, ADR-021; issues #5, #6.
