# ADR-028 — Git tools for remotes and for history: consent on the network, safety nets on rewriting, nothing left to git's defaults

**Status:** Accepted (2026-11-17)
**Date:** 2026-11-15

## Context

The git tools cover the local daily loop (`status`, `diff`, `add`, `commit`, `checkout`, `branches`,
`stash`, `reset`, `log`, `blame`, `init`) and `git_clone`, the only one behind a consent dialog (ADR-013).
`TOOLS_WTFS.md` names what an assistant still cannot do: talk to a remote (fetch, pull, push, manage
remotes, tags) and reshape history (merge, rebase, squash). The first group needs a consent rule, the
second a safety net, and both need to behave the same on every machine.

## Decision

### 1. Which operations ask

The rule is about what crosses the boundary of the machine, not about the command name:

| Crosses | Tools | Consent |
|---|---|---|
| Code **leaves** the machine | `git_push` (branches and tags) | dialog, every call |
| Code **enters the working tree** from outside | `git_pull`, `git_clone` (already) | dialog, every call |
| Where later pushes and pulls **go** changes | `git_remote` `add`, `set_url`, `rename`, `remove` | dialog, every call |
| Only remote-tracking refs change | `git_fetch`, from a remote that is already configured | none |
| Nothing leaves or enters | `git_merge`, `git_rebase`, `git_squash`, `git_tag` (local), `git_remote` `list` | none; safety nets (section 3) |

Merging a remote-tracking branch is local: the data came with an earlier `git_fetch`.
The dialog is the existing `TMcpConsentForm` (`McpConsent.pas`), one new function beside `McpConfirmClone`:
default and cancel button "Don't", a 180 s timeout means no, **no "remember"**, no setting that skips it.
It names the **remote's name and its effective URL** (`git remote get-url [--push]`, so `pushurl` and
`url.<base>.insteadOf` rewrites show as they will be used), the refs and, for a push, the commits that
would go (`<remote-tracking>..<branch>`, counted and the first lines listed). It says when the target is
the remote's default branch (read from that remote's own `refs/remotes/<remote>/HEAD`; informational
only: "protected" is a setting of the hosting service, which a local repository cannot see).

Force-push: `force: true` is refused unless the dialog is asked a second, separate question that names
the remote branch and the commits it would discard; it is always `--force-with-lease=<ref>:<expected>`,
never `--force`.

No remote or branch name is assumed: `origin` is only what `git clone` calls the first remote. With no
`remote` parameter the tools use the branch's own configured remote; with none configured they refuse
and list the remotes, except for a repository with exactly one remote (used, and the result says so).

### 2. Nothing is left to git's defaults

Git's defaults change between versions (`push.default`, `init.defaultBranch`, the `pull` fast-forward
rule, `merge.ff`) and any of them is overridden by a user's or a repository's configuration. A tool whose
behavior depends on one behaves differently on two machines, and a model cannot see which. So:

- **Every behavior the result depends on is named on the command line**, as an option or a `-c`
  override, even when it equals today's default.
- **Not pinned**: identity (`user.*`), signing, credential helpers, `safe.directory`, hooks. They are the
  user's policy. Hooks are never skipped (`--no-verify` is not offered): a `pre-push` hook is a safety
  net someone set up, and this repository's own one refuses pushes of `local/*`.
- No `GIT_CONFIG_NOSYSTEM` or `--no-global`: that removes identity and credentials along with the rest.

The pinned list, by command (a parameter, with its default, where the caller chooses):

| Command | Always passed | Parameter |
|---|---|---|
| fetch | `--recurse-submodules=no` | `tags` (`--tags` / `--no-tags`, default `--no-tags`), `prune` (`--prune` / `--no-prune`, default off) |
| pull | `--no-edit`, `--no-autostash`, `--recurse-submodules=no` | `mode`: `ff-only` (default, `--ff-only --no-rebase`), `merge` (`--no-ff --no-rebase`: a merge commit is always made), `rebase` (`--rebase=true`) |
| push | `<remote> <refspec>` written out in full (`refs/heads/x:refs/heads/x`), `--no-follow-tags`, `--recurse-submodules=no`, `--no-verify` is **not** passed | `force` (see above), `set_upstream`, `tags` (names the tags, never `--tags`) |
| merge | `--no-edit`, `--no-autostash`, `-c merge.conflictStyle=diff3` (the base is in the markers) | `ff`: `auto` (`--ff`, default), `only` (`--ff-only`), `never` (`--no-ff`); `squash` (`--squash`, nothing is committed) |
| rebase | `--no-autostash`, `--no-autosquash`, `--no-update-refs`, `--no-rebase-merges`, `--no-fork-point`, `--empty=drop`, the base always given as an explicit `<upstream>` and, with `onto`, `--onto <ref>`; never `-i` | `onto` |
| tag | `-a --cleanup=whitespace -F -`, the message on standard input (annotated; a lightweight tag only with `lightweight: true`). Not `-m`: on Windows a free-text argument is not escaped (see `RunGit`) | `force` is not offered |
| every call | `GIT_TERMINAL_PROMPT=0`, `GIT_EDITOR=true`, `GIT_MERGE_AUTOEDIT=no`, stdin closed. They are set **by key** on a copy of the parent's environment, so a value the user has set is replaced, not doubled | |
| every call that talks to a remote | `-c protocol.ext.allow=never` (the `ext::` transport runs a command) | |

