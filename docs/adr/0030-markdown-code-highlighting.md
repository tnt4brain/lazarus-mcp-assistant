# ADR-030 — Highlighted code in the Markdown viewer, in the colours of the user's editor

**Status:** Accepted and built in 1.7.0 (2026-11-18): fenced code is coloured with the editor's highlighters
**Date:** 2026-11-18

## Context

`ide_show_markdown` and the review pages show fenced code as plain monospace text. An assistant
shows code all the time (a fix, a diff, a query), and the editor beside the viewer colours the same
text in the user's own scheme. IPro, the viewer's HTML control, has no CSS, but takes `<font color>`,
`<b>` and `<i>`.

## Decision

### 1. `McpMarkdown` stays pure

The unit is compiled by the test program and knows nothing of the IDE. It gets a hook and a rule:

- `MdHighlighter(Lang, Code, out Runs)`: a function variable, nil by default. `Runs` are stretches
  of lines (line, first byte, length, colour as `#RRGGBB` or empty, bold, italic).
- The **language** is the first word of the fence's info string (`` ```pascal ``, `` ~~~sql ``,
  `` ```{.python} ``), lower case. No language, or a hook that answers false: the plain block it was.
- **The unit does the escaping.** The hook only says where and how; every piece of text is escaped
  and made to keep its blanks by `McpMarkdown`, and a colour that is not `#RRGGBB` is dropped, so a
  highlighter cannot put markup into the page.
- Bad runs (out of order, past the line's end, inside a multi-byte character) are skipped, not
  trusted. A block over 1,500 lines or 120,000 bytes is shown plain, and a hook that raises is
  treated as "no highlighting".

### 2. `McpMarkdownHighlight` drives SynEdit

A unit of the plugin (not of the test program) sets the hook. For a language it creates the
matching SynEdit highlighter, has the IDE fill it from the user's scheme
(`IDEEditorOptions.GetHighlighterObjSettings`, as the viewer already does for the Pascal colours),
walks the tokens and reports each token whose attribute has a colour, bold or italic. Neighbouring
tokens with the same look are merged, so a line is a few tags, not one per token. The colours come
from the scheme, so a dark scheme gets dark-scheme colours; no palette of ours.

Two cases where the scheme has nothing to give, found by looking at the result:

- **Highlighters that come without colours.** The SQL highlighter ships bold and italic only. A
  token whose attribute has no colour takes the colour the scheme gives Pascal for the same part
  (keyword, string, comment, symbol, number; data types, functions and the like count as keywords).
- **Diff.** The SynEdit diff highlighter marks files with background colours, which a run cannot
  carry, so a diff is coloured by what each line starts with, not by the highlighter: added and
  removed lines in the viewer's added and removed colours (which come from the scheme), hunk headers
  in the link colour and bold, file headers bold.

No colour scheme is shipped: the user's own choice in the IDE is the one used (Lazarus reads scheme
files from `userschemes`; licences of third-party palettes stay out of this repository).

Languages: Pascal (`pascal`, `pas`, `delphi`, `objectpascal`, `fpc`, `lazarus`), `lfm`, `sql`, `xml`,
`html`, `css`, `python`, `js`/`javascript`/`json` (the JScript highlighter; there is none for JSON),
`c`/`cpp`/`c++`, `java`, `php`, `perl`, `sh`/`bash`/`shell`, `ini`, `diff`/`patch`, `bat`/`batch`/`cmd`.
Anything else is plain.

### 3. Not done

- No language guessing for a fence without one: a wrong guess colours prose as code.
- No line numbers, no copy button, no theme of our own.

## Consequences

- One more unit that needs SynEdit and the IDE's options; the pure side and its tests do not.
- The highlighters are created per block on the main thread (the viewer renders there), freed after.
- A block is highlighted every time the page renders; the size cap bounds that.
