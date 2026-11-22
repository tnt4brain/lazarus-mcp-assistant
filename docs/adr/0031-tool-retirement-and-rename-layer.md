# ADR-031 — Renaming, fusing and retiring tools: old names keep working through the major version

**Status:** Accepted, built in 1.7.0 (2026-11-18): table, translation in `tools/call`, once-per-session notice, the first fusions (see section 5). Not built yet: the retirement refusal of 2.0.
**Date:** 2026-11-18

## Context

The tool set has grown to 157 tools with names and parameters that were chosen one at a time
(`TOOLS_WTFS.md`: `form_file` for `file`, `wait_seconds` for `timeout_s`, three steps as three tools,
...). ADR-029 trims the list's text without touching a call. Fixing the names, fusing near-identical
tools and dropping tools that nobody should call any more changes calls, and the server is public:
saved prompts, skills, scripts, allow-lists and assistants' notes use the old names.

Facts that shape the design:

- A connected MCP client can only call what `tools/list` shows. An old name arrives only from
  something that remembers it (a saved prompt, a skill, a script, a test, a raw HTTP caller), never
  from a model reading the current list. The layer therefore lives in `tools/call` and costs the
  list nothing.
- `McpRenameLegacyFileArg` (`McpUtils.pas`) is the one alias the server has: hard-coded, silent,
  unlogged, parameter names only, since v1.0. This ADR replaces it.
- `McpValidateArgs` rejects unknown parameters, and the lease and project guards
  (`McpGateEnter`, `McpToolNeedsProject`) decide by tool name. Everything must be translated
  before them, so they only ever see current names.
- A top-level `oneOf` in an input schema is refused by the API, so a fused tool's per-action rules
  cannot be in the schema.

## Decision

### 1. One table, four kinds of entry

One unit holds the table; one function, called first in `tools/call`, applies it:

| Kind | Entry | Example |
|---|---|---|
| Parameter rename | tool or `*`, old name, new name | `form_file` → `file` |
| Tool rename | old tool, new tool | `form_undo` → `form_history` (with `action: "undo"`) |
| Fusion | old tool, new tool, fixed arguments | `debug_step_into` → `debug_step {kind: "into"}` |
| Retirement | old tool, replacement text | the tool is gone; the text says what to use |

Each entry has `since` (the version that introduced the new form) and, for tools, `removed_in` (the
next major version). A rename keeps the arguments the caller gave; a fusion adds the fixed ones.

### 2. The lifecycle is tied to major versions

- **Through all of 1.x** an old name runs, translated. The result carries one extra line the first
  time a session uses it: `deprecated: debug_step_into is now debug_step {kind:"into"}`. Once per
  session and old name, never on every call (tokens).
- **In 2.0** every retired tool name stops running. Calling it is an error that names the
  replacement (for a fusion, the exact new call). One major later the entry leaves the table and the
  ordinary unknown-tool error remains.
- Releases between majors add entries and never refuse one. The major version is the one place
  where changes of direction are announced; its release notes list every refused name with its
  replacement.

Old names stay out of `tools/list`, so models learn the new ones only.

The 2.0 date is announced from the first release that has a rename (1.7.0), in three places: the
notice itself ("works through 1.x and is refused from 2.0"), the README, and
`docs/renamed-tools.md` (every old name with its replacement, and the permission-rule caveat).
The release notes of 1.7.0 and of each later 1.x repeat the pointer; the 2.0 notes list every
refused name.

### 3. Rules

- Old and new parameter given together with different values: an error naming both. Equal values: the
  new one is used.
- A fusion is made only between tools whose annotations are equal (read-only with read-only, and so
  on), so a client's idea of "this call is harmless" or "this call destroys" never gets weaker. An
  add fused with a delete is not a fusion.
- A fused tool's required parameters per action are checked in code, with the quality of
  `McpValidateArgs`: the error lists what the chosen action needs and every accepted parameter. The
  schema declares them optional and the description states the rules.
- Every use of an old name is written to the tool-call log (ADR-022) under the name the client sent,
  and `ide_report` lists the counts since the IDE started (built), so removal at 2.0 is decided from data.
- The guards (lease, project) see the new tool name and arguments.
- Permission rules that name an old tool (`mcp__lazarus-ide__debug_step_over` in an allow-list) stop
  matching a tool that no longer exists in the list; no alias can prevent that. The release notes
  say so.

### 4. Tests

