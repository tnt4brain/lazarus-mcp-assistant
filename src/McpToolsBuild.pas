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
  Controls, Forms, ExtCtrls,
  fpjson, jsonparser,
  LazDebuggerIntfBaseTypes, BaseDebugManager,
  McpToolContext, McpIdeListeners, McpIdeState, McpDebugGuard, McpConsent,
  McpToolsPkgManage, McpRunProgram, McpMessages;

{ ── Schema constants ─────────────────────────────────────────────────────── }

const
  SCHEMA_BUILD_PROJECT =
    '{"type":"object","properties":{}}';

  SCHEMA_RUN_PROJECT =
    '{"type":"object","properties":{"args":{"type":"string",' +
    '"description":"Command-line arguments for the program. Stored in the project''s ' +
    'run parameters (also used by debug runs); omit to keep the current ones"},' +
    '"stdin":{"type":"string","description":"Text written to the program''s stdin at ' +
    'start. Without keep_stdin_open, stdin is closed after it"},' +
    '"keep_stdin_open":{"type":"boolean","description":"Leave stdin open, to be fed with ' +
    'project_run_input"},' +
    '"wait_seconds":{"type":"integer","description":"Wait up to this long (0..300, default 10) ' +
    'for the program to end before answering"}}}';

  SCHEMA_COMPILE_PLUGIN =
    '{"type":"object","properties":{"lpk_path":{"type":"string",' +
    '"description":"Absolute path to the .lpk package file to compile"},' +
    '"package_name":{"type":"string","description":"Or a package loaded in the IDE"},' +
    '"method":{"type":"string","description":"auto (default): the IDE''s compiler for a ' +
    'package that is loaded, lazbuild otherwise; or ide, or lazbuild"},' +
    '"clean":{"type":"boolean","description":"Rebuild everything (-B). The IDE skips a unit ' +
    'whose file looks unchanged, e.g. edited within the same second as the last build"}}}';

  SCHEMA_REBUILD_IDE =
    '{"type":"object","properties":{' + MCP_REBUILD_FLAGS + '}}';

  SCHEMA_RUN_TESTS =
    '{"type":"object","properties":{' +
    '"test_project":{"type":"string","description":"Test project .lpi, absolute or ' +
    'relative to the project directory. Default: the MCP Assistant plugin''s own tests, NOT the open project''s"},' +
    '"junit_out":{"type":"string","description":"Absolute path to also write JUnit XML to"},' +
    '"suite":{"type":"string","description":"Run only this test class or Class.Test (FPCUnit --suite=) instead of all"},' +
    '"env":{"type":"object","additionalProperties":{"type":"string"},"description":"Environment variables for the test program, added to the IDE''s (for example {\"MCP_DEBUG_TESTS\":\"1\"})"}}}';

  SCHEMA_GET_COMPILER_ERRORS =
    '{"type":"object","properties":{}}';

  SCHEMA_GET_MESSAGES =
    '{"type":"object","properties":{' +
    '"skip_own":{"type":"boolean","description":"true: leave out the lines this server ' +
    'adds itself (SubTool \"MCP Server\"); default false: everything"}}}';

{ ── Dispatch ─────────────────────────────────────────────────────────────── }

function DispatchBuildTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  Obj      : TJSONObject;
  Errors   : TJSONArray;
  Warns    : TJSONArray;
  BuildRes : TModalResult;
  MsgArr   : TJSONArray;
  MsgView  : TExtToolView;
  MsgLine  : TMessageLine;
  MsgOwn   : Boolean;
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
      { every error line of the build, from the Messages window; the one the
        user had selected is all the compiler hook knows }
      Errors := TJSONArray.Create;
      Warns  := TJSONArray.Create;
      try
        McpCompilerMessages(Errors, Warns);
        if (Errors.Count = 0) and (BuildRes <> mrOK) and
           Assigned(McpHookManager) and Assigned(McpHookManager.CurrentCompilerErrors) then
          Obj.Add('errors', McpHookManager.CurrentCompilerErrors.Clone as TJSONArray)
        else
          Obj.Add('errors', Errors.Clone as TJSONArray);
        Obj.Add('warning_count', Warns.Count);
      finally
        Errors.Free;
        Warns.Free;
      end;
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'project_run' then
  begin
    Result := True;
    { starts the program and answers at once; the server then waits for its end
      off the main thread (McpRunFinish, ADR-016) }
    Ctx.Result := McpRunLaunch(Ctx.Params, Ctx.Error);
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
            MsgOwn  := McpIsOwnLine(MsgLine);
            if MsgOwn and Ctx.Params.Get('skip_own', False) then Continue;
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
    SaveUnsaved : Boolean;
    SkipCompile : Boolean;
    Unsaved    : TStringList;     { files whose editor holds unsaved changes }
    CompileFailed : Boolean;
    CompileJson : string;
    Closed     : TStringList;     { editors DoRebuild closed, to open again if the build fails }
    RebuildOk  : Boolean;
    RebuildFailure : string;
    constructor Create;
    destructor Destroy; override;
    procedure CheckUnsaved;
    procedure PreCompile;
    procedure ReopenClosed;
    procedure CollectFailure;
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

