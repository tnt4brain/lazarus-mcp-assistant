# ADR-024 — `ide_show_markdown`: show a Markdown document to the user in an IDE window

**Status:** Accepted and implemented (2026-11-07, v1.4.0)  
**Date:** 2026-11-06

## Context

Long answers (reports, plans, tables, code) read badly in a console: tables and fences come out as
raw text. The IDE is already open next to the assistant. A tool that shows a document in an IDE
window helps every MCP client, not only Claude Code, and needs nothing but the plugin.

Nothing renders Markdown for us: Lazarus has no converter and the Online Package Manager
catalog lists none (checked 2026-11-06). `TurboPowerIPro` (`TIpHtmlPanel`) ships with Lazarus
and is installed; Report Manager already uses it as the fallback viewer for its AI chat.

## Decision

1. **Tool `ide_show_markdown`** (prefix `ide_`, ADR-010). Arguments: `markdown` (required, at most
   256 KB of text; the Base64 of `data:` images is counted by 5, not here), `title` (at most 80 characters), `tab` (an id from an earlier call: its content is
   replaced; otherwise a new tab). Returns at once with `{shown, tab}`.
2. **Display only.** One modeless window with tabs (at most 8, the oldest drops out). It is shown
   without taking focus (ADR-011: no modals, no stolen input) and created on the main thread
   through the usual hop. Nothing is saved: closing the tab discards the document. No button, field
   or reply goes back to the model, and no tool reads the window.
3. **Renderer: `TIpHtmlPanel`.** One new `requires` (`TurboPowerIPro`), no download. The spike
   showed it good enough for tables, quotes and code (see Consequences), so HtmlViewer, which
   would add a dependency, stays unused.
4. **Converter: a pure unit `McpMarkdown`** (class `TMarkdownHtml`, `ToHtml(AMarkdown): string`),
   plain RTL, no IDE units, tested in the suite. Written in the style of `book_translator`'s
   `UMarkdownParser`, so that project can take it later (renaming the unit). Subset: ATX and
   setext headings, paragraphs, emphasis, strikethrough, inline code, fenced and indented code,
   nested lists, task lists, block quotes, GFM tables, links (inline and reference), rules,
   hard breaks, entities, link titles, bare `http(s)` addresses. From GitLab's flavour (GLFM,
   which is GFM plus extensions) the ones IPro can show: `> [!note]` alerts, `>>>` quotes,
   footnotes, description lists, `{+ +}` / `{- -}` diffs, front matter (shown as code),
   `[[_TOC_]]` / `[TOC]` (the top-level headings as nested lists, linked), heading anchors
   (`#some-heading`; ids are only written when the text has a TOC or such a link, and the panel
   follows a `#` link by itself, scrolling and fetching nothing), `{width=50%}` after an image,
   `:emoji:` shortcodes (about 130 common names; GitLab knows far more, an unknown one stays as
   typed) and hidden `<!-- comments -->`. Raw HTML stays escaped, but for `<br>` and the paired
   `<kbd>`, `<sub>`, `<sup>` (only when the closing tag is there). Not taken: colour chips,
   maths, diagrams, video, `<details>`, and GitLab references (`#123`, `@user`: no GitLab
   behind them).
   It is a subset of CommonMark, not a conforming implementation. An unknown construct
   becomes escaped text, never an error. Scans are bounded (a link's text 2000 characters, its
   address 2200, a missing closer is looked for once), so a hostile line stays linear. It emits only what the spike showed IPro renders:
   `h1`-`h6`, `p`, `br`, `strong`, `em`, `del`, `tt`, `a`, `blockquote`, `ul`/`ol`/`li` (nested,
   also inside a quote), `table`/`tr`/`th`/`td` (`align`, `border`), `hr`, `div`, `span`, and
   `img` (local paths only, see 5; not yet tried in the spike). Two
   forms differ from the usual: inline code is `tt` (`code` is letter-spaced), and a fence is a
   shaded one-cell table (`bgcolor`) of `tt` lines with `&nbsp;` for runs of spaces and `br`
   between lines, because IPro does not decode entities inside `pre`.
