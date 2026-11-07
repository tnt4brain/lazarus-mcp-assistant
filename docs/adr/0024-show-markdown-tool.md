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
   `UMarkdownParser`, so that project can take it later (renaming the unit). It is a subset of
   CommonMark and GitLab's flavour (GLFM, GFM plus extensions), not a conforming implementation,
   and takes what IPro can show:
   - *Blocks:* ATX and setext headings, paragraphs, quotes (also `>>>` and `> [!note]` alerts),
     bulleted, numbered and task lists (nested), description lists, fenced and indented code,
     GFM tables, rules, front matter (shown as code), `[[_TOC_]]` / `[TOC]`, footnotes.
   - *Inline:* emphasis, strikethrough, code, links (inline, reference, bare `http(s)`
     addresses, `#heading` anchors; titles kept), images (`{width=50%}` after one),
     `{+ +}` / `{- -}` diffs, footnote references, entities, `:emoji:` (about 130 common names;
     an unknown one stays as typed), `<br>` and the paired `<kbd>`, `<sub>`, `<sup>` (only when
     the closing tag is there). `<!-- comments -->` are dropped.
   - *Not taken:* colour chips, maths, diagrams, video, `<details>`, other raw HTML (escaped),
     GitLab references (`#123`, `@user`: no GitLab behind them).
   - *Anchors:* headings get GitLab-style ids only when the text has a TOC or a `#` link. The
     panel follows a `#` link by itself (scrolls, fetches nothing); the data provider refuses
     every other URL.

   An unknown construct becomes escaped text, never an error. Scans are bounded (a link's text
   2000 characters, its address 2200, a missing closer is looked for once), so a hostile line
   stays linear (a test builds 800 KB of it). The output has only tags the spike showed IPro
   renders: `h1`-`h6`, `p`, `br`, `strong`, `em`, `del`, `tt`, `kbd`, `sub`, `sup`, `a`, `ul`/`ol`/`li`
   (nested), `dl`/`dt`/`dd`, `table`/`tr`/`th`/`td`, `hr`, `font`, `img`, and a `style` block of
   whole-pixel margins. Forms that differ from the usual: inline code is `tt` (`code` is
   letter-spaced); a fence is a shaded one-cell table of `tt` lines with `&nbsp;` for runs of
   spaces and `br` between lines, because IPro does not decode entities inside `pre`; a quote
   is a table with a coloured stripe, as IPro draws no border on `blockquote`.
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
7. **Server instructions** say which answers go to the window: a reply with a table, a plan, a
   review, a code listing or more than about 15 lines of structured text; the chat reply then
   shrinks to the gist. Short answers stay in the chat. (A first, vaguer wording left the
   choice to the model and it kept answering in the console.)

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
  link, so the converter emits `a` only for `http`, `https` and `#anchor`. A click on an
  `http(s)` link reaches `OnHotClick` (the data provider's `CanHandle` is false for it); a
  `#` link is handled by the panel and scrolls.
- **Look.** Bootstrap 5 as far as IPro allows: its colours, 16 px under a block and 8 px under
  a heading (a `style` block; IPro reads tag selectors and whole pixels only), the UI font and
  a real monospace font, a 1.25 line height. IPro takes a table border's colour from the
  `border` attribute, not from CSS: the borders of tables and code frames are dark, not light
  grey. It ignores the bottom margin of `ul` and `ol`: no gap after a list. Emoji are
  monochrome (the panel draws text with GDI, with no colour fonts).
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
  dock it next to the source editor; the floating layout is unchanged. A window restored at IDE
  start has no documents and closes itself. A docked window behind another tab is not brought
  forward by a new document; the user clicks its tab. Not a page of the editor's own
  notebook: the IDE offers no way to add one.
  Closing the window hides it, with its documents dropped, and the next document shows it
  again (a closed docked window still counted as visible, and the check now looks at the host
  window too). AnchorDocking forgets where a closed window was docked, so the creator names the
  source editor as the default dock sibling (right side): a window the user closed comes back
  there, not where they had put it. A floating window opens on the monitor of the IDE's main
  window.
- The window is shown by the plain LCL `Show`, with no platform code: the active IDE form is
  remembered and focused again afterwards. If another program had the focus (a terminal), LCL
  cannot know it, and the window may take the focus then. (`ShowWindow(SW_SHOWNOACTIVATE)`
  alone was tried: LCL then thought the form hidden and the page stayed blank.)
- Tests: the converter (every construct above, escaping, images by path kind, hostile input such
  as `<script>`, `javascript:` and an 800 KB line of unclosed openers) and the image header
  checks. The window needs a manual look on Windows; links, anchors, docking and reopening were
  checked that way. Not checked: closing a docked tab by its own button, and the empty-window
  cleanup when the IDE starts with the viewer docked.
- Minor release (1.4.0).
