# ADR-004 — Self-Hosted Development: Token Persistence, IDE Rebuild, and Session Continuity

**Status:** Decided, amended 2026-11-13 (a fallback port is not saved)  
**Date:** 2026-10-02

## Context

The goal is to let Claude Code develop this plugin from within the running Lazarus
IDE — editing source, rebuilding Lazarus with the new plugin, and resuming the same
conversation after the IDE restarts.

The MCP server runs inside the Lazarus process (HTTP, 127.0.0.1 only).  When
Lazarus rebuilds and restarts, the server process dies and a new one starts.
Claude Code is a separate process and survives the restart.  Because the MCP
transport is Streamable HTTP, every tool call is an independent HTTP request —
there is no persistent socket to lose.  The only thing that breaks continuity is
the bearer token changing between starts.

Lazarus already has the restart infrastructure: `startlazarus.exe` waits for the
old process to die (via `WaitForSingleObject` / `fpKill`), renames
`lazarus.new.exe` → `lazarus.exe` → `lazarus.old.exe`, and relaunches.
`InstallPackages([piiifRebuildIDE])` triggers this entire sequence.

## Decisions

### 1 — Token persistence via existing IDE settings

The bearer token is stored in `mcpassistantoptions.xml` through the existing
`TMcpIdeSettings` mechanism (`FServerToken` field, persisted by
`LoadSettings`/`SaveSettings`).  On first run the token is generated randomly and
saved; on subsequent starts the saved value is reused.

This is the minimum change needed for session continuity across a restart.

### 2 — Token stability (no rotation)

The bearer token is generated once, stored in `mcpassistantoptions.xml`, and
**reused across all subsequent restarts**.  The post-rebuild IDE reads the same
token from settings and writes it back into the MCP config file at
`McpSettings.LastConfigPath`.

The `--mcp-rebuild` flag + per-rebuild token rotation described in an earlier
draft was **not implemented**.  Rotation was motivated by concern that a leaked
token could be reused across rebuild windows — but the token is only ever
written to a local temp file and read by a local Claude Code process on the
same machine, so the threat model does not justify the complexity.

Token stability also interacts well with decision 5 (port stability): because the
new IDE binds the same port and the token is unchanged, Claude Code's in-memory
URL + token remain valid after a rebuild without any reconnection ceremony.

### 3 — Claude Code survives the restart without losing context

Because the conversation lives in Claude Code (not in the MCP server), and HTTP
MCP is connectionless, Claude Code sees only transient tool-call failures during
the ~60 s rebuild window.  The `rebuild_ide` tool returns a structured response
before the IDE exits:

```json
{
  "status": "rebuilding",
  "message": "IDE is rebuilding and will restart. Poll with the command in poll_command until it succeeds.",
  "poll_command": "..."
}
```

`poll_command` is a ready-to-run shell command invoking `instantfpc.exe` with
`wait_for_restart.pas`.  That script polls the MCP `/ping` endpoint until it
responds, then exits with the port number on stdout.  The command passes the
path of `mcpassistantoptions.xml` (where the script reads port and token), so
it also works when Lazarus runs with a non-default primary config path (`--pcp`).  Claude runs it via the
Bash/PowerShell tool; success means the new IDE is up and tool calls can resume.

`lpk_path` is optional on `rebuild_ide`.  Omitting it rebuilds Lazarus with its
currently installed packages (the common case when only re-installing after a
source edit).  Passing a path loads and installs a new package before rebuilding.
Since v1.0 `ide_rebuild` (the renamed `rebuild_ide`) takes no `lpk_path`:
installing is `package_install`'s job, which shares the same rebuild code.

### 5 — Port stability: subprocess socket isolation

`LaunchMcpAssistant` spawns `claude.exe` via FPC's `TProcess`, which defaults
`InheritHandles` to `True`.  This duplicates every inheritable handle in the
Lazarus process — including the MCP listening socket — into Claude Code.

When Lazarus exits for a rebuild the OS cannot release the listening socket
because Claude Code still holds a duplicate handle.  The new IDE tries to bind
the same ephemeral port but finds it occupied and falls back to a different port.
The URL written to the config file changes; Claude Code's in-memory URL does not.
`/mcp reconnect` retries the cached URL and fails.

