# ADR-026 — The IDE rebuild checks first and recovers from a failed build

**Status:** Accepted (2026-11-15)  
**Date:** 2026-11-15

## Context

`ide_rebuild`, `package_install` and `package_uninstall` ran one fixed sequence: answer the client,
close every editor with `cfQuiet`, stop the MCP server, start the IDE's build. Two things went wrong:

- `cfQuiet` without `cfSaveFirst` skips the IDE's save block (`CloseEditorFile` in
  `sourcefilemanager.pas`): an editor with unsaved text is closed and the text is gone, no question.
- Nothing checked that the build could succeed. A compile error left the IDE running, half-built,
  the server stopped, the editors closed, and no way for the client to find out why (seen live
  2026-11-15; it came back only after the source was fixed on disk and the IDE rebuilt again).

## Decision

1. **Unsaved editors and packages stop the call.** Before anything is changed the call refuses,
   naming the files and packages (`status: "not_started"`). `save_unsaved: true` saves them
   first (the caller says so explicitly; the plugin never saves a user's buffer on its own).
   A package counts because the IDE would otherwise stop on a "Save package?" question after the
   server is already down (seen live 2026-11-15, after `package_add_file` left the `.lpk` unsaved).
   Packages are saved only when none of the modified ones could make the IDE ask something
   (a package never saved, or with a file missing on disk, is never saved this way and stays on
   the list); `DoSaveAllPackages` takes every modified package, so it is all or nothing.
2. **Compile first.** The package that is rebuilt (the plugin, or the `.lpk` of `package_install`)
   is compiled with the IDE's own compiler while the IDE is whole. Errors come back as the
   result, nothing is changed. `skip_compile: true` skips the check. A package that is not
   loaded (so only `lazbuild` could compile it) is left to the rebuild.
3. **A build that fails does not strand the IDE.** `InstallPackages` returning anything but ok
   means no restart is coming: the editors that were closed are opened again, the compiler
   messages go into the answer (`status: "rebuild_failed"`) and the Messages window, and the
   server is started again a moment later (the answer of the failed call is still being sent on
   the old one) on the same port and token.
4. **`wait_for_restart.pas`** says on timeout whether an IDE process is still running (it answers
   no MCP calls: the build failed or the plugin did not load), the script started one, or none
   exists. It already started the IDE itself after 45 s of nothing running.

## Consequences

- A rebuild can no longer throw away unsaved edits, or leave the IDE without its server after a
  compile error.
- Two new optional parameters on three tools (`save_unsaved`, `skip_compile`).
- The check compiles the package twice in a successful rebuild (once here, once by the IDE): a
  few seconds more.
- Tested live: the refusal (`tests/treloadfiles.pas`, `TestRebuildRefusesUnsavedEditors`; it
  passes `save_unsaved:false` so an older plugin rejects the unknown parameter instead of
  rebuilding the IDE under the test). The compile-error stop and the recovery after a failed
  build were checked by hand (2026-11-15) with a deliberately broken unit: the first call came
  back "not_started" with the errors, the second (skip_compile) "rebuild_failed", and the
  server answered again in the same client session a few seconds later. Not automated: both
  need a broken package.
