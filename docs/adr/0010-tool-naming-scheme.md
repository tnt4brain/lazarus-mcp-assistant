# ADR-010 — Tool Naming Scheme

**Status:** Accepted (v0.8)  
**Date:** 2026-10-14

## Context

The tool set grew one batch at a time (ADR-003, -006, -007, -009) to 90 tools, and
every batch named its tools in its own way:

- Verb first, noun first and bare verbs were mixed: `get_debug_state`,
  `step_over`, `run_debugger`, `exception_info`, `compile_plugin`, `ping`.
- Nothing in a name said which part of the IDE a tool works on, so related
  tools were scattered through `tools/list`. `get_project_files` and
  `get_open_editors` sat next to each other, while the 16 debugger tools were
  spread across the alphabet.
- The same idea had several spellings: `get_` / `find_` / `list_` for queries, and
  `create_` / `add_` for new things.
- `run_with_args` duplicated `run_project` with one extra argument.
- The tool `ping` had the same name as the JSON-RPC method `ping`.
- Clients show the tool name in approval prompts. An assistant picks tools by
  name, and so does a human writing an allow-list such as
  `mcp__lazarus-ide__debug_*`. A name that names its area helps both.

## Decision

### 1. `<category>_<action>`

Every tool name is a category prefix followed by an action:

| Prefix | Category title | Scope |
|---|---|---|
| `debug_` | Debugger | breakpoints, run control, stack, locals, watches, threads, output |
| `editor_` | Editor | source-editor tabs, buffers, cursor, text edits, save/close |
| `code_` | CodeTools | parser-backed navigation and refactoring |
| `form_` | Form designer | designer, Object Inspector, palette |
| `project_` | Project | project file list, settings, build/run, search, ToDo list |
| `package_` | Packages | package info, compile, install/uninstall |
| `ide_` | IDE | IDE-wide: rebuild, messages window, tests, ping |
| `git_` | Git | git commands in the project directory |

A tool belongs to the IDE area whose state it reads or changes, not to the API it
calls. For example, `project_search` greps project files, and `project_list_todos`
lists the IDE's ToDo view of the project.

### 2. Actions use a fixed vocabulary

| Verb | Meaning |
|---|---|
| `get_` | read one thing (state, properties, call stack) |
| `list_` | read a set of things (breakpoints, files, watches) |
| `find_` | resolve a reference (declaration, usages) |
| `set_` | change a value in place |
| `add_` | put a new or existing thing into a container: component onto a form, item into a collection or menu, file into the project, unit into uses, watch into the session |
| `remove_` | take a thing out of its container without destroying it (file from project, unit dependency, watch, breakpoint) |
| `delete_` | destroy a thing that lives in the form or source (component, collection item) |
| `create_` | make a standalone artifact (unit, form, project, event handler) |
| `move_` | change a thing's position or parent |
| bare verb | an action named the way the IDE names it (`debug_run`, `debug_step_over`, `editor_save`, `project_build`, `ide_rebuild`) |

### 3. Titles and annotations come from the same place

- `MakeTool` (`McpToolContext.pas`) derives the human-readable title from the
  prefix, so `debug_get_call_stack` becomes "Debugger: get call stack". It
  writes the title both to `title` (MCP 2025-06-18) and to `annotations.title`
  (older clients).
- Every tool states `readOnlyHint` / `destructiveHint` explicitly, using one of
  three presets:
  - `MCP_ANN_RO`
  - `MCP_ANN_WRITE`
  - `MCP_ANN_DEST`: deletes or overwrites without an undo path. Examples are
    `form_delete_component`, `git_reset` and `editor_revert`.
- `openWorldHint` is always false, since everything is local.
- Tools that only move the cursor or open a tab count as read-only.
- ADR-012 relies on these annotations to decide which tools other clients may
  call during a debug session, so they are load-bearing, not cosmetic.

### 4. `tools/list` is sorted by name

Sorting by name places each category's tools together, whichever unit registers them.

### 5. Clean break, no aliases

The old names were removed in v0.8 without compatibility aliases:

- Aliases would double the size of `tools/list`, and every client pays for that in
  context tokens on every session.
- Two names for one tool make an assistant's choice less predictable.
- The only clients are this project's own users, and they can reconnect.

Merged or renamed beyond the prefix:

- `run_with_args` was merged into `project_run`, which now has an optional `args`.
- `ping` became `ide_ping`. The JSON-RPC `ping` method is unchanged.

### 6. Path arguments are normalised once, for every tool (added 2026-10-14)

Clients spell paths differently: Claude Code on Windows often sends `D:/x/f.pas`,
while the IDE names the same file `D:\x\f.pas`. Tools that compared names
failed for the first spelling: every `form_*` tool, breakpoint removal and
project-file removal (bfd3f26).

So `HandleToolsCall` runs `McpNormalizePathArgs` (in `McpUtils`) before
dispatch. It covers the arguments named `file`, `file_path`, `path`,
`form_file`, `filename`, `directory`, `project_dir`, `work_dir`, `lpk_path`,
`test_project` and `junit_out`:

