# Tool reference

Every tool of the Lazarus MCP Assistant. Setup and an overview are in the [README](../README.md).

Tools are named `<category>_<action>`; `tools/list` returns them sorted, each
with a human-readable `title` ("Debugger: get call stack") and annotations:
- `readOnlyHint` for tools that change no file or project. Moving the cursor
  or opening a tab counts as read-only.
- `destructiveHint` only for changes that neither Ctrl+Z nor `form_history` can
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

**Renamed in 1.7.0.** Some tools were fused and some parameters renamed so that one idea
has one name. The old names work through all of 1.x, with a one-line notice the first time a
session uses one, and **are refused from 2.0 on**. The list, and what to change in saved
prompts, skills and permission allow-lists, is in [renamed-tools.md](renamed-tools.md).

## Editor — `editor_*`

| Tool | Description |
|---|---|
| `editor_get_active` | Active editor file path and buffer (`what` content, default), the cursor position (`cursor`) or the selected text and range (`selection`) |
| `editor_list_open` | All open editor tabs |
| `editor_read_file` | Read any file by absolute path; prefers the live editor buffer (unsaved changes) over disk |
| `editor_open` | Open a file in the editor without moving the cursor; returns `already_open` |
| `editor_create_file` | Create a new text file on the IDE's machine and open it; only inside the project, a loaded package's folder or the temp folder, never in `.git`, no overwrite unless `overwrite:true` (and not while open) |
| `editor_set_cursor` | Move the cursor (opens the file if needed) |
| `editor_edit_text` | **Preferred edit.** Replace `old_string` with `new_string`; fails if missing or ambiguous; `replace_all` for every match. Undoable with Ctrl+Z |
| `editor_replace_range` | Replace a range given by start and end, or start and `delete_len` (no end inserts, empty text deletes) — for coordinates from `code_*` tools |
| `editor_save` | Save a buffer (a form unit saves its `.lfm` too) |
| `editor_revert` | Discard unsaved changes and reload from disk |
| `editor_close` | Close a tab, discarding unsaved changes |

Where the editing tools may write, and what the limits do not do: see [write-scope.md](write-scope.md).

## CodeTools — `code_*`

| Tool | Description |
|---|---|
| `code_get_outline` | Uses, types, class members and routines with line numbers (no bodies) |
| `code_get_unit_interface` | The interface section of a unit |
| `code_get_procedure_ast` | Locals (with type) and the statements of one routine as a tree (if/for/while/repeat/try/case/with, calls, assignments) with lines and columns; `depth` sets how many levels ([ADR-008](adr/0008-structural-source-editing.md)) |
| `code_find_declaration` | Where an identifier is declared, with a context snippet (`show=true` also jumps the editor cursor there); follows the uses clauses (RTL, sibling units) and works in a program; optional `line`/`col` pick a use |
| `code_get_identifier_info` | Type, declaration and hint text for the identifier at file/line/col |
| `code_find_references` | Every reference to an identifier across the project (and the file asked about, even outside the project). `also` (`same_folder`, `lcl`, `components`, `rtl`, `fcl`, `packages`) and `search_dir` add other sources, e.g. to see how an API is used; only files that mention the name are parsed, at most `max_files` (default 300) |
| `code_rename_identifier` | Rename across all project files from the declaration or any reference, as the IDE's Rename Identifier does; `dry_run` lists the references first. Unit names are refused |
| `code_find_descendants` | The classes (and interface implementers) below a class or interface, the whole tree unless `direct_only`; scope as `code_find_references` ([ADR-027](adr/0027-navigation-and-refactoring-tools.md)) |
| `code_find_overrides` | The methods of the same name in the classes below the one that declares a method: override, reintroduce or plain |
| `code_unit_dependencies` | Uses graph: of one unit (uses, used by, unneeded units) or of the whole project with its cycles |
| `code_find_unused` | Symbols of a unit nothing refers to (a hint: widen the search before deleting public API) |
| `code_extract_method` | Extract statements into a procedure or method, as the IDE's Extract Procedure; `dry_run` reports what is possible |
| `package_move_unit` | Move a unit between two packages and add the requirement that makes necessary; refuses a cycle; `dry_run` shows the plan |
| `code_add_uses` | Add a unit to the interface or implementation uses clause |
| `code_insert_in_procedure` | Insert text right after a routine's `begin`; an overloaded name is refused with the candidates, `line` picks one |
| `code_edit_statement` | Replace, delete, insert next to or wrap (begin, try, if, while, for, with) ONE statement of a body, found by the `line`/`col` of `code_get_procedure_ast`; the text around it stays ([ADR-008](adr/0008-structural-source-editing.md)) |
| `code_replace_procedure_body` | Replace everything between a routine's `begin` and `end`; an overloaded name is refused with the candidates, `line` picks one |
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

