# ADR-018 — HTTPS for package_download through the curl executable

**Status:** Accepted and implemented (v1.0; checked against the code 2026-11-18: `curl -fsSL --max-time 120 --connect-timeout 15` in `McpToolsPackages.pas`, transport `https (curl)`). Not in the automated suite, as the ADR says: it needs the network
**Date:** 2026-10-18

## Context

`package_download` (ADR-013) fetched archives with FPC's `TFPHTTPClient`. Its HTTPS needs
OpenSSL DLLs, which the IDE on Windows usually lacks, so it fell back to plain HTTP and
relied on the catalog's MD5 alone (both come unencrypted).

## Decision

1. **Order of attempts:** in-process HTTPS; if that fails for want of OpenSSL, the `curl`
   executable; if that fails too, plain HTTP as before.
2. **curl, not a library.** Windows 10 (1803) and later ship `curl.exe` in `System32`. It
   links only system DLLs (`SspiCli`, `CRYPT32`, `bcrypt`, `WS2_32`): libcurl is built in,
   TLS is SChannel with the system certificate store, and no file has to be shipped.
   macOS and most Linux systems have `curl` on the PATH. `libcurl.dll` is not part of
   Windows, so loading the library would mean shipping it.
3. **Invocation:** `curl -fsSL --connect-timeout 15 --max-time 120 -o <temp> <url>`
   through `TProcess` without a console; the temp file is read into the stream and
   deleted. Errors come from curl's stderr.
4. **Reporting:** `transport` is `https (curl)`; the consent dialog (ADR-013) treats any
   `https…` transport as HTTPS. The "unencrypted" note appears only for plain HTTP.
5. The MD5 and archive checks are unchanged; HTTPS adds integrity in transit, not a
   new trust root.

## Alternatives considered

- **WinHTTP directly:** also SChannel, but Windows-only code to write and maintain.
- **libcurl through FPC's `libcurl` unit:** same behaviour as the executable, plus a DLL
  to ship on Windows.
- **Shipping OpenSSL DLLs:** bitness must match the IDE, and they need updates.
- **Not falling back to HTTP at all:** safer, but breaks downloads on a machine with
  neither OpenSSL nor curl.

## Consequences

- A system without OpenSSL and without curl still falls back to HTTP, with the note.
- Verified with `Lists` (1.9 KB): `transport: https (curl)`, MD5 verified.
- Not in the automated suite: it needs network access.

## Amendment 1 (1.8.1): no plain-HTTP fallback

The last step of decision 1 is removed. `package_download` now tries in-process HTTPS, then
curl, and if both fail it refuses with a message (install the OpenSSL DLLs or curl, or use the
IDE's Online Package Manager). Nothing is fetched over plain `http://`.

Why: `packages.lazarus-ide.org` answers HTTPS with a valid certificate (checked 2026-11-22:
`packagelist.json` and `Abbrevia.zip`, whose MD5 equals the catalog's `RepositoryFileHash`), so the
fallback only helped an attacker on the network: archive and catalog hash both came unencrypted
and could be swapped together. The cost is a refused download on a machine with neither OpenSSL
nor curl; Windows 10 (1803) and later ship `curl.exe`.

The `transport_note` for plain HTTP is gone from the result. The consent dialog still shows
"HTTP (unencrypted)" for a marker file written by an older version.
