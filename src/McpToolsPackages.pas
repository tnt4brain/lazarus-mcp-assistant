{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsPackages;

{ Package management tools: package_get_info, package_search_online, project_add_package,
  project_remove_package, package_install, package_uninstall. }

{$mode objfpc}{$H+}

interface

implementation

uses
  Classes, SysUtils, Contnrs,
  LazIDEIntf, SrcEditorIntf, ProjectIntf, PackageIntf,
  LazFileUtils, FileUtil,
  fpjson,
  McpToolContext;

{ ── Schema constants ─────────────────────────────────────────────────────── }

const
  SCHEMA_GET_PACKAGE_INFO =
    '{"type":"object","properties":{"package_name":{"type":"string",' +
    '"description":"Package name as registered in the IDE (e.g. LazMcpAssistant)"}},' +
    '"required":["package_name"]}';

  SCHEMA_ADD_PACKAGE_TO_PROJECT =
    '{"type":"object","properties":{"package_name":{"type":"string",' +
    '"description":"Package name to add as a dependency (e.g. LazUtils)"}},' +
    '"required":["package_name"]}';

  SCHEMA_REMOVE_PACKAGE_FROM_PROJECT =
    '{"type":"object","properties":{"package_name":{"type":"string",' +
    '"description":"Package name to remove from project dependencies"}},' +
    '"required":["package_name"]}';

  SCHEMA_INSTALL_PACKAGE =
    '{"type":"object","properties":{"lpk_path":{"type":"string",' +
    '"description":"Absolute path to the .lpk package file to install into the IDE"}},' +
    '"required":["lpk_path"]}';

  SCHEMA_UNINSTALL_PACKAGE =
    '{"type":"object","properties":{"package_name":{"type":"string",' +
    '"description":"Package name to uninstall from the IDE"}},' +
    '"required":["package_name"]}';

  SCHEMA_SEARCH_ONLINE =
    '{"type":"object","properties":{' +
    '"query":{"type":"string","description":"Words that must all occur (case-insensitive) in a package''s name, ' +
      'description, category or .lpk names/descriptions, e.g. \"chart\", \"rich memo\", \"zip\". Empty lists everything."},' +
    '"category":{"type":"string","description":"Only packages whose category contains this text, e.g. Graphics, ' +
      'Networking, DataControls, LazIDEPlugins"},' +
    '"max_results":{"type":"integer","description":"Default 20"}}}';

  OPM_REPOSITORY_URL = 'https://packages.lazarus-ide.org/';

{ ── Online Package Manager catalog ───────────────────────────────────────── }

function OpmDir(const ASub: string): string;
begin
  Result := AppendPathDelim(LazarusIDE.GetPrimaryConfigPath) + 'onlinepackagemanager' +
            PathDelim + ASub + PathDelim;
end;

{ The catalog OPM downloaded last (packagelist_<hash of repository URL>.json). }
function OpmCatalogFile: string;
var
  SR   : TSearchRec;
  Best : LongInt;
begin
  Result := '';
  Best   := -1;
  if FindFirst(OpmDir('config') + 'packagelist_*.json', faAnyFile, SR) = 0 then
  try
    repeat
      if SR.Time > Best then
      begin
        Best   := SR.Time;
        Result := OpmDir('config') + SR.Name;
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

{ OPM writes paths as 'Dir\/Sub\/'. }
function OpmPath(const S: string): string;
begin
  Result := StringReplace(S, '\/', PathDelim, [rfReplaceAll]);
  Result := StringReplace(Result, '/', PathDelim, [rfReplaceAll]);
end;

function OpmPackageType(AType: Integer): string;
begin
  case AType of
    0: Result := 'designtime+runtime';
    1: Result := 'designtime';
    2: Result := 'runtime';
    3: Result := 'runtime only';
  else Result := IntToStr(AType);
  end;
end;

function Capped(const S: string; AMax: Integer): string;
begin
  Result := Trim(S);
  if Length(Result) > AMax then
    Result := Copy(Result, 1, AMax) + '...';
end;

{ Search the cached catalog; main thread (install state comes from the IDE). }
function SearchOnlineCatalog(AParams: TJSONObject; out AErr: string): string;
var
  FileName, Text, Hay, Category : string;
  Words     : TStringArray;
  Root      : TJSONData;
  Cat       : TJSONObject;
  Data      : TJSONObject;
  Files     : TJSONArray;
  F         : TJSONObject;
  Res, FArr : TJSONArray;
  Obj, FObj, PObj : TJSONObject;
  I, J, W, Matches, MaxRes : Integer;
  Ok        : Boolean;
  BaseDir, Lpk, Desc : string;
  SL        : TStringList;
begin
  Result := '';
  AErr   := '';
  FileName := OpmCatalogFile;
  if FileName = '' then
  begin
    AErr := 'No Online Package Manager catalog found. Open Package > Online Package ' +
            'Manager in the IDE once to download it.';
    Exit;
  end;
  SL := TStringList.Create;
  try
    SL.LoadFromFile(FileName);
    Text := SL.Text;
  finally
    SL.Free;
  end;
  if Copy(Text, 1, 3) = #$EF#$BB#$BF then
    Delete(Text, 1, 3);
  Words    := nil;
  Category := '';
  MaxRes   := 20;
  if Assigned(AParams) then   { AParams may be nil: no arguments }
  begin
    Words    := LowerCase(Trim(AParams.Get('query', ''))).Split([' '], TStringSplitOptions.ExcludeEmpty);
    Category := LowerCase(Trim(AParams.Get('category', '')));
    MaxRes   := AParams.Get('max_results', 20);
  end;
  if MaxRes < 1 then MaxRes := 20;

  Root := GetJSON(Text);
  Res  := TJSONArray.Create;
  Obj  := TJSONObject.Create;
  try
    if not (Root is TJSONObject) then
    begin
      AErr := 'Unexpected catalog format: ' + FileName; Exit;
    end;
    Cat := TJSONObject(Root);
    Matches := 0;
    I := 0;
    while Cat.Find('PackageData' + IntToStr(I)) is TJSONObject do
    begin
      Data  := TJSONObject(Cat.Find('PackageData' + IntToStr(I)));
      Files := nil;
      if Cat.Find('PackageFiles' + IntToStr(I)) is TJSONArray then
        Files := TJSONArray(Cat.Find('PackageFiles' + IntToStr(I)));
      Inc(I);

      if (Category <> '') and (Pos(Category, LowerCase(Data.Get('Category', ''))) = 0) then
        Continue;
      Hay := Data.Get('Name', '') + ' ' + Data.Get('DisplayName', '') + ' ' +
             Data.Get('Category', '') + ' ' + Data.Get('CommunityDescription', '');
      if Assigned(Files) then
        for J := 0 to Files.Count - 1 do
          if Files[J] is TJSONObject then
            Hay := Hay + ' ' + TJSONObject(Files[J]).Get('Name', '') + ' ' +
                   TJSONObject(Files[J]).Get('Description', '');
      Hay := LowerCase(Hay);
      Ok := True;
      for W := 0 to High(Words) do
        if Pos(Words[W], Hay) = 0 then
        begin
          Ok := False; Break;
        end;
      if not Ok then Continue;
      Inc(Matches);
      if Res.Count >= MaxRes then Continue;

      Desc := Data.Get('CommunityDescription', '');
      BaseDir := OpmDir('packages') + OpmPath(Data.Get('PackageBaseDir', ''));
      FObj := TJSONObject.Create;
      Res.Add(FObj);
      FObj.Add('name',      Data.Get('Name', ''));
      if Data.Get('DisplayName', '') <> Data.Get('Name', '') then
        FObj.Add('display_name', Data.Get('DisplayName', ''));
      FObj.Add('category',  Data.Get('Category', ''));
      FArr := TJSONArray.Create;
      if Assigned(Files) then
        for J := 0 to Files.Count - 1 do
        begin
          if not (Files[J] is TJSONObject) then Continue;
          F := TJSONObject(Files[J]);
          if Desc = '' then Desc := F.Get('Description', '');
          Lpk  := F.Get('Name', '');
          PObj := TJSONObject.Create;
          FArr.Add(PObj);
          PObj.Add('lpk',        Lpk);
          PObj.Add('version',    F.Get('VersionAsString', ''));
          PObj.Add('type',       OpmPackageType(F.Get('PackageType', 0)));
          if F.Get('Description', '') <> '' then
            PObj.Add('description', Capped(F.Get('Description', ''), 200));
          PObj.Add('license',    Capped(F.Get('License', ''), 80));
          PObj.Add('lazarus',    F.Get('LazCompatibility', ''));
          PObj.Add('fpc',        F.Get('FPCCompatibility', ''));
          PObj.Add('widgetsets', F.Get('SupportedWidgetSet', ''));
          PObj.Add('depends_on', F.Get('DependenciesAsString', ''));
          PObj.Add('installed',
            Assigned(PackageEditingInterface.IsPackageInstalled(ChangeFileExt(Lpk, ''))));
          Lpk := BaseDir + OpmPath(F.Get('RelativeFilePath', '')) + Lpk;
          if FileExists(Lpk) then
            PObj.Add('downloaded_lpk', Lpk);   { ready for package_install }
        end;
      FObj.Add('description', Capped(Desc, 400));
      FObj.Add('homepage',   Data.Get('HomePageURL', ''));
      FObj.Add('archive',    OPM_REPOSITORY_URL + Data.Get('RepositoryFileName', ''));
      FObj.Add('archive_date', FormatDateTime('yyyy-mm-dd', Data.Get('RepositoryDate', 0.0)));
      if Data.Get('ExternalDependecies', '') <> '' then
        FObj.Add('external_dependencies', Data.Get('ExternalDependecies', ''));
      if Data.Get('OrphanedPackage', 0) <> 0 then
        FObj.Add('orphaned', True);
      FObj.Add('packages', FArr);
    end;
    Obj.Add('catalog_file', FileName);
    Obj.Add('catalog_date', FormatDateTime('yyyy-mm-dd', FileDateToDateTime(FileAge(FileName))));
    Obj.Add('catalog_packages', I);
    Obj.Add('matches', Matches);
    Obj.Add('results', Res);
    Res := nil;
    Result := Obj.AsJSON;
  finally
    Res.Free;
    Obj.Free;
    Root.Free;
  end;
end;

{ ── Dispatch ─────────────────────────────────────────────────────────────── }

function DispatchPackagesTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  PkgName  : string;
  LpkPath  : string;
  IDEPkg   : TIDEPackage;
  IDEPkg2  : TIDEPackage;
  FPList   : TFPList;
  PkgList  : TObjectList;
  PkgID    : TLazPackageID;
  PollExe  : string;
  PasFile  : string;
  RefArr   : TJSONArray;
  Obj      : TJSONObject;
  Proj     : TLazProject;
  I        : Integer;
begin
  Result := False;

  if Name = 'package_search_online' then
  begin
    Result := True;
    Ctx.Result := SearchOnlineCatalog(Ctx.Params, PkgName);
    if PkgName <> '' then
    begin
      Ctx.Error := True; Ctx.Result := PkgName;
    end;
    Exit;
  end;

  if Name = 'package_get_info' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('package_name', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'package_name required'; Exit;
    end;
    PkgName := Ctx.Params.Get('package_name', '');
    IDEPkg  := PackageEditingInterface.IsPackageInstalled(PkgName);
    Obj := TJSONObject.Create;
    try
      Obj.Add('package_name', PkgName);
      Obj.Add('is_installed', Assigned(IDEPkg));
      if Assigned(IDEPkg) then
        Obj.Add('package_file', IDEPkg.Filename);
      IDEPkg2 := PackageEditingInterface.FindPackageWithName(PkgName);
      Obj.Add('is_loaded', Assigned(IDEPkg2));
      if Assigned(IDEPkg2) then
        Obj.Add('loaded_file', IDEPkg2.Filename);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'project_add_package' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('package_name', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'package_name required'; Exit;
    end;
    PkgName := Ctx.Params.Get('package_name', '');
    Proj := LazarusIDE.ActiveProject;
    if not Assigned(Proj) then
    begin
      Ctx.Error := True; Ctx.Result := 'No active project'; Exit;
    end;
    Proj.AddPackageDependency(PkgName);
    LazarusIDE.DoSaveProject([]);
    PackageEditingInterface.GetRequiredPackages(Proj, FPList, [pirNotRecursive]);
    Obj := TJSONObject.Create;
    try
      RefArr := TJSONArray.Create;
      if Assigned(FPList) then
      begin
        for I := 0 to FPList.Count - 1 do
          RefArr.Add(TIDEPackage(FPList[I]).Name);
        FreeAndNil(FPList);
      end;
      Obj.Add('package_name',        PkgName);
      Obj.Add('project_dependencies', RefArr);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'project_remove_package' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('package_name', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'package_name required'; Exit;
    end;
    PkgName := Ctx.Params.Get('package_name', '');
    Proj := LazarusIDE.ActiveProject;
    if not Assigned(Proj) then
    begin
      Ctx.Error := True; Ctx.Result := 'No active project'; Exit;
    end;
    if not Proj.RemovePackageDependency(PkgName) then
    begin
      Ctx.Error := True;
      Ctx.Result := 'Package not found in project: ' + PkgName;
      Exit;
    end;
    LazarusIDE.DoSaveProject([]);
    PackageEditingInterface.GetRequiredPackages(Proj, FPList, [pirNotRecursive]);
    Obj := TJSONObject.Create;
    try
      RefArr := TJSONArray.Create;
      if Assigned(FPList) then
      begin
        for I := 0 to FPList.Count - 1 do
          RefArr.Add(TIDEPackage(FPList[I]).Name);
        FreeAndNil(FPList);
      end;
      Obj.Add('package_name',        PkgName);
      Obj.Add('project_dependencies', RefArr);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'package_install' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('lpk_path', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'lpk_path required'; Exit;
    end;
    LpkPath := Ctx.Params.Get('lpk_path', '');
    Obj := TJSONObject.Create;
    try
      Obj.Add('status',  'rebuilding');
      Obj.Add('message', 'IDE is rebuilding and will restart. Poll with the ' +
                         'command in poll_command until it succeeds.');
      PollExe := ExtractFilePath(LazarusIDE.GetFPCompilerFilename) +
                 'instantfpc' + GetExeExt;
      IDEPkg := PackageEditingInterface.FindPackageWithName('LazMcpAssistant');
      if Assigned(IDEPkg) then
        PasFile := ExtractFilePath(ExcludeTrailingPathDelimiter(
                     ExtractFilePath(IDEPkg.Filename))) + 'wait_for_restart.pas'
      else
        PasFile := '';
      if PasFile <> '' then
      begin
        {$IFDEF WINDOWS}
        Obj.Add('poll_command',
          'cmd /c "SET PATH=' +
          ExcludeTrailingPathDelimiter(ExtractFilePath(LazarusIDE.GetFPCompilerFilename)) +
          ';%PATH% && "' + PollExe + '" "' + PasFile + '""');
        {$ELSE}
        Obj.Add('poll_command',
          'sh -c ''PATH="' +
          ExcludeTrailingPathDelimiter(ExtractFilePath(LazarusIDE.GetFPCompilerFilename)) +
          ':$PATH" "' + PollExe + '" "' + PasFile + '"''');
        {$ENDIF}
      end;
      Ctx.Result          := Obj.AsJSON;
      Ctx.ConnectionClose := True;
    finally
      Obj.Free;
    end;
    while SourceEditorManagerIntf.UniqueSourceEditorCount > 0 do
      LazarusIDE.DoCloseEditorFile(
        SourceEditorManagerIntf.UniqueSourceEditors[0], [cfQuiet]);
    if Assigned(Ctx.StopServer) then Ctx.StopServer();
    PkgList := TObjectList.Create(True);
    try
      PackageEditingInterface.DoOpenPackageFile(LpkPath, [pofDoNotOpenEditor], False);
      IDEPkg := PackageEditingInterface.FindPackageWithName(
                  ExtractFileNameOnly(LpkPath));
      if Assigned(IDEPkg) then
      begin
        PkgID := TLazPackageID.Create;
        PkgID.AssignID(IDEPkg);
        PkgList.Add(PkgID);
      end;
      PackageEditingInterface.InstallPackages(
        PkgList, [piiifRebuildIDE, piiifSkipChecks, piiifQuiet]);
    finally
      PkgList.Free;
    end;
  end

  else if Name = 'package_uninstall' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('package_name', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'package_name required'; Exit;
    end;
    PkgName := Ctx.Params.Get('package_name', '');
    IDEPkg := PackageEditingInterface.FindPackageWithName(PkgName);
    if not Assigned(IDEPkg) then
    begin
      Ctx.Error := True; Ctx.Result := 'Package not found: ' + PkgName; Exit;
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('status',  'rebuilding');
      Obj.Add('message', 'IDE is rebuilding and will restart. Poll with the ' +
                         'command in poll_command until it succeeds.');
      PollExe := ExtractFilePath(LazarusIDE.GetFPCompilerFilename) +
                 'instantfpc' + GetExeExt;
      IDEPkg2 := PackageEditingInterface.FindPackageWithName('LazMcpAssistant');
      if Assigned(IDEPkg2) then
        PasFile := ExtractFilePath(ExcludeTrailingPathDelimiter(
                     ExtractFilePath(IDEPkg2.Filename))) + 'wait_for_restart.pas'
      else
        PasFile := '';
      if PasFile <> '' then
      begin
        {$IFDEF WINDOWS}
        Obj.Add('poll_command',
          'cmd /c "SET PATH=' +
          ExcludeTrailingPathDelimiter(ExtractFilePath(LazarusIDE.GetFPCompilerFilename)) +
          ';%PATH% && "' + PollExe + '" "' + PasFile + '""');
        {$ELSE}
        Obj.Add('poll_command',
          'sh -c ''PATH="' +
          ExcludeTrailingPathDelimiter(ExtractFilePath(LazarusIDE.GetFPCompilerFilename)) +
          ':$PATH" "' + PollExe + '" "' + PasFile + '"''');
        {$ENDIF}
      end;
      Ctx.Result          := Obj.AsJSON;
      Ctx.ConnectionClose := True;
    finally
      Obj.Free;
    end;
    while SourceEditorManagerIntf.UniqueSourceEditorCount > 0 do
      LazarusIDE.DoCloseEditorFile(
        SourceEditorManagerIntf.UniqueSourceEditors[0], [cfQuiet]);
    if Assigned(Ctx.StopServer) then Ctx.StopServer();
    PackageEditingInterface.UninstallPackage(IDEPkg, False);
    PkgList := TObjectList.Create(True);
    try
      PackageEditingInterface.InstallPackages(
        PkgList, [piiifRebuildIDE, piiifSkipChecks, piiifQuiet]);
    finally
      PkgList.Free;
    end;
  end;
end;

{ ── Schema registration ──────────────────────────────────────────────────── }

procedure RegisterPackagesSchemas(Tools: TJSONArray);
begin
  Tools.Add(MakeTool('package_search_online',
    'Search the Lazarus online package repository (the Online Package Manager''s ' +
    'catalog of community packages, cached locally — no network access) by words in ' +
    'package names, descriptions, categories and .lpk names. Returns per package: ' +
    'category, description, homepage, archive URL and each .lpk with version, license, ' +
    'Lazarus/FPC/widgetset compatibility, dependencies, whether it is installed, and ' +
    'downloaded_lpk when OPM has already downloaded it (pass that to package_install). ' +
    'The catalog lists packages, not component classes; for classes already on the ' +
    'palette use form_search_palette.',
    SCHEMA_SEARCH_ONLINE, MCP_ANN_RO));
  Tools.Add(MakeTool('package_get_info',
    'Query a package''s load and install status in the running IDE.',
    SCHEMA_GET_PACKAGE_INFO, MCP_ANN_RO));
  Tools.Add(MakeTool('project_add_package',
    'Add a package as a dependency to the active project (.lpi). ' +
    'The package must already be loaded in the IDE. No rebuild required. ' +
    'Returns the updated list of project package dependencies.',
    SCHEMA_ADD_PACKAGE_TO_PROJECT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('project_remove_package',
    'Remove a package dependency from the active project (.lpi). ' +
    'No rebuild required. Returns the updated list of project package dependencies.',
    SCHEMA_REMOVE_PACKAGE_FROM_PROJECT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('package_install',
    'Install a package into the Lazarus IDE (design-time / palette). ' +
    'Triggers an IDE rebuild and restart. Returns {"status":"rebuilding","poll_command":"..."}. ' +
    'Use package_compile first to catch errors early.',
    SCHEMA_INSTALL_PACKAGE, MCP_ANN_DEST));
  Tools.Add(MakeTool('package_uninstall',
    'Uninstall a package from the Lazarus IDE. ' +
    'Triggers an IDE rebuild and restart. Returns {"status":"rebuilding","poll_command":"..."}.',
    SCHEMA_UNINSTALL_PACKAGE, MCP_ANN_DEST));
end;

initialization
  RegisterMcpGroup(@DispatchPackagesTool);
  RegisterMcpSchemas(@RegisterPackagesSchemas);

end.
