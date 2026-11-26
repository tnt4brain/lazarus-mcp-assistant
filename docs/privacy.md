# Privacy: what the plugin connects to, writes and starts

The plugin sends nothing anywhere on its own: no telemetry, no update check, no crash report, no
analytics. This page lists every network connection it can make, every file it writes outside your
project, and every program it starts. A test (`TTestPrivacy`) fails when a network unit or a web address
appears in the source that is not on this page, so the list cannot fall behind quietly.

## Connections

| What | When | To where |
|---|---|---|
| The MCP server (`mcpideserver`) | while the IDE runs | **listens** on the address and port of the plugin's options; `127.0.0.1` by default. Needs the bearer token of a client (named tokens: Options > MCP Assistant). |
| Self-check and ping (`McpSelfTest`, `PingServer`) | Options page "Test", plugin start | the plugin's own server on `127.0.0.1` |
| `package_search_online`, `package_download` (`McpToolsPackages`) | only when a client calls them | `https://packages.lazarus-ide.org/` (the Online Package Manager's list and archives), over HTTPS only, in-process or through `curl`. The archive is unpacked and checked by the plugin; installing it asks you first. |
| `git_clone`, `git_fetch`, `git_pull`, `git_push` and `git_remote` | only when a client calls them | whatever address the client names or the repository already has: that is `git` talking, with your git credentials |
| `git_serve` (`McpGitServe`) | only after you confirm the dialog, for the minutes you chose | **listens** on one port for one other machine you named, answered with a one-time code (TOTP) from a key that is not the MCP token. Closes after the time or the fetch limit. |
| Address lookup (`McpPrimaryAddress` in `McpUtils`, and `McpGitServe`) | when a link or a server address is made | a datagram `connect` to a reserved address: it **sends nothing**; the system only picks the route to find out the local address |
| Links in the Markdown view | when you click one | `http(s)` links open in your browser through the system; other schemes are ignored |

Not in the list on purpose: the assistant itself. `claude` (or any other client) runs outside the
IDE, talks to its own service under its own terms and sees what its tools return; the plugin does not
see or control that. The MCP server answers a client; it never calls one.

## Files the plugin writes outside the project

All in the Lazarus config folder unless stated: `mcpassistantoptions.xml` (settings, client tokens as
hashes, git_serve keys), `mcp-active.json` (which IDE listens where), `mcp-sessions.log` (client
connect and disconnect), `mcp-exceptions.log` (exceptions of the plugin), and, **only when you switch it
on**, `mcp-tools.log` (one record per tool call; the place can be changed). In the temp folder:
`lazarus-mcp.json` (the client configuration), `lazarus-mcp-launch.*` (the Launch script),
and short-lived files of single tools (`mcpblame*`, `mcpidx*`, `mcpdl*`). In a project: the tools'
documented edits, plus `name.ext.agent` copies when the review policy says so.

## Programs the plugin starts

`git` (the git tools), `lazbuild` and the IDE's own compiler (build and test tools), `curl` (only
when the in-process HTTPS download has no OpenSSL), your terminal and `claude` (the Launch command,
when you click it), and programs you run through `project_run`. Nothing is started at load time.

## What a client can do

Everything above that says "when a client calls it" needs a client with the token. What a client can
read or write is limited as `docs/write-scope.md` says; limited mode narrows it to folders you list.