- **Absolute paths** go through `CleanAndExpandFilename`: native separators, no
  `.` or `..` segments.
- **Relative paths** stay as they are. Each tool resolves them against its own
  base, the project or the repository directory, never against the IDE's
  working directory.
- **`output_dir`** isn't touched. It is stored in the `.lpi` as written,
  macros included.

New tools get this for free if they use one of these names for path arguments.
Code that calls tools internally, bypassing `HandleToolsCall`, normalises for
itself.

**One name for one file (v1.0).** A tool's single source file is `file`. The
tools that called it `file_path` (`editor_open`, `debug_set_breakpoint`,
`debug_remove_breakpoint`, `debug_run_to_line`, `project_add_file`,
`project_remove_file`, `project_open`), `path` (`editor_read_file`) or
`filename` (`project_create_unit`) take `file` now. The old names still work:
`McpRenameLegacyFileArg` renames them before dispatch. Other names stay where
they say more: `form_file`, `lpk_path`, and `git_diff`'s `path`, which can be
a directory.

## Alternatives considered

- **Dotted namespaces (`debug.run`).** These read well, but some clients and LLM APIs
  restrict tool names to `[A-Za-z0-9_-]`, and `.` gets rejected or rewritten.
- **Noun-last verbs without a category (`get_call_stack`).** That is the status quo,
  with the problems listed above.
- **One tool per category with an `action` argument (`debug {action:"run"}`).**
  This gives fewer tools, but loses per-action schemas, per-action annotations and
  per-action client permissions. It also moves validation into prose.

## Consequences

- **Breaking for clients.** A client that cached the old tool list has to reconnect
  (`/mcp reconnect` in Claude Code). Allow-lists written against old names must be
  rewritten.
- Docs that mention tools must use the new names. That covers
  `lazarus-knowledge.md`, `system-prompt.md`, the README and the generated `.inc`
  files. Older ADRs keep the names they were written with, as history.
- New tools must pick an existing prefix and verb. A ninth category needs an
  amendment to this ADR, plus an entry in `ToolTitle`.

## Rename table (v0.7 → v0.8)

| Old | New | Old | New |
|---|---|---|---|
| set_breakpoint | debug_set_breakpoint | get_project_directory | project_get_directory |
| remove_breakpoint | debug_remove_breakpoint | get_project_files | project_list_files |
| list_breakpoints | debug_list_breakpoints | get_project_settings | project_get_settings |
| get_debug_state | debug_get_state | set_project_settings | project_set_settings |
| run_debugger | debug_run | add_file_to_project | project_add_file |
| pause_debugger | debug_pause | remove_file_from_project | project_remove_file |
| stop_debugger | debug_stop | list_project_templates | project_list_templates |
| step_over | debug_step_over | create_project | project_create |
| step_into | debug_step_into | add_package_to_project | project_add_package |
| step_out | debug_step_out | remove_package_from_project | project_remove_package |
| run_to_line | debug_run_to_line | build_project | project_build |
| get_call_stack | debug_get_call_stack | run_project, run_with_args | project_run |
| evaluate_expression | debug_evaluate | get_compiler_errors | project_get_compiler_errors |
| get_local_variables | debug_get_locals | search_in_project | project_search |
| set_local_variable | debug_set_variable | create_unit | project_create_unit |
| exception_info | debug_get_exception | get_symbol_declaration | code_find_declaration |
| get_active_file | editor_get_active | goto_declaration | code_goto_declaration |
| get_file_content | editor_read_file | get_unit_interface | code_get_unit_interface |
| get_open_editors | editor_list_open | get_identifier_context | code_get_identifier_info |
| get_cursor_position | editor_get_cursor | get_code_outline | code_get_outline |
| set_cursor_position | editor_set_cursor | get_ast_partial | code_get_procedure_ast |
| get_selected_text | editor_get_selection | find_all_references | code_find_references |
| replace_text | editor_replace_range | rename_identifier | code_rename_identifier |
| edit_text | editor_edit_text | add_unit_to_uses | code_add_uses |
| edit_at_position | editor_edit_at_position | insert_in_procedure | code_insert_in_procedure |
| save_file | editor_save | replace_procedure_body | code_replace_procedure_body |
| close_file | editor_close | add_to_class_section | code_add_to_class |
| revert_file | editor_revert | create_form | form_create |
| open_file | editor_open | get_form_components | form_list_components |
| get_package_info | package_get_info | get_component_properties | form_get_properties |
| install_package | package_install | set_component_property | form_set_properties |
| uninstall_package | package_uninstall | add_component | form_add_component |
| compile_plugin | package_compile | create_event_handler | form_create_event_handler |
| rebuild_ide | ide_rebuild | search_components | form_search_palette |
| get_messages | ide_get_messages | ping | ide_ping |
| run_tests | ide_run_tests | | |

`git_*` tools kept their names.
