# Lazarus MCP Assistant

An in-process MCP server for the [Lazarus IDE](https://www.lazarus-ide.org/). Installs as a standard Lazarus package and exposes 154 IDE tools over HTTP so any [MCP](https://modelcontextprotocol.io/)-capable AI assistant can read, edit, navigate, build, and inspect your project — without leaving the IDE.

> **Platform:** Windows and Linux. The whole test suite, the debugger tests
> included, passes on the combinations below (FPC 3.2.2).
>
> | Lazarus | Windows 11 | Debian 12 |
> |---|---|---|
> | **4.6** (the reference version) | passes | GTK2: passes |
> | **4.8** (the `lazarus_4_8` tag, stable) | passes | GTK2: passes |
> | **5.0RC1** (the `lazarus_5_0_RC1` tag) | passes | GTK3: passes (GTK2 is not usable with 5.0RC1 here) |
>
> **Not supported:** Lazarus trunk (4.99). It is known not to compile: the editor and
> project interfaces differ. Known differences on 5.0RC1: [#29](https://github.com/tnt4brain/lazarus-mcp-assistant/issues/29).
>
> macOS is not tested and not claimed: the plugin uses only LCL/IDE interfaces
> (no Win32 API) and has macOS code for launching Claude Code in Terminal.app,
> but it has never been compiled or run there.

---

## Why in-process HTTP?

Most MCP servers are stdio subprocesses: the AI client spawns them, reads their output on stdout, and they die when the session ends. That model does not work for an IDE plugin — a plugin lives inside the IDE process and cannot be spawned from the outside.

Running as an HTTP server inverts the ownership: the IDE starts the server; the AI client connects to it. This enables:

- **Self-hosted development** — you can use Claude Code to develop this plugin from inside the Lazarus IDE it is running in. Claude edits the source, rebuilds the IDE, and resumes the same session after restart. See [Self-hosted development](#self-hosted-development).
- **Multiple simultaneous clients** — any number of AI sessions can connect to the same running IDE instance. One session can work on the plugin while another works on a project built with it.
- **Session persistence** — the server stays running between AI sessions. No re-spawn, no re-configuration. Reconnect at any time.

Transport details: [ADR-001](docs/adr/0001-mcp-server-transport-and-lifecycle.md).

---

## Tool reference

154 tools, named `<category>_<action>` (in Claude Code: `mcp__lazarus-ide__<tool_name>`). Each has a title, a description
and annotations: `readOnlyHint`, `destructiveHint` (only for changes that neither Ctrl+Z nor `form_history` can take back),
`idempotentHint`. The full reference, with every tool, is in [docs/tools.md](docs/tools.md).

| Category | What it does |
|---|---|
| `editor_*` | Read, open, create, edit and save files; edits go through the editor buffer, so Ctrl+Z works |
| `code_*` | CodeTools: outline, declarations, references, rename, extract method, completion, formatting, structural edits |
| `form_*` | The form designer: components, properties, menus, collections, layout, undo |
| `debug_*` | Breakpoints, run and step, locals, evaluate, call stack, registers, attach |
| `project_*` | Build, run, create and open projects, settings, files, search, todos |
| `package_*` | Create, open, compile, install and edit packages and their dependencies |
| `ide_*` | Ping, rebuild the IDE, messages, dialogs, tests, reports |
| `git_*` | Status, diff, commit, branches, history, remotes, conflicts |

Files created or changed outside the IDE are seen at once. Some tools were renamed in 1.7.0; the old names work
through all of 1.x and are refused from 2.0 on: [docs/renamed-tools.md](docs/renamed-tools.md).

---

## What the tools may change

A tool changes a file only inside the open project's folder, the folder of a loaded package that is not part of
Lazarus, the git working tree holding either, and the temp folder; never inside a `.git` folder or the IDE's
settings folder. *Limited mode* (**Tools > Options > MCP Assistant > Directories**, off by default) narrows reads and
the opening of projects to folders you list. Details, and what the limits do not do:
[docs/write-scope.md](docs/write-scope.md).

---

## Requirements

- **Lazarus IDE** 4.6, 4.8 or 5.0RC1 (see the table at the top; trunk is not supported); macOS is not tested
- **Free Pascal Compiler** 3.2.2 (bundled with Lazarus)
- **Claude Code** (or any MCP client that supports Streamable HTTP transport)

Package dependencies — all bundled with Lazarus: `SynEdit`, `IDEIntf`, `FCL`,
`CodeTools`, and `jcfbase` (JEDI Code Format, for `code_format`). JCF's IDE
plugin, `jcfidelazarus`, is optional; when it is installed, `code_format` uses
its settings.

---

## Installation

1. In Lazarus: **Package → Open Package File (.lpk)** → select `src/lazmcpassistant.lpk`.
2. In the package dialog: **Use → Install**.
3. Lazarus will ask to rebuild the IDE. Confirm. The IDE restarts with the plugin loaded.

---

## Usage

1. In the IDE: **Tools → MCP Assistant → Launch MCP Assistant**.
   - This starts the HTTP server on a random local port and opens Claude Code in a terminal window.
   - Windows opens a new console. Linux opens the first terminal it finds: `x-terminal-emulator`, `gnome-terminal`, `konsole`, `xfce4-terminal` or `xterm`. macOS opens Terminal.app.
   - The MCP config file is written to a stable path in your system temp directory and reused on subsequent launches.

2. Claude Code starts pre-configured with the server URL and bearer token. No manual `--mcp-config` flag needed for subsequent sessions — the config path is persisted in `mcpassistantoptions.xml`.

3. Tools are available as `mcp__lazarus-ide__<tool_name>` in Claude Code.

### Options

**Tools → Options → MCP Assistant** (also **Tools → MCP Assistant → Options...**):

| Setting | Empty means |
|---|---|
| Claude Code executable | `claude` on `PATH` |
| Working directory | The open project's directory |
| Extra command-line options | None |
| Terminal command (Linux/macOS), e.g. `kitty -e` | Detect a terminal |
| git executable | `git` on `PATH` |
| Listen address (IPv4) | `127.0.0.1`: this machine only. `0.0.0.0` or a machine address lets other machines connect over plain HTTP with the token: see [ADR-020](docs/adr/0020-listen-address-is-a-setting.md) |
| *Test the connection* | A button under the listen address: asks the running server what a client asks (the token, `tools/list`, a wrong token, a call into the IDE) and shows one line per check with the reason when one fails ([ADR-032](docs/adr/0032-connection-test-and-port-check.md)). The server listens on a numeric address (`127.0.0.1`), never `localhost`, which can resolve to `::1` first |
| Client tokens | One named token per client on another machine: **Add token...** shows it once, masked, with an eye button and buttons to copy the token or the whole client config; only a hash is stored, so a lost token is revoked and replaced. **Revoke** cuts a client off at once and ends its sessions. The primary token (what the IDE writes for clients on this machine) is never shown; **Regenerate primary token...** replaces it. See [ADR-021](docs/adr/0021-named-client-tokens.md) |
| Allow assistants to install packages | Off; see [ADR-013](docs/adr/0013-user-consent-before-new-code.md) |
| Logging: tool-call log | Off. One `begin` and one `end` line per tool call (tool, caller, time, outcome, argument names and a hash of them; no argument values or results) in `mcp-tools.log`, rotated at 4 MB. See [ADR-022](docs/adr/0022-tool-call-log.md) |
| Logging: log file | Empty: `mcp-tools.log` in the Lazarus config folder. Any other path moves the file |
| Logging: Messages window | Off. One line per finished tool call (name, duration, and the cut error text of a failed call) in the **MCP Server** view |

Settings are stored in `mcpassistantoptions.xml` in the IDE's primary config
directory, together with the server's token and port.

---

## Self-hosted development

This plugin was built using itself: Claude edits the source through the tools, calls `ide_rebuild`, and carries on
in the rebuilt IDE with the same token and port. The loop, why it survives a restart and the boot-loop escape hatch:
[docs/self-hosted-development.md](docs/self-hosted-development.md). Design: [ADR-004](docs/adr/0004-self-hosted-development.md).

---

## Knowledge injection

Every MCP client gets `docs/system-prompt.md` as the server's `instructions` in the `initialize` reply, which clients add to the model's context (Claude Code puts it into the system prompt), so Claude launched from the IDE needs no `--append-system-prompt`. This short text covers workflows, tool preferences and the rules Claude must follow (package-install consent, debugger exceptions, rebuild/reconnect). It leaves per-tool details to the tool descriptions.

The Lazarus/FPC reference covers LCL component packages, installation patterns and common gotchas, so Claude doesn't hallucinate package names or import paths. It is served on demand as the `lazarus-ide://reference` MCP resource, and the system prompt tells Claude to read it before answering such questions.

To update the reference: edit `docs/lazarus-knowledge.md`, then run `tools/gen_knowledge_inc.exe` from the project root to regenerate `src/lazarus_knowledge.inc` and `src/system_prompt.inc` (build it once with `fpc -MObjFPC -Scghi -FEtools tools/gen_knowledge_inc.pas`), then rebuild the IDE. The same applies to `docs/system-prompt.md`.

---

## Testing

A standalone FPCUnit project lives in `tests/`: `lazbuild tests/mcpserver_tests.lpi`, then
`tests/mcpserver_tests --all --format=plain`, or the `ide_run_tests` tool. Units without IDE dependencies are tested
in-process; everything else over HTTP against the running IDE. Suites, requirements and options:
[docs/testing.md](docs/testing.md).

---

## Architecture

The design decisions are recorded as ADRs; [docs/adr/](docs/adr/README.md) lists them with one line each.

---

## Documentation

- [docs/tools.md](docs/tools.md): every tool
- [docs/write-scope.md](docs/write-scope.md): where the tools may write, limited mode
- [docs/renamed-tools.md](docs/renamed-tools.md): tools renamed in 1.7.0
- [docs/testing.md](docs/testing.md): the test suites
- [docs/self-hosted-development.md](docs/self-hosted-development.md): developing the plugin with itself
- [docs/adr/](docs/adr/README.md): design decisions
- [docs/system-prompt.md](docs/system-prompt.md) and [docs/lazarus-knowledge.md](docs/lazarus-knowledge.md): what every client is told

---

## Help wanted

- **macOS builds.** The code for launching Claude Code in Terminal.app exists but has never been compiled or run on macOS. This waits for someone who has a Mac and wants to build and test it; contributions are welcome.

---

## Provenance
Designed and directed by Sergei Pechenko: the requirements, design decisions (recorded as ADRs in [`docs/adr/`](docs/adr/)), reviews and acceptance. Most of the code, tests and docs were written by Claude (Anthropic) from his prompts and decisions, and checked by the test suite and by using the tools inside the IDE they extend. Because the code is largely AI-generated, no warranty of originality is given beyond the license's disclaimer.

## License

BSD-3-Clause — see `LICENSE`.
