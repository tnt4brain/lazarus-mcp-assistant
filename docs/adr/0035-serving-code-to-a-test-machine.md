# ADR-035 — Serving the open project's code to a test machine

**Status:** Accepted (2026-11-22), for 1.8.0. Built on branch `feat/git-serve`. Replaces the first draft of the same day
(a TOTP login and new parameters on the git tools), which solved a problem this situation lacks.
**Date:** 2026-11-21

## Context

An assistant is asked to test the code on another machine (the Linux test box). Today it packs
the tree by hand: `git archive`, base64 in parts, a sha1 check, an unpack, a snapshot commit on
the other side. The assistant already runs shell commands on that machine; what it lacks is a
way to make the machine fetch the code itself.

The assistant is on the first machine and drives both ends. So no second assistant needs a login
to be configured, and no person has to carry a code between two chats: one consent in the first
IDE is the human decision, and what follows is the same assistant's call.

## Decision

### 1. A read-only git server in the plugin

Smart HTTP, served by git itself: `GET /<name>/info/refs?service=git-upload-pack` and
`POST /<name>/git-upload-pack`, each answered by one `git upload-pack --stateless-rpc` child
(the environment of ADR-028 decision 2: no terminal, no editor). Nothing else: no `receive-pack`,
no dumb protocol, no listing. At most 2 children at once, each with a timeout.

### 2. `git_serve`: start, stop, status, and only after the person says yes

`git_serve` (`action` start, stop, status) asks the person in the IDE before it starts, like
`git_push` and the package install (ADR-013): "Serve <repository> to <peer> for N minutes?" That
dialog is the whole authorisation. Without a yes nothing listens.

Parameters: `peer` (the address of the machine that will fetch; required), `minutes` (default 15,
at most 60), `snapshot` (decision 5). The answer holds the URL and a ready command for the
receiving machine, with a code that is good for about a minute (decision 4); `action` code makes
a fresh one:

    git -c http.extraHeader="Authorization: Basic ..." fetch http://<this machine>:<port>/repo.git
        +refs/mcp/snapshot:refs/mcp/snapshot

### 3. Three limits, none of them a configured secret

- **Peer.** The listener answers only the `peer` address; any other connection is closed at once.
- **Code.** The password of HTTP Basic (user `mcp`) is a TOTP code (RFC 6238: HMAC-SHA1, 6
  digits, 30 seconds, the previous and the next step accepted) whose key is derived from the
  secret the caller and the IDE already share: HMAC-SHA1 of the bearer token of the session that
  called `git_serve`, with the fixed text `git-serve` as its message, so the code never reveals
  the token and the key is not the token. The key lives in memory only and dies with the server;
  nothing new is made, stored or configured. See decision 4.
- **Time.** The server stops after the minutes given, on `stop`, and when the IDE ends.

It listens on the one address of this machine that routes to the peer (not `0.0.0.0`), on a port
the OS picks, and never on the MCP port: opening the MCP server to a network to share code would
open every tool. The repository served is the one holding the open project, fixed at start, and
only if the write scope and limited mode (ADR-034) allow that folder.

### 4. Why a code from the session secret, and who computes it

The receiving machine does not hold the secret, so it cannot compute a code: the IDE does, on
request. `git_serve` with `action` code answers with the current code and the seconds it has left,
and the assistant puts it into the fetch command on the other machine. The gain over a token made
at start is its life: the credential that sits in that machine's command line and process list
dies within a minute, not at the end of the window. It also costs no new secret.

- The code is checked on this machine, against this machine's clock, and it is made on this
  machine: the clock of the receiving machine does not matter.
- A code made by another session's token fails; the sessions of one IDE never share it.
- 6 digits are 10^6 guesses, so the lockout stays: 5 wrong codes in a minute close the listener
  for 5 minutes. Only the peer address can reach it at all (decision 3).
- Named tokens are stored as hashes (ADR-021), so the key is taken from the token the session
  presents when it calls `git_serve`, in memory, and not from any stored value.
- A person carrying the code to another chat by hand can use the same code; Options may show it
  with its countdown. That is an addition, not part of the first build.

### 5. A snapshot of the working tree

Git moves commits, and the code to test is usually not committed. `snapshot=true` builds a commit
of the **tracked** files as they are on disk (`git stash create`, which makes the commit without
touching the stash list, then `update-ref`; HEAD itself when nothing changed) under
`refs/mcp/snapshot`. The branches and the working tree are not touched. Untracked files are left
out: private notes next to the code must not travel. `include` (a list of paths or patterns
relative to the repository root) sends the named untracked files as well: the snapshot is then
built in a throwaway index (`GIT_INDEX_FILE`: `read-tree` of the stash commit, `add --` of the
named paths, `write-tree`, `commit-tree` on HEAD), so the real index and the working tree are never
touched; ignored files are not sent, a name that matches nothing is refused, an entry that starts
with `-` is refused. Every start says which files were included and how many untracked files were
left out (with the first ten names), so a unit missing on the other machine is not a mystery.
For a linked machine there is no dialog, so the assistant that holds the link may name any file
of the repository; it could read the same file anyway. Saved files only: an unsaved editor buffer is not on disk, and the tool says
how many there are.

### 6. Two parts: the server here, a pull step there

The **local part** is decisions 1 to 5: the listener and `git_serve`, in the plugin.