- Every entry's target tool exists, and its translated arguments pass `McpValidateArgs`.
- An old call and the matching new call give the same result.
- A test fails when a shipped document (README, server instructions, `lazarus_knowledge.inc`, the
  reference resource, `docs/system-prompt.md`) names a tool or parameter that the table retires;
  only the ADRs and release notes may.
- `McpRenameLegacyFileArg` becomes parameter entries of the table, with the tests it has.

### 5. First entries (1.7.0, built)

Fusions between tools with equal annotations only (checked on the 2026-11-18 list): `debug_step_into`,
`debug_step_over` and `debug_step_out` into `debug_step {kind}`; `form_undo` and `form_redo` into
`form_history {action}`; `git_stash_pop` into `git_stash {action: "pop"}`; `code_goto_declaration`
into `code_find_declaration {show: true}`; the cursor and selection getters into
`editor_get_active {what: "cursor" | "selection"}`. Parameter entries: the nine of
`McpRenameLegacyFileArg`, `form_file` → `file` (every `form_*` tool), `wait_seconds` → `timeout_s`
(`project_run`, `project_run_output`, `project_run_input`), `project_run_input`'s `text` → `stdin`,
`debug_set_variable`'s `name` → `variable_name`. 157 tools became 150, and
`tools/list` 139,100 → 134,200 bytes. Decided against, for now: `editor_edit_text`'s `old_string`/`new_string` (they match the
Edit tool of the assistants that use this server), `name` → `package_name` in `package_create` and
`package_download` (the write-scope and package guards read `package_name` as "a loaded package"),
`name` → `component_name` in `form_add_component` and `form_add_menu_item` (tried, then taken back:
the form tools resolve `component_name` as an existing component before they run, so the new
component's name would be looked up and not found), the `max_*` limits (each names what it limits) and `data` in the breakpoint tools (it pairs with `watch`).
The add and delete pairs wait for a decision about their annotations.

The notice goes into a second `content` item of the result, never into the text, which clients
parse as JSON. A value the old tool fixed may be given again if equal; a different one is an error.
The tests: translation and the once-per-session rule (pure), the table against the live list, old
and new calls compared, and a test that the shipped documents name no retired tool.

### 6. Not done

- No `notifications/tools/list_changed`: a change of the list comes with a rebuild, which restarts
  the server and every client fetches the list again.
- No aliases for tools that were never released.

## Consequences

- The table only grows during 1.x. Its tests walk every entry, so the cost is the lines of the table.
- The tool set can be fixed without a day of breakage, and the major version marks the day an old
  name stops working.
- A client that never reads the deprecation line keeps working until 2.0.

## Amendment 1: three of the four rejected renames, taken after all (1.8.1, 2026-11-22)

A review of the tool names found them inconsistent, and the layer exists to make such a change cost nothing, so
three of the renames that section 5 decided against are done:

- `editor_edit_text`: `old_string`/`new_string` → `old_text`/`new_text`. The names no longer
  match the Edit tool of the assistants that use this server; that was the reason for keeping
  them, and the weakest of the three changes, taken for a name that says what the value is.
- `git_log` `max_count`, `package_search_online`, `code_find_descendants` and `code_find_overrides`
  `max_results` → `limit`: one name for "stop after this many".
- `debug_set_breakpoint` `data` → `watch_expression`. The answer of the breakpoint tools
  carries both `data` and `watch_expression`, so a client that reads the field keeps working.

Eleven entries in the table, each with its row in `docs/renamed-tools.md`. **Still decided
against:** `name` → `package_name` / `component_name`. The reasons in section 5 are technical
(the write-scope and package guards read `package_name` as "a loaded package"; the form tools
resolve `component_name` as an existing component), not a matter of taste, and they have not
changed.

Also in 1.8.1: `ref` is the one name for "a revision to act on" where the tool takes any revision: `git_tag`
and `git_cherry_pick` (`commit`, which also took a range) and `git_log` (`branch`). `git_merge` and
`git_archive` already used it. Left as they are, because they are git's own words for something else:
`target` of `git_checkout` and `git_reset` (a revision **or a file path**, and with `create` the new branch),
`upstream`/`onto` of `git_rebase`, `since` of `git_squash`, `start_point`, and `branch` where a branch
(not any revision) is required (`git_branch_delete`, `git_push`, `git_pull`, `git_clone`).

`git_push` `tags` (an array of tag names) became `tag_names`, because `git_fetch` `tags` is a boolean: it
was the only parameter name with two types. And `debug_get_output` and `ide_get_exceptions` are no longer
marked read-only: their `clear` flag drops the buffer they returned, and a client that lets read-only
tools through unasked would clear it unasked (they are in the `g` list of `McpToolScope`: no file).
