# ADR-001 — MCP Server Transport and Lifecycle

**Status:** Accepted  
**Date:** 2026-10-01

## Context

The plugin exposes IDE capabilities (active file, project structure, AST, compiler errors,
build) as MCP tools so that Claude Code — running as a subprocess in a terminal panel
inside Lazarus — can pull exactly what it needs, when it needs it.  The server lives
inside the IDE process (a plugin library), so it cannot be spawned as a stdio subprocess
by Claude Code.  It must expose an HTTP endpoint instead.

## Decisions

### 1. Transport: Streamable HTTP (`type = "http"`)

MCP defines three transports: stdio, HTTP+SSE (old), and Streamable HTTP (2025-03-26
revision). `claude mcp add --help` lists `http` as the example transport.  Streamable HTTP
uses a single `POST /mcp` endpoint — request/response, no long-lived SSE connection —
which maps directly to FPC's `TFPHTTPServer` and removes the cross-thread event-push
complexity of SSE.

Rejected: SSE (older standard, two-endpoint model, requires keeping a connection open
and pushing events from a second thread).  Rejected: stdio (requires a bridge executable;
adds a file to distribute and maintain).

### 2. Security

- Bind to `127.0.0.1` only, never `0.0.0.0`.  A firewall prompt or a `0.0.0.0` line in
  `netstat` means the `Address` property was ignored — treat as a build error.
- Generate a fresh bearer token on every server start using two `CreateGUID` calls
  (OS-level CSPRNG on Windows/Linux/macOS).  Reject any request whose `Authorization`
  header is not `Bearer <token>`.
- Reject any non-empty `Origin` header (one line; prevents DNS-rebinding from browsers,
  though `Authorization` already blocks cross-origin XHR without a CORS preflight).

### 3. Threading

`TFPHTTPServer.Threaded := False`.  Every tool call synchronises back to the main thread
(Lazarus/Codetools are not thread-safe), so concurrent connection threads buy nothing and
create a use-after-free risk: `FreeOnTerminate` connection threads can outlive
`TMcpServerThread` and call back into a freed object.  With `Threaded := False` the server
handles one connection at a time in its own thread.

Stop sequence (must run on the main thread):
1. `FServer.Active := False` — tells the server loop to exit.
2. Open a throwaway TCP connection to `127.0.0.1:<port>` — unblocks the current `Accept`.
3. `while not FThread.Finished do CheckSynchronize(10)` — pumps any pending `Synchronize`
   callbacks; `WaitFor` must not be used here because a request blocked in `Synchronize`
   would deadlock against a waiting main thread.

### 4. Server lifetime (lazy start)

The server is **not** started from `Register`.  It starts only when the user triggers
"Launch MCP Assistant" from the Tools → Secondary Tools menu.  The entry point is a
`TIDEMenuCommand` registered via `RegisterIDEMenuCommand(itmSecondaryTools, ...)`.

The server is stopped via `LazarusIDE.AddHandlerOnIDEClose` — registered at start time —
so the stop sequence runs while the LCL message loop is still alive (required for
`CheckSynchronize`).  `FinalizeMcpServer` in the unit `finalization` section is a
secondary safety net only.

### 5. Port and config injection

Bind to port 0 (OS assigns a free ephemeral port) using a raw `fpsocket` call; read
back the port with `fpgetsockname`.  After the server binds, verify it is reachable
by making a `ping` request via `TFPHTTPClient` before writing the config file.

The config is written to a **stable anchor path** — `McpSettings.LastConfigPath` if
it is already set (i.e. this is a subsequent start), or `GetTempDir +
'lazarus-mcp-<port>.json'` on first start.  The path is persisted in
`mcpassistantoptions.xml` so every future `WriteMcpConfig` call overwrites the
same file.  This means Claude Code always reads the same filename; only the URL
inside changes when the port changes.

```
claude --mcp-config <file> --strict-mcp-config
```

No permanent changes to `~/.claude/` or the project's `.mcp.json`.

### 6. MCP protocol

- `initialize`: echo back `params.protocolVersion` (do not hard-code `2024-11-05`).
- Implement `ping` → `{}` (clients send it as a keepalive).
- Notifications (no `id` field): respond `202 Accepted` with an empty body.
- Unknown methods: respond with JSON-RPC error `-32601 Method not found`.

### 7. Initial tool set

| Tool | Source |
|---|---|
| `get_active_file` | `SourceEditorManagerIntf` + `TSynEdit.Lines.Text` (editor buffer, not disk) |
| `get_project_files` | `LazarusIDE.ActiveProject.Files` |
| `get_file_content(path)` | disk read |
| `get_compiler_errors` | `McpHookManager.CurrentCompilerErrors` |

All tool handlers call IDE APIs via `TThread.Synchronize(TThread.CurrentThread, ...)`.
Codetools-backed tools (`find_declaration`, `get_ast`) are Phase 2.

## Verification checklist

1. `netstat -ano | findstr <port>` shows `127.0.0.1:<port> LISTENING`.
2. PowerShell `Invoke-RestMethod` with the bearer token returns valid JSON for
   `initialize`, `tools/list`, `ping`, and `tools/call get_project_files`.
3. A request without the token returns HTTP 401.
4. A GET to `/mcp` returns HTTP 405.
5. `claude -p "list the project files" --mcp-config <file> --strict-mcp-config` resolves
   the tool as `mcp__lazarus-ide__get_project_files` and returns the file list.
6. Closing the IDE with the server running exits promptly (no hang in WaitFor).