## Form designer — `form_*`

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
| `form_create` | New form, data module or frame (`kind`): `.pas` + `.lfm`, added to the project (or, with `package_name`/`lpk_path`, to that package) and opened |
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
| `form_history` (`action` undo / redo) | One step of the designer's undo list, as Edit > Undo / Redo (Ctrl+Z) in the designer; returns `can_undo` / `can_redo` |

Designer changes are in memory until `editor_save` on the unit.

**Undo.** Every changing `form_*` call is one step in the designer's own undo
list, shared with the user's Ctrl+Z and with other clients; `form_history` (`action` undo or redo) takes
back the last step, whoever made it. Simple properties, `Name`, `Parent`, adds,
deletes and `form_arrange` are recorded property by property. Changes the
designer cannot replay that way (sub-properties such as `Font.Color`, string
lists, collection items, menus, events, component references) are recorded as
a replacement of the whole component (a menu item: its whole menu). References
that other components held to it are restored. Results say `"undoable"`. The
form itself cannot be replaced, so changes of that kind to the form itself
(`Form1.Font.Color`, `Form1.Menu`, `Form1.OnCreate`) are not undoable. Undo restores the form, not the source: a field returns with its
component, but a created event handler method stays. See [ADR-014](adr/0014-designer-undo.md).

## Debugger — `debug_*`

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
debugger call runs at a time. See [ADR-012](adr/0012-multiple-clients.md).

