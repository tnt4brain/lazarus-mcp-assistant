# ADR-034 — Write-scope audit: what every tool may change, and the gaps found

**Status:** Accepted, built 2026-11-20: all six decisions (the three gaps closed and every route of a tool call checked, links followed, README section, limited mode with its Directories page, the classification test).
**Date:** 2026-11-19

## Context

Without a limit, a client (local, or on another machine with a named token, ADR-021) could write
anywhere the IDE's user can. `McpCheckWritable` (`McpToolHelpers.pas`) is that limit: a file may
change inside the project directory, the folder of a loaded package that is not part of Lazarus,
the git working tree holding either, and the temp folder; never inside a `.git` folder.
`McpWriteAllowed` (`McpToolContext.pas`) applies it before a tool runs, to tools named in three
lists (file writers, form writers, package writers); other tools call it themselves.

Roadmap item 5 asked: check what every write tool accepts, document it, decide whether a
"project directory only" mode is worth having. This is the check (2026-11-19, all 150 tools of
`tools/list`, by reading the code of each tool that is not read-only).

## Findings

### Covered

| Tools | Guard |
|---|---|
| `code_add_uses`, `_add_to_class`, `_insert_in_procedure`, `_replace_procedure_body`, `_edit_statement`, `_complete`, `_format`, `_rename_identifier`, `_extract_method` | central list (`file`); a rename also checks every other file it touches |
| `form_*` that change a form (11) | central list (`file`) |
| `package_add_file`, `_remove_file`, `_add_dependency`, `_remove_dependency`, `_set_info`, `_set_settings`, `_move_unit`, `_save` | central list (the `.lpk`) |
| `git_archive` | central (`output`) |
| `editor_create_file`, `editor_edit_text`, `editor_replace_range`, `project_create_unit`, `form_create` | in the tool |

### Gaps

1. **`package_create` `directory`**: no check. It creates a `.lpk` and a unit in any folder
   (`ForceDirectories`). Existing files are refused, so nothing is overwritten.
2. **`ide_run_tests` `junit_out`**: handed to the test program as `--junit-out`, not checked: an
   XML file is written to any path.
3. **Git tools, `work_dir`**: no check. `git_add`, `_commit`, `_reset`, `_checkout`, `_merge`,
   `_rebase`, `_cherry_pick`, `_stash`, `_resolve`, `_pull`, `_push`, `_squash`, `_tag`,
   `_branch_delete`, `_remote` act on any repository the IDE's user can reach, which changes files
   there. (`git_init` and `git_clone` create a new folder; see decision 3.)