var
  GRestartTimer : TTimer = nil;

type
  TServerRestarter = class
    procedure Tick(Sender: TObject);
  end;

var
  GServerRestarter : TServerRestarter = nil;

procedure TServerRestarter.Tick(Sender: TObject);
begin
  GRestartTimer.Enabled := False;
  if Assigned(GMcpRestartServer) then GMcpRestartServer();
end;

{ Main thread: bring the server back a moment from now (the answer of the call that
  failed is still being sent on the old one). }
procedure ScheduleServerRestart;
begin
  if GRestartTimer = nil then
  begin
    GServerRestarter := TServerRestarter.Create;
    GRestartTimer := TTimer.Create(nil);
    GRestartTimer.Enabled := False;
    GRestartTimer.OnTimer := @GServerRestarter.Tick;
  end;
  GRestartTimer.Interval := 2500;
  GRestartTimer.Enabled := True;
end;

constructor TBuildSyncHelper.Create;
begin
  inherited Create;
  Unsaved := TStringList.Create;
  Closed  := TStringList.Create;
end;

destructor TBuildSyncHelper.Destroy;
begin
  Unsaved.Free;
  Closed.Free;
  inherited Destroy;
end;

{ Main thread: which open editors hold unsaved changes?  They are saved when the
  caller said so (save_unsaved); closing an editor for the rebuild would drop them. }
procedure TBuildSyncHelper.CheckUnsaved;
var
  I  : Integer;
  Ed : TSourceEditorInterface;
begin
  Unsaved.Clear;
  for I := 0 to SourceEditorManagerIntf.UniqueSourceEditorCount - 1 do
  begin
    Ed := SourceEditorManagerIntf.UniqueSourceEditors[I];
    if Ed.Modified then
      Unsaved.Add(Ed.FileName);
  end;
  if SaveUnsaved then
    for I := Unsaved.Count - 1 downto 0 do
    begin
      Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(Unsaved[I]);
      if Assigned(Ed) and (LazarusIDE.DoSaveEditorFile(Ed, []) = mrOk) then
        Unsaved.Delete(I);
    end;
end;

{ Main thread: compile what the rebuild will compile, with the IDE's own compiler,
  while this IDE is still whole.  A package that is not loaded is left to the rebuild. }
procedure TBuildSyncHelper.PreCompile;
var
  P   : TJSONObject;
  Err : string;
  D   : TJSONData;
begin
  CompileFailed := False;
  CompileJson   := '';
  if SkipCompile or (UninstallName <> '') then Exit;
  P := TJSONObject.Create;
  try
    if LpkPath <> '' then
      P.Add('lpk_path', LpkPath)
    else if Assigned(PackageEditingInterface.FindPackageWithName('LazMcpAssistant')) then
      P.Add('package_name', 'LazMcpAssistant')
    else
      Exit;
    Err := '';
    CompileJson := McpCompilePackageIde(P, Err);
    if (Err <> '') or (CompileJson = '') or (Pos('use_lazbuild', CompileJson) > 0) then
    begin
      CompileJson := '';
      Exit;
    end;
    D := GetJSON(CompileJson);
    try
      CompileFailed := (D is TJSONObject) and not TJSONObject(D).Get('success', True);
    finally
      D.Free;
    end;
  finally
    P.Free;
  end;
end;

procedure TBuildSyncHelper.ReopenClosed;
var
  I : Integer;
begin
  for I := 0 to Closed.Count - 1 do
    LazarusIDE.DoOpenEditorFile(Closed[I], -1, -1, [ofOnlyIfExists, ofQuiet]);
  Closed.Clear;
end;

{ Main thread: the build ended without restarting the IDE.  Say so, with the compiler
  messages, and put the editors and the server back. }
procedure TBuildSyncHelper.CollectFailure;
var
  Obj : TJSONObject;
  Errors, Warnings : TJSONArray;
