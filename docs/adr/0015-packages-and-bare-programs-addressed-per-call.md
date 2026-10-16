# ADR-015 — Packages and Bare Programs: Addressed Per Call, No "Active" State

**Status:** Accepted (v1.0)  
**Date:** 2026-10-17

## Context

The IDE always has a project open. With nothing opened it is an unsaved default
project whose `ProjectInfoFile` is empty, so "no project" is not a state to design
for. Two things still had no first-class tool support:

- a **program with only a `.lpr`** (no `.lpi`), which `project_open` refused, so
  nothing could build, run or debug it;
- **packages** (`.lpk`): the tools could edit a package that was already loaded, but
  not open, list, create or configure one, `package_get_info` knew only names, and
  `package_compile` returned lazbuild's text.

Several MCP clients share one IDE (ADR-012). A global "active package" (a package
the code tools and editors default to, as the active project is) would let one
client's calls change what another client's calls mean.

## Decision

1. **No active package.** A package is named in each call: `package_name` (loaded) or
   `lpk_path` (loaded for that call without a package editor, `TargetPackage`). The
   tools that work on "the project's files" (`project_list_files`, `project_search`,
   `project_list_todos`, `code_find_references`, `code_rename_identifier`) take the same
   two parameters to work on a package's files for that call. Defaults are unchanged.
2. **Reads don't need a saved, writable package; edits do.** `TargetPackage` has a
   read-only mode (`AForEdit=False`); edits refuse virtual and read-only packages.
3. **`package_create` and the `.lpi` for a bare `.lpr` are written as XML by us.** The
   IDE's own routines (`DoNewPackage`, `CreateProjectForProgram`) show a dialog and live
   in the IDE executable, which a package cannot link against. The files follow what
   the IDE writes (debug info on, DWARF 3; `RequiredPkgs` only for what was asked;
   LCL when the program uses `Forms`/`Interfaces`) and are then loaded through the
   public API (`DoOpenPackageFile`, `DoOpenProjectFile`). `project_open` on an `.lpr`
   writes the `.lpi` next to it, as the IDE does.
4. **`package_compile` has two engines.** The IDE's (`DoCompilePackage`, with
   `pcfDoNotSaveEditorFiles` so the user's unsaved buffers are not written) when the
   package is open in the IDE; `lazbuild` otherwise, which loads nothing. Both answer
   `{method, success, errors}`; the IDE one also fills the Messages window.
   `method` forces one; `clean` adds `-B`. The IDE closes a saved, unused package when
   it goes idle, so "open" is timing-dependent and `method` is in every result.
5. **`project_build` errors come from the Messages window** (every error line), not
   from the one message the user had selected.

## Alternatives considered

- **A global active package** (the user's first idea, as an opt-in setting): rejected
  for the reason in the context. Per-call addressing costs one parameter.
- **Calling the IDE's create routines:** not linkable (decision 3).
- **Always lazbuild for packages:** keeps the old behaviour, but no structured errors
  and no use of an already loaded package's in-memory settings.

## Consequences

- A client that wants a package's files looks it up once and passes `lpk_path` to each
  call; there is no hidden state to go stale after a restart.
- Writing the XML ourselves means following the IDE's format when it changes
  (`tests/fixtures/fixturepkg` and `tests/windowee` are the reference files).
- Tests: `TTestPackageManage` (package tools on a temp package), and
  `TTestWindows` (opt-in) for the bare `.lpr`.