5. **The input is untrusted** (it can quote files and web pages):
   - Raw HTML in the Markdown is escaped, never passed on.
   - Images are shown from local files and from Base64 `data:` URIs (part 2 of the work; the
     first part has none). A Markdown image with a local path or a `data:image/...;base64,` URI
     becomes `img`; with `http(s)` (or anything else) it becomes its alt text, and for `http(s)`
     a link to the URL. Nothing is fetched from the network: a model-written URL would be a way
     to send data out and to track the reader. A `data:` URI is the only way for a client on
     another machine (ADR-020) to show a picture, as it cannot put a file where the IDE reads.
   - The viewer's image handler answers every request, always: IPro raises a modal error box for
     an `img` that has no handler (found in the spike), which ADR-011 forbids. A failure shows a
     placeholder with the alt text. For a file: a relative path is taken from the project's
     directory; a known image extension; at most 8 MB. For a `data:` URI: PNG, JPEG, GIF or BMP
     only (no SVG: it can carry scripts and references); the bytes must start with the magic
     number of the declared type; at most 4 MB decoded; the width and height are read from the
     header first and a picture over 16 megapixels is refused, before any decoder runs; a decoder
     exception is caught and shown as the placeholder. The converter does not decode: it swaps
     each `data:` URI for `mcp-img:N` and hands the Base64 strings back beside the HTML, so a
     large attribute never reaches the HTML parser.
   - Reading a file for display is no new reach: the same tools already read any path, and the
     picture goes to the user, not back to the model.
   - Only `http` and `https` links are live; a click opens the system browser, and the target is
     shown before the click. Other schemes are plain text.
6. **Logging:** ADR-022 records `arg_keys` and a hash, never values; the document stays out of
   `mcp-tools.log`.
7. **Server instructions** get two sentences: use the tool for long structured output and keep the
   chat reply short; not for short answers.

## Rejected

- **A page in the browser or a client-side artifact:** outside the IDE, and client-specific.
- **HtmlViewer now:** a dependency for the plugin, and the catalog lists only gtk2 and win32/win64
  for it. Kept as the fallback in 3.
- **WebView2 or CEF:** a heavy runtime, WebView2 is Windows-only.
- **The `book_translator` parser:** a flat span model for an editor; no tables, fences or links,
  and it would couple two projects. Its inline rules and tests are copied where they fit.
- **Buttons or a reply channel:** a second, unrequested way to drive the assistant (YAGNI).

## Consequences

- IPro renders an HTML 3.2/4 subset: no modern CSS. Documents look plain but readable. A spike
  (2026-11-07, a throwaway program drawing a test page) showed headings, emphasis, tables,
  quotes, nested lists, rules, shaded code blocks and Cyrillic text all fine. Long code lines do
  not wrap: the page scrolls sideways.
- An unknown tag is dropped but its text stays; a `javascript:` link would still look like a
  link, so the converter emits `a` only for `http` and `https`. Whether a click needs a handler
  to stay silent is checked with the window, not assumed.
- The tool shows what the model sends; a misleading document is possible, as in the console. Links
  need a click and show their target.
- Found while building the images part: the handler hands IPro a `TPicture` and IPro owns it;
  a placeholder is a small bordered bitmap with the alt text; a handler that answers `nil`
  blanks the page, so it never does. The viewer decodes PNG, JPEG, GIF and BMP with the LCL
  classes after `McpImageInfo` has checked the magic number and the header size. The HTTP server
  has no body limit of its own: a 5.7 MB request (a 4 MB picture in Base64) was accepted, so no
  raise was needed. The text limit counts the document without the Base64 of `data:` images
  (`MdTextSize`). A UNC image path is refused (Windows would log on to the named host). Link
  hints come from IPro (`ShowHints`); a click reaches `OnHotClick`, which opens only `http(s)`.
- **Docking.** The window is registered with `IDEWindowCreators` (`McpMarkdownFormID`, as the
  chat window is) and created and shown through it, so in the IDE's docking layout the user can
  dock it next to the source editor, and the IDE remembers where it was; the floating layout is
  unchanged. A window restored at IDE start has no documents and closes itself. A docked window
  behind another tab is not brought forward by a new document; the user clicks its tab.
  Not a page of the editor's own notebook: the IDE offers no way to add one.
- The window is shown by the plain LCL `Show`, with no platform code: the active IDE form is
  remembered and focused again afterwards. If another program had the focus (a terminal), LCL
  cannot know it, and the window may take the focus then. (`ShowWindow(SW_SHOWNOACTIVATE)`
  alone was tried: LCL then thought the form hidden and the page stayed blank.)
- Tests: the converter (headings, lists, tables, fences, escaping, images by path kind, hostile
  input such as `<script>` and `javascript:`) and the tool's schema and limits through the HTTP
  harness. The window needs a manual look on Windows.
- Minor release (1.4.0).
