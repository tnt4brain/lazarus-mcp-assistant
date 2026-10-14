# Lazarus / FreePascal — Developer Reference

This document is injected as context when Claude Code is launched from within the Lazarus IDE.
It covers idioms, component libraries, and gotchas specific to this ecosystem.

---

## Language & Compiler

- Compiler: **Free Pascal (FPC)** with `{$mode objfpc}{$H+}` — not Delphi dialect unless `{$mode delphi}`.
- String type: `AnsiString` by default with `{$H+}`. Use `string` everywhere; `ShortString` only for fixed-size buffers.
- `SizeOf(Pointer)` = 8 on x86_64-win64. Avoid `Integer` for pointer math; use `NativeInt`/`NativeUInt`.
- FPC generics use `specialize` keyword: `specialize TList<TFoo>`.
- Operator overloading and anonymous methods available from FPC 3.x.
- `{$ifdef FPC}` / `{$ifdef LAZARUS}` to guard FPC-specific code.
- Initialization order is per-unit `initialization`/`finalization` sections, not constructors — don't rely on cross-unit order.

## LCL (Lazarus Component Library)

- Cross-platform VCL equivalent. Use `LCLIntf`, `LCLType` for Win32 API calls.
- Message system: `TLMessage`, `LM_*` constants (not `WM_*`).
- `TControl.GetClientRect` is the safe rect — `Width`/`Height` may lag during resize.
- `Application.ProcessMessages` pumps the LCL message loop (same role as Delphi's).
- `TWinControl.Color` defaults to `clBtnFace` (theme-dependent) not white.
- Form files: `.lfm` (Lazarus) not `.dfm`. Text format; safe to hand-edit.
- `RegisterComponent` in a `Register` procedure inside the unit — called at design time.

## Packages

- Package files: `.lpk` (XML). Runtime vs design-time pair common for component packages.
- Install via: `Package → Open Package File (.lpk)` → `Use → Install` → IDE rebuilds.
- `lazbuild <pkg.lpk>` compiles without the IDE (CI-friendly).
- `PackageEditingInterface.FindPackageWithName(name)` — query installed packages at runtime.

## Key Component Libraries (FPC/Lazarus compatible)

### BGRABitmap
- **What**: Advanced 2D drawing library. Foundation for many skinned component packs.
- **Install**: Lazarus Online Package Manager (`Tools → Online Package Manager`).
- **Key units**: `BGRABitmap`, `BGRACanvas2D`, `BGRAGradients`.
- **Required by**: TyControls, CyberUI.

### TyControls
- **Repo**: https://github.com/ACTom/TyControls
- **What**: 169 fully custom-drawn components via BGRABitmap. CSS-style `.tycss` theme files. Consistent cross-platform rendering (Windows/Linux/macOS). Includes: text inputs, grids, tree views, ribbons, charts, icon fonts (Lucide), tab controls, menus.
- **Install**: `tycontrols_dt.lpk` (design-time; pulls in `tycontrols.lpk` runtime).
- **Theming**: Drop a `TTyStyleController` on the form; set `StyleFile` to a `.tycss` path.

### OnurComp
- **Repo**: https://github.com/Onur2x/onurcomp
- **What**: 20+ BGRABitmap-based skinned controls for Lazarus. Buttons, knobs, LEDs, switches, page controls, progress/track bars, crop-shaped controls (bitmap-masked). Beta. Unlicense.
- **Install**: `onur.lpk`. Requires BGRABitmap.

### CyberUI
- **Repo**: https://github.com/CodeInPas/CyberUI-Component
- **What**: 18 cyberpunk-themed components (BGRABitmap). Radar scanners, hex grids, waveform displays, 7-segment labels, rotary knobs, glitch labels. Good for dashboards and HMI.
- **Install**: `cyberui.lpk` in `src/` folder. Requires BGRABitmap.

### TWLazUI
- **Repo**: https://github.com/CodeInPas/TWLazUI
- **What**: ~27 Tailwind CSS-inspired modern UI components (BGRABitmap). Buttons, panels, cards, text fields, checkboxes, switches, combo/list boxes, badges, avatars, data tables, line charts, tabs, breadcrumbs, accordions, steppers, progress bars, spinners, alerts, toasts, tooltips, modals. Smooth anti-aliasing, rounded corners, alpha transparency, drop shadows.
- **Themes**: Primary/Secondary/Success/Danger colors, corner styles, Outline/Solid/Pills variants — all via Object Inspector.
- **Install**: `twlazui_components.lpk`. Requires BGRABitmap. Lazarus 2.2+.

### CPUView
- **Repo**: https://github.com/AlexanderBagel/CPUView
- **What**: Advanced CPU debugger UI for Lazarus. Adds a dockable window (View→Debug Windows→CPU-View, Ctrl+Shift+C) with disassembly, CPU registers, memory dump, call stack, trace log, exports, memory map, and PDB symbol manager. Runs on top of FpDebug — no new debugger engine, pure UI layer.
- **Platforms**: Windows x86_64, Linux x86_64, Linux AArch64. GTK2 and Qt5 widgetsets.
- **Install**: compile FWHexView first, then `CPUView_win_x86_64_D.lpk` (or platform equivalent). Requires stable Lazarus 3.x. MIT license.
- **Note**: purely a visual tool — no external API. Debugger state queries go through FpDebug/IdeDebugger interfaces, not CPUView.

### Floria Toolkit (ft)
- **Repo**: https://github.com/kiranaproject/ft
- **What**: Standalone native GUI framework (AGG subpixel rendering, CSS theming, 60 fps). Builds as a shared C ABI library (`libft.so`/`.dll`). **Not an LCL component pack** — requires separate integration. Not drop-in with existing LCL forms.

### VirtualTreeView (Lazarus port)
- **Repo**: https://github.com/blikblum/VirtualTreeView-Lazarus
- **What**: Highly flexible virtual (callback-based) tree/list/grid. Used in RAD Studio's own IDE UI. Virtual = no data storage in nodes; you supply data in callbacks.
- **Key classes**: `TVirtualStringTree`, `TVirtualDrawTree`.
- **FPC port**: maintained, works on Windows/Linux.

### ATSynEdit
- **Repo**: https://github.com/Alexey-T/ATSynEdit
- **What**: Multi-line syntax-highlighting editor for Lazarus. Code folding, multiple carets, minimap. Used in CudaText editor.
- **FPC-native**, actively maintained.

### HtmlViewer
- **Repo**: https://github.com/BerndGabriel/HtmlViewer
- **What**: HTML/CSS renderer component for Delphi/Lazarus. Supports majority of HTML tags, inline styles, CSS. `TFrameViewer` for framesets.

### BGRAControls
- **Repo**: https://github.com/bgrabitmap/bgracontrols
- **What**: 40+ styled/custom-drawn LCL components on BGRABitmap. Buttons (including Material Design + SVG), panels, progress bars, radial gauges, knobs, SVG viewer, image manipulation. Dark-themed variants of standard controls.
- **Install**: `bgracontrols.lpk`. Requires BGRABitmap (`bgrabitmappack.lpk`).

### ATFlatControls
- **Repo**: https://github.com/alexey-t/atflatcontrols
- **What**: Cross-platform flat custom-drawn controls from CudaText. ATTabs, ATGroups (tab sets), ATButton, ATFlatToolbar, ATListbox, ATScrollbar, ATStatusbar, ATGauge, ATLinkLabel, ATPanelSimple/Color. No external dependencies.
- **Note**: Companion to ATSynEdit (same author). Install package is inside the `atflatcontrols/` folder.

### KControls
- **Repo**: https://github.com/kryslt/KControls
- **What**: Cross-IDE (VCL + LCL) control set. Standout: `TKGrid` (full-featured grid with inplace editors, DB-aware `TKDBGrid`), hex editor, print preview.

### CEF4Delphi / WebView4Delphi
- **CEF4Delphi**: https://github.com/salvadordf/CEF4Delphi — embed Chromium in LCL apps.
- **WebView4Delphi**: https://github.com/salvadordf/WebView4Delphi — embed WebView2 (Windows, lighter than CEF).

### JPPack
- **Repo**: https://github.com/jackdp/JPPack
- **What**: Mixed VCL/LCL collection — buttons, panels, `LinkLabel`, `ProgressBar`, `ColorComboBox`, `ColorListBox`, timer. Actively maintained for both Delphi and Lazarus.

### TeeGrid
- **Repo**: https://github.com/Steema/TeeGrid
- **What**: Lightweight grid/tabular control. Supports Lazarus on Windows and Linux. No DB dependency in core.

### Dam (Dialogs)
- **Repo**: https://github.com/digao-dalpiaz/Dam
- **What**: Delphi + Lazarus message dialogs with formatted text. Replaces `ShowMessage`/`MessageDlg` with richer markup.

---

## Project Management API (IDEIntf)

All identifiers live in `IDEIntf`/`BuildIntf` units unless noted. All IDE API
calls must run on the main thread — use `TThread.Synchronize` from worker threads.

### Active project — `TLazProject` (`ProjectIntf`)

```pascal
uses LazIDEIntf, ProjectIntf;

Proj := LazarusIDE.ActiveProject;   // TLazProject; nil when no project open
LpiPath := Proj.ProjectInfoFile;    // absolute path to the .lpi file
ProjDir := ExtractFilePath(LpiPath);
```

#### Adding / removing files

```pascal
uses LazIDEIntf, ProjectIntf;

// Add a file: two-step — CreateProjectFile then AddFile
var PF: TLazProjectFile;
PF := Proj.CreateProjectFile(AbsFilename);   // creates a TLazProjectFile object
Proj.AddFile(PF, False);                     // False = don't touch uses clause
LazarusIDE.DoSaveProject([]);                // persist to .lpi

// Find a project file by absolute path (pfsfOnlyProjectFiles restricts to project)
PF := Proj.FindFile(AbsFilename, [pfsfOnlyProjectFiles]);

// Remove: FindFile then loop to get the 0-based index RemoveUnit needs
var I: Integer;
for I := 0 to Proj.FileCount - 1 do
  if Proj.Files[I].Filename = AbsFilename then
  begin
    Proj.RemoveUnit(I);   // removes from project; does NOT delete disk file
    Break;
  end;
LazarusIDE.DoSaveProject([]);
```

- `TProjectFileSearchFlags` values: `pfsfResolveFileLinks`, `pfsfOnlyEditorFiles`,
  `pfsfOnlyVirtualFiles`, `pfsfOnlyProjectFiles`.  There is no `pfsfFullPathSearched`.
- `TLazProjectFile` has no `UnitIndex` property — iterate `Proj.Files[]` to find
  the index for `RemoveUnit`.
- `Proj.Files[I].IsPartOfProject` — true for files that compile with the project.

#### Compiler options — `TLazCompilerOptions` (`CompOptsIntf`)

```pascal
var Opts: TLazCompilerOptions;
Opts := Proj.LazCompilerOptions;

Opts.TargetOS            := 'win64';     // '' = host OS
Opts.TargetCPU           := 'x86_64';   // '' = host CPU
Opts.UnitOutputDirectory := 'lib/$(TargetOS)-$(TargetCPU)';  // macros OK
Opts.CustomOptions       := '-dMY_FLAG'; // replaces the whole string

LazarusIDE.DoSaveProject([]);   // flush to .lpi
```

- **`CustomOptions` uses replace semantics.** Read with `project_get_settings` first
  if you want to preserve existing flags; set the full resulting string.
- Macro syntax: `$(TargetOS)`, `$(TargetCPU)`, `$(ProjOutDir)` expanded at build time.

#### Run parameters — `TAbstractRunParamsOptions` (`ProjectIntf`)

```pascal
// Get or create the 'default' run mode, set args, then run
Proj.RunParameters.GetOrCreate('default').CmdLineParams := '--verbose input.txt';
// No save needed before DoRunProjectWithoutDebug
LazarusIDE.DoRunProjectWithoutDebug;
```

- `TLazProject.RunParameters` → `TAbstractRunParamsOptions` (declared in `ProjectIntf`).
- `GetOrCreate(Name)` → `TAbstractRunParamsOptionsMode`; the default mode is named
  `'default'`.
- `CmdLineParams: string` — passed verbatim to the spawned process.

### Opening files — `DoOpenEditorFile` (`LazIDEIntf`)

```pascal
uses LazIDEIntf, SrcEditorIntf;

// DoOpenEditorFile returns TModalResult (mrOK on success, mrCancel if not found)
var Res: TModalResult;
Res := LazarusIDE.DoOpenEditorFile(
  AbsFilename,
  -1, -1,                          // page / window: -1 = IDE decides
  [ofOnlyIfExists, ofRegularFile]
);
// mrOK = opened; mrCancel/mrAbort = not found (with ofOnlyIfExists)

// Check if already open (before opening):
SourceEditorManagerIntf.SourceEditorIntfWithFilename(AbsFilename) <> nil
```

**`TOpenFlag` values** (from `LazIDEIntf`):

| Flag | Effect |
|------|--------|
| `ofOnlyIfExists` | Do not create; return mrCancel if not found |
| `ofRegularFile` | Treat as a normal source file, not a project/package |
| `ofAddToRecent` | Add to File → Recent Files |
| `ofQuiet` | Suppress error dialogs |
| `ofRevert` | Reload from disk even if already open |
| `ofDoNotLoadResource` | Open `.pas` without loading paired `.lfm` |

### Creating forms — `FileDescriptorForm` (`ProjectIntf`)

```pascal
uses LazIDEIntf, ProjectIntf;

// FileDescriptorForm() is a function (not a global var) from ProjectIntf
// Creates <path>.pas + <path>.lfm and adds both to the project
LazarusIDE.DoNewEditorFile(
  FileDescriptorForm,              // TProjectFileDescriptor from ProjectIntf
  '/path/to/UnitFoo.pas',          // suggested .pas path
  '',                              // source: '' = descriptor generates default
  [nfIsPartOfProject, nfOpenInEditor, nfSave]
);
```

**`TNewFlag` values** (from `LazIDEIntf`):

| Flag | Effect |
|------|--------|
| `nfIsPartOfProject` | Mark as project file |
| `nfOpenInEditor` | Open in editor after creation |
| `nfSave` | Save files immediately |
| `nfAddToRecent` | Add to File → Recent Files |

- The form class name is auto-generated by the descriptor (e.g. `TForm1`).
  Rename afterwards with `editor_edit_text`.
- `DoNewEditorFile` returns `TModalResult` (mrOK on success).

### Creating a new project — `DoNewProject` (`LazIDEIntf`, `ProjectIntf`)

```pascal
uses LazIDEIntf, ProjectIntf, LazFileUtils;

// Available descriptor names (constants in ProjectIntf):
//   ProjDescNameApplication      = 'Application'        (GUI app + Form1)
//   ProjDescNameSimpleProgram     = 'Simple Program'
//   ProjDescNameProgram           = 'Program'
//   ProjDescNameConsoleApplication = 'Console application'
//   ProjDescNameLibrary           = 'Library'
//   ProjDescNameCustomProgram     = 'Custom Program'
//   ProjDescNameEmpty             = 'Empty'

var
  Desc : TProjectDescriptor;
  Proj : TLazProject;
begin
  // 1. Pick the descriptor (use the helper functions or FindByName)
  Desc := ProjectDescriptorApplication;          // for a GUI app
  // or: Desc := ProjectDescriptors.FindByName(ProjDescNameConsoleApplication);

  // 2. Create the target directory if needed
  ForceDirectories('/path/to/myproject');

  // 3. Create the project — closes the current project first
  //    None of the built-in descriptors override DoInitDescriptor,
  //    so no dialog is shown.  CreateStartFiles for Application creates Form1.
  if LazarusIDE.DoNewProject(Desc) <> mrOK then
    Exit;  // user cancelled or error

  // 4. Set the .lpi path and save
  Proj := LazarusIDE.ActiveProject;
  Proj.ProjectInfoFile := '/path/to/myproject/MyApp.lpi';
  Proj.Title := 'MyApp';                         // optional; shown in title bar
  LazarusIDE.DoSaveProject([]);                  // writes .lpi to the path set above
end;
```

**Key points:**
- `DoNewProject` closes the current open project first; unsaved changes are lost unless
  you call `DoSaveAll([])` beforehand.
- Setting `Proj.ProjectInfoFile` before `DoSaveProject` redirects the save without
  triggering a "Save As…" dialog.
- The descriptor's `CreateStartFiles` may open new editor tabs (e.g. Form1 for
  `Application`). This is normal and expected.
