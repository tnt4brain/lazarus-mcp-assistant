# Where the tools may write

The README has the short version. This page has the details.

Without a limit a client, local or on another machine, could write anywhere the IDE's user can.
So a tool changes a file only inside: the open project's folder, the folder of a loaded package
that is not part of Lazarus, the git working tree holding either, and the temp folder. Never
inside a `.git` folder, and never in the IDE's settings folder. Links and junctions are followed:
a path that leads out of a folder through one is outside. The git tools that change a repository
(`git_commit`, `git_push`, ...), `package_create` and the `junit_out` of `ide_run_tests` follow the
same rule.

Two things this does **not** do:

- It does not stop a client that may open projects: `project_open` or `project_create` makes the
  new project's folder one of these folders. For that, use limited mode.
- It does not limit what a program does that a tool builds or runs (`project_run`,
  `ide_run_tests`, the debugger, the compiler's own options): the limit is about where the *tools*
  read and write.

**Limited mode** is off by default. In Tools > Options > MCP Assistant > Directories you list
folders; with at least one, the tools change files, create or open projects (`project_open`,
`project_create`, `git_clone`, `git_init`, `package_open`, `project_add_package`) and read files
only inside them. Besides, they may still read the open project, the loaded packages, the Lazarus and
FPC sources and the temp folder. Only you can change the list: no tool reads or changes it, and
`ide_ping` and `ide_report` tell a client that the mode is on. A refusal names the folders. It is a
limit on the file access of the tools, not a sandbox.

## Which tools are limited

`editor_edit_text`, `editor_replace_range`, `editor_create_file` and `project_create_unit` write only inside
the active project's directory, the folder of a loaded package (not one that ships with Lazarus, such as the
LCL, unless the project itself is inside the Lazarus folder), the git working tree that holds either (a
package's tests and docs sit above its source folder) and the temp folder, never inside a `.git` folder: the
same for a client on this machine and one on another. A path anywhere else is refused with the list of folders.
The `code_*` and `form_*` tools that change files follow the same rule (`code_rename_identifier` checks every
file it would touch and renames nothing if one is outside); `dry_run` is never refused. So do the tools that
change an existing package's `.lpk` (`package_add_file`, `package_remove_file`, `package_add_dependency`,
`package_remove_dependency`, `package_set_info`, `package_set_settings`, and both packages of `package_move_unit`).
Not limited: `editor_save`, `editor_revert`, `editor_undo`, `editor_redo`, `editor_close`, and the tools listed below that create, open,
download, install or uninstall.

## What the limits do not do

The tools that create or open something are not limited to any folder, because a
new project or package has no folder to be inside: `project_create`, `project_open`, `package_create`,
`package_open` and `git_clone`. What they create or open then becomes the active project or a loaded package,
so its folder becomes writable. The limits keep a client from writing where it has not been given access; they
do not stop one that may create or open a project from giving itself a new place. If that matters to you,
the lever is a consent switch for those tools (like `AllowPackageInstall`), not a path rule.