begin
  Obj := TJSONObject.Create;
  Errors := TJSONArray.Create;
  Warnings := TJSONArray.Create;
  try
    McpCompilerMessages(Errors, Warnings);
    Obj.Add('status', 'rebuild_failed');
    Obj.Add('message', 'The IDE build failed, so the IDE was NOT restarted. The MCP server ' +
      'is back in a few seconds on the same port and token; the editors that were open are ' +
      'open again. Fix the errors, then run ' + ToolName + ' again.');
    Obj.Add('errors', Errors); Errors := nil;
    Obj.Add('warning_count', Warnings.Count);
    RebuildFailure := Obj.AsJSON;
  finally
    Errors.Free;
    Warnings.Free;
    Obj.Free;
  end;
  McpAddMessage(mluImportant, 'MCP Assistant: ' + ToolName +
    ' failed; the IDE was not restarted. See the build messages above.');
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
  Closed.Clear;
  while SourceEditorManagerIntf.UniqueSourceEditorCount > 0 do
  begin
    if SourceEditorManagerIntf.UniqueSourceEditors[0].FileName <> '' then
      Closed.Add(SourceEditorManagerIntf.UniqueSourceEditors[0].FileName);
    LazarusIDE.DoCloseEditorFile(
      SourceEditorManagerIntf.UniqueSourceEditors[0], [cfQuiet]);
  end;
  RebuildOk := True;
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
    { On success the IDE restarts itself and this does not matter.  If it comes back
      with anything but ok, the build failed and this IDE is still the one running. }
    RebuildOk := PackageEditingInterface.InstallPackages(
      PkgList, [piiifRebuildIDE, piiifSkipChecks, piiifQuiet]) = mrOk;
  finally
    PkgList.Free;
  end;
  if not RebuildOk then
  begin
    { no restart is coming: this IDE stays, so put it back as it was }
    ReopenClosed;
    CollectFailure;
    ScheduleServerRestart;
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
  GBuildHelper.SaveUnsaved := Assigned(Ctx.Params) and Ctx.Params.Get('save_unsaved', False);
  GBuildHelper.SkipCompile := Assigned(Ctx.Params) and Ctx.Params.Get('skip_compile', False);

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

  { Nothing destructive until two things are known: no editor holds unsaved text
    (closing it for the rebuild would drop it), and the build can succeed (a failed
    build used to leave the IDE half rebuilt, with the server down). }
  TThread.Synchronize(nil, @GBuildHelper.CheckUnsaved);
  if GBuildHelper.Unsaved.Count > 0 then
  begin
    Ctx.Error  := True;
    Ctx.Result := '{"status":"not_started","message":"Nothing was changed. These files have ' +
      'unsaved changes, and the rebuild closes every editor without asking: ' +
      StringReplace(Trim(GBuildHelper.Unsaved.Text), LineEnding, '; ', [rfReplaceAll]) +
      '. Save them (editor_save), or pass save_unsaved=true to have them saved first."}';
    Exit;
  end;
  TThread.Synchronize(nil, @GBuildHelper.PreCompile);
  if GBuildHelper.CompileFailed then
  begin
    Ctx.Error  := True;
    Ctx.Result := '{"status":"not_started","message":"Nothing was changed: the package does ' +
      'not compile, so the rebuild would have failed. Fix the errors (skip_compile=true ' +
      'skips this check).","compile":' + GBuildHelper.CompileJson + '}';
    Exit;
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
  if not GBuildHelper.RebuildOk then
  begin
    Ctx.Error  := True;
    Ctx.Result := GBuildHelper.RebuildFailure;
  end;

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
    'optionally with new command-line arguments. Waits up to wait_seconds (default 10) and ' +
    'answers {success, running, pid, exit_code, stdout, stderr}; a program still running ' +
    '(a GUI program, a server) comes back with running=true: read it later with ' +
    'project_run_output, which can also stop it. The program has no console window. Its ' +
    'stdin is closed (it reads end of file) unless you pass stdin text or ' +
    'keep_stdin_open=true and then talk to it with project_run_input; one program at a time.',
    SCHEMA_RUN_PROJECT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('package_compile',
    'Compile a Lazarus package by package_name or lpk_path: with the IDE''s own ' +
    'compiler when the package is open in the IDE (messages also in ide_get_messages; unsaved ' +
    'editor files are compiled as on disk and listed), else with lazbuild. Returns ' +
    '{method, success, errors}. Use this as a smoke-test before calling ide_rebuild. ' +
    'Does not restart the IDE.',
    SCHEMA_COMPILE_PLUGIN, MCP_ANN_WRITE));
  Tools.Add(MakeTool('ide_rebuild',
    'Rebuild and restart the IDE with its installed packages; the server is ' +
    'down for about a minute (the result says how to wait). Run package_compile ' +
    'first. To install a package, use package_install. Refused, with nothing changed, while ' +
    'an editor has unsaved changes (save_unsaved) or the package does not compile (skip_compile); ' +
    'a failed build leaves the IDE running with the errors as the answer.',
    SCHEMA_REBUILD_IDE, MCP_ANN_DEST));
  Tools.Add(MakeTool('ide_run_tests',
    'Compile and run an FPCUnit test project; returns pass/fail counts, per-test ' +
    'output and the test_project that ran, optionally also JUnit XML. Without ' +
    'test_project it runs the MCP Assistant plugin''s OWN suite, not the open ' +
    'project''s: pass test_project (your tests'' .lpi) to test your code. ' +
    'suite runs one class or test; env sets environment variables for the run.',
    SCHEMA_RUN_TESTS, MCP_ANN_WRITE));
  Tools.Add(MakeTool('project_get_compiler_errors',
    'Return the current build compiler errors and warnings.',
    SCHEMA_GET_COMPILER_ERRORS, MCP_ANN_RO));
  Tools.Add(MakeTool('ide_get_messages',
    'Return all messages from the IDE Messages window (build output, hints, etc.), ' +
    'including the lines this server adds itself; skip_own leaves those out.',
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