- `ProjectDescriptorApplication` / `ProjectDescriptorConsoleApplication` etc. are
  convenience functions calling `ProjectDescriptors.FindByName(...)`.
- Returns `mrOK` on success; `mrCancel` / `mrAbort` on failure.

### Component palette — `IDEComponentPalette` (`ComponentReg`)

```pascal
uses ComponentReg;  // TBaseComponentPalette, TRegisteredComponent, TBaseComponentPage

var
  Comp : TRegisteredComponent;
  I    : Integer;
begin
  // IDEComponentPalette.Comps is a flat TRegisteredCompList of all components
  for I := 0 to IDEComponentPalette.Comps.Count - 1 do
  begin
    Comp := IDEComponentPalette.Comps[I];
    // Comp.ComponentClass.ClassName — e.g. 'TChart'
    // Comp.GetUnitName              — unit where the component is defined
    // Comp.OrigPageName             — palette tab name, e.g. 'Chart'
    // Comp.RealPage.PageName        — same as OrigPageName if not reordered
  end;
end;
```

- `IDEComponentPalette: TBaseComponentPalette` — global, declared in `ComponentReg`,
  assigned by the IDE at startup.
- Iterate `.Comps` (flat list) for searching; iterate `.Pages` for page-by-page
  display.
- There is **no `OriginPackage`** property on `TRegisteredComponent`.  Package
  membership is not directly accessible via IDEIntf.
