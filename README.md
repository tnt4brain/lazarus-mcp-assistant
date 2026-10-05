# Lazarus MCP Assistant

An in-process MCP server for the [Lazarus IDE](https://www.lazarus-ide.org/). Installs as a standard Lazarus package and exposes 39 IDE tools over HTTP so any [MCP](https://modelcontextprotocol.io/)-capable AI assistant can read, edit, navigate, build, and inspect your project — without leaving the IDE.

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

### Reading & navigation

| Tool | Description |
|---|---|
| `get_active_file` | Active editor file path and current buffer content |
| `get_project_files` | List of source files in the active project |
| `get_file_content` | Read any file by absolute path |
| `get_open_editors` | List of all open editor tabs |
| `get_project_directory` | Root directory of the active project (contains the `.lpi` file) |
| `get_project_settings` | Compiler options: target OS/CPU, output dir, custom flags |
| `get_cursor_position` | Current cursor position (file, line, column) |
| `get_selected_text` | Currently selected text and its start/end positions |

### Editing

| Tool | Description |
|---|---|
| `edit_text` | **Preferred.** Replace by content: find `old_string`, replace with `new_string`. Fails if not found or ambiguous. Pass `replace_all=true` for global replace. No stale line-number offsets. |
| `replace_text` | Replace a line/column range. Useful when the target location is already known precisely. |
| `set_cursor_position` | Move cursor to a line/column. Opens the file first if not already open. |
| `save_file` | Save the editor buffer to disk. |
| `close_file` | Close an editor tab. Unsaved changes are discarded. |
| `revert_file` | Discard unsaved changes and reload from disk. |

### File & project operations

| Tool | Description |
|---|---|
| `create_unit` | Create a new Pascal unit, add it to the active project, and open it in the editor. |
| `add_unit_to_uses` | Add a unit name to an interface or implementation uses clause via CodeTools. |
| `search_in_project` | Text search across all project source files. Returns file, line number, and line content. |
| `get_compiler_errors` | Current build errors and warnings. |

### Build & run

| Tool | Description |
|---|---|
| `build_project` | Incremental build of the active project. |
| `run_project` | Build (if needed) and run the active project without the debugger. |
| `compile_plugin` | Compile a `.lpk` package with `lazbuild`. Use as a smoke-test before `rebuild_ide`. |
| `rebuild_ide` | Rebuild and restart the Lazarus IDE. The IDE exits immediately; the server is unavailable for ~60 s. Pass `lpk_path` to install a new package before rebuilding; omit it to rebuild with currently installed packages. |

### Code intelligence (CodeTools)

| Tool | Description |
|---|---|
| `get_symbol_declaration` | Find where an identifier is declared: file, line, column, context snippet. |
| `get_unit_interface` | Interface section of a Pascal unit (everything above `implementation`). |
| `get_identifier_context` | Type, declaration location, and hint text for an identifier at a file/line/col. |
| `get_code_outline` | Structural outline of a Pascal unit: type names, class members, top-level routines with line numbers. Does not include method bodies. |
| `find_all_references` | All usages of an identifier across the project. |
| `rename_identifier` | Cross-file identifier rename. **Writes directly to disk — not undoable with Ctrl+Z. Use git to revert.** |
| `goto_declaration` | Jump the editor cursor to a declaration. Opens the file if needed. |

### Form designer

| Tool | Description |
|---|---|
| `get_form_components` | Component tree of a form: root class and all owned components with name and class. |
| `get_component_properties` | All published RTTI properties and current values for a named component. |
| `set_component_property` | Set a published RTTI property, including event handler assignments. Marks the designer modified; use `save_file` to persist. |

### Package management

| Tool | Description |
|---|---|
| `get_package_info` | Load and install status of a package in the running IDE. |
| `add_package_to_project` | Add a package dependency to the active project's `.lpi` (no rebuild required). |
| `remove_package_from_project` | Remove a package dependency from the active project's `.lpi`. |
| `install_package` | Open a `.lpk` and install it into the IDE, then rebuild and restart (~60 s). The response includes a `poll_command` identical to `rebuild_ide`. |
| `uninstall_package` | Mark a package for uninstall, then rebuild and restart the IDE (~60 s). |

### Protocol & knowledge

| Tool | Description |
|---|---|
| `ping` | Returns `{"status":"ok","version":"x.y"}`. Use this to poll for the server after `rebuild_ide`. |
| `get_lazarus_reference` | Built-in Lazarus/FPC component library reference. Covers available packages, install instructions, and key gotchas. |

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
2. Claude edits source files in the plugin repository using `edit_text`, `create_unit`, etc.
3. Claude calls `compile_plugin` with the `.lpk` path to catch compiler errors before touching the IDE.
4. Claude calls `rebuild_ide` (optionally passing `lpk_path`). The IDE exits and `startlazarus.exe` rebuilds it (~60 s).
5. Claude polls with `ping` until the new IDE is up (the `rebuild_ide` response includes a ready-to-run `poll_command`).
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

The reference is also available on demand via the `get_lazarus_reference` tool — useful when Claude needs to re-consult it mid-session.

To update the reference: edit `docs/lazarus-knowledge.md`, then run `tools/update_knowledge.ps1` to regenerate `src/lazarus_knowledge.inc`.

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

---

## Provenance
Designed and directed by Sergei Pechenko: the requirements, design decisions (recorded as ADRs in [`docs/adr/`](docs/adr/)), reviews and acceptance. Most of the code, tests and docs were written by Claude (Anthropic) from his prompts and decisions, and checked by the test suite and by using the tools inside the IDE they extend. Because the code is largely AI-generated, no warranty of originality is given beyond the license's disclaimer.

## License

BSD-3-Clause — see `LICENSE`.

> **Note:** the `LICENSE` file is currently empty. If you are reading this in the repository, that is a known gap. The intent is BSD-3-Clause as declared in `lazmcpassistant.lpk`.
