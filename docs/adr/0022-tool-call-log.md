# ADR-022 — A tool-call log (`mcp-tools.log`) as evidence for bug reports

**Status:** Proposed (2026-11-05)  
**Date:** 2026-11-05

## Context

When a session goes wrong, people argue from memory. `mcp-sessions.log` (ADR-012) shows how
sessions come and go, not what a client asked the IDE to do; a successful call leaves no
trace but its effect. We want a record good enough to say what was asked, in what order, with
what outcome, including the call that hung or killed the IDE. It can hold code, paths and
secrets, and logs get pasted into issues. It must not depend on the session id, which protocol
revision 2026-07-28 drops (issue #5). It is evidence, not proof: a text file anyone can edit,
and `client` is what the client claimed (only `token` is authenticated).

## Decision

1. **Own file, off by default:** `mcp-tools.log` next to `mcp-sessions.log`. Not that file
   (200 KB; a line per call would push the connection history out within minutes). Not the
   Messages pane yet: `McpCompilerMessages` takes the last view as the compiler's,
   `ide_get_messages` returns every view, `project_open` clears the pane.
2. **JSON Lines, every line has an `event`:**
   - `begin`, written when a `tools/call` arrives: `timestamp`, `seq_id`, `caller`, `tool`.
     It is what remains if the call hangs or takes the IDE down.
   - `end`, written when the call returns to the client: `timestamp`, `seq_id`, `caller`,
     `tool`, `duration_ms`, `response` (`success`; `error` on failure only, cut to 300
     characters), `project`, `args_hash`.
   - `start` at server start and `session` at each `initialize`: plugin version, log format,
     protocol settled on and asked for, Lazarus, FPC, OS, local UTC offset.
   - `timestamp` is ISO 8601 UTC with milliseconds. `mcp-sessions.log` is local time; the
     offset in `start` is how the two are matched.
   - `seq_id` is a per-process counter taken at arrival (atomic), so it is the arrival order;
     lines are written as events happen, so `end` lines can come out of that order. It
     restarts at 1 with the IDE.
   - `caller`: `client` ("name version" from `clientInfo`), `token` (the token's name, never
     its value), `session` (short id, if any).
   - `project`: file name of the project active at the end of the call (so for `project_open`
     the new one), from a copy the main thread keeps in `Run`. Calls that do not run there
     may see a stale one.
   - At Replay, `end` also has `args` (the arguments object) and, on success,
     `response.result` (text only, never image content).

   ```json
   {"event":"end","timestamp":"2026-11-05T20:51:45.196Z","seq_id":42,"caller":{"client":"claude-code 2.1","token":"laptop","session":"d97f7ac2"},"tool":"project_build","duration_ms":8120,"response":{"success":false,"error":"Compilation failed"},"project":"mcpserver_tests.lpi","args_hash":"3fa9c01b77de"}
   ```
3. **Levels:** Off (default), Calls (`begin`/`end` above), Replay (adds `args` and
   `response.result`). Replay records source code and whatever the tools return, so it is for
   the user's own reading before anything is posted; it comes in a later change, once the
   redaction below has tests. Calls costs little in privacy but not nothing: error texts
   can hold paths, and `args_hash` of a short or guessable input can be confirmed by guessing.
4. **`args_hash`:** first 12 hex characters of the SHA-1 (the `sha1` unit, as ADR-021) of the
   `arguments` object *as received*, redacted per 6 but not truncated. `HandleToolsCall`
   rewrites the arguments in place (`McpNormalizePathArgs`, `McpRenameLegacyFileArg`), so the
   hook serializes them before that, and only when the level is not Off. Different inputs
   hash differently, `a/b` and `a\b` included. Serialization is RFC 8785 (JCS), written as
   our own small unit with tests (FPC's `AsJSON` neither sorts keys nor is stable across
   versions). No arguments hash as `{}`. Not hashed: `seq_id`, time, session, JSON-RPC `id`,
   tool name, `_meta`. Twelve hex digits are enough to compare runs (about one collision in
   five million among 10,000 calls). Redaction hides a changed secret: two calls differing
   only in a password hash alike.
5. **Hook:** `HandleToolsCall`, around the whole call. `TMcpServerThread.CallOnMain` is not
   the place: validation and gate refusals never reach it, `McpBlockingDispatch` tools bypass
   it, and `ide_run_tests` and `package_compile` call it again for internal steps. Refused
   calls are logged, with the refusal as `error`. A call the HTTP thread abandons because a
   dialog blocks the main thread (`Abandoned`) gets an `end` line when the thread returns,
   with `error` "dialog open; call still running" and the duration so far. Unknown tool names
   are logged as sent. Failures before a tool name is known (bad `params`, unknown method) are
   not tool calls and stay out.
6. **Redaction (before hashing, so at Calls too) and limits:** never the `Authorization`
   header or a token value. Argument keys that contain `token`, `password`, `secret`,
   `authorization` or `key` (case-insensitive, at any depth, so `env` objects too) become
   `"<redacted>"`. URL user-info and query values named like those keys are removed.
   `project_run_input`'s stdin is not recorded. Best effort: a secret in a free-text value or
   in source being edited is not found. At Replay: strings over 2 KB are cut, keeping their
   length and SHA-1; error text up to 8 KB; a record over 64 KB is replaced by a stub with
   its length and SHA-1.
7. **Writing:** own lock, append and close per line like `McpLogSession`, on the calling
   thread. It never raises. After five failures in a row (full disk, a share that went away)
   the log is switched off for this run and one line says so in `mcp-sessions.log`. Cost is
   measured, not assumed: acceptance is a repeated `ide_ping` with the log on and off.
   Two IDE instances sharing one config folder are not supported.
8. **Rotation:** at 4 MB (size kept in memory, not read per write) `mcp-tools.log` becomes
   `.1`, `.1` becomes `.2`, `.2` becomes `.3`, the old `.3` is dropped (16 MB at most).
9. **Setting:** the level, in `mcpassistantoptions.xml` and on the options page; effective at
   the next call. No limit by listen address (ADR-020): the file is on the IDE's machine
   either way, as exposed as the sources it describes.

## Alternatives considered

- **Raise `mcp-sessions.log`'s cap and add call lines.** Mixes two audiences, and its
  keep-the-newer-half rewrite reads the whole file.
- **The Messages pane.** See decision 1; it stays a possible view over this file.
- **SQLite.** Queryable, but a dependency, a binary file nobody can paste into an issue, and
  a schema to migrate.
- **OpenTelemetry.** The right shape for tracing, but no FPC library exists (surveyed
  2026-10-06). The JSON fields are chosen so that an export stays possible.
- **One line per call, at the end.** Simpler, but loses the call that never ends (decision 2).

## Later

Messages-pane view; a command that bundles both logs and the versions, redacted, for an
issue; replay tooling (needs the project and open files recorded).

## Consequences

A report can carry the last calls, runs can be compared, and a hang leaves its `begin` line.
Costs: two small appends per call when enabled, redaction rules to maintain when a tool gains
an argument that can hold a secret, and hashes that are comparable only within one log
format. Keyed on tool calls, not on the envelope or the session, so it survives #5.

Related: ADR-012, ADR-020, ADR-021; issues #5, #6.
