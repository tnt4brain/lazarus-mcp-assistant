# Architecture decision records

Short records of the design decisions behind the plugin: what was decided, why, and what was rejected.
Decisions are made by the maintainer; the code is written with AI assistance (see the project README, "Provenance").
ADR-007 was never assigned; no document is missing.

| # | Decision |
|---|----------|
| [0001](0001-mcp-server-transport-and-lifecycle.md) | # ADR-001 — MCP Server Transport and Lifecycle |
| [0002](0002-embedded-terminal-for-claude-code.md) | # ADR-002 — Embedded Terminal for Claude Code |
| [0003](0003-undo-redo-for-rename-identifier.md) | # ADR-003 — Undo/Redo Integration for rename_identifier |
| [0004](0004-self-hosted-development.md) | # ADR-004 — Self-Hosted Development: Token Persistence, IDE Rebuild, and Session Continuity |
| [0005](0005-fpcunit-test-suite.md) | # ADR-005 — FPCUnit Test Suite |
| [0006](0006-project-lifecycle-tools.md) | # ADR-006 — Project Lifecycle Tools |
| [0008](0008-structural-source-editing.md) | # ADR-008 — Token-Aware / Structural Source Editing |
| [0009](0009-debugger-integration.md) | # ADR-009 — Debugger Integration |
| [0010](0010-tool-naming-scheme.md) | # ADR-010 — Tool Naming Scheme |
| [0011](0011-no-ide-modals-in-mcp-sessions.md) | # ADR-011 — No IDE Modals in MCP-Driven Sessions |
| [0012](0012-multiple-clients.md) | # ADR-012 — Multiple Clients: Session Identity, Debug Session Lease, Debugger Lock |
| [0013](0013-user-consent-before-new-code.md) | # ADR-013 — User Consent Before New Code Enters the IDE |
| [0014](0014-designer-undo.md) | # ADR-014 — Designer Undo |
| [0015](0015-packages-and-bare-programs-addressed-per-call.md) | # ADR-015 — Packages and Bare Programs: Addressed Per Call, No "Active" State |
| [0016](0016-running-without-the-debugger.md) | # ADR-016 — Running a Program Without the Debugger: Output, Exit Code, Later Attach |
| [0017](0017-declaration-lookup-through-uses-clauses.md) | # ADR-017 — Declaration Lookup Through Uses Clauses, and Reference Search Scopes |
| [0018](0018-https-for-package-download-via-curl.md) | # ADR-018 — HTTPS for package_download through the curl executable |
| [0019](0019-debug-attach-without-the-ide-dialog.md) | # ADR-019 — debug_attach: the IDE's attach path without its dialog |
| [0020](0020-listen-address-is-a-setting.md) | # ADR-020 — The listen address is a setting, the loopback is the default |
| [0021](0021-named-client-tokens.md) | # ADR-021 — Named client tokens, stored as tagged hashes |
| [0022](0022-tool-call-log.md) | # ADR-022 — A tool-call log (`mcp-tools.log`) as evidence for bug reports |
| [0023](0023-windows-terminal-choice.md) | # ADR-023 — The terminal Claude Code starts in on Windows is a setting |
| [0024](0024-show-markdown-tool.md) | # ADR-024 — `ide_show_markdown`: show a Markdown document to the user in an IDE window |
| [0025](0025-disk-conflict-review-window.md) | # ADR-025 — A review window for files changed on disk while the editor has unsaved changes |
| [0026](0026-rebuild-sequence.md) | # ADR-026 — The IDE rebuild checks first and recovers from a failed build |
| [0027](0027-navigation-and-refactoring-tools.md) | # ADR-027 — Navigation and refactoring beyond references and rename |
| [0028](0028-git-remote-and-history-tools.md) | # ADR-028 — Git tools for remotes and for history: consent on the network, safety nets on rewriting, nothing left to git's defaults |
| [0029](0029-tool-list-diet.md) | # ADR-029 — A smaller `tools/list`: say the same in fewer bytes, change no call |
| [0030](0030-markdown-code-highlighting.md) | # ADR-030 — Highlighted code in the Markdown viewer, in the colours of the user's editor |
| [0031](0031-tool-retirement-and-rename-layer.md) | # ADR-031 — Renaming, fusing and retiring tools: old names keep working through the major version |
| [0032](0032-connection-test-and-port-check.md) | # ADR-032 — A connection test in Options, and a port check that does not lie on Windows |
| [0033](0033-launch-tokens-and-two-ides.md) | # ADR-033 — A config file and a token of its own for every launch, and two IDEs side by side |
| [0034](0034-write-scope-audit.md) | # ADR-034 — Write-scope audit: what every tool may change, and the gaps found |
