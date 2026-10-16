{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsPkgManage;

{ Package (.lpk) tools beyond editing a loaded package: package_get_info (by
  name or .lpk file), package_list, package_open, package_create,
  package_get_settings, package_set_settings, and the IDE-side half of
  package_compile.  A package is addressed per call, by package_name or
  lpk_path (see TargetPackage): the tools keep no "active package", because
  several clients can share one IDE.  Main thread. }

{$mode objfpc}{$H+}

interface

uses
  fpjson;

{ The Messages window's last compile as {errors, warnings} arrays of
  {file, line, column, message}; warnings are capped. }
procedure McpCompilerMessages(AErrors, AWarnings: TJSONArray);

implementation

uses
  Classes, SysUtils,
  LazIDEIntf, PackageIntf, MacroIntf, IDEMsgIntf, IDEExternToolIntf, SrcEditorIntf,
  LazFileUtils, FileUtil, Controls, Forms,
  PackageDependencyIntf, PackageDefs, PackageSystem, PackageLinks,
  McpToolContext, McpToolsPackages;

const
  MAX_WARNINGS = 50;
  MAX_LIST     = 200;

  PKG_TARGET =
    '"package_name":{"type":"string","description":"A package loaded in the IDE"},' +
    '"lpk_path":{"type":"string","description":"Or the .lpk file, loaded for this call ' +
      'without a package editor"}';

  SCHEMA_GET_INFO =
    '{"type":"object","properties":{' + PKG_TARGET + ',' +
    '"files":{"type":"boolean","description":"Include the package''s files (default false)"}}}';

  SCHEMA_LIST =
    '{"type":"object","properties":{' +
    '"name_contains":{"type":"string"},' +
    '"modified_only":{"type":"boolean","description":"Only packages with unsaved changes"},' +
    '"include_ide":{"type":"boolean","description":"Also the packages that come with ' +
      'Lazarus (default false: only others, e.g. yours and downloaded ones)"}}}';

  SCHEMA_OPEN =
    '{"type":"object","properties":{' +
    '"lpk_path":{"type":"string","description":"Absolute path of the .lpk"},' +
    '"editor":{"type":"boolean","description":"Also open its package editor window ' +
      '(default false)"}},"required":["lpk_path"]}';

  SCHEMA_CREATE =
    '{"type":"object","properties":{' +
    '"name":{"type":"string","description":"Package name, a Pascal identifier"},' +
    '"directory":{"type":"string","description":"Absolute directory; name.lpk is written there"},' +
    '"type":{"type":"string","description":"RunTime (default), DesignTime, ' +
      'RunAndDesignTime or RunTimeOnly"},' +
    '"requires":{"type":"array","items":{"type":"string"},"description":"Packages to ' +
      'require (default [\"FCL\"]); each must be loaded or known to the IDE"},' +
    '"version":{"type":"string","description":"major.minor[.release[.build]]"},' +
    '"description":{"type":"string"},"author":{"type":"string"},"license":{"type":"string"},' +
    '"unit_name":{"type":"string","description":"Also write this unit skeleton in the ' +
      'directory and list it in the package"}},' +
    '"required":["name","directory"]}';

  SCHEMA_GET_SETTINGS =
    '{"type":"object","properties":{' + PKG_TARGET + '}}';

  SCHEMA_SET_SETTINGS =
    '{"type":"object","properties":{' + PKG_TARGET + ',' +
    '"package_type":{"type":"string","description":"RunTime, DesignTime, ' +
      'RunAndDesignTime or RunTimeOnly"},' +
    '"unit_output_dir":{"type":"string"},' +
    '"unit_search_path":{"type":"string","description":"Other unit files, ;-separated, ' +
      'relative to the .lpk"},' +
    '"include_path":{"type":"string"},' +
    '"custom_options":{"type":"string","description":"Replaces the compiler options text"},' +
    '"target_os":{"type":"string"},"target_cpu":{"type":"string"},' +
    '"usage_unit_path":{"type":"string","description":"Unit path added to the projects ' +
      'that use the package"},' +
    '"usage_include_path":{"type":"string"}}}';

{ ── Messages ─────────────────────────────────────────────────────────────── }

procedure McpCompilerMessages(AErrors, AWarnings: TJSONArray);
var
  View : TExtToolView;
  Line : TMessageLine;
  I    : Integer;
  Obj  : TJSONObject;
begin
  if not Assigned(IDEMessagesWindow) or (IDEMessagesWindow.ViewCount = 0) then Exit;
  View := IDEMessagesWindow.Views[IDEMessagesWindow.ViewCount - 1];
  for I := 0 to View.Lines.Count - 1 do
  begin
    Line := View.Lines.Items[I];
    if Line.Urgency < mluWarning then Continue;
    if (Line.Urgency < mluError) and (AWarnings.Count >= MAX_WARNINGS) then Continue;
    Obj := TJSONObject.Create;
    Obj.Add('file',    Line.Filename);
    Obj.Add('line',    Line.Line);
    Obj.Add('column',  Line.Column);
    Obj.Add('message', Line.Msg);
    if Line.Urgency >= mluError then AErrors.Add(Obj) else AWarnings.Add(Obj);
  end;
end;

{ ── Helpers ──────────────────────────────────────────────────────────────── }

function XmlAttr(const S: string): string;
begin
  Result := StringReplace(StringReplace(StringReplace(StringReplace(S,
    '&', '&amp;', [rfReplaceAll]), '<', '&lt;', [rfReplaceAll]),
    '>', '&gt;', [rfReplaceAll]), '"', '&quot;', [rfReplaceAll]);
end;

{ Needs at least package_name or lpk_path. }
function HasTarget(AParams: TJSONObject): Boolean;
begin
  Result := Assigned(AParams) and
    ((Trim(AParams.Get('package_name', '')) <> '') or
     (Trim(AParams.Get('lpk_path', '')) <> ''));
end;

function TypeFromIdent(const S: string; out AType: TLazPackageType): Boolean;
var
  T : TLazPackageType;
begin
  Result := False;
  for T := Low(TLazPackageType) to High(TLazPackageType) do
    if SameText(S, LazPackageTypeIdents[T]) then
    begin
      AType := T; Result := True; Exit;
    end;
end;

function KnownToIDE(const AName: string): Boolean;
begin
  Result := (PackageGraph.FindPackageWithName(AName, nil) <> nil) or
            (LazPackageLinks.FindLinkWithPkgName(AName) <> nil);
end;

procedure AddSettings(APkg: TLazPackage; AObj: TJSONObject);
begin
  AObj.Add('package',            APkg.Name);
  AObj.Add('lpk',                APkg.Filename);
  AObj.Add('package_type',       LazPackageTypeIdents[APkg.PackageType]);
  AObj.Add('unit_output_dir',    APkg.CompilerOptions.UnitOutputDirectory);
  AObj.Add('unit_search_path',   APkg.CompilerOptions.OtherUnitFiles);
  AObj.Add('include_path',       APkg.CompilerOptions.IncludePath);
  AObj.Add('custom_options',     APkg.CompilerOptions.CustomOptions);
  AObj.Add('target_os',          APkg.CompilerOptions.TargetOS);
  AObj.Add('target_cpu',         APkg.CompilerOptions.TargetCPU);
  AObj.Add('usage_unit_path',    APkg.UsageOptions.UnitPath);
  AObj.Add('usage_include_path', APkg.UsageOptions.IncludePath);
end;

{ ── package_list ─────────────────────────────────────────────────────────── }

function PackageList(AParams: TJSONObject): string;
var
  I        : Integer;
  Pkg      : TIDEPackage;
  Lp       : TLazPackage;
  Arr      : TJSONArray;
  Obj, Row : TJSONObject;
  LazDir   : string;
  Filter   : string;
  ModOnly  : Boolean;
  WithIde  : Boolean;
  Total    : Integer;
begin
  Filter  := '';
  ModOnly := False;
  WithIde := False;
  if Assigned(AParams) then
  begin
    Filter  := LowerCase(AParams.Get('name_contains', ''));
    ModOnly := AParams.Get('modified_only', False);
    WithIde := AParams.Get('include_ide', False);
  end;
  LazDir := '$(LazarusDir)';
  if not Assigned(IDEMacros) or not IDEMacros.SubstituteMacros(LazDir) then
    LazDir := '';
  if LazDir <> '' then LazDir := AppendPathDelim(LazDir);
  Obj := TJSONObject.Create;
  Arr := TJSONArray.Create;
  try
    Obj.Add('packages', Arr);
    Total := 0;
    for I := 0 to PackageEditingInterface.GetPackageCount - 1 do
    begin
      Pkg := PackageEditingInterface.GetPackages(I);
      if not (Pkg is TLazPackage) then Continue;
      Lp := TLazPackage(Pkg);
      if (Filter <> '') and (Pos(Filter, LowerCase(Lp.Name)) = 0) then Continue;
      if ModOnly and not Lp.Modified then Continue;
      if not WithIde and (LazDir <> '') and
         (CompareFilenames(Copy(Lp.Filename, 1, Length(LazDir)), LazDir) = 0) then Continue;
      Inc(Total);
      if Arr.Count >= MAX_LIST then Continue;
      Row := TJSONObject.Create;
      Arr.Add(Row);
      Row.Add('name',      Lp.Name);
      Row.Add('version',   Lp.Version.AsString);
      Row.Add('file',      Lp.Filename);
      Row.Add('type',      LazPackageTypeIdents[Lp.PackageType]);
      Row.Add('installed', PackageEditingInterface.IsPackageInstalled(Lp.Name) <> nil);
      if Lp.Modified then Row.Add('modified', True);
      if Lp.IsVirtual then Row.Add('saved', False);
      if Lp.ReadOnly then Row.Add('read_only', True);
      Row.Add('file_count', Lp.FileCount);
    end;
    Obj.Add('count', Total);
    if Total > Arr.Count then Obj.Add('truncated', True);
    Result := Obj.AsJSON;
  finally
    Obj.Free;
  end;
end;

{ ── package_open ─────────────────────────────────────────────────────────── }

function PackageOpen(AParams: TJSONObject; out AErr: string): string;
var
  Pkg    : TLazPackage;
  Was    : Boolean;
  Lpk    : string;
begin
  Result := '';
  Lpk := Trim(AParams.Get('lpk_path', ''));
  Was := (Lpk <> '') and (PackageGraph.FindPackageWithFilename(Lpk) <> nil);
  if not TargetPackage(AParams, Pkg, AErr, False) then Exit;
  if AParams.Get('editor', False) then
    PackageEditingInterface.DoOpenPackageFile(Pkg.Filename, [pofAddToRecent], False);
  Result := PackageInfoJSON(Pkg.Name, False, Pkg);
  if Was then
    Result := Copy(Result, 1, Length(Result) - 1) + ',"already_loaded":true}';
end;

{ ── package_create ───────────────────────────────────────────────────────── }

function PackageCreate(AParams: TJSONObject; out AErr: string): string;
var
  Name, Dir, Lpk, UnitName, Ver, Text, TypeIdent : string;
  PkgType : TLazPackageType;
  Req     : TJSONArray;
  Reqs    : TStringList;
  V       : TPkgVersion;
  I       : Integer;
  SL      : TStringList;
  Pkg     : TLazPackage;
  Other   : TLazPackage;
begin
  Result := '';
  Name     := Trim(AParams.Get('name', ''));
  Dir      := Trim(AParams.Get('directory', ''));
  UnitName := Trim(AParams.Get('unit_name', ''));
  Ver      := Trim(AParams.Get('version', ''));
  TypeIdent := Trim(AParams.Get('type', 'RunTime'));
  if not IsValidIdent(Name) then
  begin AErr := 'name must be a Pascal identifier, got "' + Name + '"'; Exit; end;
  if not FilenameIsAbsolute(Dir) then
  begin AErr := 'directory must be an absolute path'; Exit; end;
  if not TypeFromIdent(TypeIdent, PkgType) then
  begin AErr := 'type must be RunTime, DesignTime, RunAndDesignTime or RunTimeOnly'; Exit; end;
  if (UnitName <> '') and not IsValidIdent(UnitName) then
  begin AErr := 'unit_name must be a Pascal identifier, got "' + UnitName + '"'; Exit; end;
  Dir := AppendPathDelim(CleanAndExpandDirectory(Dir));
  Lpk := Dir + Name + '.lpk';
  if FileExists(Lpk) then
  begin AErr := Lpk + ' exists already; package_open opens it'; Exit; end;
  Other := PackageGraph.FindPackageWithName(Name, nil);
  if Assigned(Other) then
  begin
    AErr := 'A package ' + Name + ' is already loaded from ' + Other.Filename;
    Exit;
  end;
  V := TPkgVersion.Create;
  Reqs := TStringList.Create;
  try
    if Ver <> '' then
      if not V.ReadString(Ver) then
      begin AErr := 'Bad version (major.minor[.release[.build]]): ' + Ver; Exit; end;
    Req := AParams.Find('requires') as TJSONArray;
    if Req = nil then
      Reqs.Add('FCL')
    else
      for I := 0 to Req.Count - 1 do
        Reqs.Add(Trim(Req.Strings[I]));
    for I := 0 to Reqs.Count - 1 do
      if not KnownToIDE(Reqs[I]) then
      begin
        AErr := 'Package not found: ' + Reqs[I] + ' (neither loaded nor known to the ' +
                'IDE''s package links)';
        Exit;
      end;
    if (UnitName <> '') and FileExists(Dir + LowerCase(UnitName) + '.pas') then
    begin AErr := Dir + LowerCase(UnitName) + '.pas exists already'; Exit; end;
    ForceDirectories(Dir);

    Text :=
      '<?xml version="1.0" encoding="UTF-8"?>' + LineEnding +
      '<CONFIG>' + LineEnding +
      '  <Package Version="5">' + LineEnding +
      '    <Name Value="' + Name + '"/>' + LineEnding +
      '    <Type Value="' + LazPackageTypeIdents[PkgType] + '"/>' + LineEnding +
      '    <CompilerOptions>' + LineEnding +
      '      <Version Value="11"/>' + LineEnding +
      '      <SearchPaths>' + LineEnding +
      '        <UnitOutputDirectory Value="lib/$(TargetCPU)-$(TargetOS)"/>' + LineEnding +
      '      </SearchPaths>' + LineEnding +
      '    </CompilerOptions>' + LineEnding;
    if AParams.Get('description', '') <> '' then
      Text := Text + '    <Description Value="' +
              XmlAttr(AParams.Get('description', '')) + '"/>' + LineEnding;
    if AParams.Get('author', '') <> '' then
      Text := Text + '    <Author Value="' +
              XmlAttr(AParams.Get('author', '')) + '"/>' + LineEnding;
    if AParams.Get('license', '') <> '' then
      Text := Text + '    <License Value="' +
              XmlAttr(AParams.Get('license', '')) + '"/>' + LineEnding;
    Text := Text + '    <Version';
    if V.Major   <> 0 then Text := Text + ' Major="'   + IntToStr(V.Major)   + '"';
    if V.Minor   <> 0 then Text := Text + ' Minor="'   + IntToStr(V.Minor)   + '"';
    if V.Release <> 0 then Text := Text + ' Release="' + IntToStr(V.Release) + '"';
    if V.Build   <> 0 then Text := Text + ' Build="'   + IntToStr(V.Build)   + '"';
    Text := Text + '/>' + LineEnding;
    if UnitName <> '' then
      Text := Text +
        '    <Files>' + LineEnding +
        '      <Item>' + LineEnding +
        '        <Filename Value="' + LowerCase(UnitName) + '.pas"/>' + LineEnding +
        '        <UnitName Value="' + UnitName + '"/>' + LineEnding +
        '      </Item>' + LineEnding +
        '    </Files>' + LineEnding;
    if Reqs.Count > 0 then
    begin
      Text := Text + '    <RequiredPkgs>' + LineEnding;
      for I := 0 to Reqs.Count - 1 do
        Text := Text +
          '      <Item>' + LineEnding +
          '        <PackageName Value="' + XmlAttr(Reqs[I]) + '"/>' + LineEnding +
          '      </Item>' + LineEnding;
      Text := Text + '    </RequiredPkgs>' + LineEnding;
    end;
    Text := Text +
      '    <UsageOptions>' + LineEnding +
      '      <UnitPath Value="$(PkgOutDir)"/>' + LineEnding +
      '    </UsageOptions>' + LineEnding +
      '    <PublishOptions>' + LineEnding +
      '      <Version Value="2"/>' + LineEnding +
      '      <UseFileFilters Value="True"/>' + LineEnding +
      '    </PublishOptions>' + LineEnding +
      '  </Package>' + LineEnding +
      '</CONFIG>' + LineEnding;

    SL := TStringList.Create;
    try
      if UnitName <> '' then
      begin
        SL.Text :=
          'unit ' + UnitName + ';' + LineEnding + LineEnding +
          '{$mode objfpc}{$H+}' + LineEnding + LineEnding +
          'interface' + LineEnding + LineEnding +
          'implementation' + LineEnding + LineEnding +
          'end.' + LineEnding;
        SL.SaveToFile(Dir + LowerCase(UnitName) + '.pas');
      end;
      SL.Text := Text;
      SL.SaveToFile(Lpk);
    finally
      SL.Free;
    end;
  finally
    Reqs.Free;
    V.Free;
  end;

  InvalidateFileStateCache(Lpk);
  PackageEditingInterface.DoOpenPackageFile(Lpk, [pofDoNotOpenEditor, pofAddToRecent], False);
  Pkg := PackageGraph.FindPackageWithFilename(Lpk);
  if Pkg = nil then
  begin
    AErr := 'Wrote ' + Lpk + ' but the IDE could not load it';
    Exit;
  end;
  Result := PackageInfoJSON(Pkg.Name, True, Pkg);
  Result := Copy(Result, 1, Length(Result) - 1) + ',"created":true}';
end;

{ ── package_get_settings / package_set_settings ──────────────────────────── }

function PackageGetSettings(AParams: TJSONObject; out AErr: string): string;
var
  Pkg : TLazPackage;
  Obj : TJSONObject;
begin
  Result := '';
  if not TargetPackage(AParams, Pkg, AErr, False) then Exit;
  Obj := TJSONObject.Create;
  try
    AddSettings(Pkg, Obj);
    Result := Obj.AsJSON;
  finally
    Obj.Free;
  end;
end;

function PackageSetSettings(AParams: TJSONObject; out AErr: string): string;
const
  KEYS : array[0..8] of string = ('package_type', 'unit_output_dir', 'unit_search_path',
    'include_path', 'custom_options', 'target_os', 'target_cpu', 'usage_unit_path',
    'usage_include_path');
var
  Pkg      : TLazPackage;
  PkgType  : TLazPackageType;
  WasMod   : Boolean;
  I        : Integer;
  AnyKey   : Boolean;
  Obj, Old, Cur : TJSONObject;
begin
  Result := '';
  if not TargetPackage(AParams, Pkg, AErr) then Exit;
  AnyKey := False;
  for I := Low(KEYS) to High(KEYS) do
    if AParams.IndexOfName(KEYS[I]) >= 0 then AnyKey := True;
  if not AnyKey then
  begin
    AErr := 'Give at least one of: ' + KEYS[0] + ', ' + KEYS[1] + ', ' + KEYS[2] +
            ', ' + KEYS[3] + ', ' + KEYS[4] + ', ' + KEYS[5] + ', ' + KEYS[6] +
            ', ' + KEYS[7] + ', ' + KEYS[8];
    Exit;
  end;
  if AParams.IndexOfName('package_type') >= 0 then
    if not TypeFromIdent(AParams.Get('package_type', ''), PkgType) then
    begin
      AErr := 'package_type must be RunTime, DesignTime, RunAndDesignTime or RunTimeOnly';
      Exit;
    end;
  Obj := TJSONObject.Create;
  Old := TJSONObject.Create;
  try
    AddSettings(Pkg, Old);
    WasMod := Pkg.Modified;
    if AParams.IndexOfName('package_type') >= 0 then
      Pkg.PackageType := PkgType;
    if AParams.IndexOfName('unit_output_dir') >= 0 then
      Pkg.CompilerOptions.UnitOutputDirectory := AParams.Get('unit_output_dir', '');
    if AParams.IndexOfName('unit_search_path') >= 0 then
      Pkg.CompilerOptions.OtherUnitFiles := AParams.Get('unit_search_path', '');
    if AParams.IndexOfName('include_path') >= 0 then
      Pkg.CompilerOptions.IncludePath := AParams.Get('include_path', '');
    if AParams.IndexOfName('custom_options') >= 0 then
      Pkg.CompilerOptions.CustomOptions := AParams.Get('custom_options', '');
    if AParams.IndexOfName('target_os') >= 0 then
      Pkg.CompilerOptions.TargetOS := AParams.Get('target_os', '');
    if AParams.IndexOfName('target_cpu') >= 0 then
      Pkg.CompilerOptions.TargetCPU := AParams.Get('target_cpu', '');
    if AParams.IndexOfName('usage_unit_path') >= 0 then
      Pkg.UsageOptions.UnitPath := AParams.Get('usage_unit_path', '');
    if AParams.IndexOfName('usage_include_path') >= 0 then
      Pkg.UsageOptions.IncludePath := AParams.Get('usage_include_path', '');
    Cur := TJSONObject.Create;
    AddSettings(Pkg, Cur);
    if Old.AsJSON = Cur.AsJSON then
    begin
      Obj.Add('package', Pkg.Name);
      Obj.Add('unchanged', True);
      Cur.Free;
      Result := Obj.AsJSON;
      Exit;
    end;
    Obj.Add('old', Old);
    Old := nil;
    Obj.Add('new', Cur);
    Result := EditResult(Pkg, WasMod, Obj);
  finally
    Old.Free;
    Obj.Free;
  end;
end;

{ ── package_compile, IDE side ────────────────────────────────────────────── }

{ The IDE's own compile of a loaded package.  A package that is not loaded
  gives {"use_lazbuild":true}: the caller then compiles the .lpk with
  lazbuild, which loads nothing into the IDE.  Editor files with unsaved
  changes are not saved (the IDE would write the user's buffers), so they are
  compiled as on disk and listed. }
function PackageCompileIde(AParams: TJSONObject; out AErr: string): string;
var
  Pkg      : TLazPackage;
  Name, Lpk, Method : string;
  Obj      : TJSONObject;
  Errors, Warnings, Unsaved : TJSONArray;
  I        : Integer;
  Ed       : TSourceEditorInterface;
  Res      : TModalResult;
begin
  Result := '';
  Method := LowerCase(Trim(AParams.Get('method', 'auto')));
  if (Method <> 'auto') and (Method <> 'ide') and (Method <> 'lazbuild') then
  begin AErr := 'method must be auto, ide or lazbuild'; Exit; end;
  if Method = 'lazbuild' then
  begin
    Result := '{"use_lazbuild":true}';
    Exit;
  end;
  Name := Trim(AParams.Get('package_name', ''));
  Lpk  := Trim(AParams.Get('lpk_path', ''));
  Pkg  := nil;
  if Lpk <> '' then
    Pkg := PackageGraph.FindPackageWithFilename(Lpk)
  else if Name <> '' then
    Pkg := PackageGraph.FindPackageWithName(Name, nil)
  else
  begin AErr := 'package_name or lpk_path required'; Exit; end;
  if Pkg = nil then
  begin
    if (Method = 'auto') and (Lpk <> '') then
    begin
      Result := '{"use_lazbuild":true}';
      Exit;
    end;
    if Lpk = '' then
    begin
      AErr := 'Package not loaded: ' + Name + '. Give its lpk_path instead.';
      Exit;
    end;
    { method ide: load the .lpk for this call; the IDE closes it again when idle }
    if not TargetPackage(AParams, Pkg, AErr, False) then Exit;
  end;
  if Pkg.IsVirtual then
  begin AErr := Pkg.Name + ' has not been saved yet'; Exit; end;

  Obj := TJSONObject.Create;
  Errors := TJSONArray.Create;
  Warnings := TJSONArray.Create;
  Unsaved := TJSONArray.Create;
  try
    for I := 0 to Pkg.FileCount - 1 do
    begin
      Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(
              Pkg.Files[I].GetFullFilename);
      if Assigned(Ed) and Ed.Modified then
        Unsaved.Add(Pkg.Files[I].GetFullFilename);
    end;
    if AParams.Get('clean', False) then
      Res := PackageEditingInterface.DoCompilePackage(Pkg,
               [pcfDoNotSaveEditorFiles, pcfCleanCompile], False)
    else
      Res := PackageEditingInterface.DoCompilePackage(Pkg, [pcfDoNotSaveEditorFiles], False);
    McpCompilerMessages(Errors, Warnings);
    Obj.Add('method',  'ide');
    Obj.Add('package', Pkg.Name);
    Obj.Add('lpk',     Pkg.Filename);
    Obj.Add('success', Res = mrOk);
    Obj.Add('errors',  Errors);   Errors := nil;
    Obj.Add('warning_count', Warnings.Count);
    Obj.Add('warnings', Warnings); Warnings := nil;
    if Pkg.Modified then
      Obj.Add('package_modified', True);
    if Unsaved.Count > 0 then
    begin
      Obj.Add('unsaved_files', Unsaved); Unsaved := nil;
    end;
    Result := Obj.AsJSON;
  finally
    Errors.Free;
    Warnings.Free;
    Unsaved.Free;
    Obj.Free;
  end;
end;

{ ── Dispatch ─────────────────────────────────────────────────────────────── }

function DispatchPkgManageTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  Err   : string;
  Pkg   : TLazPackage;
  PName : string;
begin
  Result := True;
  Err := '';
  if Name = 'package_get_info' then
  begin
    if not HasTarget(Ctx.Params) then
      Err := 'package_name or lpk_path required'
    else if Ctx.Params.Get('lpk_path', '') <> '' then
    begin
      if TargetPackage(Ctx.Params, Pkg, Err, False) then
        Ctx.Result := PackageInfoJSON(Pkg.Name, Ctx.Params.Get('files', False), Pkg);
    end
    else
      Ctx.Result := PackageInfoJSON(Ctx.Params.Get('package_name', ''),
                                    Ctx.Params.Get('files', False));
  end
  else if Name = 'package_list' then
    Ctx.Result := PackageList(Ctx.Params)
  else if Name = 'package_open' then
    Ctx.Result := PackageOpen(Ctx.Params, Err)
  else if Name = 'package_create' then
    Ctx.Result := PackageCreate(Ctx.Params, Err)
  else if Name = 'package_get_settings' then
  begin
    if not HasTarget(Ctx.Params) then Err := 'package_name or lpk_path required'
    else Ctx.Result := PackageGetSettings(Ctx.Params, Err);
  end
  else if Name = 'package_set_settings' then
  begin
    if not HasTarget(Ctx.Params) then Err := 'package_name or lpk_path required'
    else Ctx.Result := PackageSetSettings(Ctx.Params, Err);
  end
  else if Name = 'package_compile_ide' then
  begin
    { internal: the main-thread half of package_compile }
    if not HasTarget(Ctx.Params) then Err := 'package_name or lpk_path required'
    else Ctx.Result := PackageCompileIde(Ctx.Params, Err);
  end
  else
    Result := False;
  PName := Err;
  if Result and (PName <> '') then
  begin
    Ctx.Error := True;
    Ctx.Result := PName;
  end;
end;

{ ── Schema registration ──────────────────────────────────────────────────── }

procedure RegisterPkgManageSchemas(Tools: TJSONArray);
begin
  Tools.Add(MakeTool('package_get_info',
    'A package''s status and contents, by package_name or by .lpk file (loaded for the ' +
    'call): version, type, requirements (with status: not_found etc.), the packages ' +
    'using it, output dir, search paths, compiler options, and optionally its files ' +
    '(with units and Register procedures).',
    SCHEMA_GET_INFO, MCP_ANN_RO));
  Tools.Add(MakeTool('package_list',
    'The packages loaded in the IDE: name, version, .lpk, type, installed, modified. ' +
    'By default only those that don''t come with Lazarus.',
    SCHEMA_LIST, MCP_ANN_RO));
  Tools.Add(MakeTool('package_open',
    'Load an .lpk into the IDE without installing it, so the other package_* tools ' +
    'and package_compile can use it by name. editor=true also shows its package editor.',
    SCHEMA_OPEN, MCP_ANN_WRITE_IDEM));
  Tools.Add(MakeTool('package_create',
    'Create a package: writes name.lpk (and an optional first unit) in a directory ' +
    'and loads it in the IDE. Requires FCL unless requires says otherwise.',
    SCHEMA_CREATE, MCP_ANN_WRITE));
  Tools.Add(MakeTool('package_get_settings',
    'A package''s type, output directory, unit/include search paths, compiler options, ' +
    'target, and the paths it adds to projects that use it.',
    SCHEMA_GET_SETTINGS, MCP_ANN_RO));
  Tools.Add(MakeTool('package_set_settings',
    'Change a package''s type, output directory, search paths, compiler options, ' +
    'target or usage paths; only the given fields change. Returns old and new values. ' +
    'Saves the .lpk when nothing else is unsaved.',
    SCHEMA_SET_SETTINGS, MCP_ANN_WRITE_IDEM));
end;

initialization
  RegisterMcpGroup(@DispatchPkgManageTool);
  RegisterMcpSchemas(@RegisterPkgManageSchemas);

end.
