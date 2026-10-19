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
`lpk_path` go through `McpConfirmPackageInstall` in `McpConsent.pas`. (Since
v1.0 only `package_install` installs; `ide_rebuild` refuses `lpk_path`.)

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
file: `ide_rebuild`, and `package_install` of this
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

### Downloads (v0.9)

Downloading and installing are two steps. `package_download` (`openWorldHint:
true`) only fetches. Installing stays with `package_install` and goes through
this gate unchanged. The download installs nothing, so it needs no consent.

- **Source: the official repository only.** The archive is
  `https://packages.lazarus-ide.org/<RepositoryFileName>`, named by the cached
  Online Package Manager catalog. Third-party update URLs (a package's own
  `DownloadURL`) are not supported, so the dialog's "third-party" case doesn't
  arise.
- **Transport.** HTTPS first. The IDE on Windows often has no OpenSSL DLLs, as
  on this machine ("Could not initialize OpenSSL library"). Then, and only then,
  it falls back to plain HTTP, which is what the Online Package Manager itself
  uses (its repository address is `http://`). The result says which, with a
  note when it was HTTP.
- **MD5.** The archive must match the catalog's `RepositoryFileHash` (OPM
  computes it as `MD5Print(MD5File(zip))`, but doesn't check it on download).
  If it doesn't match, nothing is saved. Over HTTP this proves only that
  archive and catalog agree: both came unencrypted.
- **Extraction** goes into OPM's folders (`options.xml`: archive and packages),
  in OPM's layout: `packages/<PackageBaseDir>`, with one top folder common to
  all zip entries dropped. Every entry is checked first: no drive, no root, no
  `..`. One bad entry and nothing is extracted. The archive is extracted to a
  temporary folder and then moved into place.
- **An earlier download** is refused unless `replace` is true. Replacing is
  refused while a package from that folder is installed or loaded. New sources
  under an installed package would reach the IDE at the next rebuild, past this
  gate.
- **The dialog names the source.** `package_download` writes
  `mcp-download.json` into the package's folder (URL, transport, MD5, date).
  When `package_install` asks, the dialog shows "downloaded by an assistant
  from …, over HTTP (unencrypted)/HTTPS; the archive's MD5 matched the
  catalog". An assistant with file access could write such a file itself.
  That's covered by "What these gates don't protect against" below.
- **Verified** with `Lists` (1.9 KB): downloaded over HTTP, MD5 matched,
  extracted to `packages/Lists`, `package_search_online` then listed its
  `downloaded_lpk`. A second download was refused, `replace` worked. Replacing
  `richmemo` (installed from OPM's folder) was refused. The test download was
  removed afterwards.
- **Dialog verified with the user** (2026-10-14). The user allowed installs,
  `package_install` asked for the downloaded `Lists`, and the dialog read:

  ```
  File:         ...\onlinepackagemanager\packages\Lists\lists.lpk
  Source:       downloaded by an assistant (package_download) on 2026-10-14 21:58 from
                http://packages.lazarus-ide.org/Lists.zip
                the Online Package Manager repository, over HTTP (unencrypted)
                the archive's MD5 matched the repository catalog
  Package:      Lists 0.0.0.1
  Requires:     FCL
  Files:        1
  ```

  The user answered "Don't install". Nothing was installed, and the download was
  removed again.

### Clones (v1.1)
`git_clone` brings files from a network address (or another folder) onto the disk
at the assistant's choice, so it gets a gate of its own, lighter than the install
gate because nothing runs:

- **A dialog for every clone** (`McpConfirmClone`, same `TMcpConsentForm` as the
  install dialog). It shows the address, the target folder, branch and depth, and
  a note for plain `http://`. "Don't clone" is the default and cancel button, and
  no answer within 180 s means no.
- **No setting.** Unlike installs there is no opt-in checkbox: the dialog is the
  gate, and a clone into a new folder can be deleted. Remembering "trusted"
  addresses was left out on purpose; every clone is asked.
- **Nothing is built, run or opened.** The result lists the `.lpi` and `.lpk`
  files found, and opening one is a separate `project_open` call by the assistant
  (building it can run the project's own commands, as noted above).
- **Arguments:** the target must be an absolute path that does not exist or is
  empty (nothing is merged into existing files). An address or branch starting
  with `-` is refused (it would be read as an option), and so is the `ext::`
  transport (it runs a command); `protocol.ext.allow=never` is also set.
- **Runs on the MCP worker thread** (a blocking group), with a 30 minute limit, so
  a slow clone does not hold the IDE. `GIT_TERMINAL_PROMPT=0` is set: stdin is
  closed, so a credential prompt would hang. Credential helpers and SSH keys still
  work; an address that needs a typed password fails with git's message.
- **Verified:** the arguments above are refused without a dialog
  (`TestCloneRefusesBadArguments`). A clone of a local repository went through
  after the user clicked Clone, and the result listed its `.lpk`. The decline
  path and a clone over the network were not exercised.
- **Open:** the first attempt in the session that tested this returned no answer
  and showed no dialog, and the cause was not found. The main-thread step now
  catches its own exceptions and returns them as the tool's error; the second
  attempt, after the IDE was rebuilt with that change, worked.

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
