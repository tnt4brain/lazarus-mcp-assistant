# Renamed tools and parameters

Version 1.7.0 gave the tools one name for each idea (ADR-031); 1.8.1 added `old_text`/`new_text`, `limit`, `watch_expression` and `ref`. **Every old name still works
through all of 1.x and is refused from 2.0 on.** A call with an old name is translated to the
new one; the first time a session uses it, the result carries one extra line:

    deprecated: tool "debug_step_over" is now "debug_step" with kind=over; the old name works
    through 1.x and is refused from 2.0.

`ide_report` lists how often each old name was used since the IDE started, so you can find the
saved prompts, skills, scripts and allow-lists that still use one.

**Permission rules are the exception.** An allow-list entry such as
`mcp__lazarus-ide__debug_step_over` names a tool that is no longer in `tools/list`, so it stops
matching; replace it with the new name (`mcp__lazarus-ide__debug_step`).

## Tools

| Old tool | New call |
|---|---|
| `debug_step_over`, `debug_step_into`, `debug_step_out` | `debug_step` with `kind` = `over`, `into`, `out` |
| `form_undo`, `form_redo` | `form_history` with `action` = `undo`, `redo` |
| `git_stash_pop` | `git_stash` with `action` = `pop` |
| `code_goto_declaration` | `code_find_declaration` with `show` = `true` |
| `editor_get_cursor`, `editor_get_selection` | `editor_get_active` with `what` = `cursor`, `selection` |

## Parameters

| Tool | Old | New |
|---|---|---|
| every `form_*` tool | `form_file` | `file` |
| `project_run`, `project_run_output`, `project_run_input` | `wait_seconds` | `timeout_s` |
| `project_run_input` | `text` | `stdin` |
| `debug_set_variable` | `name` | `variable_name` |
| `debug_set_breakpoint`, `debug_remove_breakpoint`, `debug_run_to_line`, `editor_open`, `project_add_file`, `project_remove_file`, `project_open` | `file_path` | `file` |
| `editor_read_file` | `path` | `file` |
| `project_create_unit` | `filename` | `file` |
| `editor_edit_text` | `old_string`, `new_string` | `old_text`, `new_text` |
| `git_log` | `max_count` | `limit` |
| `package_search_online`, `code_find_descendants`, `code_find_overrides` | `max_results` | `limit` |
| `debug_set_breakpoint` | `data` | `watch_expression` |
| `git_cherry_pick`, `git_tag` | `commit` | `ref` |
| `git_log` | `branch` | `ref` |

Giving the old and the new parameter together is fine if the values are equal and an error if
they differ.