- `RealPage` may be nil for components not yet placed on a palette page.

### IDE Messages window — `IDEMessagesWindow` (`IDEMsgIntf`)

```pascal
uses IDEMsgIntf, IDEExternToolIntf;

// IDEMessagesWindow exposes Views (build output, tools, etc.)
// Each TExtToolView has a TMessageLines Lines property
var
  View    : TExtToolView;
  MsgLine : TMessageLine;
  I, J    : Integer;
begin
  if not Assigned(IDEMessagesWindow) then Exit;
  for I := 0 to IDEMessagesWindow.ViewCount - 1 do
  begin
    View := IDEMessagesWindow.Views[I];
    for J := 0 to View.Lines.Count - 1 do
    begin
      MsgLine := View.Lines.Items[J];
      // MsgLine.Msg       — message text
      // MsgLine.Urgency   — TMessageLineUrgency:
      //   mluNone, mluProgress, mluDebug, mluVerbose, mluHint, mluNote,
      //   mluWarning, mluImportant, mluError, mluFatal, mluPanic
      // MsgLine.Filename  — source file (may be '')
      // MsgLine.Line      — source line (0 if not applicable)
      // MessageLineUrgencyNames[MsgLine.Urgency] — string form of urgency
    end;
  end;
end;
```

- `IDEMessagesWindow: TIDEMessagesWindowInterface` (from `IDEMsgIntf`).
- `IDEMessagesWindow` has no `LinesCount`/`Lines[]` directly — messages are
  accessed through `Views[i]: TExtToolView` and then `View.Lines`.
