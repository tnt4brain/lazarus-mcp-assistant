# ADR-022 — A tool-call log (`mcp-tools.log`) as evidence for bug reports

**Status:** Accepted and implemented (2026-11-06)  
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
   does not sort keys): keys sorted by UTF-8 bytes, no whitespace, minimal escapes, floats with
   15 digits, or 17 when 15 do not read back the same (build-stable only; `start` names the format); no
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
   with `error` the message the client was given (it names the dialog) and the duration so
   far. Unknown tool names
   are logged as sent; failures before a tool name is known (bad `params`, unknown method)
   are not tool calls and stay out.
6. **Writing:** own lock, append and close per line like `McpLogSession`, on the calling
   thread; never raises. `end` is written from a `finally`, so a tool that raises still
   gets one. After five failures in a row the log switches itself off for the
   run, with one line in `mcp-sessions.log`. Two IDE instances sharing a config folder are
   not supported.
7. **Rotation:** at 4 MB (size kept in memory) the file becomes `.1`, `.1` becomes `.2`, `.2`
   becomes `.3`, the old `.3` is dropped (16 MB at most).
8. **Setting:** on/off, in `mcpassistantoptions.xml` and on the options page, effective at
   the next call. No limit by listen address (ADR-020). Error texts can hold paths and user
   names; the options page says so.
9. **Assistants are told:** a bullet in `system_prompt.inc` (neither log is mentioned there
   now) and `ide_ping` reporting `logs` (the paths of the three logs, and `tools_enabled`), so the
   path is known before a hang, when no tool answers. Then the assistant reads the files
   itself: after a stall, a crash or a restart, the last `begin` without an `end` (by
   `seq_id`) is the call that was running; `mcp-sessions.log` has what the server saw around
   it, including the stack of an access violation; `mcp-exceptions.log` (also in the config
   folder, what `ide_get_exceptions` reads) has the IDE's own exceptions. It is told to ask
   the user before enabling the log, and that an `end` line with a long `duration_ms` or an
   error naming a dialog points at a modal dialog.

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
rotation, failure switch-off, and that `end` is written when the tool raises. Cost: 200
`ide_ping` calls with the log on and off, median difference under 5 ms. Measured beforehand
(2026-11-06, this Windows machine, 2,000 appends of a 330-byte line, open/append/close each
time): median 0.11 ms, 99th percentile 0.28 ms, worst 4 ms; SHA-1 of 1 MB of arguments 2.5 ms.
Two appends per call are far below the limit; the worst single append is not.

## Consequences

A report can carry the last calls, runs can be compared, and a hang leaves its `begin` line.
Costs: two small appends per call when on, redaction rules to maintain when a tool gains an
argument that can hold a secret, hashes comparable only within one log format. Keyed on tool
calls, not the session, so it survives #5. The Messages-pane view and the report bundle came
with Amendments 1 and 2.

## Amendment 1 — a report bundle (accepted and implemented, 2026-11-06)

**Status:** Accepted and implemented

A bug report needs the same few facts every time: versions, settings, packages, the last
lines of the three logs. People paste them by hand and forget half. One command collects
them into a single Markdown file.

1. **Triggers:** the tool `ide_report` and a menu item Tools > MCP Assistant > Write report.
   Both write the same file; the tool returns its path, the menu item shows it in a message.
2. **Output:** `mcp-report-<UTC timestamp>.md` in the config folder, never overwritten; the
   three newest are kept. Nothing is sent anywhere.
3. **Contents:**
   - plugin version and git hash, log format, Lazarus, FPC, OS and CPU, UTC offset, protocol
     revisions the server speaks;
   - plugin settings that are safe to show (listen address and port, on/off switches); tokens
     by name only, never the value;
   - the active project's settings and the installed and project packages (what
     `project_get_settings`, `package_list` and `project_list_packages` return), since a
     missing or wrong package explains many reports;
   - the last 200 lines of `mcp-tools.log`, `mcp-sessions.log` and `mcp-exceptions.log`, each
     under its own heading; an absent or switched-off log says so.
4. **Redaction:** the user's home directory becomes `~`; the user name elsewhere is not
   searched for; secrets are not in the sources (hashes are kept out of settings, tokens by
   name). Best effort, as in decision 4: the page says to read the file before posting it.
5. **Size:** capped at 256 KB; log sections shrink first, newest lines kept, with a line
   saying how many were cut.
6. **Independent of the tool-call log:** works with it off, then that section says so.
7. **Tests:** the builder is plain code over strings and a few records (no IDE): section
   order, home-directory replacement, the cap, a missing log. The tool and menu item get one
   live check each.

## Amendment 2 — a Logging page and a live view of calls (accepted and implemented, 2026-11-06)

**Status:** Accepted and implemented

1. **Page:** Tools > Options > MCP Assistant > Logging, replacing the Diagnostics group on
   General, with three settings: log tool calls to a file, the file's path (empty: the default
   `mcp-tools.log` in the config folder; rotated copies sit next to it), and show calls in the
   Messages window.
2. **Live view:** with the third setting on, each finished call adds one line to the
   `MCP Server` view: `tool  <ms> ms`, urgency progress; a failed call adds `  failed: <error>`
   (one line, cut at 120 characters), urgency important. At the end of the call, not the start:
   the file keeps the `begin` line for a call that never ends.
3. **Independent:** the file and the view work separately; either, both or neither.
4. **Threading:** the line is made on the HTTP thread and added on the main thread through
   `Application.QueueAsyncCall`, so a busy main thread never holds a call back. The lines carry
   the `MCP Server` SubTool (`skip_own` on `ide_get_messages` leaves them out).
5. **Settings keys:** `Logging/ToolCallLog`, `Logging/ToolCallLogFile`, `Logging/ToolCallPane`;
   the old `Tools/ToolCallLog` is read once and removed on the next save.
6. **Dropped:** recording arguments and results ("replay") is not planned; the rejected
   alternative above stays as the reason.

Related: ADR-012, ADR-020, ADR-021; issues #5, #6.
