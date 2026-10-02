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

### CyberUI
- **Repo**: https://github.com/CodeInPas/CyberUI-Component
- **What**: 18 cyberpunk-themed components (BGRABitmap). Radar scanners, hex grids, waveform displays, 7-segment labels, rotary knobs, glitch labels. Good for dashboards and HMI.
- **Install**: `cyberui.lpk` in `src/` folder. Requires BGRABitmap.

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

## Common Lazarus Gotchas

- **No `TForm.Create(Application)` needed** — Lazarus auto-creates forms listed in Project Options unless you remove them.
- **`TStringList.Sorted`** — setting `Sorted := True` does not sort existing items; use `Sort` explicitly after loading.
- **Unicode**: LCL uses UTF-8 strings internally (not UTF-16). `UTF8Length`, `UTF8Copy` for correct multi-byte ops.
- **`TCanvas.TextWidth/TextHeight`** — may be off on HiDPI; use `TCanvas.TextExtent` for both dims at once.
- **Signals vs events on Linux**: use `fpSetSignalHandler` via `BaseUnix`; `Application.OnException` for unhandled exceptions.
- **`{$IFDEF WINDOWS}`** (not `WIN32`) for Windows-specific code on 64-bit.
- **LCL thread safety**: all GUI calls must happen on the main thread. Use `TThread.Synchronize` or `Application.QueueAsyncCall`.
- **`TFrame`** is the recommended code-reuse unit for composite UI, not `TPanel` subclasses.

---

