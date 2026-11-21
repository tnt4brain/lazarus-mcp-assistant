# ADR-032 — A connection test in Options, and a port check that does not lie on Windows

**Status:** Accepted and built in 1.7.0 (2026-11-18): the "Test the connection" button and the Windows port check
**Date:** 2026-11-18

## Context

When an assistant cannot reach the server, the person has two ways to find out why: `ide_ping`
(which needs a working connection) and *Write Report* (which describes the IDE, not the
connection). The causes are always the same few: the server is not running, the client has an old
token, the client points at another port or address, a proxy answers instead. Each is a line in a
short list of checks the plugin can run against its own server.

`IsPortFree` (`McpUtils`) tests whether the port can be bound, with `SO_REUSEADDR` set. On Windows
that option lets a second socket bind a port another socket listens on, when that one set the
option too (checked 2026-11-18: a plain second bind is refused, a `SO_REUSEADDR` bind succeeds
against a `SO_REUSEADDR` listener). So the check can say "free" for a port another program holds.
The server's own listener is not affected (a second bind is refused, with or without the option),
and the existing test comment says the "occupied" direction was never tested for that reason.

## Decision

### 1. A "Test the connection" button in Options > MCP Assistant > Server

It asks the running server the questions a client asks, over HTTP on the address the clients use,
and shows one line per check, with the reason when one fails:

1. the server is running, and the URL (`http://host:port/mcp`);
2. `initialize` with the primary token is answered, with the protocol revision and a session id;
3. `tools/list` is answered: how many tools and how many bytes;
4. a wrong token is refused (401), so the token is really checked;
5. `ide_ping` through `tools/call` comes back, which proves the hand-off to the IDE's main thread.

A check that cannot run because an earlier one failed says so; nothing after an unreachable server
is attempted. The test runs on a thread of its own (the server answers on its threads, and the IDE
main thread is needed for check 5), and the result is shown when it is done. It uses the primary
token and sends it only to the server's own address, never anywhere else, and writes nothing to
disk or to any log.

The logic is a unit of its own (`McpSelfTest`), with no IDE dependency, so the test program runs
it against the live server, and against a wrong token and a closed port.

### 2. `IsPortFree` does not set `SO_REUSEADDR` on Windows

There it can only hide a busy port. On Unix it stays: it lets a port in `TIME_WAIT` count as free,
and a listening socket still blocks the bind there. The test that said "occupied cannot be tested"
now tests it: a listener, with and without `SO_REUSEADDR`, makes the port not free on every
platform.

### 3. Supported platforms in the README

The README already names Windows and Linux (Lazarus 4.6, FPC 3.2.2, GTK2 on Debian 12). The
requirements list gets the same versions, the address the server uses (`127.0.0.1`, never
`localhost`, which can resolve to `::1` first), and the tool count is corrected.

## Not done

- No check of the client's own configuration file: clients keep it in places of their own, and a
  guess would be wrong as often as right. The button shows the URL a client needs.
- No test of named tokens: they are tested by the token suites.

## Consequences

- A person with a connection problem gets the answer in one click, and an assistant helping them
  can ask for the same text.
- One more unit and one more test class; the port fix changes behaviour only where it was wrong.
