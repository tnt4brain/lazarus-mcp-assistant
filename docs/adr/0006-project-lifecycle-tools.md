# ADR-006 — Project Lifecycle Tools

**Status:** Proposed  
**Date:** 2026-10-05

## Context

The current 40 tools cover source editing, code navigation, building, and package
management well.  What is missing is the ability to manage the *project itself* —
its file list, its compiler settings, its run configuration, and IDE editor state.
Today Claude works around these gaps by editing `.lpi` files directly with
`edit_text`, which is fragile (XML structure, no validation) and bypasses the IDE's
own project model.

Concrete pain points observed during self-hosted development:

- Adding an existing `.pas` file to the project requires `edit_text` on `.lpi` XML.
- Changing a compiler flag (e.g. `{$DEFINE FOO}`) requires `edit_text` on `.lpi`.
- Creating a form requires knowing the `.lfm` XML schema by heart.
- Opening a file in the editor requires the cursor-movement side effect of
  `set_cursor_position`.
- `run_project` cannot pass arguments to the launched application.
- The IDE Messages window contains hints and notes that `get_compiler_errors`
  silently drops.

## Decision

Add a **Project Lifecycle** tool group covering four sub-areas:

1. **Project file management** — add/remove existing files, create forms
2. **Project settings** — write compiler options (complement to `get_project_settings`)
3. **Editor state** — open a file without a cursor side-effect
4. **Run configuration & output** — arguments for `run_project`, full message log

`create_project` is deferred: creating a project requires choosing a template,
output path, and initial settings — too much ambiguity for a single tool call
without a richer workflow.  It can be added once the other tools are in place
and the workflow is clearer.

---

## Proposed tools

### Project file management

#### `add_file_to_project`

Add an existing source file to the active project.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `file_path` | string | yes | Absolute path to the `.pas` (or other source) file |

Implementation: `LazarusIDE.ActiveProject.AddFile(FilePath, [pfAddToBuildOrder])`.  
Returns: `{"file": "<path>", "project": "<lpi path>"}`.

#### `remove_file_from_project`

Remove a source file from the active project without deleting it from disk.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `file_path` | string | yes | Absolute path to the file to remove |

Implementation: find the `TLazProjectFile` via `ActiveProject.FindFile`, then
`ActiveProject.RemoveUnit(Index)` (or `RemoveFile`).  
Returns: `{"removed": true, "file": "<path>"}`.

#### `create_form`

Create a new form: a `.pas` unit and a paired `.lfm` file, both added to the project.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `unit_name` | string | yes | Pascal unit name (e.g. `UnitSettings`) |
| `form_class` | string | no | Form class name; defaults to `T<UnitName>` (e.g. `TFormSettings`) |
| `directory` | string | no | Target directory; defaults to the active project directory |

Implementation: `LazarusIDE.CreateNewForm(...)` or, if that surface is not
available, use `LazarusIDE.DoNewEditorFile(FileDescriptorForm, ...)` to invoke
the same path as File → New Form.  
Returns: `{"unit_file": "<path>", "form_file": "<path>"}`.

---

### Project settings

#### `set_project_settings`

Write one or more compiler options to the active project.  All parameters are
optional; only supplied keys are changed.

| Parameter | Type | Description |
|-----------|------|-------------|
| `target_os` | string | Target operating system (e.g. `win64`, `linux`) |
| `target_cpu` | string | Target CPU (e.g. `x86_64`, `aarch64`) |
| `output_dir` | string | Compiler output directory |
| `custom_options` | string | Raw `-d` / `-O` / other flags appended to compiler options |

Implementation: `ActiveProject.LazCompilerOptions.TargetOS`, `.TargetCPU`,
`.UnitOutputDirectory`, `.CustomOptions`.  Call `LazarusIDE.DoSaveProject([])`
after writing.  
Returns: the same shape as `get_project_settings` reflecting the new state.

**Note on `custom_options`:** this *replaces* the existing custom options string.
Read current state with `get_project_settings` first if you want to preserve
existing flags before adding new ones.

---

### Editor state

#### `open_file`

