# ADR-005 — FPCUnit Test Suite

**Status:** Decided  
**Date:** 2026-10-05

## Context

The server has no automated tests.  All correctness verification today is
manual: call a tool via curl, watch the response, rebuild the IDE, confirm the
new tool appears.  This is fine for one-person development but breaks down
before a community release: contributors cannot tell whether a change broke
something without running the IDE by hand.

The plugin runs inside the Lazarus process.  This creates a hard testability
boundary.  Every handler in `SyncCallTool` calls IDE singletons
(`LazarusIDE`, `PackageEditingInterface`, `SourceEditorManagerIntf`, …) that
only exist inside a live Lazarus process and are not mockable at a reasonable
cost — their interfaces span thousands of lines across a dozen files.

There are four ways to test the server:

| Option | What it covers | Cost |
|--------|---------------|------|
| A — Mock `TLazIDEInterface` | Full SyncCallTool | Enormous; interface surface is too large |
| B — In-process test runner as a second plugin | Full SyncCallTool | Requires a second installed package; fragile bootstrapping |
| C — Black-box HTTP against a running IDE | Full tool pipeline | Requires the IDE to be running; can't run in CI |
| D — Standalone FPCUnit for the protocol/HTTP layer | JSON-RPC, auth, utilities | Zero IDE dependency; runs anywhere FPC is installed |

The protocol and auth code is the hardest to get right silently: a wrong
Content-Type header, a missing `jsonrpc` field, or an off-by-one in the
response ID will break every MCP client and produce no IDE-visible error.
Option D covers exactly those bugs.

## Decision

Implement a **standalone FPCUnit test project** under `tests/` that covers the
HTTP/JSON-RPC protocol layer and utility functions.  IDE-coupled handler logic
is explicitly out of scope for automated testing; the self-hosted development
loop (ADR-004) serves as its integration test.

Add a `run_tests` MCP tool so Claude can trigger test runs without needing
shell access — the same way `build_project` and `compile_plugin` expose build
operations.

### Test project layout

```
tests/
  mcpserver_tests.lpi      — standalone FPC/Lazarus project (no IDE runtime dep)
  mcpserver_tests.lpr      — program entry point: server discovery, suite
                             registration, TTestRunner invocation
  thttphelper.pas          — shared HTTP helpers and GServerPort/GServerToken globals
  tprotocol.pas            — TTestProtocol: JSON-RPC 2.0 compliance (10 tests)
  tauth.pas                — TTestAuth: Bearer token gating (7 tests)
  tutils.pas               — TTestUtils: GenerateToken, FindFreePort, IsPortFree,
                             Swap16 (7 tests)
  tjunitwriter.pas         — TJUnitResultsWriter: ITestListener that emits JUnit XML
  ttestinfra.pas           — TTestJUnitWriter: FPCUnit tests for the JUnit writer
                             itself (Uroboros)
src/
  McpUtils.pas             — pure utility functions extracted from mcpideserver.pas
                             (no IDE imports); used by both the plugin and the test project
```

`McpUtils.pas` is the extraction boundary: it depends only on `SysUtils` and
`Sockets`, so `tests/mcpserver_tests.lpi` can compile it via
`OtherUnitFiles="../src"` without pulling in `LazIDEIntf` or `PackageIntf`.

### Suite registration and server detection

`TTestUtils` is always registered (via `initialization` in `tutils.pas`).

`TTestProtocol` and `TTestAuth` are registered conditionally: the program
entry point reads `%LOCALAPPDATA%\lazarus\mcpassistantoptions.xml` for the
port and token, pings the server, and registers those suites only when the
server responds.  If the IDE is not running the utility tests still execute.

### What the suites cover

**TTestProtocol** (10 tests) — JSON-RPC 2.0 protocol compliance:
- `ping` returns `{"status":"ok"}` with `id` echoed
- `initialize` returns `protocolVersion` and `serverInfo`
- `tools/list` returns an array; every tool has `name`, `description`,
  `inputSchema`
- FR-004 package management tools present in `tools/list`
- Unknown method → error code −32601
- Malformed JSON body → 200 or 400 with error code −32700
- Response `id` echoes numeric and string request IDs exactly
- JSON-RPC notification (no `id`) → HTTP 202 with no body

**TTestAuth** (7 tests) — bearer token gating:
- Valid token → 200
- Wrong token → 401
- Missing `Authorization` header → 401
- GET /mcp → 405
- Wrong path → 404
- `Origin` header present → 403 (DNS-rebinding guard)
- Server token does not appear in any response body