`git_pull` with `mode: rebase` has no `--no-update-refs` or `--no-autosquash`; the configuration that
would turn them on is overridden with `-c rebase.updateRefs=false -c rebase.autoSquash=false
-c rebase.autoStash=false` (every pull also gets `-c merge.conflictStyle=diff3`). A key an older git does
not know is ignored, so this needs no version gate.

Output the tool parses is requested in a machine form (`--porcelain`, `--format=`, `-z`, `rev-parse`),
never scraped from messages that depend on `LANG` or `advice.*`. Where a message must be matched, the
call runs with `LC_ALL=C`.

`rebase --no-update-refs`, `--empty=` and friends need git 2.38 or newer (`merge --no-autostash`, 2.27).
The version is read from `git --version`; on an older git `git_rebase` and `git_merge` **refuse with the
version they need** instead of dropping a flag silently. `git_squash` uses only `reset` and `commit` and has
no gate. The result of every call carries the exact `command` that ran, so the transcript
shows what was asked of git, not what we meant to ask.

### 3. Safety nets for merge, rebase and squash

All three rewrite the working tree or history, so the tool refuses to start unless:

1. The tracked files of the working tree and the index are clean (`status --porcelain=v1 -z
   --untracked-files=no`); the files are named in the refusal. Untracked files do not block: git itself
   refuses when one would be overwritten, and a repository that always has some would otherwise never
   pass. No autostash: a stash popped onto a conflicted result is a second problem on top of the first.
2. No open editor has unsaved changes (the IDE would show stale text after the operation); the files are
   named, as `ide_rebuild` does (ADR-026).
3. No rebase, merge or cherry-pick is already in progress (`.git/MERGE_HEAD`, `rebase-merge`,
   `rebase-apply`, `CHERRY_PICK_HEAD`); the refusal says which and names the matching `*_abort` tool.

Then, before anything is changed, **a backup ref**: `refs/mcp-backup/<branch>/<UTC timestamp>` at the
current `HEAD`, returned in the result. One `git_reset` to that ref undoes the operation; the reflog is
not relied on (it expires, and `git gc` ignores these refs). Backup refs are listed by `git_branches`
with `backups: true` and deleted by `git_branches` `delete_backups` (older than N days); they are never
pushed (`push` refspecs are written out in full, section 2).

**Published commits.** `rebase`, `squash` and `git_reset` to an earlier commit rewrite history. The result
carries a `warning` when any commit that would be rewritten is reachable from a remote-tracking ref
(`git branch -r --contains <commit>`, any remote name): "N commits are already on <remote>/<branch>; the
branch would need a force-push". A repository with no remotes, or commits not yet pushed, give no warning.
Merge only adds commits and is not checked. No branch name is special, `main` and `master` included:
protection is the hosting service's setting, and the check above is the real hazard.

**Conflicts.** A merge or rebase that stops on a conflict is left in git's own state (no automatic abort),
and the result is `status: "conflict"` with the conflicted files (`diff --name-only --diff-filter=U`), the
backup ref, and the next steps. `git_merge_abort` and `git_rebase_abort` restore the state; after the files
are resolved, `git_add` and `git_rebase_continue` (rebase) or `git_commit` (merge) finish it.

A conflict is an outcome, not a failure: the call is not an MCP error, `status` says `conflict`. A squash
whose commit is refused by a hook puts the branch back as it was (`reset --soft` to the backup ref; the
files are kept) and says so.

**Resolving in the review window** (built in 1.7.0, `McpGitConflicts.pas`, `McpConflictFiles.pas`; the page
mode is `AConflict` of `McpReviewShow`). The three-pane page of ADR-025 takes three texts and returns a result
(`McpReviewShow(File, LeftTitle, RightTitle, Mine, Theirs, Base, HasBase, OnDone)`); a merge conflict has
exactly those three, in the index: stage 1 is the common ancestor, stage 2 "ours", stage 3 "theirs"
(`git show :1:<path>` and so on, never the marker text in the working file). So the window opens, non-modally
and without blocking the tool call, with one page per conflicted text file in its tree:

