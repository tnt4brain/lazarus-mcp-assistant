# ADR-002 — Embedded Terminal for Claude Code

**Status:** Decided — deferred to v1.x  
**Date:** 2026-10-02

## Context

Claude Code runs as a subprocess launched via `TProcess` with `poNewConsole`,
opening in a separate Windows console window.  The ideal UX is a docked
terminal panel inside the Lazarus IDE so Claude Code's session is visible
alongside the editor without alt-tabbing.

## Options considered

### A — ConPTY + custom ANSI renderer (pure Pascal)

Declare `CreatePseudoConsole` / `InitializeProcThreadAttributeList` manually
from `kernel32.dll` (FPC 3.2.2 has no built-in bindings).  Read raw output
through a pipe, parse ANSI escape sequences, render into a canvas-based
character-grid control.

- Zero external dependencies
- ~800–1000 LOC; ANSI parser coverage requires iteration against Claude Code's
  actual output (colors, cursor movement, bold, Unicode box-drawing)
- Suitable once proven stable

### B — WebView2 + xterm.js + ConPTY

ConPTY handles process I/O; xterm.js (industry-standard JS terminal emulator)
renders inside a WebView2 pane embedded in the IDE panel.  WebView2 is
pre-installed on Windows 10/11 but requires a Pascal binding package for
Lazarus.

- Best rendering quality out of the box
- External dependency on a Lazarus WebView2 package
- Considered for v1.x if Option A proves too fragile

### C — External console window (current, v0.x)

`TProcess` with `poNewConsole`.  Simple, reliable, requires no additional
components.  Claude Code opens in a separate Windows terminal window.

## Decision

**v0.x ships with Option C.**  The external window is functional and unblocks
all MCP tool development.  The terminal panel is a UX enhancement, not a
correctness requirement.

**v1.x will revisit Option A** (or adopt a proven existing Lazarus/FPC terminal
component if one emerges).  Option B is the fallback if Option A proves
unmaintainable.

## Consequences

- `LaunchMcpAssistant` keeps `poNewConsole` for v0.x releases.
- The MCP server, tool set, and IDE integration are the v0.x focus.
- When implementing Option A, verify coverage against Claude Code's ANSI output
  before shipping: colors (SGR 0/1/3x/4x/9x), cursor movement (CUP/CUU/CUD/
  CUF/CUB), erase (ED/EL), and Unicode box-drawing characters.
