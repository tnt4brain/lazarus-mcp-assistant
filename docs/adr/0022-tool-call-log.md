# ADR-022 — A tool-call log (`mcp-tools.log`) as evidence for bug reports

**Status:** Proposed (2026-11-05)  
**Date:** 2026-11-05

## Context

When a session goes wrong, people argue from memory. `mcp-sessions.log` (ADR-012) shows how
sessions come and go, not what a client asked the IDE to do. We want a record of what was
asked, in what order, with what outcome, including the call that hung or killed the IDE, and
independent of the session id, which protocol revision 2026-07-28 drops (issue #5). It is
evidence, not proof: a text file anyone can edit, and `client` is what the client claimed
(only `token` is authenticated). It holds no argument values or results: the client keeps
its own transcript, and the server's value is what the client cannot see (order across
clients, timing, refusals, a call that never returned).

## Decision

1. **Own file, off by default:** `mcp-tools.log` next to `mcp-sessions.log`. Not that file
   (200 KB; a line per call would push the connection history out within minutes). Not the
   Messages pane yet: `McpCompilerMessages` reads its last view as the compiler's output, so
   extra lines may be taken for it (untested).
2. **JSON Lines, every line has an `event`:**
   - `begin`, when a `tools/call` arrives: `timestamp`, `seq_id`, `caller`, `tool`. It is
     what remains if the call hangs or takes the IDE down. For every tool: any call can
     stall (a modal dialog, the debugger lock), and a delayed `begin` would miss an early
     crash.
   - `end`, when the call returns to the client: the same, plus `duration_ms`, `response`
     (`success`; `error` on failure only, cut to 300 characters), `project`, `arg_keys`,
     `args_hash`.
   - `start` at server start and `session` at each `initialize`: plugin version, log format,
     protocol settled on and asked for, Lazarus, FPC, OS, local UTC offset.
   - `timestamp`: ISO 8601 UTC with milliseconds (`mcp-sessions.log` is local time; the
     offset in `start` matches the two). `seq_id`: counter taken at arrival, atomic,
     restarting at 1 with the IDE; `end` lines can leave arrival order.
   - `caller`: `client` ("name version" from `clientInfo`), `token` (its name, never its
     value), `session` (short id, if any).
   - `project`: file name of the project active at the end of the call, from a copy the main
     thread keeps in `Run` (stale for calls that do not run there).
   - `arg_keys`: the top-level argument names as received, sorted.

   ```json
   {"event":"end","timestamp":"2026-11-05T20:51:45.196Z","seq_id":42,"caller":{"client":"claude-code 2.1","token":"laptop","session":"d97f7ac2"},"tool":"project_build","duration_ms":8120,"response":{"success":false,"error":"Compilation failed"},"project":"mcpserver_tests.lpi","arg_keys":["clean"],"args_hash":"3fa9c01b77de"}
   ```
3. **`args_hash`:** first 12 hex characters of the SHA-1 (the `sha1` unit, as ADR-021) of the
   `arguments` object as received, secrets redacted (4), nothing cut. Taken before
   `HandleToolsCall` rewrites the arguments in place (`McpNormalizePathArgs`,
   `McpRenameLegacyFileArg`), and only when the log is on. Different inputs hash differently,
   `a/b` and `a\b` included. Canonical JSON from our own small serializer (FPC's `AsJSON`
   does not sort keys): keys sorted by UTF-8 bytes, no whitespace, minimal escapes, floats in
   FPC's shortest round-trip form (build-stable only; `start` names the format); no
   arguments hash as `{}`. Not hashed: `seq_id`, time, session, JSON-RPC `id`, tool name,
   `_meta`. About one collision in five million among 10,000 calls. A fingerprint, not
   protection: a guessable input can be confirmed by guessing.
4. **Redaction, for the hash:** values of argument keys containing `token`, `password`,
   `secret`, `authorization` or `key` (case-insensitive, any depth, `env` objects too)
   become `"<redacted>"`; URL user-info and query values so named are removed. A changed
   secret leaves the hash unchanged. Best effort: free text and edited source are not
   searched.
5. **Hook:** `HandleToolsCall`, around the whole call. Not `CallOnMain`: validation and gate
   refusals never reach it, `McpBlockingDispatch` tools bypass it, and some tools call it
   again for internal steps. Refusals are logged with the refusal as `error`. A call the
   HTTP thread abandons because a dialog blocks the main thread (`Abandoned`) gets an `end`
   with `error` "dialog open; call still running" and the duration so far. Unknown tool names
   are logged as sent; failures before a tool name is known (bad `params`, unknown method)
   are not tool calls and stay out.
6. **Writing:** own lock, append and close per line like `McpLogSession`, on the calling
   thread; never raises. After five failures in a row the log switches itself off for the
   run, with one line in `mcp-sessions.log`. Two IDE instances sharing a config folder are
   not supported.
7. **Rotation:** at 4 MB (size kept in memory) the file becomes `.1`, `.1` becomes `.2`, `.2`
   becomes `.3`, the old `.3` is dropped (16 MB at most).
8. **Setting:** on/off, in `mcpassistantoptions.xml` and on the options page, effective at
   the next call. No limit by listen address (ADR-020). Error texts can hold paths and user
   names; the options page says so.
9. **Assistants are told:** a bullet in `system_prompt.inc` (neither log is mentioned there
   now) and `ide_ping` reporting both log paths and whether `mcp-tools.log` is on, so the
   path is known before a hang, when no tool answers. Then the assistant reads the files
   itself: after a stall, a crash or a restart, the last `begin` without an `end` (by
   `seq_id`) is the call that was running; `mcp-sessions.log` has what the server saw around
   it, including the stack of an access violation. It is told to ask the user before
   enabling the log, and that an `end` line with a long `duration_ms` or the "dialog open"
   error points at a modal dialog.

## Alternatives considered

- **Call lines in `mcp-sessions.log` with a bigger cap:** mixes two audiences; its
  keep-the-newer-half rewrite reads the whole file.
- **SQLite:** a dependency, a binary file nobody can paste into an issue, a schema to migrate.
- **OpenTelemetry:** the right shape, but no FPC library exists (surveyed 2026-10-06); the
  fields keep an export possible.
- **One line per call, at the end:** loses the call that never ends.
- **Recording arguments and results ("replay"):** source code and tool output in a file
  people paste into issues, redaction only best effort, and a re-run would also need the
  project and open files. If reports show values are needed: failed calls only, opt-in, a
  new ADR.

## Tests and acceptance

No IDE needed: serializer (key order, escapes, `{}`), redaction (nested, `env`, case),
rotation, failure switch-off. Cost: 200 `ide_ping` calls with the log on and off, median
difference under 5 ms (a guess; the first run fixes the figure).

## Consequences

A report can carry the last calls, runs can be compared, and a hang leaves its `begin` line.
Costs: two small appends per call when on, redaction rules to maintain when a tool gains an
argument that can hold a secret, hashes comparable only within one log format. Keyed on tool
calls, not the session, so it survives #5. Later: a Messages-pane view; a command bundling
both logs and the versions for an issue.

Related: ADR-012, ADR-020, ADR-021; issues #5, #6.
