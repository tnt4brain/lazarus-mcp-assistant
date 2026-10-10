(
  '# Lazarus / FreePascal — Developer Reference' + LineEnding +
  '' + LineEnding +
  'This document is injected as context when Claude Code is launched from within the Lazarus IDE.' + LineEnding +
  'It covers idioms, component libraries, and gotchas specific to this ecosystem.' + LineEnding +
  '' + LineEnding +
  '---' + LineEnding +
  '' + LineEnding +
  '## Language & Compiler' + LineEnding +
  '' + LineEnding +
  '- Compiler: **Free Pascal (FPC)** with `{$mode objfpc}{$H+}` — not Delphi dialect unless `{$mode delphi}`.' + LineEnding +
  '- String type: `AnsiString` by default with `{$H+}`. Use `string` everywhere; `ShortString` only for fixed-size buffers.' + LineEnding +
  '- `SizeOf(Pointer)` = 8 on x86_64-win64. Avoid `Integer` for pointer math; use `NativeInt`/`NativeUInt`.' + LineEnding +
  '- FPC generics use `specialize` keyword: `specialize TList<TFoo>`.' + LineEnding +
  '- Operator overloading and anonymous methods available from FPC 3.x.' + LineEnding +
  '- `{$ifdef FPC}` / `{$ifdef LAZARUS}` to guard FPC-specific code.' + LineEnding +
  '- Initialization order is per-unit `initialization`/`finalization` sections, not constructors — don''t rely on cross-unit order.' + LineEnding +
  '' + LineEnding +
  '## LCL (Lazarus Component Library)' + LineEnding +
  '' + LineEnding +
  '- Cross-platform VCL equivalent. Use `LCLIntf`, `LCLType` for Win32 API calls.' + LineEnding +
  '- Message system: `TLMessage`, `LM_*` constants (not `WM_*`).' + LineEnding +
  '- `TControl.GetClientRect` is the safe rect — `Width`/`Height` may lag during resize.' + LineEnding +
  '- `Application.ProcessMessages` pumps the LCL message loop (same role as Delphi''s).' + LineEnding +
  '- `TWinControl.Color` defaults to `clBtnFace` (theme-dependent) not white.' + LineEnding +
  '- Form files: `.lfm` (Lazarus) not `.dfm`. Text format; safe to hand-edit.' + LineEnding +
  '- `RegisterComponent` in a `Register` procedure inside the unit — called at design time.' + LineEnding +
  '' + LineEnding +
  '## Packages' + LineEnding +
  '' + LineEnding +
  '- Package files: `.lpk` (XML). Runtime vs design-time pair common for component packages.' + LineEnding +
  '- Install via: `Package → Open Package File (.lpk)` → `Use → Install` → IDE rebuilds.' + LineEnding +
  '- `lazbuild <pkg.lpk>` compiles without the IDE (CI-friendly).' + LineEnding +
  '- `PackageEditingInterface.FindPackageWithName(name)` — query installed packages at runtime.' + LineEnding +
  '' + LineEnding +
  '## Key Component Libraries (FPC/Lazarus compatible)' + LineEnding +
  '' + LineEnding +
  '### BGRABitmap' + LineEnding +
  '- **What**: Advanced 2D drawing library. Foundation for many skinned component packs.' + LineEnding +
  '- **Install**: Lazarus Online Package Manager (`Tools → Online Package Manager`).' + LineEnding +
  '- **Key units**: `BGRABitmap`, `BGRACanvas2D`, `BGRAGradients`.' + LineEnding +
  '- **Required by**: TyControls, CyberUI.' + LineEnding +
  '' + LineEnding +
  '### TyControls' + LineEnding +
  '- **Repo**: https://github.com/ACTom/TyControls' + LineEnding +
  '- **What**: 169 fully custom-drawn components via BGRABitmap. CSS-style `.tycss` theme files. Consistent cross-platform rendering (Windows/Linux/macOS). Includes: text inputs, grids, tree views, ribbons, charts, icon fonts (Lucide), tab controls, menus.' + LineEnding +
  '- **Install**: `tycontrols_dt.lpk` (design-time; pulls in `tycontrols.lpk` runtime).' + LineEnding +
  '- **Theming**: Drop a `TTyStyleController` on the form; set `StyleFile` to a `.tycss` path.' + LineEnding +
  '' + LineEnding +
  '### OnurComp' + LineEnding +
  '- **Repo**: https://github.com/Onur2x/onurcomp' + LineEnding +
  '- **What**: 20+ BGRABitmap-based skinned controls for Lazarus. Buttons, knobs, LEDs, switches, page controls, progress/track bars, crop-shaped controls (bitmap-masked). Beta. Unlicense.' + LineEnding +
  '- **Install**: `onur.lpk`. Requires BGRABitmap.' + LineEnding +
  '' + LineEnding +
  '### CyberUI' + LineEnding +
  '- **Repo**: https://github.com/CodeInPas/CyberUI-Component' + LineEnding +
  '- **What**: 18 cyberpunk-themed components (BGRABitmap). Radar scanners, hex grids, waveform displays, 7-segment labels, rotary knobs, glitch labels. Good for dashboards and HMI.' + LineEnding +
  '- **Install**: `cyberui.lpk` in `src/` folder. Requires BGRABitmap.' + LineEnding +
  '' + LineEnding +
  '### TWLazUI' + LineEnding +
  '- **Repo**: https://github.com/CodeInPas/TWLazUI' + LineEnding +
  '- **What**: ~27 Tailwind CSS-inspired modern UI components (BGRABitmap). Buttons, panels, cards, text fields, checkboxes, switches, combo/list boxes, badges, avatars, data tables, line charts, tabs, breadcrumbs, accordions, steppers, progress bars, spinners, alerts, toasts, tooltips, modals. Smooth anti-aliasing, rounded corners, alpha transparency, drop shadows.' + LineEnding +
  '- **Themes**: Primary/Secondary/Success/Danger colors, corner styles, Outline/Solid/Pills variants — all via Object Inspector.' + LineEnding +
  '- **Install**: `twlazui_components.lpk`. Requires BGRABitmap. Lazarus 2.2+.' + LineEnding +
  '' + LineEnding +
  '### CPUView' + LineEnding +
  '- **Repo**: https://github.com/AlexanderBagel/CPUView' + LineEnding +
  '- **What**: Advanced CPU debugger UI for Lazarus. Adds a dockable window (View→Debug Windows→CPU-View, Ctrl+Shift+C) with disassembly, CPU registers, memory dump, call stack, trace log, exports, memory map, and PDB symbol manager. Runs on top of FpDebug — no new debugger engine, pure UI layer.' + LineEnding +
  '- **Platforms**: Windows x86_64, Linux x86_64, Linux AArch64. GTK2 and Qt5 widgetsets.' + LineEnding +
  '- **Install**: compile FWHexView first, then `CPUView_win_x86_64_D.lpk` (or platform equivalent). Requires stable Lazarus 3.x. MIT license.' + LineEnding +
  '- **Note**: purely a visual tool — no external API. Debugger state queries go through FpDebug/IdeDebugger interfaces, not CPUView.' + LineEnding +
  '' + LineEnding +
  '### Floria Toolkit (ft)' + LineEnding +
  '- **Repo**: https://github.com/kiranaproject/ft' + LineEnding +
  '- **What**: Standalone native GUI framework (AGG subpixel rendering, CSS theming, 60 fps). Builds as a shared C ABI library (`libft.so`/`.dll`). **Not an LCL component pack** — requires separate integration. Not drop-in with existing LCL forms.' + LineEnding +
  '' + LineEnding +
  '### VirtualTreeView (Lazarus port)' + LineEnding +
  '- **Repo**: https://github.com/blikblum/VirtualTreeView-Lazarus' + LineEnding +
  '- **What**: Highly flexible virtual (callback-based) tree/list/grid. Used in RAD Studio''s own IDE UI. Virtual = no data storage in nodes; you supply data in callbacks.' + LineEnding +
  '- **Key classes**: `TVirtualStringTree`, `TVirtualDrawTree`.' + LineEnding +
  '- **FPC port**: maintained, works on Windows/Linux.' + LineEnding +
  '' + LineEnding +
  '### ATSynEdit' + LineEnding +
  '- **Repo**: https://github.com/Alexey-T/ATSynEdit' + LineEnding +
  '- **What**: Multi-line syntax-highlighting editor for Lazarus. Code folding, multiple carets, minimap. Used in CudaText editor.' + LineEnding +
  '- **FPC-native**, actively maintained.' + LineEnding +
  '' + LineEnding +
  '### HtmlViewer' + LineEnding +
  '- **Repo**: https://github.com/BerndGabriel/HtmlViewer' + LineEnding +
  '- **What**: HTML/CSS renderer component for Delphi/Lazarus. Supports majority of HTML tags, inline styles, CSS. `TFrameViewer` for framesets.' + LineEnding +
  '' + LineEnding +
  '### BGRAControls' + LineEnding +
  '- **Repo**: https://github.com/bgrabitmap/bgracontrols' + LineEnding +
  '- **What**: 40+ styled/custom-drawn LCL components on BGRABitmap. Buttons (including Material Design + SVG), panels, progress bars, radial gauges, knobs, SVG viewer, image manipulation. Dark-themed variants of standard controls.' + LineEnding +
  '- **Install**: `bgracontrols.lpk`. Requires BGRABitmap (`bgrabitmappack.lpk`).' + LineEnding +
  '' + LineEnding +
  '### ATFlatControls' + LineEnding +
  '- **Repo**: https://github.com/alexey-t/atflatcontrols' + LineEnding +
  '- **What**: Cross-platform flat custom-drawn controls from CudaText. ATTabs, ATGroups (tab sets), ATButton, ATFlatToolbar, ATListbox, ATScrollbar, ATStatusbar, ATGauge, ATLinkLabel, ATPanelSimple/Color. No external dependencies.' + LineEnding +
  '- **Note**: Companion to ATSynEdit (same author). Install package is inside the `atflatcontrols/` folder.' + LineEnding +
  '' + LineEnding +
  '### KControls' + LineEnding +
  '- **Repo**: https://github.com/kryslt/KControls' + LineEnding +
  '- **What**: Cross-IDE (VCL + LCL) control set. Standout: `TKGrid` (full-featured grid with inplace editors, DB-aware `TKDBGrid`), hex editor, print preview.' + LineEnding +
  '' + LineEnding +
  '### CEF4Delphi / WebView4Delphi' + LineEnding +
  '- **CEF4Delphi**: https://github.com/salvadordf/CEF4Delphi — embed Chromium in LCL apps.' + LineEnding +
  '- **WebView4Delphi**: https://github.com/salvadordf/WebView4Delphi — embed WebView2 (Windows, lighter than CEF).' + LineEnding +
  '' + LineEnding +
  '### JPPack' + LineEnding +
  '- **Repo**: https://github.com/jackdp/JPPack' + LineEnding +
  '- **What**: Mixed VCL/LCL collection — buttons, panels, `LinkLabel`, `ProgressBar`, `ColorComboBox`, `ColorListBox`, timer. Actively maintained for both Delphi and Lazarus.' + LineEnding +
  '' + LineEnding +
  '### TeeGrid' + LineEnding +
  '- **Repo**: https://github.com/Steema/TeeGrid' + LineEnding +
  '- **What**: Lightweight grid/tabular control. Supports Lazarus on Windows and Linux. No DB dependency in core.' + LineEnding +
  '' + LineEnding +
  '### Dam (Dialogs)' + LineEnding +
  '- **Repo**: https://github.com/digao-dalpiaz/Dam' + LineEnding +
  '- **What**: Delphi + Lazarus message dialogs with formatted text. Replaces `ShowMessage`/`MessageDlg` with richer markup.' + LineEnding +
  '' + LineEnding +
  '---' + LineEnding +
  '' + LineEnding +
  '## Project Management API (IDEIntf)' + LineEnding +
  '' + LineEnding +
  'All identifiers live in `IDEIntf`/`BuildIntf` units unless noted. All IDE API' + LineEnding +
  'calls must run on the main thread — use `TThread.Synchronize` from worker threads.' + LineEnding +
  '' + LineEnding +
  '### Active project — `TLazProject` (`ProjectIntf`)' + LineEnding +
  '' + LineEnding +
  '```pascal' + LineEnding +
  'uses LazIDEIntf, ProjectIntf;' + LineEnding +
  '' + LineEnding +
  'Proj := LazarusIDE.ActiveProject;   // TLazProject; nil when no project open' + LineEnding +
  'LpiPath := Proj.ProjectInfoFile;    // absolute path to the .lpi file' + LineEnding +
  'ProjDir := ExtractFilePath(LpiPath);' + LineEnding +
  '```' + LineEnding +
  '' + LineEnding +
  '#### Adding / removing files' + LineEnding +
  '' + LineEnding +
  '```pascal' + LineEnding +
  'uses LazIDEIntf, ProjectIntf;' + LineEnding +
  '' + LineEnding +
  '// Add a file: two-step — CreateProjectFile then AddFile' + LineEnding +
  'var PF: TLazProjectFile;' + LineEnding +
  'PF := Proj.CreateProjectFile(AbsFilename);   // creates a TLazProjectFile object' + LineEnding +
  'Proj.AddFile(PF, False);                     // False = don''t touch uses clause' + LineEnding +
  'LazarusIDE.DoSaveProject([]);                // persist to .lpi' + LineEnding +
  '' + LineEnding +
  '// Find a project file by absolute path (pfsfOnlyProjectFiles restricts to project)' + LineEnding +
  'PF := Proj.FindFile(AbsFilename, [pfsfOnlyProjectFiles]);' + LineEnding +
  '' + LineEnding +
  '// Remove: FindFile then loop to get the 0-based index RemoveUnit needs' + LineEnding +
  'var I: Integer;' + LineEnding +
  'for I := 0 to Proj.FileCount - 1 do' + LineEnding +
  '  if Proj.Files[I].Filename = AbsFilename then' + LineEnding +
  '  begin' + LineEnding +
  '    Proj.RemoveUnit(I);   // removes from project; does NOT delete disk file' + LineEnding +
  '    Break;' + LineEnding +
  '  end;' + LineEnding +
  'LazarusIDE.DoSaveProject([]);' + LineEnding +
  '```' + LineEnding +
  '' + LineEnding +
  '- `TProjectFileSearchFlags` values: `pfsfResolveFileLinks`, `pfsfOnlyEditorFiles`,' + LineEnding +
  '  `pfsfOnlyVirtualFiles`, `pfsfOnlyProjectFiles`.  There is no `pfsfFullPathSearched`.' + LineEnding +
  '- `TLazProjectFile` has no `UnitIndex` property — iterate `Proj.Files[]` to find' + LineEnding +
  '  the index for `RemoveUnit`.' + LineEnding +
  '- `Proj.Files[I].IsPartOfProject` — true for files that compile with the project.' + LineEnding +
  '' + LineEnding +
  '#### Compiler options — `TLazCompilerOptions` (`CompOptsIntf`)' + LineEnding +
  '' + LineEnding +
  '```pascal' + LineEnding +
  'var Opts: TLazCompilerOptions;' + LineEnding +
  'Opts := Proj.LazCompilerOptions;' + LineEnding +
  '' + LineEnding +
  'Opts.TargetOS            := ''win64'';     // '''' = host OS' + LineEnding +
  'Opts.TargetCPU           := ''x86_64'';   // '''' = host CPU' + LineEnding +
  'Opts.UnitOutputDirectory := ''lib/$(TargetOS)-$(TargetCPU)'';  // macros OK' + LineEnding +
  'Opts.CustomOptions       := ''-dMY_FLAG''; // replaces the whole string' + LineEnding +
  '' + LineEnding +
  'LazarusIDE.DoSaveProject([]);   // flush to .lpi' + LineEnding +
  '```' + LineEnding +
  '' + LineEnding +
  '- **`CustomOptions` uses replace semantics.** Read with `get_project_settings` first' + LineEnding +
  '  if you want to preserve existing flags; set the full resulting string.' + LineEnding +
  '- Macro syntax: `$(TargetOS)`, `$(TargetCPU)`, `$(ProjOutDir)` expanded at build time.' + LineEnding +
  '' + LineEnding +
  '#### Run parameters — `TAbstractRunParamsOptions` (`ProjectIntf`)' + LineEnding +
  '' + LineEnding +
  '```pascal' + LineEnding +
  '// Get or create the ''default'' run mode, set args, then run' + LineEnding +
  'Proj.RunParameters.GetOrCreate(''default'').CmdLineParams := ''--verbose input.txt'';' + LineEnding +
  '// No save needed before DoRunProjectWithoutDebug' + LineEnding +
  'LazarusIDE.DoRunProjectWithoutDebug;' + LineEnding +
  '```' + LineEnding +
  '' + LineEnding +
  '- `TLazProject.RunParameters` → `TAbstractRunParamsOptions` (declared in `ProjectIntf`).' + LineEnding +
  '- `GetOrCreate(Name)` → `TAbstractRunParamsOptionsMode`; the default mode is named' + LineEnding +
  '  `''default''`.' + LineEnding +
  '- `CmdLineParams: string` — passed verbatim to the spawned process.' + LineEnding +
  '' + LineEnding +
  '### Opening files — `DoOpenEditorFile` (`LazIDEIntf`)' + LineEnding +
  '' + LineEnding +
  '```pascal' + LineEnding +
  'uses LazIDEIntf, SrcEditorIntf;' + LineEnding +
  '' + LineEnding +
  '// DoOpenEditorFile returns TModalResult (mrOK on success, mrCancel if not found)' + LineEnding +
  'var Res: TModalResult;' + LineEnding +
  'Res := LazarusIDE.DoOpenEditorFile(' + LineEnding +
  '  AbsFilename,' + LineEnding +
  '  -1, -1,                          // page / window: -1 = IDE decides' + LineEnding +
  '  [ofOnlyIfExists, ofRegularFile]' + LineEnding +
  ');' + LineEnding +
  '// mrOK = opened; mrCancel/mrAbort = not found (with ofOnlyIfExists)' + LineEnding +
  '' + LineEnding +
  '// Check if already open (before opening):' + LineEnding +
  'SourceEditorManagerIntf.SourceEditorIntfWithFilename(AbsFilename) <> nil' + LineEnding +
  '```' + LineEnding +
  '' + LineEnding +
  '**`TOpenFlag` values** (from `LazIDEIntf`):' + LineEnding +
  '' + LineEnding +
  '| Flag | Effect |' + LineEnding +
  '|------|--------|' + LineEnding +
  '| `ofOnlyIfExists` | Do not create; return mrCancel if not found |' + LineEnding +
  '| `ofRegularFile` | Treat as a normal source file, not a project/package |' + LineEnding +
  '| `ofAddToRecent` | Add to File → Recent Files |' + LineEnding +
  '| `ofQuiet` | Suppress error dialogs |' + LineEnding +
  '| `ofRevert` | Reload from disk even if already open |' + LineEnding +
  '| `ofDoNotLoadResource` | Open `.pas` without loading paired `.lfm` |' + LineEnding +
  '' + LineEnding +
  '### Creating forms — `FileDescriptorForm` (`ProjectIntf`)' + LineEnding +
  '' + LineEnding +
  '```pascal' + LineEnding +
  'uses LazIDEIntf, ProjectIntf;' + LineEnding +
  '' + LineEnding +
  '// FileDescriptorForm() is a function (not a global var) from ProjectIntf' + LineEnding +
  '// Creates <path>.pas + <path>.lfm and adds both to the project' + LineEnding +
  'LazarusIDE.DoNewEditorFile(' + LineEnding +
  '  FileDescriptorForm,              // TProjectFileDescriptor from ProjectIntf' + LineEnding +
  '  ''/path/to/UnitFoo.pas'',          // suggested .pas path' + LineEnding +
  '  '''',                              // source: '''' = descriptor generates default' + LineEnding +
  '  [nfIsPartOfProject, nfOpenInEditor, nfSave]' + LineEnding +
  ');' + LineEnding +
  '```' + LineEnding +
  '' + LineEnding +
  '**`TNewFlag` values** (from `LazIDEIntf`):' + LineEnding +
  '' + LineEnding +
  '| Flag | Effect |' + LineEnding +
  '|------|--------|' + LineEnding +
  '| `nfIsPartOfProject` | Mark as project file |' + LineEnding +
  '| `nfOpenInEditor` | Open in editor after creation |' + LineEnding +
  '| `nfSave` | Save files immediately |' + LineEnding +
  '| `nfAddToRecent` | Add to File → Recent Files |' + LineEnding +
  '' + LineEnding +
  '- The form class name is auto-generated by the descriptor (e.g. `TForm1`).' + LineEnding +
  '  Rename afterwards with `edit_text`.' + LineEnding +
  '- `DoNewEditorFile` returns `TModalResult` (mrOK on success).' + LineEnding +
  '' + LineEnding +
  '### Creating a new project — `DoNewProject` (`LazIDEIntf`, `ProjectIntf`)' + LineEnding +
  '' + LineEnding +
  '```pascal' + LineEnding +
  'uses LazIDEIntf, ProjectIntf, LazFileUtils;' + LineEnding +
  '' + LineEnding +
  '// Available descriptor names (constants in ProjectIntf):' + LineEnding +
  '//   ProjDescNameApplication      = ''Application''        (GUI app + Form1)' + LineEnding +
  '//   ProjDescNameSimpleProgram     = ''Simple Program''' + LineEnding +
  '//   ProjDescNameProgram           = ''Program''' + LineEnding +
  '//   ProjDescNameConsoleApplication = ''Console application''' + LineEnding +
  '//   ProjDescNameLibrary           = ''Library''' + LineEnding +
  '//   ProjDescNameCustomProgram     = ''Custom Program''' + LineEnding +
  '//   ProjDescNameEmpty             = ''Empty''' + LineEnding +
  '' + LineEnding +
  'var' + LineEnding +
  '  Desc : TProjectDescriptor;' + LineEnding +
  '  Proj : TLazProject;' + LineEnding +
  'begin' + LineEnding +
  '  // 1. Pick the descriptor (use the helper functions or FindByName)' + LineEnding +
  '  Desc := ProjectDescriptorApplication;          // for a GUI app' + LineEnding +
  '  // or: Desc := ProjectDescriptors.FindByName(ProjDescNameConsoleApplication);' + LineEnding +
  '' + LineEnding +
  '  // 2. Create the target directory if needed' + LineEnding +
  '  ForceDirectories(''/path/to/myproject'');' + LineEnding +
  '' + LineEnding +
  '  // 3. Create the project — closes the current project first' + LineEnding +
  '  //    None of the built-in descriptors override DoInitDescriptor,' + LineEnding +
  '  //    so no dialog is shown.  CreateStartFiles for Application creates Form1.' + LineEnding +
  '  if LazarusIDE.DoNewProject(Desc) <> mrOK then' + LineEnding +
  '    Exit;  // user cancelled or error' + LineEnding +
  '' + LineEnding +
  '  // 4. Set the .lpi path and save' + LineEnding +
  '  Proj := LazarusIDE.ActiveProject;' + LineEnding +
  '  Proj.ProjectInfoFile := ''/path/to/myproject/MyApp.lpi'';' + LineEnding +
  '  Proj.Title := ''MyApp'';                         // optional; shown in title bar' + LineEnding +
  '  LazarusIDE.DoSaveProject([]);                  // writes .lpi to the path set above' + LineEnding +
  'end;' + LineEnding +
  '```' + LineEnding +
  '' + LineEnding +
  '**Key points:**' + LineEnding +
  '- `DoNewProject` closes the current open project first; unsaved changes are lost unless' + LineEnding +
  '  you call `DoSaveAll([])` beforehand.' + LineEnding +
  '- Setting `Proj.ProjectInfoFile` before `DoSaveProject` redirects the save without' + LineEnding +
  '  triggering a "Save As…" dialog.' + LineEnding +
  '- The descriptor''s `CreateStartFiles` may open new editor tabs (e.g. Form1 for' + LineEnding +
  '  `Application`). This is normal and expected.' + LineEnding +
  '- `ProjectDescriptorApplication` / `ProjectDescriptorConsoleApplication` etc. are' + LineEnding +
  '  convenience functions calling `ProjectDescriptors.FindByName(...)`.' + LineEnding +
  '- Returns `mrOK` on success; `mrCancel` / `mrAbort` on failure.' + LineEnding +
  '' + LineEnding +
  '### Component palette — `IDEComponentPalette` (`ComponentReg`)' + LineEnding +
  '' + LineEnding +
  '```pascal' + LineEnding +
  'uses ComponentReg;  // TBaseComponentPalette, TRegisteredComponent, TBaseComponentPage' + LineEnding +
  '' + LineEnding +
  'var' + LineEnding +
  '  Comp : TRegisteredComponent;' + LineEnding +
  '  I    : Integer;' + LineEnding +
  'begin' + LineEnding +
  '  // IDEComponentPalette.Comps is a flat TRegisteredCompList of all components' + LineEnding +
  '  for I := 0 to IDEComponentPalette.Comps.Count - 1 do' + LineEnding +
  '  begin' + LineEnding +
  '    Comp := IDEComponentPalette.Comps[I];' + LineEnding +
  '    // Comp.ComponentClass.ClassName — e.g. ''TChart''' + LineEnding +
  '    // Comp.GetUnitName              — unit where the component is defined' + LineEnding +
  '    // Comp.OrigPageName             — palette tab name, e.g. ''Chart''' + LineEnding +
  '    // Comp.RealPage.PageName        — same as OrigPageName if not reordered' + LineEnding +
  '  end;' + LineEnding +
  'end;' + LineEnding +
  '```' + LineEnding +
  '' + LineEnding +
  '- `IDEComponentPalette: TBaseComponentPalette` — global, declared in `ComponentReg`,' + LineEnding +
  '  assigned by the IDE at startup.' + LineEnding +
  '- Iterate `.Comps` (flat list) for searching; iterate `.Pages` for page-by-page' + LineEnding +
  '  display.' + LineEnding +
  '- There is **no `OriginPackage`** property on `TRegisteredComponent`.  Package' + LineEnding +
  '  membership is not directly accessible via IDEIntf.' + LineEnding +
  '- `RealPage` may be nil for components not yet placed on a palette page.' + LineEnding +
  '' + LineEnding +
  '### IDE Messages window — `IDEMessagesWindow` (`IDEMsgIntf`)' + LineEnding +
  '' + LineEnding +
  '```pascal' + LineEnding +
  'uses IDEMsgIntf, IDEExternToolIntf;' + LineEnding +
  '' + LineEnding +
  '// IDEMessagesWindow exposes Views (build output, tools, etc.)' + LineEnding +
  '// Each TExtToolView has a TMessageLines Lines property' + LineEnding +
  'var' + LineEnding +
  '  View    : TExtToolView;' + LineEnding +
  '  MsgLine : TMessageLine;' + LineEnding +
  '  I, J    : Integer;' + LineEnding +
  'begin' + LineEnding +
  '  if not Assigned(IDEMessagesWindow) then Exit;' + LineEnding +
  '  for I := 0 to IDEMessagesWindow.ViewCount - 1 do' + LineEnding +
  '  begin' + LineEnding +
  '    View := IDEMessagesWindow.Views[I];' + LineEnding +
  '    for J := 0 to View.Lines.Count - 1 do' + LineEnding +
  '    begin' + LineEnding +
  '      MsgLine := View.Lines.Items[J];' + LineEnding +
  '      // MsgLine.Msg       — message text' + LineEnding +
  '      // MsgLine.Urgency   — TMessageLineUrgency:' + LineEnding +
  '      //   mluNone, mluProgress, mluDebug, mluVerbose, mluHint, mluNote,' + LineEnding +
  '      //   mluWarning, mluImportant, mluError, mluFatal, mluPanic' + LineEnding +
  '      // MsgLine.Filename  — source file (may be '''')' + LineEnding +
  '      // MsgLine.Line      — source line (0 if not applicable)' + LineEnding +
  '      // MessageLineUrgencyNames[MsgLine.Urgency] — string form of urgency' + LineEnding +
  '    end;' + LineEnding +
  '  end;' + LineEnding +
  'end;' + LineEnding +
  '```' + LineEnding +
  '' + LineEnding +
  '- `IDEMessagesWindow: TIDEMessagesWindowInterface` (from `IDEMsgIntf`).' + LineEnding +
  '- `IDEMessagesWindow` has no `LinesCount`/`Lines[]` directly — messages are' + LineEnding +
  '  accessed through `Views[i]: TExtToolView` and then `View.Lines`.' + LineEnding +
  '- `TExtToolView` and `TMessageLine` are from `IDEExternToolIntf` (BuildIntf).' + LineEnding +
  '- `mluHint` and `mluNote` are dropped by `get_compiler_errors` — `get_messages`' + LineEnding +
  '  returns all urgency levels.' + LineEnding +
  '- The window is cleared at the start of each build; call after build completes.' + LineEnding +
  '' + LineEnding +
  '---' + LineEnding +
  '' + LineEnding +
  '## Debugger API (FpDebug / DebugBoss)' + LineEnding +
  '' + LineEnding +
  'All identifiers live in `IdeDebuggerIntf`, `Debugger`, `DebuggerIntf`, `IdeDebuggerWatchResult` unless noted.' + LineEnding +
  'All debugger API calls **must** run on the main thread — use `TThread.Synchronize`.' + LineEnding +
  '' + LineEnding +
  '### State and control — `TDebugManager` (`Debugger` unit)' + LineEnding +
  '' + LineEnding +
  '```pascal' + LineEnding +
  'uses Debugger, IdeDebuggerIntf;' + LineEnding +
  '' + LineEnding +
  '// Global — valid after IDE startup' + LineEnding +
  'DebugBoss : TDebugManager;' + LineEnding +
  '' + LineEnding +
  '// Debugger state' + LineEnding +
  'TDBGState = (dsNone, dsIdle, dsStop, dsPause, dsInit, dsRun, dsError, dsDestroying);' + LineEnding +
  'DebugBoss.State : TDBGState;' + LineEnding +
  '' + LineEnding +
  '// Run control (main thread only)' + LineEnding +
  'DebugBoss.RunDebugger;         // F9 — start or continue' + LineEnding +
  'DebugBoss.DoPauseProject;      // pause running session' + LineEnding +
  'DebugBoss.DoStopProject;       // terminate session (async)' + LineEnding +
  'DebugBoss.DoStepOverProject;   // F8' + LineEnding +
  'DebugBoss.DoStepIntoProject;   // F7' + LineEnding +
  'DebugBoss.DoStepOutProject;    // Shift+F8' + LineEnding +
  '```' + LineEnding +
  '' + LineEnding +
  '`DebugBoss.OnState` callback fires on every state transition (main thread).' + LineEnding +
  '`DebugBoss.OnCurrent` fires when the current source line changes after a step or breakpoint.' + LineEnding +
  '' + LineEnding +
  '### Breakpoints — `TIDEBreakPoints`' + LineEnding +
  '' + LineEnding +
  '```pascal' + LineEnding +
  '// Add' + LineEnding +
  'BP := DebugBoss.BreakPoints.Add(AbsFilePath, Line);   // TIDEBreakPoint' + LineEnding +
  '' + LineEnding +
  '// Remove — iterate to find by source+line' + LineEnding +
  'for I := DebugBoss.BreakPoints.Count - 1 downto 0 do' + LineEnding +
  'begin' + LineEnding +
  '  BP := DebugBoss.BreakPoints.Items[I];' + LineEnding +
  '  if (BP.Source = AbsFilePath) and (BP.Line = Line) then' + LineEnding +
  '  begin' + LineEnding +
  '    BP.ReleaseReference;   // frees the object' + LineEnding +
  '    Break;' + LineEnding +
  '  end;' + LineEnding +
  'end;' + LineEnding +
  '' + LineEnding +
  '// Enumerate' + LineEnding +
  'for I := 0 to DebugBoss.BreakPoints.Count - 1 do' + LineEnding +
  '  BP := DebugBoss.BreakPoints.Items[I];' + LineEnding +
  '  // BP.Source, BP.Line, BP.Enabled, BP.Valid, BP.HitCount' + LineEnding +
  '```' + LineEnding +
  '' + LineEnding +
  '### Call stack — `TIdeCallStack` (async load)' + LineEnding +
  '' + LineEnding +
  '```pascal' + LineEnding +
  'uses IdeDebuggerIntf;' + LineEnding +
  '' + LineEnding +
  '// Must be called on main thread; returns nil if not paused' + LineEnding +
  'Stack := TIdeCallStack(DebugBoss.CallStack.EntriesForRange(0, MaxFrames - 1, ThreadId));' + LineEnding +
  '' + LineEnding +
  '// CountValidity: dcvUnknown until async load completes; dcvValid when ready' + LineEnding +
  'Stack.CountLimited(MaxFrames);   // trigger async load' + LineEnding +
  '// Poll: repeat Synchronize(@ReadCallStack) until Stack.CountValidity = dcvValid' + LineEnding +
  '' + LineEnding +
  '// Per frame (TIdeCallStackEntry):' + LineEnding +
  'Frame := TIdeCallStackEntry(Stack.Entries[I]);' + LineEnding +
  'Frame.Source; Frame.Line; Frame.FunctionName; Frame.Address' + LineEnding +
  '```' + LineEnding +
  '' + LineEnding +
  '### Locals — `TIDELocals` (async load)' + LineEnding +
  '' + LineEnding +
  '```pascal' + LineEnding +
  '// Get locals for a thread+frame on main thread' + LineEnding +
  'Locals := TIDELocals(DebugBoss.Locals.Entries[ThreadId, FrameIndex]);' + LineEnding +
  'Locals.Count;   // trigger async load (may return 0 while loading)' + LineEnding +
  '// Poll until Locals.Count > 0 or a validity field flips' + LineEnding +
  '' + LineEnding +
  '// Per entry (TIdeLocalsValue):' + LineEnding +
  'LVal := TIdeLocalsValue(Locals.Entries[I]);' + LineEnding +
  'LVal.Name; LVal.Value' + LineEnding +
  '```' + LineEnding +
  '' + LineEnding +
  '### Evaluate expression — `DebugBoss.Evaluate` (async callback)' + LineEnding +
  '' + LineEnding +
  '```pascal' + LineEnding +
  '// Returns True if evaluation started; callback fires on main thread' + LineEnding +
  'OutStarted := DebugBoss.Evaluate(ExprStr, @MyCallback);' + LineEnding +
  '' + LineEnding +
  'procedure MyCallback(Sender: TObject; ASuccess: Boolean;' + LineEnding +
  '  ResultText: string; ResultDBGType: TDBGType);' + LineEnding +
  '// ResultDBGType.TypeName — may be nil for simple types' + LineEnding +
  '```' + LineEnding +
  '' + LineEnding +
  '**Critical threading rule**: call `DebugBoss.Evaluate` inside a `TThread.Synchronize` callback,' + LineEnding +
  'then return immediately. The callback fires via `Application.ProcessMessages` /' + LineEnding +
  '`ProcessAsyncCallQueue` on the main thread. Never `Sleep` or `ProcessMessages` inside the' + LineEnding +
  'Synchronize callback — that blocks the event loop and prevents the callback from being delivered.' + LineEnding +
  'The worker thread polls a flag set by the callback.' + LineEnding +
  '' + LineEnding +
  '---' + LineEnding +
  '' + LineEnding +
  '## Common Lazarus Gotchas' + LineEnding +
  '' + LineEnding +
  '- **No `TForm.Create(Application)` needed** — Lazarus auto-creates forms listed in Project Options unless you remove them.' + LineEnding +
  '- **`TStringList.Sorted`** — setting `Sorted := True` does not sort existing items; use `Sort` explicitly after loading.' + LineEnding +
  '- **Unicode**: LCL uses UTF-8 strings internally (not UTF-16). `UTF8Length`, `UTF8Copy` for correct multi-byte ops.' + LineEnding +
  '- **`TCanvas.TextWidth/TextHeight`** — may be off on HiDPI; use `TCanvas.TextExtent` for both dims at once.' + LineEnding +
  '- **Signals vs events on Linux**: use `fpSetSignalHandler` via `BaseUnix`; `Application.OnException` for unhandled exceptions.' + LineEnding +
  '- **`{$IFDEF WINDOWS}`** (not `WIN32`) for Windows-specific code on 64-bit.' + LineEnding +
  '- **LCL thread safety**: all GUI calls must happen on the main thread. Use `TThread.Synchronize` or `Application.QueueAsyncCall`.' + LineEnding +
  '- **`TThread.Synchronize` + async callbacks**: never do work (ProcessMessages, ProcessAsyncCallQueue, Sleep) *inside* a Synchronize callback — it blocks the main thread''s event loop and prevents `Application.QueueAsyncCall` callbacks from being delivered. Pattern: one Synchronize call that starts the async op and returns immediately; worker thread polls the result field with `Sleep`. See `get_call_stack` in `McpToolsDebugger.pas` for the canonical example.' + LineEnding +
  '- **`TFrame`** is the recommended code-reuse unit for composite UI, not `TPanel` subclasses.' + LineEnding +
  '' + LineEnding +
  '---' + LineEnding +
  '' + LineEnding
)
