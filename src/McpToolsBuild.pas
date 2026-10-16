{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsBuild;

{ Build / run tools: project_build, project_run, ide_rebuild, project_get_compiler_errors,
  ide_get_messages, project_run; the rebuilds of package_install and
  package_uninstall, whose schemas are in McpToolsPackages.
  Schema registration also covers package_compile and ide_run_tests, which run
  off the main thread and remain handled in HandleToolsCall. }

{$mode objfpc}{$H+}

interface

implementation

uses
  Classes, SysUtils, Contnrs,
  LazIDEIntf, SrcEditorIntf, ProjectIntf, PackageIntf, CompOptsIntf,
  LazFileUtils, FileUtil,
  IDEMsgIntf, IDEExternToolIntf,
  Controls, Forms,
  fpjson,
  LazDebuggerIntfBaseTypes, BaseDebugManager,
  McpToolContext, McpIdeListeners, McpIdeState, McpDebugGuard, McpConsent;

{ ── Schema constants ─────────────────────────────────────────────────────── }

const
  SCHEMA_BUILD_PROJECT =
    '{"type":"object","properties":{}}';

  SCHEMA_RUN_PROJECT =
    '{"type":"object","properties":{"args":{"type":"string",' +
    '"description":"Command-line arguments for the program. Stored in the project''s ' +
    'run parameters (also used by debug runs); omit to keep the current ones"}}}';

  SCHEMA_COMPILE_PLUGIN =
    '{"type":"object","properties":{"lpk_path":{"type":"string",' +
    '"description":"Absolute path to the .lpk package file to compile"}},' +
    '"required":["lpk_path"]}';

  SCHEMA_REBUILD_IDE =
    '{"type":"object","properties":{}}';

  SCHEMA_RUN_TESTS =
    '{"type":"object","properties":{' +
    '"test_project":{"type":"string","description":"Test project .lpi, absolute or ' +
    'relative to the project directory. Default: the MCP Assistant plugin''s own tests, NOT the open project''s"},' +
    '"junit_out":{"type":"string","description":"Absolute path to also write JUnit XML to"}}}';

  SCHEMA_GET_COMPILER_ERRORS =
    '{"type":"object","properties":{}}';

  SCHEMA_GET_MESSAGES =
    '{"type":"object","properties":{}}';

{ ── Dispatch ─────────────────────────────────────────────────────────────── }

function DispatchBuildTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  Obj      : TJSONObject;
  Errors   : TJSONArray;
  BuildRes : TModalResult;
  Proj     : TLazProject;
  MsgArr   : TJSONArray;
  MsgView  : TExtToolView;
  MsgLine  : TMessageLine;
  MsgObj   : TJSONObject;
  I, J     : Integer;
begin
  Result := False;

  if Name = 'project_get_compiler_errors' then
  begin
    Result := True;
    if Assigned(McpHookManager) then
      Errors := McpHookManager.CurrentCompilerErrors
    else
      Errors := nil;
    if Assigned(Errors) then
      Ctx.Result := Errors.AsJSON
    else
      Ctx.Result := '[]';
  end

  else if Name = 'project_build' then
  begin
    Result := True;
    if not Assigned(LazarusIDE) then
    begin
      Ctx.Error := True; Ctx.Result := 'No IDE available'; Exit;
    end;
    BuildRes := LazarusIDE.DoBuildProject(crCompile, []);
    Obj := TJSONObject.Create;
    try
      Obj.Add('success', BuildRes = mrOK);
      if Assigned(McpHookManager) then
        Errors := McpHookManager.CurrentCompilerErrors
      else
        Errors := nil;
      if Assigned(Errors) then
        Obj.Add('errors', Errors.Clone as TJSONArray)
      else
        Obj.Add('errors', TJSONArray.Create);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'project_run' then
  begin
    Result := True;
    if not Assigned(LazarusIDE) then
    begin
      Ctx.Error := True; Ctx.Result := 'No IDE available'; Exit;
    end;
    if Assigned(Ctx.Params) and (Ctx.Params.IndexOfName('args') >= 0) then
    begin
      Proj := LazarusIDE.ActiveProject;
      if not Assigned(Proj) then
      begin
        Ctx.Error := True; Ctx.Result := 'No active project'; Exit;
      end;
      { stored in the project's run parameters, so debug runs use them too }
      Proj.RunParameters.GetOrCreate('default').CmdLineParams :=
        Ctx.Params.Get('args', '');
    end;
    BuildRes := LazarusIDE.DoRunProjectWithoutDebug;
    Obj := TJSONObject.Create;
    try
      Obj.Add('success', BuildRes = mrOK);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'ide_get_messages' then
  begin
    Result := True;
    MsgArr := TJSONArray.Create;
    try
      if Assigned(IDEMessagesWindow) then
        for I := 0 to IDEMessagesWindow.ViewCount - 1 do
        begin
          MsgView := IDEMessagesWindow.Views[I];
          for J := 0 to MsgView.Lines.Count - 1 do
          begin
            MsgLine := MsgView.Lines.Items[J];
            MsgObj  := TJSONObject.Create;
            MsgObj.Add('urgency', MessageLineUrgencyNames[MsgLine.Urgency]);
            MsgObj.Add('msg',     MsgLine.Msg);
            MsgObj.Add('file',    MsgLine.Filename);
            MsgObj.Add('line',    MsgLine.Line);
            MsgArr.Add(MsgObj);
          end;
        end;
      Obj := TJSONObject.Create;
      try
        Obj.Add('messages',   MsgArr.Clone as TJSONArray);
        Obj.Add('line_count', MsgArr.Count);
        Ctx.Result := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    finally
      MsgArr.Free;
    end;
  end

end;

{ ── Blocking ide_rebuild / package_install ───────────────────────────────── }
{ ide_rebuild, package_install (the same rebuild with a package listed
  first) and package_uninstall (the package removed first) run on the HTTP
  worker thread.  If an exception dialog is open,
  it queues a non-blocking close request to the main thread (TThread.Queue),
  then polls for the dialog globals to clear before proceeding with the rebuild.
  All IDE API calls still happen via TThread.Synchronize. }

type
  TBuildSyncHelper = class
  public
    LpkPath    : string;
    UninstallName : string;  { package_uninstall: the package to remove }
    ToolName   : string;
    PollCmd    : string;
    StopServer : TMcpStopServerProc;
    ConsentOk  : Boolean;
    ConsentMsg : string;
    PkgFound   : Boolean;
    procedure CheckConsent;
    procedure FindUninstallPackage;
    procedure DismissExceptionDialog;
    procedure ReadPollPaths;
    procedure DoStopDebugger;
    procedure DoRebuild;
  end;

var
  GBuildHelper   : TBuildSyncHelper = nil;
  GRebuildActive : LongInt = 0;   { InterlockedCompareExchange guard }

procedure TBuildSyncHelper.DismissExceptionDialog;
var
  I : Integer;
  F : TCustomForm;
begin
  for I := 0 to Screen.FormCount - 1 do
  begin
    F := Screen.Forms[I];
    if F.ClassNameIs('TIDEExceptionDlg') and F.Visible then
    begin
      { Break (mrOK): Close would mean Continue, and the program would run
        past the exception (possibly into its own error box) before the
        debugger is stopped }
      F.ModalResult := mrOK;
      Break;
    end;
  end;
end;

{ Main thread: may LpkPath be installed? (ADR-013) }
procedure TBuildSyncHelper.CheckConsent;
begin
  ConsentOk := McpConfirmPackageInstall(LpkPath, ToolName, ConsentMsg);
end;

{ Main thread: does the package to uninstall exist? }
procedure TBuildSyncHelper.FindUninstallPackage;
begin
  PkgFound := PackageEditingInterface.FindPackageWithName(UninstallName) <> nil;
end;

procedure TBuildSyncHelper.ReadPollPaths;
begin
  PollCmd := McpPollCommand(LpkPath);
end;

procedure TBuildSyncHelper.DoStopDebugger;
begin
  if Assigned(DebugBoss) and (DebugBoss.State in [dsRun, dsPause, dsInternalPause]) then
  begin
    McpMarkDebugDriven;  { no "Execution stopped" dialog }
    DebugBoss.DoStopProject;
  end;
end;

procedure TBuildSyncHelper.DoRebuild;
var
  IDEPkg  : TIDEPackage;
  PkgList : TObjectList;
  PkgID   : TLazPackageID;
  I       : Integer;
  F       : TCustomForm;
begin
  { Close any stray message dialogs (e.g. "Execution stopped") so they do not
    become orphaned when the IDE exits for the rebuild. }
  for I := Screen.FormCount - 1 downto 0 do
  begin
    F := Screen.Forms[I];
    if F.Visible and (F.BorderStyle = bsDialog) then
      F.Close;
  end;
  while SourceEditorManagerIntf.UniqueSourceEditorCount > 0 do
    LazarusIDE.DoCloseEditorFile(
      SourceEditorManagerIntf.UniqueSourceEditors[0], [cfQuiet]);
  if Assigned(StopServer) then StopServer();
  PkgList := TObjectList.Create(True);
  try
    if UninstallName <> '' then
    begin
      IDEPkg := PackageEditingInterface.FindPackageWithName(UninstallName);
      if Assigned(IDEPkg) then
        PackageEditingInterface.UninstallPackage(IDEPkg, False);
    end;
    { A package already installed from this file is just rebuilt: listing it
      again made the IDE rebuild but not restart (2026-10-14). }
    if (LpkPath <> '') and McpPackageNeedsConsent(LpkPath) then
    begin
      PackageEditingInterface.DoOpenPackageFile(LpkPath, [pofDoNotOpenEditor], False);
      IDEPkg := PackageEditingInterface.FindPackageWithName(
                  ExtractFileNameOnly(LpkPath));
      if Assigned(IDEPkg) then
      begin
        PkgID := TLazPackageID.Create;
        PkgID.AssignID(IDEPkg);
        PkgList.Add(PkgID);
      end;
    end;
    PackageEditingInterface.InstallPackages(
      PkgList, [piiifRebuildIDE, piiifSkipChecks, piiifQuiet]);
  finally
    PkgList.Free;
  end;
end;

function DispatchBuildBlockingTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  Obj     : TJSONObject;
  Waited  : Integer;
  LpkPath : string;
  UninstallName : string;
begin
  Result := False;
  if (Name <> 'ide_rebuild') and (Name <> 'package_install') and
     (Name <> 'package_uninstall') then Exit;
  Result := True;

  LpkPath := '';
  if Assigned(Ctx.Params) then
    LpkPath := Ctx.Params.Get('lpk_path', '');
  if (Name = 'package_install') and (LpkPath = '') then
  begin
    Ctx.Error := True; Ctx.Result := 'lpk_path required'; Exit;
  end;
  UninstallName := '';
  if (Name = 'package_uninstall') and Assigned(Ctx.Params) then
    UninstallName := Ctx.Params.Get('package_name', '');
  if (Name = 'package_uninstall') and (UninstallName = '') then
  begin
    Ctx.Error := True; Ctx.Result := 'package_name required'; Exit;
  end;
  if (Name = 'ide_rebuild') and (LpkPath <> '') then
  begin
    Ctx.Error  := True;
    Ctx.Result := 'ide_rebuild only rebuilds; install a package with package_install.';
    Exit;
  end;

  { In-flight guard: refuse a concurrent rebuild. }
  if InterlockedCompareExchange(GRebuildActive, 1, 0) <> 0 then
  begin
    Ctx.Error  := True;
    Ctx.Result := 'A rebuild of the IDE is already in progress.';
    Exit;
  end;
  try

  GBuildHelper.LpkPath    := LpkPath;
  GBuildHelper.UninstallName := UninstallName;
  GBuildHelper.ToolName   := Name;
  GBuildHelper.StopServer := Ctx.StopServer;

  if UninstallName <> '' then
  begin
    TThread.Synchronize(nil, @GBuildHelper.FindUninstallPackage);
    if not GBuildHelper.PkgFound then
    begin
      Ctx.Error := True; Ctx.Result := 'Package not found: ' + UninstallName; Exit;
    end;
  end;

  { installing a package that is not installed yet needs the user's consent }
  if GBuildHelper.LpkPath <> '' then
  begin
    TThread.Synchronize(nil, @GBuildHelper.CheckConsent);
    if not GBuildHelper.ConsentOk then
    begin
      Ctx.Error  := True;
      Ctx.Result := GBuildHelper.ConsentMsg;
      Exit;
    end;
  end;

  { Phase 1 — if the exception dialog is open, close it from the main thread
    via TThread.Queue (non-blocking), then poll until the LCL form is gone.
    Queue is used instead of Synchronize so the worker thread stays free to
    time out if the main thread's modal loop does not process the queue. }
  if (GMcpLastExceptionLabel <> '') or (GMcpExceptionDialogHwnd <> 0) then
  begin
    TThread.Queue(nil, @GBuildHelper.DismissExceptionDialog);
    Waited := 0;
    while (GMcpLastExceptionLabel <> '') or (GMcpExceptionDialogHwnd <> 0) do
    begin
      Sleep(200);
      Inc(Waited, 200);
      if Waited >= 5000 then
      begin
        Ctx.Error  := True;
        Ctx.Result := '{"error":"Exception dialog is still showing after 5 s. ' +
                      'Click Break or Continue on the dialog, then call ' + Name + ' again."}';
        Exit;
      end;
    end;
    Sleep(300);
  end;

  { Phase 2 — main thread is free; read IDE paths. }
  TThread.Synchronize(nil, @GBuildHelper.ReadPollPaths);

  { Build the response JSON before doing anything destructive. }
  Obj := TJSONObject.Create;
  try
    Obj.Add('status',  'rebuilding');
    Obj.Add('message', 'IDE is rebuilding and will restart. Poll with the ' +
                       'command in poll_command until it succeeds.');
    if GBuildHelper.PollCmd <> '' then
      Obj.Add('poll_command', GBuildHelper.PollCmd);
    Ctx.Result          := Obj.AsJSON;
  finally
    Obj.Free;
  end;

  { Phase 3 — stop the debugger (main thread). }
  TThread.Synchronize(nil, @GBuildHelper.DoStopDebugger);

  { Poll for dsNone on the worker thread — never wait inside Synchronize.
    DoStopProject is async; allow up to 20 s for the state to reach dsNone. }
  Waited := 0;
  while Assigned(DebugBoss) and (DebugBoss.State <> dsNone) and (Waited < 20000) do
  begin
    Sleep(200);
    Inc(Waited, 200);
  end;

  { Phase 4 — close editors, dismiss stray dialogs, stop server, rebuild. }
  TThread.Synchronize(nil, @GBuildHelper.DoRebuild);

  finally
    InterlockedCompareExchange(GRebuildActive, 0, 1);
  end;
end;

{ ── Schema registration ──────────────────────────────────────────────────── }

procedure RegisterBuildSchemas(Tools: TJSONArray);
begin
  Tools.Add(MakeTool('project_build',
    'Trigger an incremental build of the active project and return ' +
    'success/failure with any compiler errors.',
    SCHEMA_BUILD_PROJECT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('project_run',
    'Build (if needed) and run the active project without the debugger, ' +
    'optionally with new command-line arguments.',
    SCHEMA_RUN_PROJECT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('package_compile',
    'Compile a Lazarus package (.lpk) using lazbuild and return the full ' +
    'compiler output. Use this as a smoke-test before calling ide_rebuild. ' +
    'Does not restart the IDE.',
    SCHEMA_COMPILE_PLUGIN, MCP_ANN_WRITE));
  Tools.Add(MakeTool('ide_rebuild',
    'Rebuild and restart the IDE with its installed packages; the server is ' +
    'down for about a minute (the result says how to wait). Run package_compile ' +
    'first. To install a package, use package_install.',
    SCHEMA_REBUILD_IDE, MCP_ANN_DEST));
  Tools.Add(MakeTool('ide_run_tests',
    'Compile and run an FPCUnit test project; returns pass/fail counts, per-test ' +
    'output and the test_project that ran, optionally also JUnit XML. Without ' +
    'test_project it runs the MCP Assistant plugin''s OWN suite, not the open ' +
    'project''s: pass test_project (your tests'' .lpi) to test your code.',
    SCHEMA_RUN_TESTS, MCP_ANN_WRITE));
  Tools.Add(MakeTool('project_get_compiler_errors',
    'Return the current build compiler errors and warnings.',
    SCHEMA_GET_COMPILER_ERRORS, MCP_ANN_RO));
  Tools.Add(MakeTool('ide_get_messages',
    'Return all messages from the IDE Messages window (build output, hints, etc.).',
    SCHEMA_GET_MESSAGES, MCP_ANN_RO));
end;

initialization
  GBuildHelper := TBuildSyncHelper.Create;
  RegisterMcpGroup(@DispatchBuildTool);
  RegisterMcpBlockingGroup(@DispatchBuildBlockingTool);
  RegisterMcpSchemas(@RegisterBuildSchemas);

finalization
  GBuildHelper.Free;

end.
