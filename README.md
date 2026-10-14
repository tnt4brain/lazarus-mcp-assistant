# Lazarus MCP Assistant

An in-process MCP server for the [Lazarus IDE](https://www.lazarus-ide.org/). Installs as a standard Lazarus package and exposes 97 IDE tools over HTTP so any [MCP](https://modelcontextprotocol.io/)-capable AI assistant can read, edit, navigate, build, and inspect your project — without leaving the IDE.

> **Platform:** Windows (v0.x). Linux/macOS support is not tested and not claimed.

---

## Why in-process HTTP?

Most MCP servers are stdio subprocesses: the AI client spawns them, reads their output on stdout, and they die when the session ends. That model does not work for an IDE plugin — a plugin lives inside the IDE process and cannot be spawned from the outside.

Running as an HTTP server inverts the ownership: the IDE starts the server; the AI client connects to it. This enables:

- **Self-hosted development** — you can use Claude Code to develop this plugin from inside the Lazarus IDE it is running in. Claude edits the source, rebuilds the IDE, and resumes the same session after restart. See [Self-hosted development](#self-hosted-development).
- **Multiple simultaneous clients** — any number of AI sessions can connect to the same running IDE instance. One session can work on the plugin while another works on a project built with it.
- **Session persistence** — the server stays running between AI sessions. No re-spawn, no re-configuration. Reconnect at any time.

Transport details: [ADR-001](docs/adr/0001-mcp-server-transport-and-lifecycle.md).

---

## Tool reference

Tools are named `<category>_<action>`; `tools/list` returns them sorted, each
with a human-readable `title` ("Debugger: get call stack") and
`readOnlyHint` / `destructiveHint` annotations. In Claude Code they appear as
`mcp__lazarus-ide__<tool_name>`.

### Editor — `editor_*`

| Tool | Description |
|---|---|
| `editor_get_active` | Active editor file path and current buffer content |
| `editor_list_open` | All open editor tabs |
| `editor_read_file` | Read any file by absolute path; prefers the live editor buffer (unsaved changes) over disk |
| `editor_open` | Open a file in the editor without moving the cursor; returns `already_open` |
| `editor_get_cursor` / `editor_set_cursor` | Read / move the cursor (opens the file if needed) |
| `editor_get_selection` | Selected text and its range |
| `editor_edit_text` | **Preferred edit.** Replace `old_string` with `new_string`; fails if missing or ambiguous; `replace_all` for every match. Undoable with Ctrl+Z |
| `editor_replace_range` | Replace a line/column range (empty range inserts, empty text deletes) |
| `editor_edit_at_position` | Replace `delete_len` characters at (line, col) — for coordinates from `code_*` tools |
| `editor_save` | Save a buffer (a form unit saves its `.lfm` too) |
| `editor_revert` | Discard unsaved changes and reload from disk |
| `editor_close` | Close a tab, discarding unsaved changes |

### CodeTools — `code_*`

| Tool | Description |
|---|---|
| `code_get_outline` | Uses, types, class members and routines with line numbers (no bodies) |
| `code_get_unit_interface` | The interface section of a unit |
| `code_get_procedure_ast` | Locals and block-level control flow (if/for/while/try/case…) of one routine, with line ranges |
| `code_find_declaration` | Where an identifier is declared, with a context snippet |
| `code_goto_declaration` | Jump the editor cursor to a declaration |
| `code_get_identifier_info` | Type, declaration and hint text for the identifier at file/line/col |
| `code_find_references` | Every reference to an identifier across the project |
| `code_rename_identifier` | Rename across all project files. **Writes to disk, not undoable with Ctrl+Z — use git** |
| `code_add_uses` | Add a unit to the interface or implementation uses clause |
| `code_insert_in_procedure` | Insert text right after a routine's `begin` |
| `code_replace_procedure_body` | Replace everything between a routine's `begin` and `end` |
| `code_add_to_class` | Append a declaration to a class section (private/protected/public/published) |

### Form designer — `form_*`

Property access goes through the Object Inspector's property editors: nested
properties by dotted path (`BorderSpacing.Around`, `Font.Style`,
`AnchorSideLeft.Control`, `ChildSizing.Layout`), enums/sets as text
(`alClient`, `[akLeft,akTop]`), component references by name, events by
handler name (created if missing), and `Name` renames the component in the
source too. Collection items are addressed by index (`Columns[0].Caption`,
`Panels[1].Width`), and string lists (`Memo.Lines`, `ListBox.Items`) are read
as `lines` and set from an array of strings.

| Tool | Description |
|---|---|
| `form_create` | New form, data module or frame (`kind`): `.pas` + `.lfm`, added to the project and opened |
| `form_list_components` | Every component with class, parent, bounds, Align, Anchors, Visible, Caption/Text, TabOrder; form and client size |
| `form_get_lfm` | LFM text of the live designer state (incl. unsaved changes) — whole form or one component |
| `form_get_properties` | Properties of a component, nested ones as dotted paths; with `names`, also the allowed values |
| `form_set_properties` | Set several properties at once; one result per property. `Parent` moves a control into another container |
| `form_add_component` | Add a palette component, optionally inside a container, with `name` and initial `properties`; adds the unit to `uses` |
| `form_delete_component` | Delete a component and its child controls, or a menu item and its submenu (fields removed from the source) |
| `form_list_collection_items` | Items of a collection property (ListView `Columns`, StatusBar `Panels`, grid `Columns`, `Sections`, `Bands`) with their properties |
| `form_add_collection_item` / `form_delete_collection_item` / `form_move_collection_item` | Add (at an index, with properties), delete or reorder collection items |
| `form_get_menu` | Item tree of a `TMainMenu`/`TPopupMenu`: captions, shortcuts, checked/enabled, OnClick |
| `form_add_menu_item` / `form_move_menu_item` | Add an item or separator (`-`) to a menu or submenu; move an item to another position or parent |
| `form_arrange` | Same size as the first control, distribute with a fixed gap or evenly, align edges/centres to the first control or the parent |
| `form_create_event_handler` | Create (or show) the handler for a component event |
| `form_search_palette` | Find palette classes by name: class, unit, palette page |

Designer changes are in memory until `editor_save` on the unit.

### Debugger — `debug_*`

Run and step tools block until the program pauses or `timeout_s` elapses.
Sessions driven through these tools never show IDE modals: an exception pauses
the program and is returned as `reason: "exception"` with class, message, file
and line; "Execution stopped" is suppressed; debugger error messages are
returned as `debugger_message`. Sessions you start yourself (F9) behave as usual.

With several clients connected, the first one that drives the debugger owns the
session. Until it ends, other clients are refused the debugger-driving tools and
`project_build`/`project_run`/`project_create`/`ide_rebuild`/`package_install`/
`package_uninstall`; everything else stays available. The owner's lease expires
after 300 s without calls from it (`debug_run` `lease_idle_timeout`), and the
abandoned session is then stopped. `debug_get_state` shows the owner. Only one
debugger call runs at a time. See [ADR-012](docs/adr/0012-multiple-clients.md).

| Tool | Description |
|---|---|
| `debug_set_breakpoint` / `debug_remove_breakpoint` / `debug_list_breakpoints` | Source breakpoints (no session needed) |
| `debug_run` | Start, or continue from a pause (F9) |
| `debug_run_to_line` | Run to a file/line via a temporary breakpoint |
| `debug_step_over` / `debug_step_into` / `debug_step_out` | F8 / F7 / Shift+F8 |
| `debug_pause` / `debug_stop` | Pause / stop the session |
| `debug_get_state` | State and source location, in any state |
| `debug_get_call_stack` | Frames with file, line, function and address (`max_frames`) |
| `debug_get_locals` | Locals and parameters of a frame |
| `debug_evaluate` | Evaluate a Pascal expression in the current context |
| `debug_set_variable` | Modify a variable or expression |
| `debug_get_exception` | The exception the program is paused at |
| `debug_add_watch` / `debug_remove_watch` / `debug_list_watches` | Watches window; values for the current thread and frame |
| `debug_list_threads` | Threads with state and top frame |
| `debug_get_output` | What the program wrote to its console, and debugger output |

### Project — `project_*`

| Tool | Description |
|---|---|
| `project_get_directory` | Root directory of the active project (contains the `.lpi`) |
| `project_list_files` | Source files of the active project |
| `project_get_settings` / `project_set_settings` | Target OS/CPU, output directory, custom options |
| `project_add_file` / `project_remove_file` | Project file list (files stay on disk) |
| `project_create_unit` | New unit on disk, added to the project and opened |
| `project_add_package` / `project_remove_package` | Package dependencies in the `.lpi` |
| `project_search` | Case-insensitive text search across project files |
| `project_list_todos` | `TODO` / `FIXME` / `DONE` comments, as the IDE's ToDo List shows them |
| `project_build` | Incremental build; returns success and errors |
| `project_get_compiler_errors` | Errors and warnings of the last build |
| `project_run` | Build if needed and run without the debugger; optional `args` (stored in the run parameters) |
| `project_list_templates` / `project_create` | Project templates; create a project from one |

### Packages — `package_*`

| Tool | Description |
|---|---|
| `package_get_info` | Load and install status of a package |
| `package_compile` | Compile a `.lpk` with `lazbuild` — a smoke test before `ide_rebuild` |
| `package_install` / `package_uninstall` | Install or uninstall, then rebuild and restart the IDE |

### IDE — `ide_*`

| Tool | Description |
|---|---|
| `ide_ping` | `{"status":"ok","version":"x.y"}` — poll after `ide_rebuild` |
| `ide_get_messages` | Everything in the Messages window, all urgency levels |
| `ide_rebuild` | Rebuild and restart the IDE (optionally installing `lpk_path` first); the server is gone for ~60 s |
| `ide_run_tests` | Build and run the FPCUnit test project; structured results, optional JUnit XML |

### Git — `git_*`

`git_status`, `git_diff`, `git_log`, `git_branches`, `git_add`, `git_commit`,
`git_checkout`, `git_stash`, `git_stash_pop`, `git_reset` (soft/mixed only —
no hard reset). `work_dir` defaults to the project directory.

### Resources

| URI | Content |
|---|---|
| `lazarus-ide://reference` | Lazarus/FPC component and IDE API reference (`docs/lazarus-knowledge.md`) |
| `lazarus-ide://system-prompt` | The instructions injected into Claude at launch (`docs/system-prompt.md`) |

### While a tool runs

Nobody is at the IDE's keyboard while a tool call executes, so the plugin
answers the IDE's "Some files have changed on disk" dialog with *Reload*,
which reloads only files without unsaved editor changes. Every HTTP response
carries `Connection: close`, and the server's sockets are not inheritable, so a
program started by the IDE cannot keep a connection open.

### Clients

`initialize` returns an `Mcp-Session-Id` header (and the same id as an
`mcp_session` cookie); clients send it back to identify themselves, and
`DELETE /mcp` ends the session. Requests without either share one identity,
`anonymous`; a client with a cookie jar (`curl -b jar -c jar`) gets its own.

---

## Requirements

- **Lazarus IDE** (tested on the stable series; v0.x targets Windows only)
- **Free Pascal Compiler** (bundled with Lazarus)
- **OpenSSL DLLs** on Windows — required by `opensslsockets` (used for the Anthropic API client). Download from the [OpenSSL for Windows](https://wiki.openssl.org/index.php/Binaries) page or use the DLLs bundled with many Lazarus distributions.
- **Claude Code** (or any MCP client that supports Streamable HTTP transport)

Package dependencies — all bundled with Lazarus: `SynEdit`, `IDEIntf`, `FCL`, `CodeTools`.

---

## Installation

1. In Lazarus: **Package → Open Package File (.lpk)** → select `src/lazmcpassistant.lpk`.
2. In the package dialog: **Use → Install**.
3. Lazarus will ask to rebuild the IDE. Confirm. The IDE restarts with the plugin loaded.

---

## Usage

1. In the IDE: **Tools → Secondary Tools → Launch MCP Assistant**.
   - This starts the HTTP server on a random local port and opens Claude Code in a separate console window.
   - The MCP config file is written to a stable path in your system temp directory and reused on subsequent launches.

2. Claude Code starts pre-configured with the server URL and bearer token. No manual `--mcp-config` flag needed for subsequent sessions — the config path is persisted in `mcpassistantoptions.xml`.

3. Tools are available as `mcp__lazarus-ide__<tool_name>` in Claude Code.

---

## Self-hosted development

This plugin was built using itself. The development loop:

1. **Launch MCP Assistant** — starts the server and opens Claude Code.
2. Claude edits source files in the plugin repository using `editor_edit_text`, `project_create_unit`, etc.
3. Claude calls `package_compile` with the `.lpk` path to catch compiler errors before touching the IDE.
4. Claude calls `ide_rebuild` (optionally passing `lpk_path`). The IDE exits and `startlazarus.exe` rebuilds it (~60 s).
5. Claude polls with `ide_ping` until the new IDE is up (the `ide_rebuild` response includes a ready-to-run `poll_command`).
6. The new IDE starts with the same bearer token and the same ephemeral port. Claude's session resumes without any reconnection step.

**Why this works across a restart:** the bearer token is generated once and stored in `mcpassistantoptions.xml`; subsequent starts reuse it. The new IDE writes the same token back to the same config file at the same path. The port stays stable because `TProcess.InheritHandles := False` prevents Claude Code from holding a duplicate of the listening socket across the rebuild.

**Boot-loop escape hatch:** if a bad build causes the IDE to crash on startup, open a terminal and run:
```
rename lazarus.old.exe lazarus.exe
```
from the Lazarus installation directory. `startlazarus.exe` always keeps the previous working executable as `lazarus.old.exe`.

Architecture details: [ADR-004](docs/adr/0004-self-hosted-development.md).

---

## Knowledge injection

The plugin injects a Lazarus/FPC reference document into Claude's system prompt at launch (`--append-system-prompt`). This covers LCL component packages, installation patterns, and common gotchas, so Claude does not hallucinate package names or import paths.

The reference is also available on demand as the `lazarus-ide://reference` MCP resource — useful when Claude needs to re-consult it mid-session.

To update the reference: edit `docs/lazarus-knowledge.md`, then run `tools/gen_knowledge_inc.exe` from the project root to regenerate `src/lazarus_knowledge.inc` and `src/system_prompt.inc` (build it once with `fpc -MObjFPC -Scghi -FEtools tools/gen_knowledge_inc.pas`), then rebuild the IDE. The same applies to `docs/system-prompt.md`.

---

## Testing

A standalone FPCUnit test project lives in `tests/`. It covers the protocol/auth/utility layer — the parts that compile without IDE dependencies.

```
cd tests
fpc -Fu../src mcpserver_tests.lpr
mcpserver_tests.exe
```

**Suites:**

| Suite | Count | Requires |
|---|---|---|
| `TTestUtils` | 7 | Nothing (always runs) |
| `TTestProtocol` | 10 | MCP server reachable |
| `TTestAuth` | 7 | MCP server reachable |

The runner detects the running server by reading `%LOCALAPPDATA%\lazarus\mcpassistantoptions.xml` and pinging it. If the server is not up, `TTestProtocol` and `TTestAuth` are skipped and only the utility tests run.

Architecture details: [ADR-005](docs/adr/0005-fpcunit-test-suite.md).

---

## Architecture

| Document | Covers |
|---|---|
| [ADR-001](docs/adr/0001-mcp-server-transport-and-lifecycle.md) | Transport (Streamable HTTP), security, threading, port & config management |
| [ADR-002](docs/adr/0002-embedded-terminal-for-claude-code.md) | Embedded terminal (deferred to v1.x; v0.x uses an external console window) |
| [ADR-003](docs/adr/0003-undo-redo-for-rename-identifier.md) | CodeTools-backed refactoring tools |
| [ADR-004](docs/adr/0004-self-hosted-development.md) | Self-hosted development: token persistence, rebuild cycle, port stability |
| [ADR-005](docs/adr/0005-fpcunit-test-suite.md) | FPCUnit test suite: testability boundary, standalone test project layout |
| [ADR-006](docs/adr/0006-project-lifecycle-tools.md) | Project lifecycle tools: file management, project settings, component search, editor state, run configuration |
| [ADR-008](docs/adr/0008-structural-source-editing.md) | Token-aware / structural source editing |
| [ADR-009](docs/adr/0009-debugger-integration.md) | Debugger integration: blocking checkpoint model |
| [ADR-010](docs/adr/0010-tool-naming-scheme.md) | Tool naming scheme `<category>_<action>`, titles, annotations; v0.7 → v0.8 rename table |
| [ADR-011](docs/adr/0011-no-ide-modals-in-mcp-sessions.md) | No IDE modals in MCP-driven debug sessions |
| [ADR-012](docs/adr/0012-multiple-clients.md) | Multiple clients: session identity, debug session lease, debugger lock |

---

## Provenance
Designed and directed by Sergei Pechenko: the requirements, design decisions (recorded as ADRs in [`docs/adr/`](docs/adr/)), reviews and acceptance. Most of the code, tests and docs were written by Claude (Anthropic) from his prompts and decisions, and checked by the test suite and by using the tools inside the IDE they extend. Because the code is largely AI-generated, no warranty of originality is given beyond the license's disclaimer.

## License

BSD-3-Clause — see `LICENSE`.

> **Note:** the `LICENSE` file is currently empty. If you are reading this in the repository, that is a known gap. The intent is BSD-3-Clause as declared in `lazmcpassistant.lpk`.
