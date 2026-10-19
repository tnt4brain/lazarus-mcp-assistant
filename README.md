# Lazarus MCP Assistant

An in-process MCP server for the [Lazarus IDE](https://www.lazarus-ide.org/). Installs as a standard Lazarus package and exposes 124 IDE tools over HTTP so any [MCP](https://modelcontextprotocol.io/)-capable AI assistant can read, edit, navigate, build, and inspect your project — without leaving the IDE.

> **Platform:** Windows and Linux. The whole test suite, the debugger tests
> included, passes on Windows and on Debian 12 (Lazarus 4.6, FPC 3.2.2, GTK2).
> macOS is not tested and not claimed: the plugin uses only LCL/IDE interfaces
> (no Win32 API) and has macOS code for launching Claude Code in Terminal.app,
> but it has never been compiled or run there.

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
with a human-readable `title` ("Debugger: get call stack") and annotations:
- `readOnlyHint` for tools that change no file or project. Moving the cursor
  or opening a tab counts as read-only.
- `destructiveHint` only for changes that neither Ctrl+Z nor `form_undo` can
  take back: closing or reverting an editor with unsaved changes,
  `git_checkout`, `git_reset`, rebuilds and installs.
- `idempotentHint` where repeating a call with the same arguments changes
  nothing more.

In Claude Code they appear as `mcp__lazarus-ide__<tool_name>`.

A tool that works on one source file takes it as `file`, an absolute path;
`D:/x/f.pas` and `D:\x\f.pas` name the same file. The names used before v1.0
(`file_path`, `path`, `filename`) are still accepted. A file that doesn't exist
is an error of the tool, never the IDE's "File not found" dialog. Files created
or changed outside the IDE (by the assistant's shell, say) are seen at once.

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
| `editor_replace_range` | Replace a range given by start and end, or start and `delete_len` (no end inserts, empty text deletes) — for coordinates from `code_*` tools |
| `editor_save` | Save a buffer (a form unit saves its `.lfm` too) |
| `editor_revert` | Discard unsaved changes and reload from disk |
| `editor_close` | Close a tab, discarding unsaved changes |

### CodeTools — `code_*`

| Tool | Description |
|---|---|
| `code_get_outline` | Uses, types, class members and routines with line numbers (no bodies) |
| `code_get_unit_interface` | The interface section of a unit |
| `code_get_procedure_ast` | Locals and block-level control flow (if/for/while/try/case…) of one routine, with line ranges |
| `code_find_declaration` | Where an identifier is declared, with a context snippet; follows the uses clauses (RTL, sibling units) and works in a program; optional `line`/`col` pick a use |
| `code_goto_declaration` | Jump the editor cursor to a declaration |
| `code_get_identifier_info` | Type, declaration and hint text for the identifier at file/line/col |
| `code_find_references` | Every reference to an identifier across the project (and the file asked about, even outside the project). `also` (`same_folder`, `lcl`, `components`, `rtl`, `fcl`, `packages`) and `search_dir` add other sources, e.g. to see how an API is used; only files that mention the name are parsed, at most `max_files` (default 300) |
| `code_rename_identifier` | Rename across all project files from the declaration or any reference, as the IDE's Rename Identifier does; `dry_run` lists the references first. Unit names are refused |
| `code_add_uses` | Add a unit to the interface or implementation uses clause |
| `code_insert_in_procedure` | Insert text right after a routine's `begin` |
| `code_replace_procedure_body` | Replace everything between a routine's `begin` and `end` |
| `code_add_to_class` | Append a declaration to a class section (private/protected/public/published) |
| `code_complete` | Code completion as Ctrl+Shift+C does it: method bodies, property fields and setters, forward procedures, local variables, event handlers. Returns the changed lines |
| `code_format` | Format a file or a range of lines with JEDI Code Format, using the IDE's JCF settings; one undo step. Returns the changed lines |

Changing `code_*` tools edit the editor buffer, as the IDE's own commands do:
Ctrl+Z undoes them, and nothing is written to disk until `editor_save` (or
`auto_save: true`).

`code_complete` is the IDE's Ctrl+Shift+C without its dialogs. `code_format`
runs JEDI Code Format, as **Source → JEDI Code Format** does, on `.pas`, `.pp`,
`.lpr`, `.dpr` and `.inc` files. Both return the changed lines as hunks (the
lines removed and added) rather than the whole file.
- `code_format` uses the settings of JCF's IDE plugin (**Tools → Options →
  JEDI Code Format**). Without that plugin, it uses `jcfsettings.cfg` in the
  IDE's config folder, created from JCF's defaults; the result says so.
  Lazarus's default JCF settings change the case of some words (for example
  `Integer` becomes `integer`); that is a style setting, not the tool: change it in
  **Clarify → Capitalisation** (or edit `jcfsettings.cfg`).
