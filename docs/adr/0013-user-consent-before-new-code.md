# ADR-013 — User Consent Before New Code Enters the IDE

**Status:** Accepted (v0.8)  
**Date:** 2026-10-14

## Context

Installing a package rebuilds Lazarus with that package's code. The code then runs
inside the IDE, with the user's rights, every time Lazarus starts. Until now
`package_install` and `ide_rebuild` with `lpk_path` installed any `.lpk` an
assistant pointed them at: one it had just written, one from a download, one from
anywhere on disk. No human was involved.

`package_search_online` (v0.8) makes it easy to find community packages, and a
download-and-install tool is the obvious next step. That step only widens a hole
that already exists, so the gate comes first.

The client's own permission prompt isn't enough. Users often allow an MCP server's
tools wholesale, and the client can't tell installing a package from other
destructive edits.

## Decision

Installing a package that is **not already installed from that same `.lpk` file**
requires the two steps below. Both `package_install` and `ide_rebuild` with
`lpk_path` go through `McpConfirmPackageInstall` in `McpConsent.pas`.

1. **An opt-in setting, off by default.** Tools → MCP Assistant →
   *Allow Assistants to Install Packages* (a checkable menu item, stored as
   `Security/AllowPackageInstall` in `mcpassistantoptions.xml`). The same
   checkbox is on the Tools → Options → MCP Assistant page. While it is off,
   the tool refuses at once. The refusal says only the user can change the setting
   and tells the assistant not to change it itself.
2. **A confirmation in the IDE for each install.** A dialog of its own class,
   `TMcpConsentForm`, shows:
   - the requesting tool
   - the file and the package name/version
   - author, license, required packages and file count, read from the `.lpk`
   - a note when it would replace an installed package of the same name from a
     different file
   - what installing means: the code runs at every IDE start

   It is designed for the human at the keyboard:
   - **"Don't install" is the default and cancel button**, so a stray Enter or
     Escape never approves.
   - **No answer within 180 s means no.**
   - **The tool-call auto-answer leaves it alone.** It answers only the specific
     IDE dialogs it knows by class name (ADR-011), and this isn't one of them.
   - **Every decision is logged** in the Messages window.
   - **A refusal or timeout tells the assistant** not to retry unless the user asks.

**No consent is needed** to rebuild packages that are already installed from that
file: `ide_rebuild` without `lpk_path`, and `ide_rebuild`/`package_install` of this
plugin during its own development loop. That code is already in the IDE.

`package_uninstall` removes code and needs no consent.

### Requirements of installed packages (v0.9)

`package_add_dependency` is a second way in. If an installed package starts
requiring one that isn't installed, the next plain `ide_rebuild` compiles the
new one into the IDE, and nothing asks. So the tool refuses when the target is
installed and the required package isn't. It points to `package_install`, which
goes through this gate. "Installed" is `IsPackageInstalled`, which is true for
packages compiled into the IDE as dependencies too (`LazUtils`, `FCL`), so
ordinary requirements are not refused.

Adding a file to an installed package isn't gated. That's the same as editing
the package's sources with the editor tools: the package is already in the IDE.

### Downloads (v0.9, not built yet)

A future online-install tool will download into the Online Package Manager's
packages directory, check the catalog's MD5 hash, and then go through this same
gate. The dialog will name the source:

- the official repository archive, or
- a third-party URL (a package's own update file or homepage), flagged as not
  coming from the repository.

That tool will also carry `openWorldHint: true` for clients.

## Alternatives considered

- **MCP elicitation (`elicitation/create`).** It asks the user in the client's UI.
  It needs streamed (SSE) responses, which this server doesn't support yet, and
  not every client implements it. Consent in the client UI also comes from the same
  application the assistant drives. The IDE dialog works with every client.
- **The setting alone.** Once enabled, every install would go through silently,
  which is too much for "runs at every IDE start".
- **Dialog alone, always available.** An assistant could trigger the dialog
  repeatedly. The off-by-default setting means users who never want this see no
  dialogs at all.

## Consequences

- **What these gates don't protect against.** An assistant that can also run shell
  commands or edit files has other ways around them. It could:
  - edit `mcpassistantoptions.xml` and restart the IDE
  - post clicks to the dialog, as this project's own tests once did to dismiss an
    IDE dialog
  - run `lazbuild` itself

  The gates stop an assistant using these tools from installing code into the IDE
  without the user knowing. Limiting what the assistant can do *outside* the IDE is
  the client's permission system's job.
- Building still runs code at build time: an `.lpk`'s or a project's
  "execute before/after" commands run with `package_compile` and `project_build`.
  This ADR doesn't change that. It applies to anything the user builds.
- **Verified:**
  - with the setting off, both tools refused a package that wasn't installed,
    without showing a dialog
  - `ide_rebuild` with the plugin's own `.lpk` rebuilt without asking
- **Fix found while testing.** Listing an already-installed package again in
  `InstallPackages` made the IDE rebuild but *not restart*. Such a package is now
  just rebuilt.
- **Dialog verified with the user**, who turned the setting on for the test:
  - left unanswered, it closed itself after 180 s and the tool reported a decline
  - "Don't install" declined at once (the tool returned after 8 s)
  - nothing was installed, and the IDE was not rebuilt
- **Install button verified with the user** (2026-10-14). The user turned the
  setting on and clicked Install for `tests/manual/consentprobe/mcpconsentprobe.lpk`,
  an empty design-time package kept for this check. `package_install` returned
  `rebuilding`, and the IDE rebuilt and restarted. `package_get_info` then
  reported the probe installed and loaded from that file. The refusal while
  installs are off is also tested automatically (`TTestConsent`, ADR-005).
