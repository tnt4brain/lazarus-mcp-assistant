# ADR-008 — Token-Aware / Structural Source Editing

**Status:** Tiers 1 and 2 built (renamed by ADR-010); overload disambiguation built 2026-11-15 (gap 1); tier 3 only partly: locals, no statement nodes (gaps 2 and 3 open)  
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

## As built (checked 2026-11-15, by reading the code and calling the tools on a unit with overloads)

| Proposed | Built as | Where | Matches the ADR? |
|---|---|---|---|
| `edit_at_position` | `editor_replace_range` (`start_line`, `start_col`, and `end_line`/`end_col` or `delete_len`; no end inserts) | `McpToolsEditor.pas` | Yes, and more: it takes a range end, opens the file if needed, `auto_save` |
| `insert_after_uses` | `code_add_uses` (`in_interface` selects the section; duplicates handled) | `McpToolsCodeTools.pas` | Yes |
| `insert_in_procedure` | `code_insert_in_procedure` | same | Located by name, see gap 1 |
| `replace_procedure_body` | `code_replace_procedure_body` | same | Located by name, see gap 1 |
| `add_to_class_section` | `code_add_to_class` (indents like the members around it) | same | Yes; tests in `tfinddeclaration.pas`, `tcodecomplete.pas` |
| `get_ast_partial` | `code_get_procedure_ast` (`proc_name` + `class_name`, or `line`) | same | **Partly**, see gaps 2 and 3 |

`edit_text` and `replace_text` stayed as promised (now `editor_edit_text` and `editor_replace_range`).

### Gaps against the decision

1. **Overloads and same-named methods were not detected (fixed 2026-11-15, see Follow-up).** `FindProcBodyLines` returns at the first
   match, and all three of `code_insert_in_procedure`, `code_replace_procedure_body` and
   `code_get_procedure_ast` use it. The ADR's consequence ("return an error listing the candidates and
   require a qualified name") was not built. Seen live: a unit with `Put(Integer)` and `Put(string)`:
   `proc_name: "Put"` answered for the first overload without a word, the second is reachable only by
   `line`. Without `class_name`, a name also matches the method of any class by its suffix (`.Create`),
   and the first one wins. For the two *writing* tools this edits the wrong routine silently.
2. **`code_get_procedure_ast` reports no statements.** `nodes` came back `[]` for a body with an
   `if ... then` statement (two procedures tried), because CodeTools' tree does not go below the
   `begin` block, and the `PScanner` token walk the ADR planned for statement level was never written.
   The tool description and the README row ("block-level control flow, if/for/while/try/case") say more
   than it delivers; what works is `scope`, `begin_line`, `end_line` and `locals`.
3. **Locals carry a name and a line, no type** (the ADR's example has `"type"`).
4. **Tests** (fixed for gap 1 and the three tools' basic results; the statement nodes of gap 2 have none yet, because there are none to test).

Not checked: the LF normalisation of inserted text and the cache flush before the CodeTools query
(implementation notes above).

## Follow-up

**Gap 1, done.** `FindProcBodyLines` collects every routine with a body that matches. One match: as
before. Several: nothing is changed and the error lists them (`Ambiguous: "Put" matches 2 routines`, each
with its line and its header line). The three tools take a `line` (any line inside the routine meant, so a
line from the candidate list works) next to `class_name`; no routine contains that line: "not found", never a
guess. Tests: `tests/tprocedures.pas` (8, live: overloads refused and picked by line for replace, insert and
the AST tool; the same method in two classes refused and picked by `class_name`; a unique name and an
unknown one as before; the file is untouched after a refusal).

Gaps 2 and 3 are either built (a
`PScanner` walk over the body's range, as the ADR describes) or the description and README are cut back
to what the tool returns. Both need tests that read the result.
