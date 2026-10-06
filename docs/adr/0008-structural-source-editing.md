# ADR-008 — Token-Aware / Structural Source Editing

**Status:** Proposed  
**Date:** 2026-10-06

## Context

All current editing tools operate on raw text:

- `edit_text` — finds an exact string in the editor buffer and replaces it.
- `replace_text` — operates on line-number ranges supplied by the caller.

Both are fragile in practice:

- `edit_text` fails when the target string appears more than once, when whitespace
  drifts (re-indent, blank-line insertion), or when line endings differ.
- `replace_text` goes stale the moment any edit shifts line numbers above the
  target site.
- Both require the caller (the AI client) to supply exact, up-to-date text
  extracted from a prior `get_file_content` call — a round-trip that still
  misfires under CRLF or encoding edge cases.

The root problem is that text-matching is the wrong level of abstraction for
structured source code.  Pascal has a well-defined token grammar; CodeTools already
parses it to a full AST with precise source positions.  Editing at the AST / token
level is inherently robust to whitespace, formatting, and encoding variation.

Observation from `fpprofiler` (graemeg/fpprofiler): source-level transformation
via `PScanner` works, but token-counting is inferior to the full CodeTools AST for
named-node targeting.

## Decision

Add a **structural editing** layer with two tiers:

### Tier 1 — Positional primitive

```
edit_at_position(file, line, col, delete_len, insert_text)
```

- Converts `(line, col)` to a buffer offset; deletes `delete_len` characters;
  inserts `insert_text`.
- No string matching.  The caller is responsible for supplying correct coordinates
  (obtained from a prior CodeTools query or outline call).
- Existing `TCodeBuffer` mechanics handle the actual mutation; the save path is
  unchanged.

This is the escape hatch for callers that already have a CodeTools position.

### Tier 2 — Semantic structural tools

Each tool uses `CodeToolBoss` to locate a named node, derives its exact
`TCodeXYPosition`, then delegates to the Tier-1 primitive.

| Tool | Locates via CodeTools | Operation |
|---|---|---|
| `insert_after_uses` | `FindUnitInAllUsesSections` → end of uses clause | Insert text (typically a new unit name) |
| `insert_in_procedure` | `FindProcBody` by name (+ optional class) → body start | Insert text at top of body |
| `replace_procedure_body` | `FindProcBody` → begin..end range | Replace entire body |
| `add_to_class_section` | `FindClassNode` → named section (public/private/protected/published) | Append declaration text |

These cover the cases where `edit_text` misfires most often during self-hosted
IDE development: adding to uses, patching a routine body, adding a field or method
declaration.

### Tier 3 — Structural read (AST query)

```
get_ast_partial(file, line, col)   — or —   get_ast_partial(file, proc_name, class_name)
```

Returns the structural content of the innermost named scope at the given location:
local variable declarations, and a flat list of block-level nodes (control flow,
calls, assignments) with their line ranges.  Example response shape:

```json
{
  "scope": "TMyClass.DoSomething",
  "range": {"from": 42, "to": 87},
  "locals": [
    {"name": "I", "type": "Integer", "line": 44}
  ],
  "nodes": [
    {"kind": "for",  "line": 47, "to": 52},
    {"kind": "if",   "line": 54, "to": 61},
    {"kind": "try",  "line": 63, "to": 70},
    {"kind": "call", "line": 72, "name": "FreeAndNil"}
  ]
}
```

Implementation: `CodeToolBoss` locates the procedure body via `FindProcBody` and
walks `TCodeTreeNode` children to `ctnBeginBlock` depth for control-flow nodes and
`ctnVarSection` for locals.  Statement-level detail (individual calls, assignments)
uses `PScanner` token-walking scoped to the body's character range — the same
technique `fpprofiler` uses, but bounded to one procedure.

**This is a read-only, one-direction tool — it does not reconstruct Pascal from
nodes.**  The purpose is purely targeting: the AI client uses the returned line/col
ranges as inputs to Tier-1 `edit_at_position` or Tier-2 tools.  A full AST→source
round-trip (requiring a Pascal pretty-printer) is explicitly out of scope.

The three tiers form a single coherent workflow:

```
Read                        Write
────────────────────────────────────────────────────────────
get_code_outline            (existing — structural map)
get_ast_partial             edit_at_position            ← Tier 1
                            insert_after_uses
                            insert_in_procedure         ← Tier 2
                            replace_procedure_body
                            add_to_class_section
```

`get_ast_partial` lives in `McpToolsCodeTools.pas` alongside the other read-side
CodeTools tools.

## What stays

- `edit_text` is retained for quick, unambiguous one-off patches where string
  matching is adequate.
- `replace_text` is retained for backward compatibility.
- No existing tool is removed in this pass.

## Implementation notes

- All Tier-2 tools live in `McpToolsCodeTools.pas` (natural home alongside
  `get_code_outline`, `get_symbol_declaration`, etc.).
- `edit_at_position` lives in `McpToolsEditor.pas` (alongside other buffer-level
  tools).
- CodeTools must parse the file before any positional query; call
  `CodeToolBoss.BuildCodeTree` if the buffer is dirty.
- Multi-line `insert_text` values use `\n` (LF); the tool normalises to the
  buffer's native line ending before insertion.
- Each Tier-2 tool must call `LazarusIDE.DoSaveSourceEditorChangesToCodeCache`
  (or equivalent) before the CodeTools query to ensure the in-memory buffer
  reflects unsaved edits.

## Consequences

- `edit_text` misfires drop to near-zero for structural edits (uses, class
  sections, procedure bodies).
- The AI client no longer needs to extract exact match strings from
  `get_file_content` for common structural operations.
- `edit_at_position` requires the caller to supply correct `(line, col)` — it is
  only safe when paired with a fresh CodeTools query in the same logical turn.
- Tier-2 tools handle overloaded names conservatively: if `FindProcBody` returns
  multiple candidates, return an error listing them and require the caller to
  disambiguate with a qualified name.

## Migration order

1. `edit_at_position` — proves the primitive compiles and round-trips correctly.
2. `insert_after_uses` — simplest Tier-2 tool; validates the CodeTools call chain.
3. `insert_in_procedure` + `replace_procedure_body` — highest-frequency misfires.
4. `add_to_class_section` — closes the remaining common case.
5. `get_ast_partial` — read-side; validates `TCodeTreeNode` walk + PScanner body scan.

Smoke call after each step: modify a known file, verify result with
`get_file_content`, revert with `revert_file`.  For `get_ast_partial`: call on a
known procedure and verify the returned node list matches a manual reading of the
source.