| | Left pane (stage 2) | Right pane (stage 3) | Base (stage 1) |
|---|---|---|---|
| merge | "Ours: `<branch>`" | "Theirs: `<merged ref>`" | the merge base |
| rebase | "Upstream: `<onto>`" (git's "ours") | "Your commit: `<short hash> <subject>`" (git's "theirs") | the commit's parent |

(In a rebase git swaps the meaning of ours and theirs; the titles say what each side *is*, never "ours".)
No stage 1 (both sides added the file): two-way, as the page already falls back. One stage missing (modify
against delete), a binary file, a symlink or a submodule: not a text merge; the file is listed in the result
under `needs_decision` with the reason and the stages that exist, and is settled with `git_resolve` through the tools, not in the window.

What differs from the file-on-disk case of ADR-025, and is added to the page as a mode, not a copy:
- **Apply** writes the result **to the working-tree file** and stages it (`git add`), the git meaning of
  "resolved". The line ending of the existing working file is kept (`core.autocrlf` makes the blobs LF and
  the file CRLF). The caption says "Resolve (write and stage)", the other button "Leave unresolved" (the
  markers stay in the file, nothing is staged). It is not an editor undo step: Ctrl+Z is not the way back,
  `git_merge_abort` / `git_rebase_abort` and the backup ref are.
- **A conflict starts as the common lines.** The result begins as the automatic merge with every change only
  one side made taken, and each conflict holding the *base* (stage 1) lines (`ConflictStart`), so both side
  panes stand against it, as in the JetBrains merge window. With no common ancestor the result starts empty
  and the whole file is one conflict. Apply stays disabled until every conflict has been decided, and refuses
  a result that still contains a conflict block (a `<<<<<<<` line followed by a `>>>>>>>` line; a lone
  `=======` is a Markdown title underline and does not count).
- **The gutters carry the controls.** Beside each change of a side that touches a conflict
  (`SpanOfHunk`; a change nothing conflicts with gets none) the gutter has **X** (drop: the result keeps what
  it has) and **>>** / **<<** (take: the side's lines replace the result's there). Once the *other* side's
  lines have been taken there, the take button turns into a down arrow that puts this side's lines *below*
  them, both stay (with nothing of the other side in the way, as after a drop, the result still holds the
  common lines, there is nothing to go below and the button stays "take"; likewise when the other side's
  change took lines away, so that a pure insertion has nothing to go below either). Left first and then the right one
  below it gives both sides in that order, and the other way round. A side that has been taken, put below
  or dropped is dealt with: its change there has no buttons, no colour and no Next/Previous stop any more.
  Dropping both leaves the common lines (that is the text, not "nothing"; the user deletes it by taking a
  side that deleted it, or by editing).
- **Colours say what a change does.** A side's lines the result lacks are an addition: pale green, with the
  result's empty slot pale green; lines the result has and the side lacks are a deletion: the result's lines
  pale red; different lines are pale blue. The place a change would go is a line under the row above it
  (SynEdit draws no top edge): green in the result for an addition, red in the side pane for a deletion.
  The buttons take the colour of their change. The ADR-025 page keeps its own tints and arrows.
- **A decision can be taken back.** A conflict something was done to (a button, or typed text) has a grey
  *again* button on its first row, in the gutter of each side that was dealt with (`ResetConflict`): its lines in the result go back to the
  common lines, both sides' changes are offered again, and the "keep" marks of its changes are forgotten.
  It resets the whole conflict, not one side (a taken change leaves no hunk to carry a button); text typed
  over it is replaced after a question. The symbols (cross, arrows `➡` `⬅` to take, `⬊` `⬋` to put below, again) are
  drawn in Segoe UI Symbol / DejaVu Sans, with letters where that font is missing.
- **Each conflict has its own state.** `Merge3` says where every conflict is in the result; the page keeps
  that range (`TConflictSpan`, `McpConflictFiles`) and moves it through every button and every edit. A
  conflict is *decided* when one of those touched its lines, and only then: going back and forth on one
  change decides that one conflict, not the next. The status line says "3 of 5 conflict(s) to decide".
- **A third version is a decision.** Neither side's text: "Edit", type over the conflict's lines in the
  result, "Done editing" (Apply is disabled while editing, since what was typed is only looked at then). A
  change *at the edge* of a conflict's lines does not settle it when typed (a line added above it is not a
  decision about it), but does when made by a button.
