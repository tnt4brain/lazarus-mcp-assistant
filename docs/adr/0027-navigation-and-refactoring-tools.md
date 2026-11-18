# ADR-027 — Navigation and refactoring beyond references and rename

**Status:** Accepted and implemented (2026-11-15; all six tools exist in `McpToolsCodeNav.pas`, 11 tests in `tests/tcodenav.pas`; released in v1.6.0)
**Date:** 2026-11-15

## Context

`TOOLS_WTFS.md` (feature surface, gaps 1 and 2) named what an assistant could not do safely: find the
classes below a class, the methods that override one, the unit dependency graph, unused symbols, and
extract a method or move a unit between packages. CodeTools can answer most of it; nothing exposed it.

## Decision

Six tools, in `McpToolsCodeNav.pas` (all main thread, CodeTools only, no new IDE dependency):

| Tool | How |
|---|---|
| `code_find_descendants` | CodeTools has no descendants query. The references of a class name are searched (`FindReferencesInFiles`, scope as `code_find_references`: project or package, `also`, `search_dir`); a reference that sits inside a heritage list (`ctnClassInheritance`) names a descendant or an implementer of an interface. Repeated for every hit unless `direct_only`. |
| `code_find_overrides` | The descendants of the method's class, and in each the method of the same name; `override`, `reintroduce` or plain same name, with the signature line. |
| `code_unit_dependencies` | `FindUsedUnitNames` per unit. With `file`: its uses (interface/implementation), who uses it, `FindUnusedUnits`. Without: the project graph and its cycles (Tarjan; interface-only cycles listed separately, the compiler rejects those). |
| `code_find_unused` | The unit's declarations (types, routines, methods, fields, properties, variables, constants) and, for each, the references in the files that mention the name. A mention in a routine header (the implementation of a method) is not a use. Published members, overrides, abstract methods, constructors and `Register` are left out. |
| `code_extract_method` | `CheckExtractProc` / `ExtractProc` (what the IDE's Extract Procedure dialog calls). `dry_run` reports the possible kinds and the missing identifiers. |
| `package_move_unit` | `package_get_info`, `package_add_dependency`, `package_add_file`, `package_remove_file`: works out whether the target needs the source (the unit uses units that stay) or the reverse (units that stay use it), adds that requirement, refuses when both are true (a cycle), moves the entry. The file stays on disk where it is. |

## Caveats, said in the tool descriptions

- Descendants and unused symbols are found by name search over the searched files: a class in a file
  outside the scope is missed (`also` and `search_dir` widen it). `code_find_unused` is a hint, not proof,
  above all for the public API of a package.
- A routine header counts as no use; a field that is only written counts as used.
- `ExtractProc` reports failure after it applied the change when it cannot find the new routine to jump
  to (seen with a plain procedure): the tool then checks the buffer, and reports success with the new
  routine located by name.
- Loading a package whose file name differs from its package name opens a native IDE question
  ("Filename differs from Packagename") that no tool can answer; `package_move_unit` and
  `package_get_info` with `lpk_path` hit it.

## Consequences

- 6 new tools (the list was already long, see TOOLS_WTFS.md); descriptions kept short.
- Live tests: `tests/tcodenav.pas` (11 tests on small units in a temp folder).