- `TExtToolView` and `TMessageLine` are from `IDEExternToolIntf` (BuildIntf).
- `mluHint` and `mluNote` are dropped by `project_get_compiler_errors` — `ide_get_messages`
  returns all urgency levels.
- The window is cleared at the start of each build; call after build completes.

---

## Debugger API (FpDebug / DebugBoss)

All identifiers live in `IdeDebuggerIntf`, `Debugger`, `DebuggerIntf`, `IdeDebuggerWatchResult` unless noted.
All debugger API calls **must** run on the main thread — use `TThread.Synchronize`.

### State and control — `TDebugManager` (`Debugger` unit)

```pascal
uses Debugger, IdeDebuggerIntf;

// Global — valid after IDE startup
DebugBoss : TDebugManager;

// Debugger state
TDBGState = (dsNone, dsIdle, dsStop, dsPause, dsInit, dsRun, dsError, dsDestroying);
DebugBoss.State : TDBGState;

// Run control (main thread only)
DebugBoss.RunDebugger;         // F9 — start or continue
DebugBoss.DoPauseProject;      // pause running session
DebugBoss.DoStopProject;       // terminate session (async)
DebugBoss.DoStepOverProject;   // F8
DebugBoss.DoStepIntoProject;   // F7
DebugBoss.DoStepOutProject;    // Shift+F8
```