- After formatting, the editor is checked against JCF's output. If they
  differ, the change is put back and an error returned.
- JCF itself isn't idempotent on long wrapped lines: a second run can still
  change a few of them.

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
| `form_get_menu` | Item tree of a `TMainMenu`/`TPopupMenu`: captions, shortcuts, checked/enabled, OnClick; `menu_name` is optional when the form has one menu, and errors list the form's menus |
| `form_add_menu_item` / `form_move_menu_item` | Add an item or separator (`-`) to a menu or submenu; move an item to another position or parent |
| `form_arrange` | Same size as the first control, distribute with a fixed gap or evenly, align edges/centres to the first control or the parent |
| `form_create_event_handler` | Create (or show) the handler for a component event |
| `form_search_palette` | Find palette classes by name: class, unit, palette page |
| `form_undo` / `form_redo` | One step of the designer's undo list, as Edit > Undo / Redo (Ctrl+Z) in the designer; returns `can_undo` / `can_redo` |

Designer changes are in memory until `editor_save` on the unit.

**Undo.** Every changing `form_*` call is one step in the designer's own undo
list, shared with the user's Ctrl+Z and with other clients; `form_undo` takes
back the last step, whoever made it. Simple properties, `Name`, `Parent`, adds,
deletes and `form_arrange` are recorded property by property. Changes the
designer cannot replay that way (sub-properties such as `Font.Color`, string
lists, collection items, menus, events, component references) are recorded as
a replacement of the whole component (a menu item: its whole menu). References
that other components held to it are restored. Results say `"undoable"`. The
form itself cannot be replaced, so changes of that kind to the form itself
(`Form1.Font.Color`, `Form1.Menu`, `Form1.OnCreate`) are not undoable. Undo restores the form, not the source: a field returns with its
component, but a created event handler method stays. See [ADR-014](docs/adr/0014-designer-undo.md).

### Debugger — `debug_*`

Run and step tools block until the program pauses or `timeout_s` elapses.
Sessions driven through these tools never show IDE modals: an exception pauses
the program and is returned as `reason: "exception"` with class, message, file
and line; "Execution stopped" is suppressed; debugger error messages are
returned as `debugger_message`. Sessions you start yourself (F9) behave as usual. If such a
session stops in the IDE's exception dialog, an assistant can take it over:
`debug_get_state` reports `waiting_for`, and `debug_pause` (or any other
debugger-driving tool) answers the dialog with *Break*, as you would.

With several clients connected, the first one that drives the debugger owns the
session. Until it ends, other clients are refused the debugger-driving tools and
`project_build`/`project_run`/`project_create`/`project_open`/`ide_rebuild`/`package_install`/
`package_uninstall`; everything else stays available. The owner's lease expires
after 300 s without calls from it (`debug_run` `lease_idle_timeout`), and the
abandoned session is then stopped. `debug_get_state` shows the owner. Only one
debugger call runs at a time. See [ADR-012](docs/adr/0012-multiple-clients.md).

