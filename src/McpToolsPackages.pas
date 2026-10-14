{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsPackages;

{ Package management tools: package_get_info, package_find_unit, package_search_online,
  project_list_packages, project_add_package, project_remove_package,
  package_install, package_uninstall. }

{$mode objfpc}{$H+}

interface

implementation

uses
  Classes, SysUtils, Contnrs,
  LazIDEIntf, SrcEditorIntf, ProjectIntf, PackageIntf,
  LazFileUtils, FileUtil,
  PackageDependencyIntf,
  PackageDefs, Project,   { IdePackager/IdeProject, linked via IdeDebugger: TPkgDependency }
  fpjson,
  McpToolContext, McpIdeState, McpConsent;

{ ── Schema constants ─────────────────────────────────────────────────────── }

const
  SCHEMA_GET_PACKAGE_INFO_EX =
    '{"type":"object","properties":{"package_name":{"type":"string",' +
    '"description":"Package name as registered in the IDE (e.g. LazMcpAssistant)"},' +
    '"files":{"type":"boolean","description":"Include the package''s files (default false)"}},' +
    '"required":["package_name"]}';

  SCHEMA_LIST_PROJECT_PACKAGES =
    '{"type":"object","properties":{"recursive":{"type":"boolean",' +
    '"description":"Also list every package the project needs indirectly, in compile ' +
    'order, each with its own requirements (default false)"}}}';

  SCHEMA_FIND_UNIT =
    '{"type":"object","properties":{"unit_name":{"type":"string",' +
    '"description":"Unit name, e.g. SynEdit or fpjson"}},"required":["unit_name"]}';

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

{ ── Dependencies (IDE package graph) ─────────────────────────────────────── }

function DepStatus(Dep: TPkgDependency): string;
begin
  if Assigned(Dep.RequiredPackage) then Exit('ok');
  if Dep.DependencyType = pdtFPMake then Exit('fpmake');
  case Dep.LoadPackageResult of
    lprAvailableOnline: Result := 'available_online';
    lprNotFound:        Result := 'not_found';
    lprLoadError:       Result := 'load_error';
  else                  Result := 'unresolved';
  end;
end;

function OwnerName(AOwner: TObject): string;
begin
  if AOwner is TLazPackage then
    Result := TLazPackage(AOwner).Name
  else if AOwner is TProject then
    Result := 'project ' + ExtractFileName(TProject(AOwner).ProjectInfoFile)
  else
    Result := 'IDE';
end;

{ One requirement as declared in the .lpi/.lpk, plus what it resolved to. }
function DepJSON(Dep: TPkgDependency): TJSONObject;
var
  Pkg: TLazPackage;
begin
  Result := TJSONObject.Create;
  Result.Add('name', Dep.PackageName);
  if pdfMinVersion in Dep.Flags then
    Result.Add('min_version', Dep.MinVersion.AsString);
  if pdfMaxVersion in Dep.Flags then
    Result.Add('max_version', Dep.MaxVersion.AsString);
  Result.Add('status', DepStatus(Dep));
  Pkg := Dep.RequiredPackage;
  if Assigned(Pkg) then
  begin
    Result.Add('version', Pkg.Version.AsString);
    Result.Add('file', Pkg.Filename);
    Result.Add('type', LazPackageTypeIdents[Pkg.PackageType]);
    Result.Add('installed', Pkg.Installed <> pitNope);
  end;
end;

function DepNames(First: TPkgDependency): TJSONArray;
begin
  Result := TJSONArray.Create;
  while Assigned(First) do
  begin
    if Assigned(First.RequiredPackage) then
      Result.Add(First.PackageName)
    else
      Result.Add(First.PackageName + ' (' + DepStatus(First) + ')');
    First := First.NextRequiresDependency;
  end;
end;

function ProjectPackagesJSON(Proj: TProject; Recursive: Boolean): string;
var
  Obj, PObj : TJSONObject;
  Arr       : TJSONArray;
  Dep       : TPkgDependency;
  List      : TFPList;
  Pkg       : TLazPackage;
  I         : Integer;
begin
  Obj := TJSONObject.Create;
  try
    Obj.Add('project', Proj.ProjectInfoFile);
    Arr := TJSONArray.Create;
    Obj.Add('requires', Arr);
    Dep := Proj.FirstRequiredDependency;
    while Assigned(Dep) do
    begin
      Arr.Add(DepJSON(Dep));
      Dep := Dep.NextRequiresDependency;
    end;
    if Recursive then
    begin
      PackageEditingInterface.GetRequiredPackages(Proj, List, [pirCompileOrder]);
      Arr := TJSONArray.Create;
      Obj.Add('compile_order', Arr);
      if Assigned(List) then
      try
        for I := 0 to List.Count - 1 do
        begin
          if not (TObject(List[I]) is TLazPackage) then Continue;
          Pkg  := TLazPackage(List[I]);
          PObj := TJSONObject.Create;
          Arr.Add(PObj);
          PObj.Add('name', Pkg.Name);
          PObj.Add('version', Pkg.Version.AsString);
          PObj.Add('file', Pkg.Filename);
          PObj.Add('requires', DepNames(Pkg.FirstRequiredDependency));
        end;
      finally
        List.Free;
      end;
    end;
    Result := Obj.AsJSON;
  finally
    Obj.Free;
  end;
end;

{ package_get_info: install state, plus requirements, users and files of a loaded package. }
function PackageInfoJSON(const PkgName: string; WithFiles: Boolean): string;
var
  Obj, FObj : TJSONObject;
  Arr       : TJSONArray;
  IDEPkg    : TIDEPackage;
  Pkg       : TLazPackage;
  Dep       : TPkgDependency;
  F         : TLazPackageFile;
  I         : Integer;
begin
  Obj := TJSONObject.Create;
  try
    Obj.Add('package_name', PkgName);
    IDEPkg := PackageEditingInterface.IsPackageInstalled(PkgName);
    Obj.Add('is_installed', Assigned(IDEPkg));
    if Assigned(IDEPkg) then
      Obj.Add('package_file', IDEPkg.Filename);
    IDEPkg := PackageEditingInterface.FindPackageWithName(PkgName);
    Obj.Add('is_loaded', Assigned(IDEPkg));
    if IDEPkg is TLazPackage then
    begin
      Pkg := TLazPackage(IDEPkg);
      Obj.Add('loaded_file', Pkg.Filename);
      Obj.Add('version', Pkg.Version.AsString);
      Obj.Add('type', LazPackageTypeIdents[Pkg.PackageType]);
      if Pkg.Description <> '' then
        Obj.Add('description', Capped(Pkg.Description, 400));
      if Pkg.Modified then
        Obj.Add('modified', True);
      if Pkg.ReadOnly then
        Obj.Add('read_only', True);
      if Pkg.Missing then
        Obj.Add('lpk_missing', True);
      Arr := TJSONArray.Create;
      Obj.Add('requires', Arr);
      Dep := Pkg.FirstRequiredDependency;
      while Assigned(Dep) do
      begin
        Arr.Add(DepJSON(Dep));
        Dep := Dep.NextRequiresDependency;
      end;
      Arr := TJSONArray.Create;
      Obj.Add('required_by', Arr);
      Dep := Pkg.FirstUsedByDependency;
      while Assigned(Dep) do
      begin
        Arr.Add(OwnerName(Dep.Owner));
        Dep := Dep.NextUsedByDependency;
      end;
      Obj.Add('file_count', Pkg.FileCount);
      if WithFiles then
      begin
        Arr := TJSONArray.Create;
        Obj.Add('files', Arr);
        for I := 0 to Pkg.FileCount - 1 do
        begin
          F := Pkg.Files[I];
          FObj := TJSONObject.Create;
          Arr.Add(FObj);
          FObj.Add('file', F.GetShortFilename(False));
          FObj.Add('type', PkgFileTypeIdents[F.FileType]);
          if F.Unit_Name <> '' then
            FObj.Add('unit', F.Unit_Name);
          if (F.FileType in PkgFileRealUnitTypes) and not F.InUses then
            FObj.Add('in_uses', False);
        end;
      end;
    end;
    Result := Obj.AsJSON;
  finally
    Obj.Free;
  end;
end;

{ Which loaded packages list a unit; whether the active project can see them. }
function FindUnitJSON(const AUnit: string): string;
var
  Obj, PObj : TJSONObject;
  Arr       : TJSONArray;
  Pkg       : TIDEPackage;
  F         : TLazPackageFile;
  Proj      : TLazProject;
  DepOwner  : TObject;
  I, J      : Integer;
begin
  Obj := TJSONObject.Create;
  try
    Obj.Add('unit_name', AUnit);
    Arr := TJSONArray.Create;
    Obj.Add('packages', Arr);
    Proj := LazarusIDE.ActiveProject;
    for I := 0 to PackageEditingInterface.GetPackageCount - 1 do
    begin
      Pkg := PackageEditingInterface.GetPackages(I);
      for J := 0 to Pkg.FileCount - 1 do
      begin
        F := Pkg.Files[J];
        if not (F.FileType in PkgFileUnitTypes) or
           (CompareText(F.Unit_Name, AUnit) <> 0) and
           (CompareText(ExtractFileNameOnly(F.Filename), AUnit) <> 0) then
          Continue;
        PObj := TJSONObject.Create;
        Arr.Add(PObj);
        PObj.Add('package', Pkg.Name);
        PObj.Add('package_file', Pkg.Filename);
        PObj.Add('unit_file', F.GetFullFilename);
        PObj.Add('installed', Assigned(PackageEditingInterface.IsPackageInstalled(Pkg.Name)));
        if Assigned(Proj) then
          PObj.Add('project_requires',
            PackageEditingInterface.IsOwnerDependingOnPkg(Proj, Pkg.Name, DepOwner));
        Break;
      end;
    end;
    if Arr.Count = 0 then
      Obj.Add('hint', 'No loaded package lists this unit. It may be an FPC unit ' +
        '(check the unit path), or the package is not loaded: try package_search_online.');
    Result := Obj.AsJSON;
  finally
    Obj.Free;
  end;
end;

{ ── Dispatch ─────────────────────────────────────────────────────────────── }

function DispatchPackagesTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  PkgName  : string;
  LpkPath  : string;
  IDEPkg   : TIDEPackage;
  FPList   : TFPList;
  PkgList  : TObjectList;
  PkgID    : TLazPackageID;
  PollCmd  : string;
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
    Ctx.Result := PackageInfoJSON(Ctx.Params.Get('package_name', ''),
                                  Ctx.Params.Get('files', False));
  end

  else if Name = 'project_list_packages' then
  begin
    Result := True;
    if not (LazarusIDE.ActiveProject is TProject) then
    begin
      Ctx.Error := True; Ctx.Result := 'No active project'; Exit;
    end;
    Ctx.Result := ProjectPackagesJSON(TProject(LazarusIDE.ActiveProject),
                    Assigned(Ctx.Params) and Ctx.Params.Get('recursive', False));
  end

  else if Name = 'package_find_unit' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Trim(Ctx.Params.Get('unit_name', '')) = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'unit_name required'; Exit;
    end;
    Ctx.Result := FindUnitJSON(Trim(Ctx.Params.Get('unit_name', '')));
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
    { new code into the IDE needs the user's consent (ADR-013) }
    if not McpConfirmPackageInstall(LpkPath, 'package_install', PkgName) then
    begin
      Ctx.Error := True; Ctx.Result := PkgName; Exit;
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('status',  'rebuilding');
      Obj.Add('message', 'IDE is rebuilding and will restart. Poll with the ' +
                         'command in poll_command until it succeeds.');
      PollCmd := McpPollCommand;
      if PollCmd <> '' then
        Obj.Add('poll_command', PollCmd);
      Ctx.Result          := Obj.AsJSON;
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
      PollCmd := McpPollCommand;
      if PollCmd <> '' then
        Obj.Add('poll_command', PollCmd);
      Ctx.Result          := Obj.AsJSON;
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
    'Search the Online Package Manager''s catalog of community packages (local ' +
    'cache, no network). Finds packages, not component classes: for installed ' +
    'classes use form_search_palette. A result''s downloaded_lpk can go to package_install.',
    SCHEMA_SEARCH_ONLINE, MCP_ANN_RO));
  Tools.Add(MakeTool('package_get_info',
    'A package''s load and install status; for a loaded package also its version, ' +
    'requirements (with status: not_found etc.), the packages using it, and optionally its files.',
    SCHEMA_GET_PACKAGE_INFO_EX, MCP_ANN_RO));
  Tools.Add(MakeTool('project_list_packages',
    'The active project''s required packages as in Project Inspector: version ' +
    'limits, the resolved .lpk, and status (ok, not_found, ...). recursive=true adds the ' +
    'whole dependency graph in compile order.',
    SCHEMA_LIST_PROJECT_PACKAGES, MCP_ANN_RO));
  Tools.Add(MakeTool('package_find_unit',
    'Which loaded packages contain a unit, and whether the active project depends on ' +
    'them. Use for "Can''t find unit" errors.',
    SCHEMA_FIND_UNIT, MCP_ANN_RO));
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
    'Install a package into the IDE (design-time / palette); the IDE rebuilds and ' +
    'restarts. A package not installed yet needs the user''s consent. Run ' +
    'package_compile first.',
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