`DebugBoss.OnState` callback fires on every state transition (main thread).
`DebugBoss.OnCurrent` fires when the current source line changes after a step or breakpoint.

### Breakpoints — `TIDEBreakPoints`

```pascal
// Add
BP := DebugBoss.BreakPoints.Add(AbsFilePath, Line);   // TIDEBreakPoint

// Remove — iterate to find by source+line
for I := DebugBoss.BreakPoints.Count - 1 downto 0 do
begin
  BP := DebugBoss.BreakPoints.Items[I];
  if (BP.Source = AbsFilePath) and (BP.Line = Line) then
  begin
    BP.ReleaseReference;   // frees the object
    Break;
  end;
end;

// Enumerate
for I := 0 to DebugBoss.BreakPoints.Count - 1 do
  BP := DebugBoss.BreakPoints.Items[I];
  // BP.Source, BP.Line, BP.Enabled, BP.Valid, BP.HitCount
```

### Async data: trigger once, then only read validity

Call stack, locals, watches and threads load asynchronously on FpDebug worker
threads; results are delivered to the main thread through
`Application.QueueAsyncCall`. The pattern that works from an MCP worker thread:

1. One `TThread.Synchronize` that **triggers** the load, then returns.
2. Worker thread `Sleep`s, then `Synchronize`s a method that **only reads**
   validity/state and builds the result when ready.