The **remote part** is plain git behind a small script, `scripts/mcp-pull.sh` (POSIX sh): it takes
the URL, the code and a target folder, makes a repository there on first use, runs `git fetch` of
`refs/mcp/snapshot` and `git checkout -f` of it, and prints the commit it now holds. The
`git_serve` answer carries the same step as text for `bash` and for `powershell`, so the assistant
can paste it into its shell executor without the script being on that machine. The other machine
needs no plugin and nothing installed but git.

Nothing changes in `git_fetch`, `git_pull` or `git_clone`. A later ADR may add `url` and a
credential to the MCP git tools for an assistant that works through its own IDE.

## Not done

- No push back to this machine (corrections made on the box come back as a patch: `git diff refs/remotes/mcp/snapshot` there, applied here; a return path into `refs/mcp/incoming/*` is for a later release); no HTTPS (a token controls who fetches, not what is read on the
  wire; the peer limit and the minutes keep that small, a tunnel covers anything wider).
- No automatic firewall change. Windows asks once, or the person allows the port: the first
  start tells them when the peer cannot connect.

## Caveats

- A snapshot can still hold a secret that was committed to a tracked file.
- The code is in a command line on the other machine for about a minute; a fetch that needs
  more than a minute between its first and its last request would need a new code (git sends the
  same one with each request, so a normal fetch is not affected).
- The peer address is not proof of who connects; on a shared network a second machine can take
  that address. The token is the second lock.

## Consequences

- "Test it on the Linux box" becomes: `git_serve` (one yes), one `fetch` on the box, the existing
  build and test job. No parts, no base64, no sha1 of an archive.
- One new tool, one listener, one unit; no change to existing tools, so it fits 1.7.1 only if you
  call a new tool a patch; by our own rules it is 1.8.0.

## Open questions

- (Settled: 1.8.0, a new tool; the snapshot and `include` are in the first build; both `bash` and
  `powershell` texts are in the answer.)

## Amendment 1: a link, so that nothing asks twice (2026-11-21)

The test box is driven by the same assistant, and a person who must answer a dialog for every
test run makes the idea useless. So the flow became: **set up a transfer here, `git_fetch` there,
`git_reset` there, tear the transfer down.**

- `git_serve link` (`peer`, optional `port`) asks the person once (the dialog of decision 2) and
  stores a **link**: the peer address, the address of this machine, a fixed port and a random
  20-byte key, in the IDE's settings. Linking again replaces the key; `unlink` removes it; `links`
  lists them (never the key).
- The key replaces the session-token key of decision 3 for a linked machine: the code is the
  TOTP of the link's key, computed **on the box** by a git credential helper: an instantfpc script
  (`scripts/git-credential-mcp.pas`, the same HMAC and TOTP as the server, no other dependency but
  FPC, which a Lazarus test box has) or, when `instantfpc` is not found there, a shell script
  (`scripts/git-credential-mcp`, needs sh, date and openssl); the setup installs both and picks
  one on the box. The code is checked here (one step either side, so the
  box's clock must be within a minute). The setup text from `link` is run once on the box
  through the assistant's shell executor: it makes the folder and the remote `mcp`, whose fetch
  refspec is `+refs/mcp/snapshot:refs/remotes/mcp/snapshot`, and installs the helper. No dialog
  is shown on the box.
- `git_serve start` for a linked machine **asks nothing**: the link is the consent. It refreshes
  `refs/mcp/snapshot`, opens the listener on the link's port (it refuses when the port is taken: the
  box's URL would be wrong; when this machine's address changed it says so and how to repair the
  remote), and closes itself after `fetches` fetches (default 1; a fetch is an answer that carried
  a packfile) or after `minutes`, whichever comes first. `stop` is for an abandoned run.
- On the box the run is the standard tools: `git_fetch` of the remote `mcp` (ADR-028: no dialog
  for a configured remote), then `git_reset` hard to `refs/remotes/mcp/snapshot`, which also removes
  files the snapshot no longer has. `git_pull` is not used: it asks the person at that IDE every time.
- Without a link, `start` is as in decisions 2 and 3: a dialog every time and a command with a code
  of a minute, from the session's token.

What the link costs: the box holds a long-lived key, like an SSH key. It opens nothing while the
listener is down, and while it is up it is limited to the peer address, read-only and rate-limited
(decision 3).

## Prototype (2026-11-21)

Built on branch `feat/git-serve`, not released: `McpGitServe.pas` (listener, TOTP, smart HTTP; no IDE
unit), `McpToolsGitServe.pas` (`git_serve`), `scripts/mcp-pull.sh` (the remote part), tests in
`tests/tgitservetests.pas` (RFC 2202 and RFC 6238 vectors; a real `git fetch` with the right code, a
wrong code, a code of another token, the lockout and `stop`). Differences from the text above:
the snapshot uses `git stash create` (decision 5); `include` was built afterwards (decision 5); the request is limited to
64 MB and 10 minutes; gzip and chunked request bodies are understood. Checked by hand (2026-11-21/22): the consent dialog of `link`;
a linked `start` without a dialog; a fetch and `reset --hard` from two containers on the Linux
test host, one with `instantfpc` (the FPC helper) and one without FPC (the shell helper); the
listener closing itself after the fetch; `include`. No Windows firewall prompt appeared, since the
IDE already was allowed to accept connections.

Found on the way: Git for Windows lists Git Credential Manager as a system credential helper, which
opened a window and asked for a password when the server answered 401. The setup therefore puts an
empty `credential.helper` entry first (it clears the inherited list), and the tests pass
`-c credential.helper=` to every git call.

Limits: one link per peer address, so a second container behind the same host address replaces the
first one's key; the clock of the other machine must be within about a minute of this one
(one 30-second step either side is accepted).
