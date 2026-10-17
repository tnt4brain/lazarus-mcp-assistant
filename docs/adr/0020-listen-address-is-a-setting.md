# ADR-020 — The listen address is a setting, the loopback is the default

**Status:** Accepted (v1.0)  
**Date:** 2026-10-17

## Context

The server listened on `127.0.0.1` only, written into the code in several places (the
listening socket, the probe for a free port, the dummy connection that unblocks `accept`,
the URLs in the discovery file, the copied config and the messages). That is the right
default: the tools edit files, run programs, drive a debugger and can install packages. But
an assistant on another machine (a VM, a container, a laptop next to the IDE's workstation)
could not reach it without a tunnel.

## Decision

1. **`Server/ListenAddress` in `mcpassistantoptions.xml`, shown on Tools > Options > MCP
   Assistant > Server.** Default `127.0.0.1`. A value that is not a dotted IPv4 address
   (`McpValidListenAddress`) is not saved by the dialog and means `127.0.0.1` when read
   from the file. IPv4 only, because `fphttpserver` binds an `AF_INET` socket; no host
   names, so nothing is resolved behind the user's back.
2. **`0.0.0.0` means every interface.** Clients on this machine still reach it through the
   loopback, so what is written for a local client (`mcp-active.json`, the launched
   Claude's config) uses `McpClientHost`: the address itself, or `127.0.0.1` for
   `0.0.0.0`. The config copied to the clipboard is for pasting into a client that may be
   elsewhere: for `0.0.0.0` it holds this machine's address on the network
   (`McpPrimaryAddress`, the local end of a datagram socket "connected" to a documentation
   address, which sends nothing), and the loopback when there is none. With several
   network cards the guess may be the wrong one: the host in the pasted URL can be edited.
3. **The dialog warns, the IDE says so at start.** For an address outside `127.0.0.0/8` the
   options page shows that others can connect, that the token lets them edit files and
   run programs, and that the connection is not encrypted (plain HTTP, bearer token);
   the messages window repeats it each time the server starts that way. Nothing else
   changes for such a server: the token, the `Origin` refusal and the debug lease (ADR-012)
   apply as before. The `package_install` consent (ADR-013) still goes to the dialog on
   the IDE's own screen, never to a remote client.
4. **A change restarts the server.** OK in the options page calls `FinalizeMcpServer` and
   `InitializeMcpServer` when the address changed; clients get the 404 for their old
   session and initialize again (ADR-012), like after `ide_rebuild`.
5. **An address that cannot be bound falls back to `127.0.0.1`,** with a message, instead
   of leaving no server. The port is kept when it is free there.

## Alternatives considered

- **TLS:** the right answer for an open network, but the in-process OpenSSL is the thing
  ADR-018 found missing on Windows. Left to a tunnel (`ssh -L`) or a reverse proxy.
- **A second token or an allow-list of client addresses:** more to configure for a case that
  is the user's explicit choice; the token is already 256 bits and required.
- **Listening on every interface when the setting is empty:** unsafe by default.
- **IPv6 and host names:** wait until `fphttpserver` can bind them.

## Consequences

- The default behaviour and the tests are unchanged; `McpUtils` takes the address as a
  parameter (`FindFreePort`, `IsPortFree`) with the loopback as its default.
- Anyone who sets a non-loopback address accepts that the token travels in clear text on
  that network.