Never call the trigger again in step 2 (it can restart the load), and never
`Sleep`/`ProcessMessages` inside a Synchronize callback (the main loop must run
to deliver the results).

### Call stack — `TIdeCallStack` (two async phases)

```pascal
Stack := DebugBoss.CallStack.CurrentCallStackList.EntriesForThreads[ThreadId];

// Phase 1 — frame count. CountLimited only requests "at least N" frames:
// CountValidity stays ddsUnknown unless the backend read every frame,
// so do NOT wait for CountValidity alone.
Stack.CountLimited(Max + 1);                         // trigger, once
// poll:
case Stack.CountValidity of
  ddsValid:             Cnt := Min(Stack.Count, Max);
  ddsInvalid, ddsError: Cnt := 0;
else
  if Stack.HasAtLeastCount(Max + 1) = nbTrue then Cnt := Max   // read-only once requested
  else {retry};
end;

// Phase 2 — frame details. Entries are created as ddsRequested.
Stack.PrepareRange(0, Cnt);                          // trigger, once
// poll until no Stack.Entries[I].Validity in [ddsUnknown, ddsRequested, ddsEvaluating]
Frame := Stack.Entries[I];   // TIdeCallStackEntry: Source, Line, FunctionName, Address
```

### Locals — `TIDELocals`

```pascal
Locals := DebugBoss.Locals.CurrentLocalsList[ThreadId, FrameIndex];
Locals.Count;                                        // trigger, once
// poll: TCurrentLocals(Locals).Validity  (ddsValid → read; ddsInvalid → give up)
LVal := TIdeLocalsValue(Locals.Entries[I]);          // DisplayName, Value, ResultData
```

### Watches — `DebugBoss.Watches.CurrentWatches`

```pascal
W := DebugBoss.Watches.CurrentWatches.Add('Expr');  // or .Find('Expr'); W.Free removes
W.Enabled := True;
V := W.Values[ThreadId, Frame];   // TIdeWatchValue
V.Value;                          // reading Value triggers the load when unknown
V.Validity;                       // reading Validity does not — poll this
```

### Printing values

`Value` is empty for structured results (objects, records, arrays). Print
`ResultData` the way the IDE does:

```pascal
uses IdeDebuggerWatchResPrinter, IdeDebuggerWatchValueIntf;
S := DebugBoss.HintWatchPrinter.PrintWatchValue(V.ResultData,
       DefaultWatchDisplayFormat, Expr);
// FormatFlags := [] for one line (restore the old flags afterwards — the
// printer is shared with the IDE's hints); an object dump can be tens of KB.
```

### Threads

`DebugBoss.Threads.CurrentThreads.Count` requests data only while unknown, so
it is safe to poll; ready when Count > 0 (a paused process has ≥ 1 thread).
`Entries[I]`: ThreadId, ThreadName, ThreadState, TopFrame.

### Evaluate expression — `DebugBoss.Evaluate` (async callback)

```pascal
// Returns True if evaluation started; callback fires on the main thread
OutStarted := DebugBoss.Evaluate(ExprStr, @MyCallback);

procedure MyCallback(Sender: TObject; ASuccess: Boolean;
  ResultText: string; ResultDBGType: TDBGType);
// ResultDBGType.TypeName — may be nil for simple types
```

Call `DebugBoss.Evaluate` inside a `TThread.Synchronize` callback and return
immediately; the worker thread polls a flag set by the callback. A new
`Evaluate` aborts a pending one, which fires the old callback first.

### Debugger events and IDE modals

