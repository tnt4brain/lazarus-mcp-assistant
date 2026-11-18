# ADR-025 — A review window for files changed on disk while the editor has unsaved changes

**Status:** Accepted and implemented (2026-11-15; released in v1.6.0; extended for git conflicts by ADR-028)
**Date:** 2026-11-14

## Context

Agents sometimes write files with their own tools, not ours. ADR-011 amendment (2026-11-13): an
open editor that is **not modified** is reloaded quietly before each tool call. An editor
**with unsaved changes** is never touched, and nothing used to tell anyone that its file changed.
The IDE's own "files changed on disk" dialog is modal (ADR-011), all-or-nothing per list, and
decides "modified" from the project's unit list: a file open in an editor but outside the
project, with unsaved edits, is pre-checked and reloaded over them (`diskdiffsdialog.pas`).

A JetBrains IDE shows what a reviewer wants: the versions side by side, changes highlighted,
per-change accept or reject, next/previous change. This ADR is about that window.

## Decision

1. **Trigger.** The reload pass (`McpReloadChangedFiles`, before every tool call, and after the
   IDE's own dialog, see 11) meets an editor that is modified **and** whose file changed on disk
   since the editor and the disk last agreed ("changed" is a file stamp, modification time to
   the millisecond plus size, `McpFileStamp`: `FileAge` is DOS time of two seconds, and a second
   write within the same two seconds was not seen at all, which also left unmodified editors
   stale). The window opens non-modally, never blocks a tool
   call, and is also reachable from the Tools menu without an agent (always a window, whatever
   the policy).
2. **Notice to the model.** The result of the next tool call says which files were affected and
   what became of them (`ReviewNoticeText`, one sentence naming every file of the pass, grouped by
   outcome: waiting for the user, the editor kept its text, the editor took the disk text). No new
   MCP tool (the tool list is already too large).
3. **One window, a file tree.** A regular, dockable IDE window (`IDEWindowCreators`), not a window
   per file: the files waiting for review are a tree on the left (folders below the project root,
   files outside it by full path, a count of changes per file), the selected file's page on the
   right. Font, colours and gutter come from the IDE (`IDEEditorOptions.GetSynEditorSettings`);
   tints are blended from the editor background, so dark schemes work. Not Markdown: this is code.
4. **Three panes, a three-way merge.** Editor's text | **Result** | disk's text. The result is the
   only editable pane (the *Edit* button; the other two carry a padlock in their title bar). The
   first result is the automatic merge (decision 8): changes only the disk has are taken (shown in
   green), changes only the editor has stay, overlapping or adjacent changes are conflicts and
   stay as the editor has them. Between the panes, arrows: `>>` between editor and result pulls
   the editor's version of a change into the result, `<<` between result and disk pulls the
   disk's; a right click on an arrow keeps the result as it is for that change (remembered by the
   change's text, not its position). `AlignRows3` aligns the three texts around the result, so a
   line only one side has gets a filler row on the others (red in the result pane for a deletion,
   grey on the outer panes). Changed line pairs are diffed again by word, with the differing span
   marked more strongly. Next/previous change (F7 / Shift+F7).
5. **Actions per file and for all files.** *Apply to editor* (the editor takes the result),
   *Keep mine* (the editor stays; the disk version is marked seen), *Apply all clean / Keep all*.
   Apply writes **into the editor buffer as one undo block, never to the disk**, so Ctrl+Z brings
   the old text back. If the file changed again while it was reviewed, nothing is applied and the
   next tool call opens the review again.
6. **Seen versions.** After any answer, `MakeFileDateValid` on the code buffer marks the disk
   version as seen, and that text becomes the new base; otherwise the IDE's own dialog would open
   for the same change on the next focus. A later write to the file is a new conflict.
7. **Conflict policy (a setting, Options > MCP Assistant).** *Ask me* (the window, default),
   *The editor wins* (the editor keeps its text; the disk's file is copied byte for byte to
   `name.ext.agent` beside it, overwriting an older copy; if the copy fails, the window opens
   instead), *The disk wins* (the editor takes the disk text as one undo step, no window).
   Stored as `Review/Policy` (`ask`, `editor`, `disk`; anything else reads as `ask`). It is a
   setting of the user, not a tool: an assistant cannot change it. "The editor wins" is not
   "write the buffer to disk": that would save unfinished code the user did not choose to save.
8. **Three-way from the first version.** Editor against disk alone cannot tell the user's own
   unsaved changes from the agent's. The plugin therefore keeps a **base**: the text of each open
   file as the reload pass last saw it unmodified (and as it was last answered), in memory, for
   files up to 1 MB. With base, mine and theirs, the changes fall into: only mine, only theirs,
   both the same, and conflicts. The merge is the classic diff3 of line diffs; adjacent changes
   from both sides count as a conflict, as in git. Without a base (the file was modified before
   the plugin first saw it) the window falls back to two-way, says so, and does not merge.
9. **Markers in the editor.** While a file waits, its real editor shows change bars in the gutter
   (`McpReviewGutter`: theirs-only green, conflict red; a click opens the window at that change)
   and a ` (!)` after the tab caption. Both go when the file is answered. The IDE rewrites a tab
   caption when it differs from its own, so the mark is put back by the source window's
   caption-update handler for as long as the file waits. The window objects are kept alive for the
   rest of the session (a window may call the handler while the IDE shuts down). When the editor
   is closed while its file waits, its review is dropped (page, base, session): the editor is
   told apart by identity, because its file name is already gone when the IDE announces the
   destruction (found by test: stale entries piled up in the window).
10. **Explain** (a button that copies a prompt with the differences to the clipboard) exists but is
    hidden for now: the prompt is not finished. The plugin is a server and has no model of its own;
    MCP sampling would be a bonus for clients that declare it.
11. **The IDE's own dialog.** When the IDE shows `TDiskDiffsDlg` (the window got the focus back),
    the files whose editor is modified are unchecked first. The dialog is answered by itself when
    nothing is left checked, or while a tool call runs; otherwise the user decides about the rest.
    Whenever the dialog is gone (`OnFormRemoved`), the reload pass runs once (queued, after the
    IDE's own reload), so the unchecked files go to the review however the dialog was answered.

## Build order (as done)

1. `McpDiff.pas`, pure RTL, tested like `tmarkdown.pas`: line and word diff, alignment
   (`AlignRows`, `AlignRows3`), `MergeAutoEx`, fuzz tests (applying any subset of changes, the
   aligned columns reproduce the texts).
2. The side-by-side spike, word marks through a custom `TSynEditMarkup`.
3. Trigger, notice, file tree, Apply/Keep, seen-version marking, base capture, docking.
4. Gutter bars, three panes with arrows and padlocks, the IDE's dialog, the policy setting, the
   tab mark, the multi-file notice.

## Alternatives considered

- **Reverse it: roll the disk back to the editor's text.** Saves unfinished code, cannot tell an
  agent from `git checkout` or a formatter, and silently deletes the agent's version.
- **Show the diff in the Markdown viewer.** No colour, no per-change action, not an editor.
- **The IDE's own `TDiskDiffsDlg`.** Modal, per file only, and the modified-file test above.
  Its sources are GPL and are not a package we can link.
- **A window per file.** Many files from one agent run meant many windows; replaced by the tree.
- **A new MCP tool to open the window, or to set the policy.** Costs context on every conversation
  for a thing the user, not the model, does; and the policy is the user's to set.

## Consequences

- A conflict no longer waits for the user to come back to the IDE and meet a dialog.
- The model learns, from the tool result, which files were affected, what became of them, and to
  use the `editor_*` tools.
- A new unit family (`McpDiff`, `McpReviewView`, `McpReviewFlow`, `McpReviewGutter`,
  `McpReviewPaths`), the `Review/Policy` setting, and tests for the diff, the alignment and the
  notice and the file stamp. The part that runs inside the IDE is tested over HTTP against the
  live server (`tests/treloadfiles.pas`): the notice names the waiting file, the editor keeps its
  text, nothing lands beside the file, closing the editor ends the review (also in the window's
  count), a file waits again on the same path, and a second write right behind the first is seen.
  Policy "editor"/"disk" cannot be reached that way (the setting is the user's, not a tool, and
  must not be settable from outside); the tests skip when the IDE is set to another policy.
- The three-pane page has no review-specific parts besides its buttons: it takes three texts and
  returns a result, so it could be reused later for merge conflicts in the git tools.
- Verified live (2026-11-15): the notice, the tab mark (` (!)` seen on the tab in a screenshot),
  the padlocks, the cleanup on close. Not verified live: the "editor wins" copy, the "disk wins"
  path, and the dialog handler's deferred reload after `OnFormRemoved` (it fires only on an IDE
  focus change, which nothing over HTTP can cause).