4. **Paths are compared as text.** `..`, case and a trailing separator are handled and tested. A
   symbolic link or a junction inside a root that points outside it is not followed: a write
   through it lands outside. (Short `8.3` names and `\\?\` prefixes make a path fail the test,
   which is the safe side.) A repository cloned with `git_clone` can carry symbolic links.
5. **A root can be made.** `project_open`, `project_create` (and, after a clone, `project_open` on
   it) make the new project's folder a root. This is stated in `project_open`'s description. So
   the limit stops mistakes and a client that is not trying to get around it; a client that
   may open projects can reach any folder. Reads are not limited at all (`editor_read_file`,
   `editor_open`, `project_search` with `directory`, the git read tools).
6. **Running code is outside the limit.** `project_run`, `ide_run_tests`, the debugger,
   `project_build` (custom compiler options) and the rebuild and install tools execute what the
   client wrote or what the user's compiler runs. The limit says where a tool writes a file, not
   what a built program does.

### Not a gap

`editor_save`, `editor_close`, `editor_revert` act on buffers that were already open;
`project_add_file`, `package_add_file` and `project_add_package` write the project's or the
package's own file and only name the other; `package_download` writes where the IDE's package
manager does and has its own consent (ADR-013); `ide_show_markdown`, `debug_*` and `ide_*`
write no user file.

## Decision

1. **Close the three plain gaps** (1, 2, 3) with the existing guard: `package_create` `directory`
   and `ide_run_tests` `junit_out` go into the central check; a git tool that changes a
   repository requires `work_dir` inside a root (the folder itself counts, which
   `McpCheckWritable` does not for a root, so a `McpCheckWritableFolder` is added). The git
   read tools (`status`, `log`, `diff`, `blame`, `branches`, and the read actions of
   `git_remote`, `git_tag`, `git_stash`) stay unrestricted, except in limited mode (decision 5).
2. **Follow links** (4): both the path and the roots are resolved to their real location, as far
   as the path exists (the deepest existing parent for a file that does not exist yet), before
   they are compared. Tested with a symbolic link on Linux and a junction on Windows.
3. **A new folder may be anywhere:** `git_init`, `git_clone` and `project_create` make a folder
   that did not exist, or an empty one; nothing existing changes. They stay as they are.
4. **Tell the truth in the documents** (5, 6): the README gets a section "What the tools may
   change" with the roots, the exceptions above, and two plain sentences: the limit does not
   stop a client that may open projects, and does not limit what a program run through the
   tools does. `project_open`'s description already says the first.
5. **Limited mode, off by default** (5; the idea is the user's; "sandbox" and "restricted" were rejected: the first suggests isolation, the second means "runs no code" in other tools; this one runs code). A setting
   "Allowed folders" in Options: a list of absolute folders, empty by default, which means
   limited mode is off and today's behaviour. With one or more folders set, the IDE is in limited mode:
   - **Writes:** a root (project, package, git tree) counts only where it lies inside an allowed
     folder; the temp folder still counts. A project that is open outside the allowed folders is read
     but not changed, and the refusal says so.
   - **New places:** `project_open`, `project_create`, `git_clone`, `git_init` and
     `package_create` refuse a folder outside the allowed folders, so a client cannot make a root
     elsewhere (finding 5).
   - **Reads:** `editor_read_file`, `editor_open`, `project_search` with `directory`, and the
     git tools with `work_dir` read only inside the allowed folders, the Lazarus folder and the FPC
     source folders (the references an assistant needs), and the temp folder.
   - **Only the user sets it:** no tool reads or changes the setting; it lives in the IDE's
     options file, outside every root. `ide_ping` and `ide_report` say `limited_mode: on` and list the
     folders, and every refusal names them, so the client learns the limit from the first
     refusal at the latest.
   - **Not a guarantee against running code** (finding 6): a limit on the allowed folders covers what the tools read
     and write, not what a program the client built and ran does. The README says so.
   It turns the limit from a guard against mistakes into one against a client that may open
   projects, at the price of listing the folders once. The README calls it what it is: a limit on
   the file access of the tools.
6. **No tool is added unclassified.** A test walks the live `tools/list`: every tool that is not
   read-only is in exactly one table of the code, either "guarded, by this argument" or
   "writes no file outside what is already open or owned (reason)". A new write tool fails the
   test until someone puts it in a table.

## Tests

- Pure, with a stub for `GMcpWriteCheck`: each tool of the central lists is refused with an
  outside path and passes with an inside one, `dry_run` passes; `package_create`, `junit_out` and
  the git writers likewise; the git read tools are not asked.
- Links: a path through a symbolic link (Linux) or junction (Windows) that leaves the root is
  refused; one that stays inside passes; a file that does not exist yet is judged by its parent.
- The classification test of decision 6, against `tools/list`.
- Limited mode: pure tests of the roots with an allowed-folders list (empty list = unchanged); the five
  refusals of new places; reads inside and outside; the temp folder; `ide_report` shows it.

## Consequences

- Three tools stop writing outside the roots; a client that did that now gets a refusal naming
  the roots.
- Symbolic links and junctions stop being a way out of a root.
- The README says what the limit is and is not.
- A new write tool cannot be added without a decision about its scope.
- With limited mode a user gets an actual boundary for what the tools touch, at the price of
  listing the folders once; without it nothing changes.
