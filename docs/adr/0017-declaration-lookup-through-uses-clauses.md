# ADR-017 — Declaration Lookup Through Uses Clauses, and Reference Search Scopes

**Status:** Accepted (v1.0)  
**Date:** 2026-10-17

## Context

Two code-navigation tools were narrower than the IDE's own:

- `code_find_declaration` and `code_goto_declaration` called
  `CodeToolBoss.FindDeclarationInInterface(symbol)`, which searches only the interface of
  the unit given. A type from `Classes` or a sibling unit was "not found", and a program
  (`.lpr`, no interface) was refused.
- `code_find_references` searched the project's files (or a package's, ADR-015). For a
  file outside the project it searched nothing, not even that file, and answered `[]`.
  It could not answer the usual question about a framework symbol, "how is this used?",
  because LCL, RTL and component sources are not part of any project.

`FindDeclaration(Code, X, Y)` at a *use* of a name does follow the uses clauses; it needs
a position, and the tools take a name.

## Decision

1. **Declaration lookup has three steps, in order.**
   1. With `line` and `col` (optional arguments): `FindDeclaration` at that position.
   2. The unit's own interface (`FindDeclarationInInterface`): fast, and the old behaviour.
   3. `FindDeclaration` at the file's own uses of the name, one after the other, comments
      and strings skipped by a small scanner, at most 30 tries. CodeTools resolves each use
      through the uses clauses, so `TList` is found in `Classes`, a sibling unit's type in
      its unit, and a program works. A name that never appears in the file answers "not
      used in this file; pass line and col of a use".
   `code_goto_declaration` shares the lookup (`ResolveDeclaration`).
2. **`code_find_references` always searches the file asked about**, added to the project or
   package list when missing.
3. **Extra scopes are opt-in.** `also` takes `same_folder`, `lcl`, `components` (under
   `$(LazarusDir)`), `rtl`, `fcl` (the FPC packages, under `$(FPCSrcDir)`) and
   `packages` (the folders of the packages loaded in the IDE); `search_dir` adds a folder
   and its subfolders; `max_files` (default 300) bounds them. The default scope is
   unchanged, so nothing gets slower unless asked.
4. **A text prefilter keeps it affordable.** The roots hold about 7,000 source files.
   Each candidate (`*.pas`, `*.pp`, `*.lpr`) is read and kept only if it contains the
   identifier at the declaration as a whole word, ignoring case; only those are given to
   `FindReferencesInFiles`, which still decides what is a real reference. Include files
   (`.inc`) are not candidates themselves; they are reached through the units that
   include them.
5. **The answer says how far the search went.** With an extra scope the result is
   `{references, extra_files_searched, truncated?}`; without one it stays the plain
   array, so existing clients are unaffected. `truncated` means more files mentioned the
   name than `max_files`: narrow the scope or raise the limit. An unknown `also` name is
   an error that lists the valid ones.

## Alternatives considered

- **Resolving the name ourselves from the uses clauses** (open each used unit and look
  for the declaration): reimplements CodeTools' scoping, and gets overloads, helpers and
  nested scopes wrong. Resolving at a real use leaves that to CodeTools.
- **Always searching the framework sources:** every call would pay for the RTL, and a
  project's references would be buried in LCL's own uses of common names.
- **Handing all 7,000 files to CodeTools:** the first RTL parse alone took about 15 s for
  the files a common name touches; unfiltered, a call would run for minutes on the main
  thread.
- **A reverse uses index over the disk:** accurate, but needs a stored index and a
  freshness rule. The text prefilter is stateless.

## Consequences

- The prefilter is a text test: a name reached only through a differently spelled alias,
  or used only inside an include file that no candidate unit mentions it in, is missed.
  The tool description says the search covers files that mention the name.
- The first call that parses the RTL or LCL is slow (about 15 s measured for `TList`);
  later calls take under a second, because CodeTools keeps what it parsed. The call runs
  on the IDE's main thread, like the other CodeTools tools.
- Declaration lookup depends on there being a use in the file. Where there is none
  (a name only used in a macro or an include), the caller gives `line` and `col`.
- Tests: `TTestFindDeclaration` (own interface, sibling unit, RTL unit, program, given
  position, comments and strings, unused name, references outside the project,
  `same_folder`, `search_dir` with `max_files`, unknown scope).
