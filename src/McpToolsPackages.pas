{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsPackages;

{ Package management tools: get_package_info, add_package_to_project,
  remove_package_from_project, install_package, uninstall_package. }

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

  if Name = 'get_package_info' then
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

  else if Name = 'add_package_to_project' then
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

  else if Name = 'remove_package_from_project' then
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

  else if Name = 'install_package' then
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

  else if Name = 'uninstall_package' then
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
  Tools.Add(MakeTool('get_package_info',
    'Query a package''s load and install status in the running IDE.',
    SCHEMA_GET_PACKAGE_INFO));
  Tools.Add(MakeTool('add_package_to_project',
    'Add a package as a dependency to the active project (.lpi). ' +
    'The package must already be loaded in the IDE. No rebuild required. ' +
    'Returns the updated list of project package dependencies.',
    SCHEMA_ADD_PACKAGE_TO_PROJECT));
  Tools.Add(MakeTool('remove_package_from_project',
    'Remove a package dependency from the active project (.lpi). ' +
    'No rebuild required. Returns the updated list of project package dependencies.',
    SCHEMA_REMOVE_PACKAGE_FROM_PROJECT));
  Tools.Add(MakeTool('install_package',
    'Install a package into the Lazarus IDE (design-time / palette). ' +
    'Triggers an IDE rebuild and restart. Returns {"status":"rebuilding","poll_command":"..."}. ' +
    'Use compile_plugin first to catch errors early.',
    SCHEMA_INSTALL_PACKAGE));
  Tools.Add(MakeTool('uninstall_package',
    'Uninstall a package from the Lazarus IDE. ' +
    'Triggers an IDE rebuild and restart. Returns {"status":"rebuilding","poll_command":"..."}.',
    SCHEMA_UNINSTALL_PACKAGE));
end;

initialization
  RegisterMcpGroup(@DispatchPackagesTool);
  RegisterMcpSchemas(@RegisterPackagesSchemas);

end.
