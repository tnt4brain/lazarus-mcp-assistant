# Self-hosted development

The README has the short version.

This plugin was built using itself. The development loop:

1. **Launch MCP Assistant** — starts the server and opens Claude Code.
2. Claude edits source files in the plugin repository using `editor_edit_text`, `project_create_unit`, etc.
3. Claude calls `ide_rebuild`. The IDE exits and `startlazarus.exe` rebuilds it (~60 s).
4. Claude runs the `poll_command` from the `ide_rebuild` response, which waits until the new IDE is up. If `startlazarus` never brings the IDE back (seen once: no `lazarus` process and no build running), the script starts the IDE itself after 45 s, from the same executable and config directory.
5. The new IDE starts with the same bearer token and the same ephemeral port, so Claude Code's next call just works: its old session id gets a 404, and it starts a new session by itself (verified). Changed tool descriptions still reach Claude Code only in a new conversation: it keeps the ones it loaded earlier, even in the new session and after `/mcp reconnect` (seen with tool search on).

**Why this works across a restart:** the bearer token is generated once and stored in `mcpassistantoptions.xml`; subsequent starts reuse it. The new IDE writes the same token back to the same config file at the same path. The port stays stable because `TProcess.InheritHandles := False` prevents Claude Code from holding a duplicate of the listening socket across the rebuild.

**Boot-loop escape hatch (Windows):** if a bad build causes the IDE to crash on startup, open a terminal and run:
```
rename lazarus.old.exe lazarus.exe
```
from the Lazarus installation directory. `startlazarus.exe` always keeps the previous working executable as `lazarus.old.exe`.

Architecture details: [ADR-004](adr/0004-self-hosted-development.md).
