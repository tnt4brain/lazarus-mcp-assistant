# ADR-003 — Undo/Redo Integration for rename_identifier

**Status:** Decided — deferred to v0.5  
**Date:** 2026-10-02

## Context

`rename_identifier` applies cross-file refactors using the Codetools pipeline:
`FindReferencesInFiles` → `RenameIdentifier` → `ApplyChanges`.  Changes land in
`TCodeBuffer` objects (Codetools' own in-memory buffer), which are then written
to disk with `TCodeBuffer.Save`.  Open editors are reloaded via
`LazarusIDE.DoRevertEditorFile`.

The IDE's undo/redo history lives inside each `TSynEdit` instance.  It only
records changes made *through the editor*.  A disk-reload clears that history,
so after a rename Ctrl+Z has no effect on any touched file.

## Options considered

### A — Document and warn (current, v0.x)

Add a WARNING to the `rename_identifier` tool description so Claude knows the
operation is non-undoable and must ask for user confirmation before calling it.
Git history is the undo mechanism.

- Zero implementation cost
- Relies on the LLM reading and respecting the warning
- Appropriate while the tool set is still being proven in practice

### B — Apply changes through TSourceEditorInterface (correct fix)

For each file that is already open in the IDE, find its `TSourceEditorInterface`,
compute the change positions in editor coordinates, and call the editor's
replace API instead of writing to `TCodeBuffer` directly.  For files that are
not open, the current disk-write path is acceptable (no undo stack exists for
a closed file).

- Preserves Ctrl+Z for open files
- Requires position translation between Codetools clean-source offsets and
  editor line/col, plus iteration over `SourceEditorManagerIntf`
- ~80–120 LOC; risk of off-by-one errors on position mapping
- Natural fit once the MCP tool set has stabilised and the rename workflow is
  proven end-to-end

### C — IDE-level refactoring command

Delegate entirely to `LazarusIDE.DoIdentifierRenaming` (or equivalent) if such
a public entry point exists in `LazIDEIntf`.  This would reuse the IDE's own
refactoring pipeline, including undo.

- No position-mapping code to own
- `DoIdentifierRenaming` is not currently exposed in `LazIDEIntf`; adding it
  would require a patch to the Lazarus IDE or a workaround

## Decision

**v0.x ships with Option A.**  The tool description carries a clear WARNING;
Claude is instructed to confirm with the user before calling it, and git serves
as the safety net.

**v0.5 will implement Option B** for open files, falling back to the disk-write
path for closed files.  Option C is noted but not pursued without an upstream
`LazIDEIntf` entry point.

## Consequences

- The `rename_identifier` tool description permanently warns that the operation
  is non-undoable via Ctrl+Z.
- Users should work in a clean git working tree before invoking the tool.
- When implementing Option B, validate position translation with a unit that
  has at least one open editor and one closed file containing references.
