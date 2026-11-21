# ADR-029 — A smaller `tools/list`: say the same in fewer bytes, change no call

**Status:** Accepted, built as far as it pays (2026-11-18)
**Date:** 2026-11-18

## Context

Every client that loads the tool list pays for it in context, on every conversation: names,
descriptions, JSON schemas. Measured on 2026-11-18 (v1.7 candidate, `tools/list` through the
running server, compact JSON):

| | bytes |
|---|---|
| 157 tools in all | 139,100 |
| of which `inputSchema` | 69,700 (36,700 of it parameter descriptions) |
| tool descriptions | 38,500 |
| titles, twice (`title` and `annotations.title`) | 3,500 each |
| annotations other than the title | 9,800 |
| server `instructions` (once per session) | 7,900 |

The wire format is pretty-printed (`FormatJSON`: 210,000 bytes). That costs the model nothing (a
client parses it), so it is not counted as a saving below, but it is free to drop.

The earlier estimate (`ROADMAP.md`, 132 tools, 100 KB) predates the 25 git tools.

## Decision

### 1. The rule: no call changes without a decision of its own

Trimming changes **text only**. For every tool the name, the parameter names, `required`, the types,
the enums and the defaults stay what they are. A script compares the list before and after and fails
on any difference other than description text and the shape of the annotations; it is run before
every commit of this work.

### 2. What goes

- The response is written compactly (`AsJSON`).
- Repeated parameter descriptions (`work_dir` 25 times in two wordings, `auto_save` 20 times in two,
  `lpk_path`, `package_name`, `form_file`, ...) become one short wording each, kept in constants
  next to the schema builders. A shared `$ref` across tools is not possible, so each copy is
  shortened, not merged.
- Tool descriptions lose what restates the schema or the tool's name. They keep every default, every
  refusal, every side effect and every "use X instead" (those steer the model, and a description that
  was cut too far costs more in wrong calls than it saves).
- The title is sent where the client reads it: `title` for protocol 2025-06-18, `annotations.title`
  for the older revisions, if the handler knows the session's revision; else both stay.
- Annotations stay explicit unless the MCP default is the safe reading for a client that ignores
  defaults: a missing `readOnlyHint` is read as "writes", so a `false` may go; a missing
  `destructiveHint` is read as "destroys" by the spec but as "harmless" by a careless client, so a
  `true` stays; `openWorldHint` stays, its default being `true`.

### What it came to (2026-11-18)

Measured with `tests/compare_tool_lists.py` (it fails on any difference but description text and the
spelling of the annotations):

| Step | `tools/list`, compact |
|---|---|
| Before | 139,100 B |
| `readOnlyHint: false` left out (the MCP default; 96 tools) | −2,000 B |
| `save_unsaved` and `skip_compile` shortened (one shared text, three tools) | −440 B |
| After | 136,700 B (−1.7%) |
| Then ADR-031's fusions (157 → 150 tools) | 134,200 B |
| The two longest descriptions (`ide_show_markdown`, `code_complete`) said shorter | 134,000 B (−3.7% in all) |

Shortening the longest descriptions saved 200 bytes for two tools; the rest would save about as little
per tool and cost wrong calls, so the trimming stops here. Status: built as far as it pays.

The estimate that "about 11 KB of parameter descriptions repeat" counted what the copies cost, not
what shortening them saves. Most were short already (`Also save to disk (default false)`), and most
copies come from a few shared source lines. The weight is elsewhere: the 28 tool descriptions over
250 bytes (about 3.5 KB), the title written twice (3.5 KB, kept: the session's protocol revision is
not known where the list is built), and the tools themselves, which is what ADR-031 reduces.

### 3. Fusing tools is a separate decision

`ROADMAP.md` lists fusions (17 tools fewer, about 9 KB). They change the names a client can call, so
they break saved prompts, scripts, memory notes and docs, and an MCP client can only call what
`tools/list` shows, so an alias for a removed name would serve only direct HTTP callers. They also
merge annotations (an add and a delete fused is destructive as a whole, so the add asks for approval
too) and move required-parameter checks from the schema, where a top-level `oneOf` is refused by the
API, into code. This ADR does not include them; if they are taken up, only pairs with equal
annotations, with the old names listed in the release notes and every reference updated.

### 4. Not done

- Groups per session (`ROADMAP.md` item 9) cut far more, but are a feature of their own.
- Cutting the `instructions`: 7.9 KB once per session is not where the weight is.

## Consequences

- The saving is bounded by what can be said shorter; the target is the 5-10% that is repetition, not
  a rewrite of the tool set.
- The list is smaller for every client, whether it loads all tools or each on demand.
- A client that cached the old list refetches it on the next connection anyway (a rebuild restarts
  the server).