| Tool | Description |
|---|---|
| `debug_set_breakpoint` / `debug_remove_breakpoint` / `debug_list_breakpoints` | Source (file + line), address (`$401000`, or `Proc+12` for a procedure with debug info, resolved while paused) and data breakpoints (`data` + `watch` write/read/readwrite); each with `condition` and `pass_count`. Setting one again at its location changes it. No session needed, except to resolve a symbol |
| `debug_run` | Start, or continue from a pause (F9). Refused up front when the project has no DWARF info (the IDE would ask in a dialog); a program that ends reports `reason: "exited"` and `exit_code`; a stop on a breakpoint says `reason: "breakpoint"`; if no session starts (a failed build) the answer is an error saying so |
| `debug_run_to_line` | Run to a file/line via a temporary breakpoint |
| `debug_step_over` / `debug_step_into` / `debug_step_out` | F8 / F7 / Shift+F8 |
| `debug_attach` | Attach the debugger to a running process by id (e.g. the program `project_run` started); it stops with its stack readable. `debug_stop` with `detach: true` lets it go on |
| `debug_pause` / `debug_stop` | Pause / stop the session (ends an attached program unless `detach`); a pause makes the program's main thread current (not the debugger's break-in thread) |
| `debug_get_state` | State and source location, in any state |
| `debug_get_call_stack` | Frames with file, line, function and address (`max_frames`) |
| `debug_get_locals` | Locals and parameters of a frame (`thread`, `frame`) |
| `debug_evaluate` | Evaluate a Pascal expression in the selected frame, or in `thread`/`frame` for this call only. Raw memory too: `^Byte($1000A0)[0..15]`, with a type the program uses (there is no separate memory dump tool; see [ADR-009](ADR-009.md#v09-registers-and-disassembly)) |
| `debug_select_frame` | Select a thread and stack frame, as the Threads and Call Stack windows do |
| `debug_set_variable` | Modify a variable or expression |
| `debug_get_exception` | The exception the program is paused at |
| `debug_add_watch` / `debug_remove_watch` / `debug_list_watches` | Watches window; values for the selected (or given) thread and frame |
| `debug_list_threads` | Threads with state and top frame |
| `debug_get_registers` | CPU registers of a thread and frame, as the Registers window shows them, plus `hex`; `changed` since the previous pause; `names` or `general` keep only some (the full list is ~20 KB) |
| `debug_disassemble` | Machine code around an address, a symbol, or a frame: bytes, instruction, function+offset, source lines, call/jump targets |
| `debug_get_output` | What the program wrote to its console, and debugger output |

### Project — `project_*`

| Tool | Description |
|---|---|
| `project_get_directory` | Root directory of the active project (contains the `.lpi`) |
| `project_list_files` | Source files of the active project |
| `project_get_settings` / `project_set_settings` | Target OS/CPU, output directory, custom options, debug info (`debug_info`: none, dwarf3, ...; the debugger needs DWARF), compiler and FPC version, LCL widgetset of the active build mode (set in the build-mode matrix, as Project Options does) |
| `project_add_file` / `project_remove_file` | Project file list (files stay on disk). Adding a file already in the project reports `already_in_project`. Removing a file open in the editor is refused until it is closed |
| `project_create_unit` | New unit on disk, added to the project and opened |
| `project_list_packages` | Required packages as in Project Inspector: version limits, resolved `.lpk`, status (`ok`, `not_found`, ...); `recursive` adds the whole graph in compile order |
| `project_add_package` / `project_remove_package` | Package dependencies in the `.lpi` |
| `project_search` | Case-insensitive text search across project files |
| `project_list_todos` | `TODO` / `FIXME` / `DONE` comments, as the IDE's ToDo List shows them |
| `project_build` | Incremental build; returns success and errors |
| `project_get_compiler_errors` | Errors and warnings of the last build |
| `project_run` | Build if needed and run without the debugger; optional `args` (stored in the run parameters). Answers with the program's stdout, stderr and exit code (waits up to `wait_seconds`, default 10; a program still running comes back with `running: true`) |
| `project_run_output` | The output of that program since the last read, its exit code once it ended; can wait for more, or stop it |
| `project_run_input` | Sends text to the stdin of that program (`project_run` with `stdin` or `keep_stdin_open`), or closes it; returns the answer |
| `project_get_windows` | The running program's visible windows (Windows: a tree of windowed controls, `Class "text" x,y wxh`, about 20 tokens a line. Linux (X11): the top-level windows only, found by process id, without the controls inside); `image` adds a PNG of each window (scaled to `max_size`), which also shows controls without a handle such as `TLabel`. Never waits for the program, so it also works while the program is paused in the debugger (the image is then copied from the screen) |
| `project_open` | Open a `.lpi` (or a program's `.lpr`, for which the `.lpi` is written next to it), closing the current project; refused while debugging or building, or with unsaved changes |
| `project_list_templates` / `project_create` | Project templates; create a project from one |

### Packages — `package_*`

| Tool | Description |
|---|---|
| `package_get_info` | A package by name or `.lpk` path: status, version, type, requirements with their status, the packages using it, output dir, search paths, compiler options, and (`files`) its files with units and `Register` |
| `package_list` | The packages loaded in the IDE (default: those that do not come with Lazarus) |
| `package_open` / `package_create` | Load an `.lpk` without installing it; create a package (`.lpk`, optional first unit) in a directory and load it |
| `package_get_settings` / `package_set_settings` | Package type, output dir, unit/include paths, compiler options, target, usage paths; old and new values returned, `.lpk` saved |
| `package_find_unit` | Which loaded packages contain a unit, and whether the project depends on them — for "Can't find unit" |
| `package_add_file` / `package_remove_file` | Files of a `.lpk`, as the package editor's Add/Remove: unit name and `Register` detected, unit/include path extended when needed |
| `package_add_dependency` / `package_remove_dependency` | Required packages of a `.lpk`, with version limits; cycles, unknown packages and new code for the IDE are refused (ADR-013) |
| `package_set_info` | Version, description, author and/or license of a `.lpk`, as on the package options' Package page; returns old and new values |
| `package_search_online` | Search the online package repository (Online Package Manager catalog, read locally): description, license, compatibility, install state, and the `.lpk` path if OPM already downloaded it |
| `package_download` | Download a package from the online repository into the Online Package Manager's folder: MD5 checked against the catalog, archive checked before extracting; installs nothing (HTTPS in-process or through curl; plain HTTP only when neither works) |
| `package_compile` | Compile a package (`package_name` or `.lpk`): with the IDE's compiler when it is open there (errors as data, also in the Messages window), else `lazbuild` — a smoke test before `ide_rebuild` |
| `package_install` / `package_uninstall` | Install or uninstall, then rebuild and restart the IDE, as `ide_rebuild` does |

Installing a package that is not installed yet with `package_install` is off
by default. Turn it on with
**Tools → MCP Assistant → Allow Assistants to Install Packages** (or the same
checkbox in **Tools → Options → MCP Assistant**); each install is
then shown to you in the IDE (package, author, license, dependencies) and
happens only if you click *Install* (no answer in 180 s means no). Rebuilding
packages that are already installed never asks. See [ADR-013](docs/adr/0013-user-consent-before-new-code.md).

### IDE — `ide_*`

| Tool | Description |
|---|---|
| `ide_ping` | `{"status":"ok","version":"x.y","client":"<id>"}` — confirms the server is back after `ide_rebuild` and shows the caller's identity |
| `ide_get_messages` | Everything in the Messages window, all urgency levels |
| `ide_get_exceptions` | Unhandled exceptions the IDE showed in its error dialog (access violations and others), with stack and the last MCP tool called before; also appended to `mcp-exceptions.log` in the Lazarus config folder |
| `ide_rebuild` | Rebuild and restart the IDE with its installed packages (`package_install` adds one); the server is gone for ~60 s |
| `ide_run_tests` | Build and run the FPCUnit test project; structured results, optional JUnit XML; `suite` runs one class or test, `env` sets environment variables for the run (for example `MCP_DEBUG_TESTS`) |

### Git — `git_*`

`git_status`, `git_diff`, `git_log`, `git_branches`, `git_add`, `git_commit`,
`git_checkout`, `git_stash`, `git_stash_pop`, `git_reset` (soft/mixed only —
no hard reset). `work_dir` defaults to the project directory.

`git_init` makes a repository of an existing directory and keeps its files
(`initial_branch`, default `main`; `gitignore=true` adds a Lazarus
`.gitignore` if there is none). It commits nothing and refuses inside an
existing repository.

`git_clone` clones a repository into a new folder (`url`, `target_dir`; optional
`branch` and `depth`). The user is asked in the IDE for every clone (ADR-013),
it runs without holding the IDE, and nothing is built or opened: the result lists
the `.lpi` and `.lpk` files found, for `project_open`.

For the file open in the editor: `git_blame` (who last changed a line, and in
which commit) defaults to the active editor's file and cursor line, and blames
unsaved edits as uncommitted; `git_diff` with `active_file` diffs that file in
its own repository.

### Resources

| URI | Content |
|---|---|
| `lazarus-ide://reference` | Lazarus/FPC component and IDE API reference (`docs/lazarus-knowledge.md`) |
| `lazarus-ide://system-prompt` | The server's instructions to every client (`docs/system-prompt.md`) |

### While a tool runs

Nobody is at the IDE's keyboard while a tool call executes, so the plugin
answers the IDE's "Some files have changed on disk" dialog with *Reload*,
which reloads only files without unsaved editor changes. Every HTTP response
carries `Connection: close`, and the server's sockets are not inheritable, so a
program started by the IDE cannot keep a connection open.

### Clients

`initialize` returns an `Mcp-Session-Id` header (and the same id as an
`mcp_session` cookie); clients send it back to identify themselves, and
`DELETE /mcp` ends the session. A session id the server didn't hand out since it
started (after `ide_rebuild`, say) gets HTTP 404, and the client starts a new session
with `initialize`. Requests without either share one identity, `anonymous`; a client
with a cookie jar (`curl -b jar -c jar`) gets its own.

---

## Requirements

- **Lazarus IDE** (tested with 4.6 on Windows and Linux)
- **Free Pascal Compiler** (bundled with Lazarus)
- **Claude Code** (or any MCP client that supports Streamable HTTP transport)

Package dependencies — all bundled with Lazarus: `SynEdit`, `IDEIntf`, `FCL`,
`CodeTools`, and `jcfbase` (JEDI Code Format, for `code_format`). JCF's IDE
plugin, `jcfidelazarus`, is optional; when it is installed, `code_format` uses
its settings.

---

## Installation

1. In Lazarus: **Package → Open Package File (.lpk)** → select `src/lazmcpassistant.lpk`.
2. In the package dialog: **Use → Install**.
3. Lazarus will ask to rebuild the IDE. Confirm. The IDE restarts with the plugin loaded.

---

## Usage

1. In the IDE: **Tools → MCP Assistant → Launch MCP Assistant**.
   - This starts the HTTP server on a random local port and opens Claude Code in a terminal window.
   - Windows opens a new console. Linux opens the first terminal it finds: `x-terminal-emulator`, `gnome-terminal`, `konsole`, `xfce4-terminal` or `xterm`. macOS opens Terminal.app.
   - The MCP config file is written to a stable path in your system temp directory and reused on subsequent launches.

2. Claude Code starts pre-configured with the server URL and bearer token. No manual `--mcp-config` flag needed for subsequent sessions — the config path is persisted in `mcpassistantoptions.xml`.

3. Tools are available as `mcp__lazarus-ide__<tool_name>` in Claude Code.

### Options

**Tools → Options → MCP Assistant** (also **Tools → MCP Assistant → Options...**):

| Setting | Empty means |
|---|---|
| Claude Code executable | `claude` on `PATH` |
| Working directory | The open project's directory |
| Extra command-line options | None |
| Terminal command (Linux/macOS), e.g. `kitty -e` | Detect a terminal |
| git executable | `git` on `PATH` |
| Listen address (IPv4) | `127.0.0.1`: this machine only. `0.0.0.0` or a machine address lets other machines connect over plain HTTP with the token: see [ADR-020](docs/adr/0020-listen-address-is-a-setting.md) |
| Client tokens | One named token per client on another machine: **Add token...** shows it once, masked, with an eye button and buttons to copy the token or the whole client config; only a hash is stored, so a lost token is revoked and replaced. **Revoke** cuts a client off at once and ends its sessions. The primary token (what the IDE writes for clients on this machine) is never shown; **Regenerate primary token...** replaces it. See [ADR-021](docs/adr/0021-named-client-tokens.md) |
| Allow assistants to install packages | Off; see [ADR-013](docs/adr/0013-user-consent-before-new-code.md) |

Settings are stored in `mcpassistantoptions.xml` in the IDE's primary config
directory, together with the server's token and port.

---

## Self-hosted development

This plugin was built using itself. The development loop:

1. **Launch MCP Assistant** — starts the server and opens Claude Code.
2. Claude edits source files in the plugin repository using `editor_edit_text`, `project_create_unit`, etc.
5. Claude runs the `poll_command` from the `ide_rebuild` response, which waits until the new IDE is up. If `startlazarus` never brings the IDE back (seen once: no `lazarus` process and no build running), the script starts the IDE itself after 45 s, from the same executable and config directory.
4. Claude calls `ide_rebuild`. The IDE exits and `startlazarus.exe` rebuilds it (~60 s).
5. Claude runs the `poll_command` from the `ide_rebuild` response, which waits until the new IDE is up.
6. The new IDE starts with the same bearer token and the same ephemeral port, so Claude Code's next call just works: its old session id gets a 404, and it starts a new session by itself (verified). Changed tool descriptions still reach Claude Code only in a new conversation: it keeps the ones it loaded earlier, even in the new session and after `/mcp reconnect` (seen with tool search on).

**Why this works across a restart:** the bearer token is generated once and stored in `mcpassistantoptions.xml`; subsequent starts reuse it. The new IDE writes the same token back to the same config file at the same path. The port stays stable because `TProcess.InheritHandles := False` prevents Claude Code from holding a duplicate of the listening socket across the rebuild.

**Boot-loop escape hatch (Windows):** if a bad build causes the IDE to crash on startup, open a terminal and run:
```
rename lazarus.old.exe lazarus.exe
```
from the Lazarus installation directory. `startlazarus.exe` always keeps the previous working executable as `lazarus.old.exe`.

Architecture details: [ADR-004](docs/adr/0004-self-hosted-development.md).

---

## Knowledge injection

Every MCP client gets `docs/system-prompt.md` as the server's `instructions` in the `initialize` reply, which clients add to the model's context (Claude Code puts it into the system prompt), so Claude launched from the IDE needs no `--append-system-prompt`. This short text covers workflows, tool preferences and the rules Claude must follow (package-install consent, debugger exceptions, rebuild/reconnect). It leaves per-tool details to the tool descriptions.

The Lazarus/FPC reference covers LCL component packages, installation patterns and common gotchas, so Claude doesn't hallucinate package names or import paths. It is served on demand as the `lazarus-ide://reference` MCP resource, and the system prompt tells Claude to read it before answering such questions.

To update the reference: edit `docs/lazarus-knowledge.md`, then run `tools/gen_knowledge_inc.exe` from the project root to regenerate `src/lazarus_knowledge.inc` and `src/system_prompt.inc` (build it once with `fpc -MObjFPC -Scghi -FEtools tools/gen_knowledge_inc.pas`), then rebuild the IDE. The same applies to `docs/system-prompt.md`.

---

## Testing

A standalone FPCUnit test project lives in `tests/`. Plugin units without IDE dependencies (utilities, launcher, settings file) are tested in-process. Everything else is tested over HTTP against the running IDE. The `ide_run_tests` tool builds and runs it, or by hand:

```
lazbuild tests/mcpserver_tests.lpi
tests/mcpserver_tests.exe --all --format=plain
```

**Suites:**

| Suite | Count | Requires |
|---|---|---|
| `TTestUtils` | 11 | Nothing (always runs) |
| `TTestJUnitWriter` | 8 | Nothing (always runs) |
| `TTestLauncher` | 10 | Nothing (always runs): sh quoting, launch script, terminal choice |
| `TTestSettingsFile` | 3 | Nothing (always runs): settings save/load, obsolete keys removed |
| `TTestProtocol` | 12 | MCP server reachable: JSON-RPC, `initialize` (version negotiation, instructions) |
| `TTestAuth` | 7 | MCP server reachable |
| `TTestProjectTools` | 6 | MCP server reachable |
| `TTestSession` | 8 | MCP server reachable: session id, cookie, anonymous, `DELETE /mcp`, 404 for unknown session ids |
| `TTestToolSmoke` | 22 | MCP server reachable: one call per tool group, on `tests/fixtures/` and temp files; `editor_replace_range`; a file deleted and created again outside the IDE |
| `TTestPackageEdit` | 6 | MCP server reachable: package editing on `tests/fixtures/fixturepkg/` (changed and changed back); `package_download` refusing an unknown package (no network) |
| `TTestPackageManage` | 3 | MCP server reachable: `package_create`/`get_settings`/`set_settings`/`compile` (IDE and lazbuild) on a package written to a temp directory, `project_list_files`/`project_search` scoped to it |
| `TTestFormUndo` | 11 | MCP server reachable: `form_undo`/`form_redo` and what the `form_*` tools record, on a temp copy of the fixture form |
| `TTestCodeComplete` | 8 | MCP server reachable: `code_complete` on a temp copy of `tests/fixtures/fixturecomplete.pas` (classes, locals, forward procedures, unsaved edits, a 600-method class, an include file created later) |
| `TTestCodeFormat` | 7 | MCP server reachable: `code_format` on temp files (whole file, line range, parse errors, include files, trailing lines) |
| `TTestCodeRename` | 5 | MCP server reachable: `code_rename_identifier` on two temp units (dry run, rename into unsaved editors, unsaved edits, `auto_save`, refusals) |
| `TTestConsent` | 2 | MCP server reachable, installs not allowed: `package_install` of a new package is refused; `ide_rebuild` refuses `lpk_path` |
| `TTestDebugger` | 13 | Opt-in: `MCP_DEBUG_TESTS=1`, or `tests/debuggee/mcpdebuggee.lpi` open in the IDE. Breakpoint/step/evaluate, exception without a dialog, lease refusal, debugger lock, lease expiry; conditions, pass counts, data and symbol breakpoints, frames, threads, registers and disassembly (about 40 s) |

The runner detects the running server by reading `mcpassistantoptions.xml` and pinging it. It looks in `%LOCALAPPDATA%\lazarus` on Windows and `~/.lazarus` elsewhere; set `MCP_OPTIONS_FILE` if Lazarus runs with `--pcp`. If the server is not up, the suites that need it are skipped. With `MCP_DEBUG_TESTS=1` the debugger suite opens the debuggee project itself and reopens yours afterwards; it stops with an error instead if your project or an editor has unsaved changes.

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
| [ADR-009](docs/adr/0009-debugger-integration.md) | Debugger integration: blocking checkpoint model, and how it was built (polling, async data, the socket-inheritance hang) |
| [ADR-010](docs/adr/0010-tool-naming-scheme.md) | Tool naming scheme `<category>_<action>`, titles, annotations; v0.7 → v0.8 rename table |
| [ADR-011](docs/adr/0011-no-ide-modals-in-mcp-sessions.md) | No IDE modals in MCP-driven debug sessions |
| [ADR-012](docs/adr/0012-multiple-clients.md) | Multiple clients: session identity, debug session lease, debugger lock |
| [ADR-013](docs/adr/0013-user-consent-before-new-code.md) | User consent before new code enters the IDE (package installs) |
| [ADR-014](docs/adr/0014-designer-undo.md) | Designer undo: the IDE's undo list, replacement steps, keeping references |
| [ADR-015](docs/adr/0015-packages-and-bare-programs-addressed-per-call.md) | Packages and bare programs: addressed per call, no active state |
| [ADR-016](docs/adr/0016-running-without-the-debugger.md) | Running without the debugger: output, exit code, later attach |
| [ADR-017](docs/adr/0017-declaration-lookup-through-uses-clauses.md) | Declaration lookup through uses clauses; reference search scopes |
| [ADR-018](docs/adr/0018-https-for-package-download-via-curl.md) | HTTPS for package_download through the curl executable |
| [ADR-019](docs/adr/0019-debug-attach-without-the-ide-dialog.md) | debug_attach: the IDE's attach path without its process dialog |
| [ADR-020](docs/adr/0020-listen-address-is-a-setting.md) | The listen address is a setting; the loopback is the default |
| [ADR-021](docs/adr/0021-named-client-tokens.md) | Named client tokens, stored as tagged hashes and shown once |

ADR-007 was never assigned; no document is missing.

---

## Planned

For v1.0:

- **macOS builds.** Never compiled or run there yet.

---

## Provenance
Designed and directed by Sergei Pechenko: the requirements, design decisions (recorded as ADRs in [`docs/adr/`](docs/adr/)), reviews and acceptance. Most of the code, tests and docs were written by Claude (Anthropic) from his prompts and decisions, and checked by the test suite and by using the tools inside the IDE they extend. Because the code is largely AI-generated, no warranty of originality is given beyond the license's disclaimer.

## License

BSD-3-Clause — see `LICENSE`.