`DebugBoss.Debugger` is not public (only with `DBG_WITH_DEBUGGER_DEBUG`). The
debugger object is reachable through
`DebugBoss.RegisterStateChangeHandler(procedure(ADebugger: TDebuggerIntf; AOldState: TDBGState))`.
These handlers run on every state change **before** the IDE decides to show
"Execution stopped", so `ADebugger.SetSkipStopMessage` there suppresses it (the
flag resets on any change to a state other than dsStop).

The IDE re-assigns `OnException`, `OnFeedback`, `OnConsoleOutput`,
`OnDbgOutput` each time it initialises the debugger, so wrappers must be
re-installed per session (check in the state handler). `OnException` with
`AContinue := False` breaks at the exception without the IDE dialog; the
debugger has already applied the IDE's ignore list. See `McpDebugGuard.pas`.

### HTTP server: one request per connection, no inheritable sockets

`fphttpserver` (FPC 3.2.2) serves one request per connection and closes it
without `Connection: close`; send that header yourself. Sockets are
inheritable on Windows: a process spawned meanwhile (the debuggee!) keeps a
copy, the client never sees FIN, reuses the connection and hangs. Mark sockets
non-inheritable (`SetHandleInformation(…, HANDLE_FLAG_INHERIT, 0)` /
`FD_CLOEXEC`) in `OnAllowConnect`.

---

## Form designer API (property editors)

Set and read properties the way the Object Inspector does — through
`PropEdits` property editors — instead of raw RTTI:

```pascal
GlobalDesignHook.LookupRoot := Designer.LookupRoot;
GetPersistentProperties(Comp, tkAny, GlobalDesignHook, @AddEditor, nil);
// AddEditor(Prop: TPropertyEditor) receives ownership: free every editor.
Ed.GetName; Ed.GetValue; Ed.SetValue('alClient'); Ed.GetAttributes;
if paSubProperties in Ed.GetAttributes then Ed.GetProperties(@AddEditor);  // BorderSpacing.Around
Ed.GetValues(@AddString);   // allowed values when paValueList
```

This handles nested properties, sets/enums as text, component references by
name, events (`TMethodPropertyEditor.SetValue` creates the handler) and `Name`
(renames the field in the source).

- Designer for a unit: `LazarusIDE.GetDesignerForProjectEditor(SrcEdit, True)`.
- After `FormEditingHook.CreateComponent`, call
  `GlobalDesignHook.PersistentAdded(NewComp, False)` like a palette drop —
  otherwise the unit is not added to `uses` and the package dependency is not added.
- Delete: select through the hook first (`GlobalDesignHook.SetSelection`),
  then `TComponentEditorDesigner(Designer).SelectOnlyThisComponent` +
  `DeleteSelection`. With only the designer call the selection may belong to
  another form and `DeleteSelection` silently does nothing.
- LFM text of the live designer state: `CreateLRSWriter` +
  `Writer.WriteDescendent(Root, nil)` + `LRSObjectBinaryToText`; resolve
  designer methods in `OnWriteMethodProperty` via `GlobalDesignHook.GetMethodName`.

---

## Common Lazarus Gotchas

- **No `TForm.Create(Application)` needed** — Lazarus auto-creates forms listed in Project Options unless you remove them.
- **`TStringList.Sorted`** — setting `Sorted := True` does not sort existing items; use `Sort` explicitly after loading.
- **Unicode**: LCL uses UTF-8 strings internally (not UTF-16). `UTF8Length`, `UTF8Copy` for correct multi-byte ops.
- **`TCanvas.TextWidth/TextHeight`** — may be off on HiDPI; use `TCanvas.TextExtent` for both dims at once.
- **Signals vs events on Linux**: use `fpSetSignalHandler` via `BaseUnix`; `Application.OnException` for unhandled exceptions.
- **`{$IFDEF WINDOWS}`** (not `WIN32`) for Windows-specific code on 64-bit.
- **LCL thread safety**: all GUI calls must happen on the main thread. Use `TThread.Synchronize` or `Application.QueueAsyncCall`.
- **`TThread.Synchronize` + async callbacks**: never do work (ProcessMessages, ProcessAsyncCallQueue, Sleep) *inside* a Synchronize callback — it blocks the main thread's event loop and prevents `Application.QueueAsyncCall` callbacks from being delivered. Pattern: one Synchronize call that starts the async op and returns immediately; worker thread polls the result field with `Sleep`. See `InitCallStack`/`ReadCallStack` in `McpToolsDebugger.pas`.
- **`TFrame`** is the recommended code-reuse unit for composite UI, not `TPanel` subclasses.

---