Fix: set `Proc.InheritHandles := False` before `Proc.Execute`.  With no inherited
socket the port is freed when Lazarus exits, the new IDE reuses it, and the
in-memory URL stays valid — automatic reconnection with no user action.

Rejected: closing the socket before spawning — requires accessing a private field
of `TFPCustomHTTPServer`; over-engineered for a one-line fix.  
Rejected: always rotating the port — hides the symptom; the Claude Code client
does not re-read the config file on `/mcp reconnect`, so a changed port still
breaks continuity.

**Bootstrap caveat:** a Claude Code session spawned by an IDE build that
predates this fix already holds the inherited socket for its lifetime.  One
manual restart of Claude Code (from the fixed IDE) is needed to enter the clean
state; all subsequent rebuilds are automatic.

### 6 — Rollback

`lazarus.old.exe` is always kept by `startlazarus` (see `RenameLazarusExecutable`
in `lazarusmanager.pas`).  No additional rollback tooling is needed in this
plugin; git is the source-level safety net.

The manual escape hatch if the IDE boot-loops: rename `lazarus.old.exe` →
`lazarus.exe` from a terminal.  Document this in the README.

## New tools

| Tool | Does |
|------|------|
| `compile_plugin` | Runs `lazbuild <lpkpath>` as a subprocess; returns full compiler output. Generic — takes any `.lpk` path. No restart. |
| `rebuild_ide` | Loads the package if needed, calls `InstallPackages([piiifRebuildIDE])`. Returns `{"status":"rebuilding"}` then the IDE exits. |
| `get_package_info` | `FindPackageWithName` + `IsPackageInstalled` — lets Claude inspect package state before acting. |

## Consequences

- `TMcpIdeSettings` gains `FServerToken` and `FLastConfigPath`.
- `InitializeMcpServer` reads the persisted token instead of generating a new one
  each time (generates only on first run or if the stored value is empty).
- `WriteMcpConfig` writes to `LastConfigPath` if set (stable anchor); creates a
  new `lazarus-mcp-<port>.json` file only on first launch.  Always saves the
  path back to settings.
- On every startup: rewrite the existing config file with the current port + token.
  No flag detection or rotation logic needed.
- `PackageIntf` must be added to implementation uses in `mcpideserver.pas`.
- `LaunchMcpAssistant` sets `Proc.InheritHandles := False` so Claude Code does
  not inherit the MCP listening socket.

## Amendment (2026-11-13): a fallback port is not saved

Decision 5 keeps the URL stable by reusing the port stored in
`mcpassistantoptions.xml`. That works while the stored port is free at start. When it
is not, the server falls back to a free port chosen by the OS. This happens when
the previous process still holds the socket (the case decision 5 fixes) and also when
a second IDE instance is running, since both read the same options file.

The server used to store whatever port it ended up on. The second instance then
overwrote the stored port with a random one, and the first instance, restarting later,
started on a URL none of its clients had. A contributor saw the port move 38765 →
64099 → 56742 across restarts (PR #2, issue #18). Clients with a direct URL broke
without any message.

- **The stored port is what clients are configured for, so only it is kept.** After
  the server starts, the port is written to the settings only if none was stored yet
  (first start) or if the server is on the stored port. `McpPortToPersist` makes that
  decision and has a unit test.
- **A fallback lives for one run.** The config file written for the terminal launcher
  holds the port actually in use, and the report (`ide_report`) shows the saved port
  and, when it differs, the one this run listens on. Nothing is stored.
- **The Messages window says so.** When the stored port is busy, one line names both
  ports ("port N is busy (another IDE instance?), listening on M for this session; the
  saved port stays N").

Rejected: a port setting per IDE instance (per `--pcp`): the options file already is
per config directory, and two instances on the same directory are the unusual case;
the fix only has to stop the unusual case from damaging the usual one.  
Not covered: the wider sharing of one options file between instances (tokens, consent
switches). Nothing here changes it.

The call site in `InitializeMcpServer` has no automated test: it needs a live IDE and a
second process holding the port. The helper's rule is tested; the wiring is checked by
hand (start a second instance on the same config directory, confirm the stored port is
unchanged).