**TTestUtils** (7 tests) — pure utility functions:
- `GenerateToken` produces exactly 64 hex characters
- Two consecutive calls produce distinct values
- `FindFreePort` returns a non-zero port that `IsPortFree` confirms is usable
- `IsPortFree` returns `True` for a port freed after a socket closes
- `Swap16` round-trip and single byte-swap

### Platform notes

On Windows, `SO_REUSEADDR` allows binding to an already-bound port; a
`IsPortFree` call with `SO_REUSEADDR` will return `True` even for a port in
LISTEN state.  The suite therefore tests only the freed direction (close socket
→ port must be free); the occupied direction would require `SO_EXCLUSIVEADDRUSE`
and is intentionally untested.

### How to run

```
lazbuild tests/mcpserver_tests.lpi
tests/mcpserver_tests.exe --all --format=plain
```

(Plain `fpc -Fu../src` worked until the tests started using LazUtils; see
the update below.)  Or via Lazarus: open `tests/mcpserver_tests.lpi` and run.  No plugin
installation needed.  The binary exits with code 0 on pass, non-zero on
failure.

### `run_tests` MCP tool

The tool allows Claude to trigger a test run from inside a conversation without
needing shell access — the same pattern as `build_project` and `compile_plugin`.

**Inputs:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `test_project` | string | `tests/mcpserver_tests.lpi` (relative to project dir) | Path to the `.lpi` or `.lpr` to compile and run |

**Behaviour:**

1. Compile the test project with `lazbuild <lpi>` (reuses the existing build
   cache; no clean needed on each run).
2. Execute the resulting binary.
3. Parse stdout for the FPCUnit plain-text summary line
   (`N:<n> E:<e> F:<f> I:<i>`).
4. Return a structured result:

```json
{
  "compiled": true,
  "run": true,
  "total": 24,
  "errors": 0,
  "failures": 0,
  "ignored": 0,
  "passed": true,
  "output": "<full stdout>"
}
```

If compilation fails, `compiled` is `false`, `run` is `false`, and `output`
contains the compiler error lines.

**Why not `fpc` directly?** `lazbuild` resolves package paths the same way the
IDE does, so the test project always finds `McpUtils` via the search path
declared in the `.lpi`.  A raw `fpc` invocation requires spelling out `-Fu`
flags manually.

### JUnit XML output

FPCUnit's built-in output formats (`fPlain`, `fXML`, `fLatex`, `fHtml`) are
not JUnit-compatible.  The `fXML` format uses FPCUnit's own schema
(`<TestResults><TestSuite><Test Result="OK"/>`); it is not the
`<testsuites><testsuite><testcase>` schema that GitHub Actions, Jenkins,
GitLab CI, and `pytest --junitxml` consumers all expect.

**Decision:** implement `TJUnitResultsWriter` in `tests/tjunitwriter.pas` as
an `ITestListener` that writes JUnit XML to a `TStream`.  The test runner
attaches it to a `TTestResult` alongside the normal console writer.

Output schema:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="MCP Server Tests" tests="24" errors="0" failures="0" time="0.387">
  <testsuite name="TTestUtils" tests="7" errors="0" failures="0" time="0.001">
    <testcase name="TestGenerateTokenIs64Chars" classname="TTestUtils" time="0.000"/>
    <testcase name="TestIsPortFreeForBoundPort" classname="TTestUtils" time="0.001">
      <failure message="Port must be free">stack trace here</failure>
    </testcase>
  </testsuite>
