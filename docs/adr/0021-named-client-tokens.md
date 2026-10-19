# ADR-021 — Named client tokens, stored as tagged hashes

**Status:** Accepted and implemented (2026-10-19)
**Date:** 2026-10-19

## Context

One bearer token guarded the server (ADR-004 decision 2: generated once, kept in
`mcpassistantoptions.xml`, reused across restarts so that `ide_rebuild` does not break
clients). That fits a server on the loopback. With a listen address other than
`127.0.0.1` (ADR-020) the token is the only gate, and it has to be handed to other machines:
a leaked one cannot be replaced without editing the settings file by hand, and replacing it
cuts off every client at once. (It has happened once already: a config with the header was
pasted into a chat.)

## Decision

1. **The primary token stays as it is, and is local.** It is what the IDE writes into
   `mcp-active.json` and the config of the Claude it launches, what `wait_for_restart.pas`
   and local helpers read from `mcpassistantoptions.xml`: it has to be readable by the IDE
   itself, so it cannot be hashed. It is never shown or copied by the options page, and a
   "Regenerate" button replaces it. ADR-004 decision 2 (no rotation across restarts) stays
   true for it.
2. **Every token that leaves the machine is a named one.** The options page has a table of
   them (name, created, last used, the last characters of the token) with Add and Revoke,
   about 16 at most. Each client gets its own, so a leaked token costs one client.
3. **A token is shown once.** Creating one opens a dialog with the token masked, an eye
   button to reveal it, a button to copy it, and a button to copy the whole MCP server config
   with the token in it; nothing goes on the clipboard until one of them is pressed. The
   settings file keeps only the hash. A lost token is revoked and a new one made. The
   "copy config" menu command no longer copies the primary token: it makes a named token
   (it asks for the name) and shows it the same way. Same model as GitLab's access tokens.
4. **Tagged hashes: `sha1:<hex>`.** The stored value says which algorithm made it, so an
   entry can be checked by its own algorithm and migrated to another one when it is next
   used, without a flag day. A request's token is hashed and compared with each stored hash
   in constant time (at most 16 entries).
5. **The hash is SHA-1, from FPC's own `sha1` unit. The reason is simple: it is in the
   current FPC, and we do not handle cryptography ourselves.** No SHA-256 exists in FPC
   3.2.2, so it is not an option until the compiler ships one, and writing or patching hash
   code is not something we do. Also:
   - It is adequate here. A token is 256 random bits, and the hash only has to keep a
     leaked options file from revealing a usable token, which needs preimage resistance.
     SHA-1's known breaks are collision attacks; a preimage still costs about 2^160 (about
     2^156 over 16 entries).
   - `sha1` is part of FPC 3.2.2's `hash` package, in use for years, and works on every
     platform the plugin builds on.
   - Nothing is vendored, so there is no licence notice to carry and no unit name that a
     later FPC could define a second time inside the IDE.
6. **Token format `lmcp_` + 43 base64url characters (32 random bytes),** so that a leaked
   token is recognisable by secret scanners. The bytes come from the operating system's
   random source (`/dev/urandom`; `BCryptGenRandom` on Windows), replacing the GUID-based
   `GenerateToken`.
7. **Revoking works at once.** The token's live sessions are dropped (their clients get 404
   and then 401) and a debug lease held by one of them is released (ADR-012). The token's name
   is the client's name in the session log, `ide_ping` and the lease messages, in place of the
   opaque session id.
8. **Existing settings need no migration:** the primary token keeps its `Server/Token`
   attribute; named tokens go in a new list in the same file.

## What we looked at and did not do

- **SHA-256.** FPC 3.2.2 has none. Trunk has `fpsha256.pp` (package `fcl-hash`, with
  `fphashutils.pp` and an x86 assembly include); we compiled it unmodified with 3.2.2 and it
  gave the right digests on the standard vectors (empty string, `abc`, the two-block 448-bit
  message, a million `a`), both in its default build and forced to its Pascal path with
  `-dSHA256PASCAL`. On x86 it uses SHA-NI only when the CPU reports it, and elsewhere it
  uses the Pascal code, so it is not x86-only. Not taken: it would be vendored code under
  FPC's package licence, and the same unit name can appear in a later FPC. **When Lazarus 5
  or FPC 3.4 ships `fpsha256`, add `sha256:` to the tag and use the library's function:**
  new tokens get it, old ones migrate when used.
- **Our own SHA-256.** Rejected: rolling one's own cryptography is a bad idea, however
  small, and "tested against the vectors" does not answer the people who say so.
- **Automatic or periodic rotation.** Rejected: it would break every client's config and the
  rebuild loop on a schedule, and it does not address the main network risk, which is the
  token travelling in plain HTTP (ADR-020: use a tunnel on untrusted networks).
- **Hashing the primary token too.** Would need a separate local credential for the IDE's
  own files and helpers; no gain for a file only the user can read.
- **Read-only tokens.** Cheap (every tool carries a `readOnlyHint`), and a natural next step
  for a viewer on another machine; left out of the first version.

## Consequences

- A lost token cannot be shown again, by design.
- A new unit for tokens (generation, hashing, lookup) and an `Authorization` check that
  accepts the primary or any live named token; the tests cover: the hash and tag, a revoked
  token getting 401, its sessions and lease going with it, and the primary token surviving a
  restart.
- ADR-004 decision 2 holds for the primary token only.