- **Where the window is told.** `git_merge`, `git_rebase`, `git_rebase_continue` and a squash merge open the
  pages when they stop; the result carries `review` (`window`, `files`, `needs_decision`). The pages of files
  that are no longer unmerged leave the window after `git_add`, `git_commit`, `git_resolve`, the aborts and
  the next merge or rebase step (`SyncConflicts`).
- **Open editors.** Merge and rebase refuse unsaved editors beforehand (section 3), so an editor of a
  conflicted file is unmodified and the reload pass shows the resolved file after Apply. If the file
  changes on disk meanwhile (the model resolved it with the `editor_*` tools), nothing is applied: the page
  is dropped, as ADR-025 does when "the file changed again while it was reviewed".
- **The model and the user share the work.** The tool result names the window and the files; the model
  may resolve some files itself (edit, `git_add`) and leave the rest to the user. `git_status` shows which
  paths are still unmerged; `git_rebase_continue` and the merge `git_commit` refuse while any remains. A
  rebase that stops again at the next commit replaces the pages of the same files with the new stages.

`git_resolve` (`file`, `side`: `ours` | `theirs` | `delete`) is added for the whole-file cases and for a
model that has decided: `git checkout --ours/--theirs -- <file>` (with the rebase swap spelled out in the
parameter description, `side` is **upstream** or **commit** for a rebase) followed by `git add`.

`git_squash` (`count` or `since`, `message`): the last N commits of the current branch become one
(`reset --soft <HEAD~N>` then `commit -F -`), after the same checks and the same backup ref; it refuses a
range that contains a merge commit.

### 4. The tools

`git_fetch`, `git_pull`, `git_push`, `git_remote` (`list`, `add`, `set_url`, `rename`, `remove`),
`git_merge`, `git_merge_abort`, `git_rebase`, `git_rebase_abort`, `git_rebase_continue`, `git_resolve`, `git_squash`,
`git_tag` (`list`, `create`, `delete`). `git_cherry_pick` waits for a request.

The network ones (`fetch`, `pull`, `push`) run in a blocking group on the worker thread with a 30-minute
limit like `git_clone` (`RunGitTimed`); `merge`, `rebase`, `squash` and the local ones run on the main
thread through `RunGit`, which gains an environment parameter for the variables above.

### 5. How the consent is tested, and why that cannot be abused

`git_clone`'s dialog is not stubbed anywhere: its test needs a human. The dialogs of this ADR are
tested through a hook (`__test_arm_consent__`, in `McpTestHooks`, refused unless the IDE was started with
`MCP_TEST_HOOKS=1`), and a hook that approves is exactly what `McpIsConsentDialog` exists to prevent, so it is
narrow on purpose:

- It replaces `ShowModal` and nothing else: the text is still built and kept, so tests assert on what the
  user would have been shown (`__test_get_consent__`).
- It answers the next one or two dialogs (a force push asks twice) and is then spent.
- A **yes** is honoured only when the address is a folder under the system's temp directory. For any other
  address the dialog is shown to the human as usual, and the stub is spent. A **no** is always honoured.

So an assistant that can reach the hook can decline its own requests, and can approve a push into a
temporary folder, and nothing else.

`git_pull` also refuses while an editor holds unsaved changes (section 3, item 2): it rewrites files on disk.

## Caveats

- A credential helper that opens its own window (the Windows credential manager) can still ask the
  user something; `GIT_TERMINAL_PROMPT=0` only stops git's own terminal prompt. The 30-minute limit ends a
  call that waits for it.
- `git_fetch` is not consented: it changes no branch and no file, but it does contact a server and
  download objects. If that proves too loose, one setting ("ask before fetch") can be added later.
- A rebase interrupted by an IDE restart stays in git's state; `git_rebase_abort` and `git_status` see it.
- The consent dialog shows commits and names, not file contents: it is a prompt, not a review.

## Consequences

- 12 new tools; descriptions kept short, the pinned flags and the safety rules live here and in the tool
  descriptions' last sentence.
- `McpConsent.pas` gains one dialog function; `McpToolsGit.pas` grows (split into `McpToolsGitRemote.pas`
  if it passes 1500 lines).
- Tests (`tests/tgitremote.pas`): temporary repositories, a bare repository as the remote **named
  something other than `origin`**, and a hostile configuration in the repository under test
  (`push.default=matching`, `pull.rebase=true`, `merge.ff=only`, `rebase.updateRefs=true`,
  `rebase.autoSquash=true`, `init.defaultBranch=trunk`) to show that the pinned flags win. Cases: push and
  its dialog refusal (the consent function is stubbed by a test hook, as for clone), force refused,
  pull `ff-only` against a diverged remote, merge clean and with a conflict, abort, rebase with the
  published-commit warning, squash with its backup ref, dirty tree and unsaved editor refusals.