Open a file in the IDE editor and make it the active tab, without moving the
cursor.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `file_path` | string | yes | Absolute path to the file to open |

Implementation: `LazarusIDE.DoOpenEditorFile(FilePath, -1, -1, [ofOnlyIfExists, ofRegularFile])`.  
Returns: `{"file": "<path>", "already_open": <bool>}`.

Why not just use `set_cursor_position`?  That tool opens the file as a side effect
but the primary semantic is cursor movement.  A caller that just wants a file
visible in the editor should not need to supply a line and column.

---

### Component registry

#### `search_components`

Search the IDE's Component Class Registry (CCR) — the set of all registered
components visible on the component palette — and return matching entries with
their class name, package, unit, and palette page.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `query` | string | yes | Substring to match against class name or description (case-insensitive) |

Implementation: iterate `IDEComponentPalette` (via `IDEIntf.IDEComponentPaletteIntf`)
or `RegisteredComponents` to enumerate all registered component classes; filter by
`query` against `AClass.ClassName` and the component's description string.  
Returns:
```json
[
  {"class_name": "TChart", "package": "tachart", "unit": "TAGraph",
   "palette_page": "Chart", "description": "TeeChart component"}
]
```

**Typical workflow:**  
`search_components` → identify the package lpk → `add_package_to_project` or
`install_package` as needed.  Closes the gap where Claude must guess which package
a component lives in.

---

### Run configuration & output

#### `run_with_args`

Build (if needed) and run the active project with command-line arguments.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `args` | string | yes | Command-line argument string passed to the launched process |

Implementation: set `ActiveProject.RunParameterOptions.CmdLineParams := Args`
before calling `LazarusIDE.DoBuildProject` + `LazarusIDE.DoRunProject`, then
restore (or leave, since Claude set it intentionally).  
Returns: same as `run_project` — `{"status": "running"}`.

#### `get_messages`

Return the full content of the IDE Messages window from the last build or run,
including hints and notes that `get_compiler_errors` drops.

No parameters.

Implementation: `IDEMessagesWindow.GetMessagesAsString` (or iterate
`IDEMessagesWindow.Lines`).  
Returns: `{"messages": "<full text>", "line_count": N}`.

**Relationship to `get_compiler_errors`:** `get_compiler_errors` returns only
parsed error/warning records; `get_messages` returns the raw window text.  Both
remain useful — errors for structured processing, messages for full context.

---

## Knowledge injection

The project-lifecycle and component-registry APIs are not well-known outside
active Lazarus contributors.  Before implementation, a **Project Management API**
section will be added to `lazarus-knowledge.md` covering:

- `LazarusIDE.ActiveProject` surface: `AddFile`, `RemoveUnit`, `FindFile`,
  `LazCompilerOptions`, `RunParameterOptions`
- `LazarusIDE.DoOpenEditorFile` flags: `ofOnlyIfExists`, `ofRegularFile`, etc.
- `IDEComponentPalette` / `RegisteredComponents` enumeration
- `IDEMessagesWindow` access pattern

`tools/update_knowledge.ps1` regenerates `src/lazarus_knowledge.inc`; the
updated reference is injected at launch and available via `get_lazarus_reference`.

---

## Out of scope for this ADR

- **`create_project`** — deferred; needs template selection and path negotiation.
- **Breakpoints / debugger** — separate ADR (significantly larger scope).
- **Run parameters beyond args** (working directory, environment variables) —
  can be added as parameters to `run_with_args` in the implementation without
  a new ADR.

## Consequences

- Tool count rises from 40 to 48.
- `set_project_settings` eliminates the last common reason to use `edit_text` on
  `.lpi` files directly.
- `create_form` closes the last gap in the new-file workflow: Claude can now
  create units, forms, and projects (once `create_project` is added) without
  leaving the IDE model.
- `search_components` eliminates the need to consult external documentation or
  guess package names when adding a new component to a form.
- `get_messages` gives full build context; `get_compiler_errors` remains the
  preferred tool for structured error processing.
- A new **Project Management API** knowledge section in `lazarus-knowledge.md`
  reduces hallucination risk for obscure IDEIntf surface area.
