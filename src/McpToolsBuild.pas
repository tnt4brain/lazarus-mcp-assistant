{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsBuild;

{ Build / run tools: build_project, run_project, rebuild_ide, get_compiler_errors,
  get_messages, run_with_args.
  Schema registration also covers compile_plugin and run_tests, which run
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
  McpToolContext, McpIdeListeners, McpDebugGuard;

{ ── Schema constants ─────────────────────────────────────────────────────── }

const
  SCHEMA_BUILD_PROJECT =
    '{"type":"object","properties":{}}';

  SCHEMA_RUN_PROJECT =
    '{"type":"object","properties":{}}';

  SCHEMA_COMPILE_PLUGIN =
    '{"type":"object","properties":{"lpk_path":{"type":"string",' +
    '"description":"Absolute path to the .lpk package file to compile"}},' +
    '"required":["lpk_path"]}';

  SCHEMA_REBUILD_IDE =
    '{"type":"object","properties":{"lpk_path":{"type":"string",' +
    '"description":"Absolute path to the .lpk package file to install and ' +
    'rebuild with. Omit to rebuild with currently installed packages ' +
    '(e.g. after compile_plugin)."}}}';

  SCHEMA_RUN_TESTS =
    '{"type":"object","properties":{' +
    '"test_project":{"type":"string","description":"Path to the FPCUnit test ' +
    'project .lpi (absolute, or relative to the active project directory). ' +
    'Defaults to tests/mcpserver_tests.lpi next to the active project."},' +
    '"junit_out":{"type":"string","description":"If provided, also write ' +
    'JUnit-compatible XML to this absolute path. Readable by GitHub Actions, ' +
    'Jenkins, and other CI tools."}}}';

  SCHEMA_GET_COMPILER_ERRORS =
    '{"type":"object","properties":{}}';

  SCHEMA_GET_MESSAGES =
    '{"type":"object","properties":{}}';

  SCHEMA_RUN_WITH_ARGS =
    '{"type":"object","properties":{"args":{"type":"string",' +
    '"description":"Command-line argument string passed verbatim to the launched process"}},' +
    '"required":["args"]}';

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

  if Name = 'get_compiler_errors' then
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

  else if Name = 'build_project' then
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

  else if Name = 'run_project' then
  begin
    Result := True;
    if not Assigned(LazarusIDE) then
    begin
      Ctx.Error := True; Ctx.Result := 'No IDE available'; Exit;
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

  else if Name = 'run_with_args' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) then
    begin
      Ctx.Error := True; Ctx.Result := 'args required'; Exit;
    end;
    Proj := LazarusIDE.ActiveProject;
    if not Assigned(Proj) then
    begin
      Ctx.Error := True; Ctx.Result := 'No active project'; Exit;
    end;
    Proj.RunParameters.GetOrCreate('default').CmdLineParams :=
      Ctx.Params.Get('args', '');
    BuildRes := LazarusIDE.DoRunProjectWithoutDebug;
    Obj := TJSONObject.Create;
    try
      Obj.Add('success', BuildRes = mrOK);
      Obj.Add('status',  'running');
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'get_messages' then
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

{ ── Blocking rebuild_ide ─────────────────────────────────────────────────── }
{ rebuild_ide runs on the HTTP worker thread.  If an exception dialog is open,
  it queues a non-blocking close request to the main thread (TThread.Queue),
  then polls for the dialog globals to clear before proceeding with the rebuild.
  All IDE API calls still happen via TThread.Synchronize. }

type
  TBuildSyncHelper = class
  public
    LpkPath    : string;
    PollExe    : string;
    PasFile    : string;
    FpcDir     : string;
    StopServer : TMcpStopServerProc;
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
      F.Close;
      Break;
    end;
  end;
end;

procedure TBuildSyncHelper.ReadPollPaths;
var
  IDEPkg: TIDEPackage;
begin
  FpcDir  := ExtractFilePath(LazarusIDE.GetFPCompilerFilename);
  PollExe := FpcDir + 'instantfpc' + GetExeExt;
  FpcDir  := ExcludeTrailingPathDelimiter(FpcDir);
  if LpkPath <> '' then
    PasFile := ExtractFilePath(ExcludeTrailingPathDelimiter(
                 ExtractFilePath(LpkPath))) + 'wait_for_restart.pas'
  else
  begin
    IDEPkg := PackageEditingInterface.FindPackageWithName('LazMcpAssistant');
    if Assigned(IDEPkg) then
      PasFile := ExtractFilePath(ExcludeTrailingPathDelimiter(
                   ExtractFilePath(IDEPkg.Filename))) + 'wait_for_restart.pas'
    else
      PasFile := '';
  end;
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
    if LpkPath <> '' then
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
  Obj    : TJSONObject;
  Waited : Integer;
begin
  Result := False;
  if Name <> 'rebuild_ide' then Exit;
  Result := True;

  { In-flight guard: refuse a concurrent rebuild. }
  if InterlockedCompareExchange(GRebuildActive, 1, 0) <> 0 then
  begin
    Ctx.Error  := True;
    Ctx.Result := 'rebuild_ide is already in progress.';
    Exit;
  end;
  try

  GBuildHelper.LpkPath    := '';
  GBuildHelper.StopServer := Ctx.StopServer;
  if Assigned(Ctx.Params) then
    GBuildHelper.LpkPath := Ctx.Params.Get('lpk_path', '');

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
                      'Click Break or Continue on the dialog, then call rebuild_ide again."}';
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
    if GBuildHelper.PasFile <> '' then
    begin
      {$IFDEF WINDOWS}
      Obj.Add('poll_command',
        'cmd /c "SET PATH=' + GBuildHelper.FpcDir +
        ';%PATH% && "' + GBuildHelper.PollExe + '" "' + GBuildHelper.PasFile + '""');
      {$ELSE}
      Obj.Add('poll_command',
        'sh -c ''PATH="' + GBuildHelper.FpcDir +
        ':$PATH" "' + GBuildHelper.PollExe + '" "' + GBuildHelper.PasFile + '"''');
      {$ENDIF}
    end;
    Ctx.Result          := Obj.AsJSON;
    Ctx.ConnectionClose := True;
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
  Tools.Add(MakeTool('build_project',
    'Trigger an incremental build of the active project and return ' +
    'success/failure with any compiler errors.',
    SCHEMA_BUILD_PROJECT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('run_project',
    'Build (if needed) and run the active project without the debugger.',
    SCHEMA_RUN_PROJECT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('compile_plugin',
    'Compile a Lazarus package (.lpk) using lazbuild and return the full ' +
    'compiler output. Use this as a smoke-test before calling rebuild_ide. ' +
    'Does not restart the IDE.',
    SCHEMA_COMPILE_PLUGIN, MCP_ANN_WRITE));
  Tools.Add(MakeTool('rebuild_ide',
    'Rebuild and restart the Lazarus IDE. Pass lpk_path to install a package ' +
    'before rebuilding; omit it to rebuild with currently installed packages. ' +
    'The IDE exits immediately after this call; the MCP server will be ' +
    'unavailable for ~60 s. Call compile_plugin first to catch errors early.',
    SCHEMA_REBUILD_IDE, MCP_ANN_DEST));
  Tools.Add(MakeTool('run_tests',
    'Compile and run the FPCUnit test project, then return structured results ' +
    '(pass/fail counts, individual test output). Standalone utility and ' +
    'infrastructure tests always run; protocol and auth tests run only when ' +
    'the MCP server is reachable. Optionally writes JUnit XML for CI consumption.',
    SCHEMA_RUN_TESTS, MCP_ANN_WRITE));
  Tools.Add(MakeTool('get_compiler_errors',
    'Return the current build compiler errors and warnings.',
    SCHEMA_GET_COMPILER_ERRORS, MCP_ANN_RO));
  Tools.Add(MakeTool('get_messages',
    'Return all messages from the IDE Messages window (build output, hints, etc.).',
    SCHEMA_GET_MESSAGES, MCP_ANN_RO));
  Tools.Add(MakeTool('run_with_args',
    'Set command-line arguments for the active project and run it (build if needed). ' +
    'Equivalent to run_project but passes args to the launched process.',
    SCHEMA_RUN_WITH_ARGS, MCP_ANN_WRITE));
end;

initialization
  GBuildHelper := TBuildSyncHelper.Create;
  RegisterMcpGroup(@DispatchBuildTool);
  RegisterMcpBlockingGroup(@DispatchBuildBlockingTool);
  RegisterMcpSchemas(@RegisterBuildSchemas);

finalization
  GBuildHelper.Free;

end.
