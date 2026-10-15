# ADR-012 — Multiple Clients: Session Identity, Debug Session Lease, Debugger Lock

**Status:** Accepted (v0.8), amended 2026-10-15 (unknown session ids get 404)  
**Date:** 2026-10-14

## Context

The server is in-process HTTP (ADR-001), so several MCP clients can talk to one IDE
at once. Typical cases are two Claude Code windows, or an assistant plus a script
calling it with curl. The IDE has one debugger, one project and one main thread.
Three problems showed up:

1. **No identity.** Every client sends the same bearer token. `clientInfo.name`
   isn't unique either, since two Claude Code windows both say "claude-code".
   So the server couldn't tell who was calling.
2. **Shared per-request state.** `TFPHttpServer` runs one thread per connection
   (`Threaded=True`), but the "call this tool on the main thread" workspace was
   stored in fields of the single server-thread object (`FSyncToolName`,
   `FSyncParams`, `FSyncResult`, `FSyncError`). Two concurrent requests could
   overwrite each other's tool name, arguments or result. This affected every
   tool, not just the debugger.
3. **Debugger races.** All debugger tools share one helper object (`GSyncHelper`)
   with the IDE's debugger. Two concurrent debugger calls corrupt each other's
   state, and this was reproduced. Beyond corruption, two assistants stepping
   the same session — or one building the project while another debugs it —
   leaves both confused and can trigger IDE modals (ADR-011).

The user suggested an exclusive lock acquired by the assistant that starts the
session. It would be held until the session ends, while other assistants only get
read-only tools. A "leaky bucket" would free the lock when its holder goes quiet.

## Decision

### 1. Identity: the MCP session id, with a cookie fallback

- **Session id.** The `initialize` response carries `Mcp-Session-Id: <uuid>`
  (Streamable HTTP transport). Spec-following clients echo it on every later
  request, and that id is the client's identity. `clientInfo.name` and the
  version are kept only to label the client in messages.
- **Cookie.** The same id is also set as a cookie
  (`mcp_session=<id>; Path=/mcp; HttpOnly; SameSite=Strict`). Simple clients that
  keep a cookie jar (`curl -b jar -c jar`) get an identity without handling headers.
- **Requests with neither.** These share the identity `anonymous` and are offered
  a fresh cookie. A cookie-aware client turns into a distinct identity on its next
  request, even without calling `initialize`.
