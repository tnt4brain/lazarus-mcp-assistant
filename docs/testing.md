# Testing

The test project of the Lazarus MCP Assistant. A short version is in the [README](../README.md).

A standalone FPCUnit test project lives in `tests/`. Plugin units without IDE dependencies (utilities, launcher, settings file) are tested in-process. Everything else is tested over HTTP against the running IDE. The `ide_run_tests` tool builds and runs it, or by hand:

```
lazbuild tests/mcpserver_tests.lpi
tests/mcpserver_tests.exe --all --format=plain
```

**Suites:**

| Suite | Count | Requires |
|---|---|---|
| `TTestUtils` | 11 | Nothing (always runs) |
| `TTestJUnitWriter` | 8 | Nothing (always runs) |
| `TTestLauncher` | 10 | Nothing (always runs): sh quoting, launch script, terminal choice |
| `TTestSettingsFile` | 3 | Nothing (always runs): settings save/load, obsolete keys removed |
| `TTestProtocol` | 12 | MCP server reachable: JSON-RPC, `initialize` (version negotiation, instructions) |
| `TTestAuth` | 7 | MCP server reachable |
| `TTestProjectTools` | 15 | MCP server reachable: project tool schemas, `project_clean`, dialog tools, `project_list_directory` on a temp folder |
| `TTestGitWrite` | 16 | MCP server reachable: `git_checkout`/`reset`/`stash`/`commit` (amend)/`branch_delete`/`cherry_pick`/`archive`/`init` on temp repositories |
| `TTestDialogHooks` | 2 | Only with `MCP_TEST_HOOKS=1` set for the IDE and the test run: opens a real native dialog through a test-only hook and answers it with `ide_answer_dialog` |
| `TTestSession` | 8 | MCP server reachable: session id, cookie, anonymous, `DELETE /mcp`, 404 for unknown session ids |
| `TTestToolSmoke` | 22 | MCP server reachable: one call per tool group, on `tests/fixtures/` and temp files; `editor_replace_range`; a file deleted and created again outside the IDE |
| `TTestPackageEdit` | 6 | MCP server reachable: package editing on `tests/fixtures/fixturepkg/` (changed and changed back); `package_download` refusing an unknown package (no network) |
| `TTestPackageManage` | 5 | MCP server reachable: `package_create`/`get_settings`/`set_settings`/`compile` (IDE and lazbuild) on a package written to a temp directory, `project_list_files`/`project_search` scoped to it |
| `TTestFormUndo` | 11 | MCP server reachable: `form_history` and what the `form_*` tools record, on a temp copy of the fixture form |
| `TTestCodeComplete` | 8 | MCP server reachable: `code_complete` on a temp copy of `tests/fixtures/fixturecomplete.pas` (classes, locals, forward procedures, unsaved edits, a 600-method class, an include file created later) |
| `TTestCodeFormat` | 7 | MCP server reachable: `code_format` on temp files (whole file, line range, parse errors, include files, trailing lines) |
| `TTestCodeRename` | 5 | MCP server reachable: `code_rename_identifier` on two temp units (dry run, rename into unsaved editors, unsaved edits, `auto_save`, refusals) |
| `TTestCodeNav` | 11 | MCP server reachable: descendants, overrides, unit uses, unused symbols, extract method (dry run, real, bad name), move unit (plan, cycle refusal) on small temp units |
| `TTestConsent` | 2 | MCP server reachable, installs not allowed: `package_install` of a new package is refused; `ide_rebuild` refuses `lpk_path` |
| `TTestDebugger` | 13 | Opt-in: `MCP_DEBUG_TESTS=1`, or `tests/debuggee/mcpdebuggee.lpi` open in the IDE. Breakpoint/step/evaluate, exception without a dialog, lease refusal, debugger lock, lease expiry; conditions, pass counts, data and symbol breakpoints, frames, threads, registers and disassembly (about 40 s) |

The runner detects the running server by reading `mcpassistantoptions.xml` and pinging it. It looks in `%LOCALAPPDATA%\lazarus` on Windows and `~/.lazarus` elsewhere; set `MCP_OPTIONS_FILE` if Lazarus runs with `--pcp`. If the server is not up, the suites that need it are skipped. With `MCP_DEBUG_TESTS=1` the debugger suite opens the debuggee project itself and reopens yours afterwards; it stops with an error instead if your project or an editor has unsaved changes.

Architecture details: [ADR-005](adr/0005-fpcunit-test-suite.md).
