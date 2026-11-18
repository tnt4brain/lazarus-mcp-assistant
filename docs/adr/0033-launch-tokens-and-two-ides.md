# ADR-033 — A config file and a token of its own for every launch, and two IDEs side by side

**Status:** Proposed (2026-11-19)
**Date:** 2026-11-19

## Context

`Tools > MCP Assistant > Launch` starts the user's terminal with `claude --mcp-config <file>`.
`WriteMcpConfig` (`mcpideserver.pas`) writes that file:

- **One fixed name.** `McpSettings.LastConfigPath` if one was saved, else `lazarus-mcp.json` in the
  temp folder. The file is rewritten after a rebuild, so the running Claude Code finds the new URL.
- **The primary token.** ADR-021 decision 1 chose this: the primary token is plain text in the
  options file, local clients read it, and named tokens are hashes that cannot be written to a file.

Two consequences:

1. **A leaked config file is a leaked primary token.** Replacing it cuts off every client
   (ADR-021, context). The roadmap's item 6 asks for a launch-scoped token.
2. **Two IDEs overwrite each other's file.** Both write `lazarus-mcp.json` (the saved path is in the
   options file they share, and `--pcp` does not change the temp folder). The second IDE launches
   Claude, the file now holds its port and token, and the first IDE's Claude Code re-reads it after
   a rebuild and talks to the wrong IDE: it edits the second project. ADR-004's amendment (a fallback
   port is not saved) covers the stored port only.

Facts from the code (2026-11-19):

- `TMcpClientToken` has `Created` and `LastUsed`, no expiry. The store holds at most 16 tokens.
- A named token is stored as `sha1:<hex>`; its plain text exists once, at creation.
- `mcp-active.json` sits in the IDE's primary config folder (`--pcp` separates it) and holds the
  primary token for local helpers (`wait_for_restart.pas`). It is not part of this ADR.

## Decision

### 1. Every launch gets its own token

- A launch makes a **launch token**: a named token with `Launch = True`, named
  `launch <port> <yyyy-mm-dd hh:nn>`, made like any other (`McpNewClientToken`, hash stored).
- The plain text goes into that launch's config file and nowhere else; the IDE keeps no copy.
  When the file must be rewritten (a new port after a rebuild), the IDE reads the token back from
  the file it owns. If the file is gone, the next launch makes a new token.
- The **primary token no longer goes into any file the launcher writes.** ADR-021 decision 1 is
  amended for the launcher only: `mcp-active.json` and the options file keep the primary token
  for the local helpers.

### 2. Launch tokens expire when unused, and are few

- A launch token is removed after **7 days without use** (`LastUsed`, or `Created` if never used),
  checked when the IDE starts and when the options page opens. Sliding, so a long session never
  loses its token while it works; an abandoned one goes away by itself.
- The IDE keeps at most **4 launch tokens**; a new launch beyond that revokes the oldest (its
  sessions end, as in ADR-021 decision 7). They do not count against the 16 named tokens.
- They are listed on the options page like the others, marked "launch", and can be revoked by
  hand. Revoking one ends that Claude Code's access, which is the point.

### 3. One config file per launch

- The file is `lazarus-mcp-<token id>.json` in the temp folder (the id is the 8 hex characters
  of the token), so two launches, from one IDE or two, never share a file.
- Each IDE keeps in memory which launch files are its own and rewrites only those. The saved
  `LastConfigPath` stays as a hint for finding the last file after a restart; it is no longer
  the name of a shared file.
- Launch files that belong to a removed token are deleted at start.

### 4. Two IDEs: what is supported

- **Supported:** two IDEs with their own `--pcp` (own options file, own port, own tokens, own logs).
  The launcher's files no longer collide.
- **Works, with one limit:** two IDEs on the same config folder share the options file. The second
  one runs on a fallback port for that run (ADR-004), and its launcher config carries that port.
  After a restart of **both** at once each may pick the other's `LastConfigPath`; launch tokens
  stay valid either way, but the URL in a file may be stale until the next launch. A client
  configured by hand with the stored port reaches only the IDE that holds it.
- **Not supported:** the tool-call log with two IDEs on one folder (ADR-022, unchanged).
- The README gets a short section with these three lines.

### 5. Not done

- **Revoking when the terminal closes:** an external terminal gives no signal; the idle expiry
  and the cap are the substitute.
- **Moving `mcp-active.json` into the per-launch scheme:** local helpers read it by name.
- **A mailbox between agents:** `ROADMAP.md`, ideas.

## Tests

- Pure (`McpTokens`): a launch token is created, found, expires after 7 idle days (an injectable
  clock), the fifth launch revokes the oldest, the 16-token cap ignores launch tokens, a revoked
  one gives 401.
- Pure: the config file name from a token id; the JSON carries the launch token, never the primary.
- Settings: `Launch` is saved and loaded, an old settings file loads with `Launch = False`.
- By hand (written down here as the procedure): start two IDEs with different `--pcp`, launch
  Claude from each, rebuild one, and confirm each Claude still talks to its own IDE; revoke one
  launch token and confirm only that Claude gets 401.

## Consequences

- A leaked launcher config costs one launch, and the user can revoke it.
- Two IDEs stop overwriting each other's launcher config.
- A new `Launch` flag in the token record and the settings file; old files load unchanged.
- ADR-021 decision 1 is amended for the launcher.