</testsuites>
```

`run_tests` gains an optional `junit_out` parameter (path for the XML file).
When supplied, the tool writes the file before returning the JSON result.

**Self-testing (Uroboros):** `TJUnitResultsWriter` is tested by a dedicated
suite `TTestJUnitWriter` in `tests/ttestinfra.pas`.  It constructs minimal
synthetic `TTestCase` subclasses with known pass/fail outcomes, runs them
through the writer against a `TStringStream`, and asserts the XML structure
with string matching — FPCUnit tests verifying the FPCUnit infrastructure.

`ttestinfra.pas` is always registered (like `tutils.pas`); it needs no running
server.

### What is out of scope

- Testing `SyncCallTool` handlers — they require a live IDE singleton.
  Coverage comes from the self-hosted dev loop: call the tool via the running
  server, observe the result.
- Mocking `TLazIDEInterface` — surface is too large; cost exceeds benefit.
- In-IDE test runner — adds a second installed package with no gain over
  manual tool-call testing.

## Consequences

- `tests/` directory in the repository root; the test project is a normal
  `.lpi` that contributors can open without installing the plugin.
- `McpUtils.pas` is the extraction boundary between testable and IDE-coupled
  code; new utility functions should go there, not into `mcpideserver.pas`.
- `run_tests` closes the last gap in the self-hosted loop: Claude can verify
  protocol correctness within the same session that modifies server code.
- JUnit XML output makes the suite consumable by GitHub Actions, Jenkins, and
  any CI tool that reads `junit.xml`; no post-processing step required.
- `TTestJUnitWriter` provides regression coverage for the writer itself — the
  infrastructure is tested by the infrastructure it tests.
- Passing tests are a necessary but not sufficient condition for a correct
  plugin: IDE-level behaviour is still verified by hand or by the self-hosted
  loop.

## Update (2026-10-14): more extraction, and option C after all

The suite grew from 38 tests (after `TTestProjectTools`, ADR-006) to 73
(68 without the opt-in debugger suite), in two directions.

**More code behind the extraction boundary.** Besides `McpUtils`, two more
plugin units have no IDE imports, so the test program links them:

- `McpLauncher`: the Linux/macOS launch path is plain string code.
  `TTestLauncher` (`tlauncher.pas`, 10 tests) covers sh quoting, the launch
  script and the choice of terminal.
- `McpSettingsFile`: the settings class moved here out of `McpIdeState`, which
  now only passes it the file name. `TTestSettingsFile` (`tsettings.pas`,
  3 tests) covers save/load and the removal of obsolete keys. It uses
  `Laz2_XMLCfg`, so the test project requires the LazUtils package and is
  built with `lazbuild`.

Both suites always run.

**Option C for tool handlers.** "Can't run in CI" still holds, but the
suites are skipped when no server answers, and `ide_run_tests` runs them in
the self-hosted loop anyway. So read-only tool calls are now tested over HTTP:

- `TTestSession` (`tsession.pas`, 7 tests): ADR-012 identity: the
  `Mcp-Session-Id` from `initialize`, the `mcp_session` cookie, header over
  cookie, anonymous callers being offered a cookie, `DELETE /mcp`.
- `TTestToolSmoke` (`ttoolsmoke.pas`, 7 tests): one read-only call per tool
  group (editor, CodeTools, forms, git, project, debugger) against the
  fixture unit and form in `tests/fixtures/`. The form test opens the
  fixture in the designer and closes it again. The git and project tests are
  ignored, not failed, without a git checkout or an open project.

The tool tests found a bug on their first run. `form_*` tools failed for
`D:/...` paths because the open editor's `D:\...` didn't match
(fixed in bfd3f26).

### The consent and debugger suites

- `TTestConsent` (`tconsent.pas`, 2 tests): with installs not allowed,
  `package_install` and `ide_rebuild` with a new package are refused, and the
  IDE stays up. The tests never change the setting and never see the consent
  dialog: they are ignored when installs are allowed, and the `.lpk` path
  doesn't exist, so even then the request would stop at "not found".
- `TTestDebugger` (`tdebugger.pas`, 5 tests), **opt-in**: breakpoint, step
  and evaluate; an exception coming back without a dialog (ADR-011); a second
  client refused while the first owns the session, but able to read it; the
  debugger lock (`debug_get_state` answers during a blocking `debug_run`,
  `debug_evaluate` waits for it); a 10 s lease expiring and stopping the
  session (ADR-012). Two clients are simulated with two `Mcp-Session-Id`
  values. v0.9 added 7 more (12 now): conditions, pass counts, run-to-line on
  an existing breakpoint, data and symbol breakpoints, frames, threads (ADR-009).
  Teardown removes every watch and every breakpoint `debug_list_breakpoints` shows, whatever
  its kind.

The debugger suite debugs `tests/debuggee/mcpdebuggee.lpr`, a console program
(no message box waits for a click after its exception). The tests find their
lines by `MARK:` comments. Lazarus only debugs the active project, so the
suite runs only when asked to:

- **`MCP_DEBUG_TESTS=1`:** a `TTestSetup` decorator opens the debuggee with
  `project_open` and reopens the previous project afterwards. Setting a
  breakpoint marks a project modified, and `project_open` won't leave a
  modified project. So after removing the breakpoints, teardown saves the
  fixture (unchanged on disk) before switching back. If the user's project or
  an editor has unsaved changes, the suite fails at setup instead.
- **Or the debuggee is already the active project:** the suite runs, for
  example from `ide_run_tests`, and leaves the project as it is.

It takes about 35 s, most of it the lease expiry. Run twice in a row, all
tests passed both times (73 then; 84 with the v0.9 tests).

Still not tested automatically: answering the exception dialog of a session
the user started (that dialog only appears in user-driven sessions), and the
consent dialog itself, which only the user may answer.
