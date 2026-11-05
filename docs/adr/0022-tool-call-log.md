# ADR-022 — A tool-call log (`mcp-tools.log`) as evidence for bug reports

**Status:** Proposed (2026-11-05)
**Date:** 2026-11-05

## Context

When a session goes wrong, the people involved (a user, the maintainers, a contributor
sending a pull request) argue from what each remembers. `mcp-sessions.log` (ADR-012)
records how sessions come and go (initialize, 404, DELETE, server start, token events,
hang warnings, crash traces) but not what a client asked the IDE to do. A successful
`editor_edit_text` or `project_build` leaves no trace except its effect on the project.
What is wanted is a record good enough to say what was asked, in which order, with what
outcome, and, where the IDE state allows, to repeat it.

Constraints: the log can hold source code, paths and secrets, and logs get pasted into
issues; a tool call must never fail or slow down because of its log; and ADR-012's
identity model (the session id) is not the only possible one: the protocol revision
2026-07-28 has no sessions (issue #5), so the record must not depend on one.

## Decision

1. **A separate file, off by default.** `mcp-tools.log` in the IDE's config folder, next
   to `mcp-sessions.log`. Not the same file: the session log is small (about 200 KB,
   keeps the newer half) and a line per call would push the connection history out within
   minutes. Not the Messages pane (yet): `McpCompilerMessages` reads the last view as the
   compiler's, `ide_get_messages` returns every view, and `project_open` clears the pane.
2. **JSON Lines, one object per finished call.** UTF-8, one line each, so it can be
   filtered with any tool and parsed by a replay script:
   `t` (local time, ms), `seq` (counter since the server started), `caller` (object: `client`
   as `name version` from `clientInfo`, `token` as the token's name, `session` as the short id
   when there is one), `tool`, `ms`, `ok` (false when the call raised or answered with an
   error), `project` (file name of the open project, or empty), and at the Replay level `args`
   and `result`. A `session` record at each `initialize` carries what is needed to read the
   rest: plugin version, protocol revision settled on and asked for, Lazarus and FPC
   versions, OS.
3. **Levels: Off (default), Calls, Replay.** Calls writes everything above except `args`
   and `result`, and instead `args_hash` (a short hash of the argument JSON, so repeated or
   equal calls can be seen without their content) and, for an error, its text. Replay adds
   `args` and `result`. Calls is implemented first: it answers "what happened, in which
   order, how long, with what outcome" with no privacy cost. Replay follows with its own
   change, after the redaction rules below have tests.
4. **Where it is written.** In `TMcpServerThread.CallOnMain`: the one place every tool call
   passes, so calls refused before they start (open dialog, schema check) and calls the
   caller gave up on (they finish later, the line carries the real duration) are all
   recorded, and the log is independent of the JSON-RPC envelope that changes with the
   protocol revision. The open project's name is read on the main thread (in `Run`) and
   carried back in the call object. The log has its own lock, opens, appends and closes per
   line like `McpLogSession`, and never raises.
5. **Redaction and limits (Replay).** The `Authorization` header and tokens are never
   written. Argument keys matching `token|password|secret|authorization|key`
   (case-insensitive) are replaced by `"<redacted>"`; the user-info part of any URL in an
   argument (`https://user:pass@host`) is removed; the standard-input argument of
   `project_run_input` is not recorded. Any string longer than 2 KB (file contents,
   `new_string`, results) is cut and keeps its length and its hash; an error text is kept to
   8 KB. The options page says what Replay writes.
6. **Rotation.** At 4 MB the file becomes `.1`, `.1` becomes `.2`, `.2` becomes `.3` (the old
   `.3` is dropped): about 16 MB at most, and cheap, unlike rewriting a large file to drop
   its older half.
7. **The setting** (level) lives in `mcpassistantoptions.xml` and on the options page next
   to the tokens. A change takes effect at the next call, without a restart.
8. **No restriction by listen address.** The log is written on the IDE's machine whatever the
   listen address (ADR-020), and has the same exposure as the source files it describes;
   what other clients send is not logged beyond the same rules.

## Not decided here

The Messages-pane view (needs the interference with `McpCompilerMessages` and
`ide_get_messages` tested first), a command that bundles both logs and the versions with
redaction applied for attaching to an issue, and replay tooling (most tools depend on IDE
state, so a bundle should say which project and files were open).

## Consequences

- A report can carry the last calls of a session; two runs can be compared.
- Costs: a small file write per call when enabled (nothing when off), and a redaction rule
  set that has to be kept up to date when a tool gets an argument that can hold a secret.
- The record keys on tool calls, not on the protocol envelope or the session, so it keeps
  working when sessions go (issue #5).

## Related

ADR-012 (multiple clients, `mcp-sessions.log`), ADR-020 (listen address), ADR-021 (named
tokens); issues #5 and #6.
