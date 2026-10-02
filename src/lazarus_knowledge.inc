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
  '### CyberUI' + LineEnding +
  '- **Repo**: https://github.com/CodeInPas/CyberUI-Component' + LineEnding +
  '- **What**: 18 cyberpunk-themed components (BGRABitmap). Radar scanners, hex grids, waveform displays, 7-segment labels, rotary knobs, glitch labels. Good for dashboards and HMI.' + LineEnding +
  '- **Install**: `cyberui.lpk` in `src/` folder. Requires BGRABitmap.' + LineEnding +
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
  '## Common Lazarus Gotchas' + LineEnding +
  '' + LineEnding +
  '- **No `TForm.Create(Application)` needed** — Lazarus auto-creates forms listed in Project Options unless you remove them.' + LineEnding +
  '- **`TStringList.Sorted`** — setting `Sorted := True` does not sort existing items; use `Sort` explicitly after loading.' + LineEnding +
  '- **Unicode**: LCL uses UTF-8 strings internally (not UTF-16). `UTF8Length`, `UTF8Copy` for correct multi-byte ops.' + LineEnding +
  '- **`TCanvas.TextWidth/TextHeight`** — may be off on HiDPI; use `TCanvas.TextExtent` for both dims at once.' + LineEnding +
  '- **Signals vs events on Linux**: use `fpSetSignalHandler` via `BaseUnix`; `Application.OnException` for unhandled exceptions.' + LineEnding +
  '- **`{$IFDEF WINDOWS}`** (not `WIN32`) for Windows-specific code on 64-bit.' + LineEnding +
  '- **LCL thread safety**: all GUI calls must happen on the main thread. Use `TThread.Synchronize` or `Application.QueueAsyncCall`.' + LineEnding +
  '- **`TFrame`** is the recommended code-reuse unit for composite UI, not `TPanel` subclasses.' + LineEnding +
  '' + LineEnding +
  '---' + LineEnding +
  '' + LineEnding
)