| Tool | Description |
|---|---|
| `debug_set_breakpoint` / `debug_remove_breakpoint` / `debug_list_breakpoints` | Source (file + line), address (`$401000`, or `Proc+12` for a procedure with debug info, resolved while paused) and data breakpoints (`data` + `watch` write/read/readwrite); each with `condition` and `pass_count`. Setting one again at its location changes it. No session needed, except to resolve a symbol |
| `debug_run` | Start, or continue from a pause (F9). Refused up front when the project has no DWARF info (the IDE would ask in a dialog); a program that ends reports `reason: "exited"` and `exit_code`; a stop on a breakpoint says `reason: "breakpoint"`; if no session starts (a failed build) the answer is an error saying so |
| `debug_run_to_line` | Run to a file/line via a temporary breakpoint |
| `debug_step` (`kind` over / into / out) | F8 / F7 / Shift+F8 |
| `debug_attach` | Attach the debugger to a running process by id (e.g. the program `project_run` started); it stops with its stack readable. `debug_stop` with `detach: true` lets it go on |
| `debug_pause` / `debug_stop` | Pause / stop the session (ends an attached program unless `detach`); a pause makes the program's main thread current (not the debugger's break-in thread) |
| `debug_get_state` | State and source location, in any state |
| `debug_get_call_stack` | Frames with file, line, function and address (`max_frames`) |
| `debug_get_locals` | Locals and parameters of a frame (`thread`, `frame`) |
| `debug_evaluate` | Evaluate a Pascal expression in the selected frame, or in `thread`/`frame` for this call only. Raw memory too: `^Byte($1000A0)[0..15]`, with a type the program uses (there is no separate memory dump tool; see [ADR-009](adr/0009-debugger-integration.md#v09-registers-and-disassembly)) |
| `debug_select_frame` | Select a thread and stack frame, as the Threads and Call Stack windows do |
| `debug_set_variable` | Modify a variable or expression |
| `debug_get_exception` | The exception the program is paused at |
| `debug_add_watch` / `debug_remove_watch` / `debug_list_watches` | Watches window; values for the selected (or given) thread and frame |
| `debug_list_threads` | Threads with state and top frame |
| `debug_get_registers` | CPU registers of a thread and frame, as the Registers window shows them, plus `hex`; `changed` since the previous pause; `names` or `general` keep only some (the full list is ~20 KB) |
| `debug_disassemble` | Machine code around an address, a symbol, or a frame: bytes, instruction, function+offset, source lines, call/jump targets |
| `debug_get_output` | What the program wrote to its console, and debugger output |

## Project — `project_*`

| Tool | Description |
|---|---|
| `project_get_directory` | Root directory of the active project (contains the `.lpi`) |
| `project_list_files` | Source files of the active project |
| `project_list_directory` | Files and folders of any directory on disk (depth up to 5, size per file, capped) |
| `project_get_settings` / `project_set_settings` | Target OS/CPU, output directory, custom options, debug info (`debug_info`: none, dwarf3, ...; the debugger needs DWARF), compiler and FPC version, LCL widgetset of the active build mode (set in the build-mode matrix, as Project Options does), and the debug-run switches `heaptrc`, `trash_variables`, `line_info`, `io_checks`, `range_checks`, `overflow_checks`, `stack_checks`, `assertions`, `smart_link`, `verify_method_calls` and `optimization` (0-3); the build modes (`build_modes` lists them, `mode_options` gives each mode's own custom options and switches (read only), `build_mode` makes one active, and the other settings of the call then change that mode); the application `icon` (an .ico file, `default` or `none`) and `use_manifest` |
| `project_add_file` / `project_remove_file` | Project file list (files stay on disk). Adding a file already in the project reports `already_in_project`. Removing a file open in the editor is refused until it is closed |
| `project_create_unit` | New unit on disk, added to the project and opened |
| `project_list_packages` | Required packages as in Project Inspector: version limits, resolved `.lpk`, status (`ok`, `not_found`, ...); `recursive` adds the whole graph in compile order |
| `project_add_package` / `project_remove_package` | Package dependencies in the `.lpi` |
| `project_search` | Case-insensitive text search across project files |
| `project_list_todos` | `TODO` / `FIXME` / `DONE` comments, as the IDE's ToDo List shows them |
| `project_build` | Incremental build; returns success and errors |
| `project_get_compiler_errors` | Errors and warnings of the last build |
| `project_run` | Build if needed and run without the debugger; optional `args` (stored in the run parameters). Answers with the program's stdout, stderr and exit code (waits up to `timeout_s`, default 10; a program still running comes back with `running: true`); a heaptrc report in stderr also comes back parsed as `heap_report` (unfreed blocks and bytes, each leak's size and call stack) |
| `project_run_output` | The output of that program since the last read, its exit code once it ended; can wait for more, or stop it |
| `project_run_input` | Sends text to the stdin of that program (`project_run` with `stdin` or `keep_stdin_open`), or closes it; returns the answer |
| `project_get_windows` | The running program's visible windows (Windows: a tree of windowed controls, `Class "text" x,y wxh`, about 20 tokens a line. Linux (X11): the top-level windows only, found by process id, without the controls inside); `image` adds a PNG of each window (scaled to `max_size`), which also shows controls without a handle such as `TLabel`. Never waits for the program, so it also works while the program is paused in the debugger (the image is then copied from the screen). `ide=true` with `window` looks at the IDE's own windows instead (a form being built, a dialog); `window` is required then, so only the windows you name are shown |
| `project_open` | Open a `.lpi` (or a program's `.lpr`, for which the `.lpi` is written next to it), closing the current project; refused while debugging or building, or with unsaved changes |
| `project_close` | Close the current project like File > Close Project: the IDE shows its Project Wizard, which `project_create` / `project_open` dismiss; refused while debugging or building, or with unsaved changes |
| `project_list_templates` / `project_create` | Project templates; create a project from one |

## Packages — `package_*`

| Tool | Description |
|---|---|
| `package_get_info` | A package by name or `.lpk` path: status, version, type, requirements with their status, the packages using it, output dir, search paths, compiler options, and (`files`) its files with units and `Register` |
| `package_list` | The packages loaded in the IDE (default: those that do not come with Lazarus) |
| `package_open` / `package_create` | Load an `.lpk` without installing it; create a package (`.lpk`, optional first unit) in a directory and load it |
| `package_get_settings` / `package_set_settings` | Package type, output dir, unit/include paths, compiler options, target, usage paths; old and new values returned, `.lpk` saved |
| `package_find_unit` | Which loaded packages contain a unit, and whether the project depends on them — for "Can't find unit" |
| `package_add_file` / `package_remove_file` | Files of a `.lpk`, as the package editor's Add/Remove: unit name and `Register` detected, unit/include path extended when needed |
| `package_add_dependency` / `package_remove_dependency` | Required packages of a `.lpk`, with version limits; cycles, unknown packages and new code for the IDE are refused (ADR-013) |
| `package_save` | Write unsaved packages to disk: the named one, or all modified ones; refused, naming the cause, when the IDE would have to ask a question |
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
packages that are already installed never asks. See [ADR-013](adr/0013-user-consent-before-new-code.md).

## IDE — `ide_*`

| Tool | Description |
|---|---|
| `ide_ping` | `{"status":"ok","version":"x.y","client":"<id>"}` — confirms the server is back after `ide_rebuild` and shows the caller's identity |
| `ide_get_status` | Overview, several tools in one call: the open project as `project_get_directory` reports it (name, `.lpi`, directory; the section is omitted when no project is open), unsaved editors as `editor_list_open` (count and at most 10 file names), the debugger state with the session lease as `debug_get_state` reports it, and the server version. `include_git=true` adds the git section of `git_status` (`in_repo`, branch, changed files count) for the project's directory; it is off by default because `git status` can be slow |
| `ide_report` | Writes versions, plugin and project settings, packages and the last 200 lines of the three logs into one Markdown file in the Lazarus config folder (`mcp-report-<UTC time>.md`, three newest kept) and returns its path; the same as Tools > MCP Assistant > Write Report. For bug reports: read it before posting |
| `ide_get_messages` | Everything in the Messages window, all urgency levels |
| `ide_get_open_dialogs` | The dialogs blocking the IDE's main thread: LCL modal forms and native Windows dialogs, with caption, text and button captions |
| `ide_answer_dialog` | Clicks a button of such a dialog: through the form for an LCL dialog, by clicking the button for a native one (Windows). Never answers a consent dialog (installing, cloning ...); `caption` picks one of several |
| `ide_get_exceptions` | Unhandled exceptions the IDE showed in its error dialog (access violations and others), with stack and the last MCP tool called before; also appended to `mcp-exceptions.log` in the Lazarus config folder |
| `ide_rebuild` | Rebuild and restart the IDE with its installed packages (`package_install` adds one); the server is gone for ~60 s. Refused, changing nothing, while an editor or a package has unsaved changes (`save_unsaved` saves them first; a package that was never saved, or has a file missing on disk, still stops it) or the package does not compile (`skip_compile` skips that check); a build that fails leaves the IDE running, reopens the editors and brings the server back, with the errors as the answer (ADR-026) |
| `ide_run_tests` | Build and run the FPCUnit test project; structured results, optional JUnit XML; `suite` runs one class or test, `env` sets environment variables for the run (for example `MCP_DEBUG_TESTS`) |
| `ide_show_markdown` | Show a Markdown document to the user in an IDE window (tabs, without taking the focus), rendered by `TIpHtmlPanel`: headings, lists, tables, code, http(s) links, and images from a project-relative path or a Base64 `data:` URI. Display only; returns `{shown, tab}`; `tab` replaces that document; `file` instead of `markdown` shows a Markdown file in one tab per file that follows it (the open editor's text, else the disk), so the text is not sent each time ([ADR-024](adr/0024-show-markdown-tool.md)) |
| *(menu)* | Tools > MCP Assistant > View Markdown..., View > Markdown Viewer... and the source editor's "View as Markdown" show the active `.md` file (or one you pick) in the same window, one tab per file; relative links to other `.md` files open in it |

## Git — `git_*`

`git_status`, `git_diff`, `git_log`, `git_branches`, `git_add`, `git_commit`
(`amend=true` folds the staged changes into the last commit; refused once a remote
branch holds it), `git_checkout` (`create=true` makes a new branch), `git_branch_delete` (a merged local
branch only, `git branch -d`; no force), `git_cherry_pick` (a commit or a range `a..b`;
`abort=true` undoes one that stopped on a conflict), `git_archive` (committed files of a ref
into a new .tar, .tar.gz, .tgz or .zip; never overwrites; the output path is write-checked), `git_stash` (`action` push: all changes, or
only `paths`; pop applies a stash entry), `git_reset` (soft/mixed only — no hard reset).
`work_dir` defaults to the project directory.

`git_init` makes a repository of an existing directory and keeps its files
(`initial_branch`, default `main`; `gitignore=true` adds a Lazarus
`.gitignore` if there is none). It commits nothing and refuses inside an
existing repository.

`git_clone` clones a repository into a new folder (`url`, `target_dir`; optional
`branch` and `depth`). The user is asked in the IDE for every clone (ADR-013),
it runs without holding the IDE, and nothing is built or opened: the result lists
the `.lpi` and `.lpk` files found, for `project_open`.

Remotes and history ([ADR-028](adr/0028-git-remote-and-history-tools.md)):

- `git_remote` (`list`, `add`, `set_url`, `rename`, `remove`), `git_fetch` (a configured remote; no
  tags unless asked), `git_pull` (`ff-only` by default, or `merge`, or `rebase`), `git_push` (one branch
  and named tags; `force` is `--force-with-lease`) and `git_tag` (`list`, `create`, `delete`; local).
  **The user is asked in the IDE** for every push, every pull and every change of a remote's address,
  with the remote, the address git will use and the commits that would go; there is no "remember" and no
  setting that skips it. A force push asks a second question that names the commits it would discard.
  Fetch from a configured remote, listing and local tags do not ask. No remote or branch name is assumed
  (`origin` is only what `git clone` calls the first one), and every behavior a result depends on is
  named on the command line, so a user's or a repository's `push.default`, `pull.rebase` or `merge.ff`
  cannot change what a tool does; the answer carries the exact command that ran.
- `git_merge` (`ff`, `squash`), `git_rebase` (`upstream`, `onto`; never interactive), `git_squash` (`count`
  or `since`, `message`), `git_resolve` (one side of a whole file, or delete it), `git_merge_abort`,
  `git_rebase_abort` and `git_rebase_continue`. Each refuses to start unless the tracked files are clean,
  no editor has unsaved changes and nothing else is in progress, and makes a **backup ref**
  (`refs/mcp-backup/<branch>/<UTC time>`) first: `git_reset` to it undoes the operation, `git_branches`
  with `backups=true` lists them and `delete_backups=N` removes the old ones. A conflict is left in git's
  own state and reported with the files and the next steps. Rebase and squash (and `git_reset`) warn when
  commits that are already on a remote would be rewritten. They need git 2.38 (`git_merge`: 2.27).

Testing on another machine ([ADR-035](adr/0035-serving-code-to-a-test-machine.md)):

- `git_serve` lets **one** other machine fetch the repository that holds the open project, read-only,
  over plain HTTP. `link` asks the user once and returns a setup for that machine (a remote `mcp` and a
  git credential helper, an `instantfpc` script, [`scripts/git-credential-mcp.pas`](../scripts/git-credential-mcp.pas),
  or [`scripts/git-credential-mcp`](../scripts/git-credential-mcp) where there is no FPC); after that the
  assistant works without dialogs: `start` (opens the listener, closes itself after the fetch or the
  `minutes`), then `git_fetch` and `git_reset` on the other machine. Only the linked address can connect,
  the password is a code that changes every 30 seconds (TOTP), five wrong codes close the door for five
  minutes. With `snapshot` (the default) the tracked files go as they are on disk, uncommitted changes
  included. Untracked files stay home unless `include` names them (paths or patterns relative to the
  repository root, e.g. a new unit); every `start` says how many were left out. Also `unlink`, `links`,
  `status`, `stop`. A machine without a link: `start` asks the user
  every time and returns ready `bash` and `powershell` commands with a code of a minute
  ([`scripts/mcp-pull.sh`](../scripts/mcp-pull.sh) does the same from a file).

For the file open in the editor: `git_blame` (who last changed a line, and in
which commit) defaults to the active editor's file and cursor line, and blames
unsaved edits as uncommitted; `git_diff` with `active_file` diffs that file in
its own repository.

## Resources

| URI | Content |
|---|---|
| `lazarus-ide://reference` | Lazarus/FPC component and IDE API reference (`docs/lazarus-knowledge.md`) |
| `lazarus-ide://system-prompt` | The server's instructions to every client (`docs/system-prompt.md`) |

## While a tool runs

Nobody is at the IDE's keyboard while a tool call executes, so the plugin
answers the IDE's "Some files have changed on disk" dialog with *Reload*,
which reloads only files without unsaved editor changes. Before each call it
also reloads, quietly, the open editors whose file an agent changed with its own
tools. An editor with unsaved changes is never overwritten: when its file changed on
disk, a review window opens (the Tools menu opens it by hand too) with three
panes, the editor's text, the result and the disk's text, a merge of both where
the changes do not overlap, and per-change arrows to take either side; only the
result pane is editable, and nothing is written to the disk. *Options > MCP
Assistant* can instead keep the editor's text and save the disk's version beside
the file as `name.ext.agent`, or let the editor take the disk's text (undo with
Ctrl+Z). The next tool result tells the assistant which happened. Every HTTP response
carries `Connection: close`, and the server's sockets are not inheritable, so a
program started by the IDE cannot keep a connection open.

## Clients

`initialize` returns an `Mcp-Session-Id` header (and the same id as an
`mcp_session` cookie); clients send it back to identify themselves, and
`DELETE /mcp` ends the session. A session id the server didn't hand out since it
started (after `ide_rebuild`, say) gets HTTP 404, and the client starts a new session
with `initialize`. Requests without either share one identity, `anonymous`; a client
with a cookie jar (`curl -b jar -c jar`) gets its own.