- **Unknown ids get 404** (amended 2026-10-15, v1.0; first decided the other way,
  see *Amendment* below). A request with an `Mcp-Session-Id` the server didn't hand
  out since it started gets HTTP 404 and a JSON-RPC error that says to send
  `initialize`; `initialize` itself is always accepted and hands out a new id. This
  is the spec's rule. After `ide_rebuild` the restarted IDE knows no sessions, so a
  client starts a new one and gets the current instructions and tool list. Cookie
  identities (decision 1's fallback) are not sessions and stay accepted as they are.
- **`DELETE /mcp` ends the session.** It is the spec's way to close a session,
  and before this change it got a 405. If that session owns the debug lease,
  the lease expires at the next watchdog tick. Clients that crash never send it,
  which is why the lease also has an idle timeout (decision 3).

### 2. Per-request main-thread calls

Each request thread builds its own `TMcpMainCall` object (tool name, `Ctx`, log
text) and passes that object's method to `TThread.Synchronize`. Nothing that
belongs to one request is stored on the server thread any more.

### 3. Debug session lease

**Who owns the session.** The first client to call a debugger tool that isn't
read-only (`debug_run`, `debug_step_*`, `debug_set_breakpoint`, …) while the
lease is free becomes the owner. This works the same for a session the user
started with F9 and later handed to an assistant.

**What the others can do.** While someone else owns the session, a client is
**refused** these tools:

- every non-read-only `debug_*` tool
- the tools that end or disturb the session: `project_build`, `project_run`,
  `project_create`, `project_open` (added later), `ide_rebuild`,
  `package_install`, `package_uninstall`

Everything else stays available: read-only tools by annotation (ADR-010), such as
`debug_get_state`, `debug_get_locals`, `debug_evaluate` and `debug_get_call_stack`,
plus editing and the `code_*`, `form_*` and `git_*` tools.

This deliberately narrows the original idea of "only read-only tools for others".
Blocking a second assistant from editing a different unit for the whole session
protects nothing, because only the listed tools can actually break a live session.
The user chose this scope.

**What a refusal says.** The refusal names the owner (client name plus a short
session id). It also gives the idle timeout and either the remaining time or
"it has a call running now", so the refused client can wait instead of retrying
blindly. `debug_get_state` reports the same as `lease`.

**Idle timeout instead of a leaky bucket.** A leaky bucket drains at a constant
rate and refills with each call. With a refill of "full", that behaves exactly
like an idle timeout. The timeout is simpler to explain to a user ("released after
5 minutes without calls from its owner"), so that's what was built.

- **Default 300 s.** That is long enough for an assistant waiting on a human
  approval prompt. `debug_run` takes `lease_idle_timeout` (10–3600 s) to change it
  for the session.
- **Every owner call refreshes the lease**, at its start and at its end.
- **The lease never expires while an owner call is running.** `debug_run` may
  legitimately block for its whole `timeout_s` waiting for a breakpoint.

**On expiry.** A watchdog thread checks every second and queues the expiry onto the
main thread. That uses `TThread.Queue`, never `Synchronize`, so it can't deadlock
an IDE that is shutting down. On the main thread it re-reads the real debugger
state. Then:

- **The session is still live and MCP-driven** (`GMcpDriven`, ADR-011). It is
  stopped without dialogs, the lease is released, and a line goes to the IDE's
  Messages window.
- **The user has taken the session over** with the IDE's own commands. Only the
  lease is dropped, and the session keeps running.

**Release.** The lease is released when the session ends, through `McpDebugGuard`'s
state handler. If an owner call is still running at that point, for example the
`debug_stop` that ended the session, the watchdog releases it right after that
call returns. A lease taken without a session ever starting (say, after
`debug_set_breakpoint` alone) is released within about a second.

The human at the keyboard is never gated: the IDE's own UI isn't affected.

### 4. Debugger lock

At most one `debug_*` call runs at a time, whoever makes it, and that includes an
owner's own parallel calls. `debug_stop` and `debug_get_state` are exempt. They
are the escape hatches while a `debug_run` blocks: one only posts a command, the
other only reads the state, and both run on the main thread. Non-owners still
can't call `debug_stop`, because the lease refuses them. The lease alone wouldn't prevent those, since Claude
Code issues tool calls in parallel. The lock is taken on the request thread
before dispatch, never on the main thread, so a waiting request can't block the
IDE. A waiter gives up after 60 s with "Debugger busy".

All of this is enforced in one place, `McpGateEnter`/`McpGateLeave` around every
`tools/call` in `HandleToolsCall`, so tool units don't need to know about clients.

## Alternatives considered

- **`clientInfo.name` as identity.** Not unique, as noted in the context.
- **One bearer token per client.** That needs token management UI and per-client
  config. The session id gives the same separation for free.
- **Owner-only access to every write tool** (the literal reading of the request).
  Rejected in favour of the narrower list, for the reason under decision 3.
- **Lazy expiry (checked only on the next request).** That leaves an abandoned
  debuggee paused in the IDE indefinitely, so a watchdog does the work.
- **Accepting unknown session ids as they are.** The original decision (v0.8): the
  id string was the key and needed no validation, and a client that handled a 404
  badly could have broken the self-hosted rebuild loop. Replaced by the 404; see
  *Amendment*.

## Amendment (2026-10-15): 404 for unknown session ids

Decision 1 first accepted unknown ids, so that clients would keep working across
`ide_rebuild` without re-initializing. Two things changed that:

- **The client handles it.** Tried with Claude Code: after `ide_rebuild`, its
  request with the old id got 404, it started a new session by itself, and the next
  tool call succeeded with no `/mcp reconnect`. The rebuild loop survives.
- **A new session is worth having.** The `initialize` reply now carries the
  server's `instructions` (the system prompt), and a rebuild may change the tool
  list. Accepting the old id kept the client on its first session forever.

Not solved by this: Claude Code keeps the tool definitions it loaded earlier in a
conversation, even in the new session, so changed tool descriptions still reach it
only in a new conversation. `notifications/tools/list_changed` would need a
server-to-client stream (SSE), which the server doesn't have; not tried.

Also changed with it: `DELETE` of an unknown session gets 404, and a request after
`DELETE` gets 404 instead of being accepted. The debugger tests start real sessions
with `initialize` instead of making ids up.

## Consequences

- **Verified with two simulated clients over HTTP:**
  - the second client was refused `debug_step_over` and `project_build`, while
    `debug_get_state`, `debug_get_locals` and `debug_evaluate` worked for it
  - three parallel calls were serialised correctly
  - the idle lease expired after 20 s and the session was stopped without a
    dialog
  - the other client then acquired it, and `debug_stop` released it
  - `debug_get_state` answered in under 0.1 s while a `debug_run` was blocked
- **Verified with `curl`:**
  - a cookie-only client (`Cookie: x=1; mcp_session=<id>`) is identified by its
    cookie
  - a cookie jar without `initialize` gets its own identity
  - `DELETE /mcp` for the owner releases the lease, and the session was stopped
    within the next watchdog tick
  - Windows PowerShell 5.1's `Invoke-WebRequest -Headers @{Cookie=…}` doesn't
    send the cookie, so don't test cookies with it
- **Verified with Claude Code** (2026-10-14): after `/mcp reconnect`, Claude Code
  sends `Mcp-Session-Id` back. Two `ide_ping` calls reported the same session id,
  not `anonymous`. (`ide_ping` returns the caller's identity as `client` for this
  kind of check.)
- **Verified: taking over a session the user started** (4b6a10e). The user
  pressed F9 and the program stopped in the IDE's exception dialog. That dialog
  appears only in sessions the user drives (ADR-011).
  - `debug_get_state` reported `waiting_for`.
  - `debug_pause` answered the dialog with Break, as the user would, and
    returned the pause at the exception (`reason: "exception"`).
  - The Claude Code session then held the lease, and the call stack and locals
    could be read.
  - Every debugger-driving tool takes over this way: `debug_run` and the steps
    continue after the Break, and `debug_stop` stops once the dialog has closed.
- **Verified: lease expiry with Claude Code** (2026-10-14). After the takeover
  above, the Claude Code session made no calls for 300 s. The session was then
  stopped (no dialog, debuggee gone), and the Messages window showed:
  `MCP: debug session lease of client (session d97f7ac2) expired after 300 s
  without calls; session stopped.`
- **Automated since then:** `TTestSession` covers identity, and the opt-in
  `TTestDebugger` (ADR-005) covers the refusal, the lock and expiry with a
  10 s lease.
- All clients without a session id or cookie count as one. Two such scripts can
  step on each other, exactly as before this ADR.
- The debugger lock trades parallelism for correctness. A read-only debugger call
  waits while another client's `debug_run` is blocked. That's acceptable, because
  every debugger call already goes through the single IDE main thread.
