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
  PackageLinks, PackageLinkIntf, PackageDefs,
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
    '"timeout_s":{"type":"integer","description":"Seconds to wait (0..300, default 10; 0 = answer at once, ' +
    'the program keeps running) for the program to end before answering"}}}';

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

  case Name of
    'project_get_compiler_errors':
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
    end;

    'project_build':
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
    end;

    'project_run':
    begin
      Result := True;
      { starts the program and answers at once; the server then waits for its end
        off the main thread (McpRunFinish, ADR-016) }
      Ctx.Result := McpRunLaunch(Ctx.Params, Ctx.Error);
    end;

    'ide_get_messages':
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
    end;
  end;

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
    SelName    : string;     { package_name / lpk_path as given, for ResolveSelector }
    SelLpk     : string;
    SelError   : string;
    SelInstall : Boolean;    { True: an install wants the .lpk; False: an uninstall wants the name }
    ToolName   : string;
    PollCmd    : string;
    StopServer : TMcpStopServerProc;
    ConsentOk  : Boolean;
    ConsentMsg : string;
    PkgFound   : Boolean;
    SaveUnsaved : Boolean;
    SkipCompile : Boolean;
    Unsaved    : TStringList;     { files whose editor holds unsaved changes }
    Diverged   : TStringList;     { packages changed in the IDE AND on disk: saving would overwrite the disk }
    CompileFailed : Boolean;
    CompileJson : string;
    Closed     : TStringList;     { editors DoRebuild closed, to open again if the build fails }
    RebuildOk  : Boolean;
    RebuildFailure : string;
    RaisedText : string;      { class and message of an exception DoRebuild caught }
    HasProject : Boolean;
    constructor Create;
    procedure ReadHasProject;
    destructor Destroy; override;
    procedure CheckUnsaved;
    procedure PreCompile;
    procedure ReopenClosed;
    procedure CollectFailure;
    procedure CheckConsent;
    procedure FindUninstallPackage;
    procedure ResolveSelector;
    procedure DismissExceptionDialog;
    procedure ReadPollPaths;
    procedure DoStopDebugger;
    procedure DoRebuild;
  end;

var
  GBuildHelper   : TBuildSyncHelper = nil;
  GRebuildActive : LongInt = 0;   { InterlockedCompareExchange guard }

procedure TBuildSyncHelper.ReadHasProject;
begin
  HasProject := Assigned(LazarusIDE) and Assigned(LazarusIDE.ActiveProject);
end;

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
{ Main thread: the other half of package_name / lpk_path.  For an install SelLpk is
  filled from SelName (a loaded package, else the IDE's package links); for an
  uninstall SelName from SelLpk (the loaded package of that file, else the file name).
  SelError is set when the two given disagree or nothing is known. }
procedure TBuildSyncHelper.ResolveSelector;
var
  Pkg  : TIDEPackage;
  Link : TPackageLink;
  I    : Integer;
begin
  SelError := '';
  if (SelLpk <> '') and (SelName <> '') and
     not SameText(ExtractFileNameOnly(SelLpk), SelName) then
  begin
    SelError := 'package_name ' + SelName + ' and lpk_path ' + SelLpk +
                ' name different packages; give one of them';
    Exit;
  end;
  if SelInstall and (SelLpk = '') and (SelName <> '') then
  begin
    Pkg := PackageEditingInterface.FindPackageWithName(SelName);
    if Assigned(Pkg) and (Pkg.Filename <> '') then
      SelLpk := Pkg.Filename
    else
    begin
      Link := LazPackageLinks.FindLinkWithPkgName(SelName);
      if Assigned(Link) then SelLpk := Link.LPKFilename;
    end;
    if (SelLpk = '') or not FileExists(SelLpk) then
    begin
      SelLpk := '';
      SelError := 'Package ' + SelName + ' is not loaded and not known to the IDE: give ' +
                  'its lpk_path';
    end;
  end
  else if (not SelInstall) and (SelName = '') and (SelLpk <> '') then
  begin
    SelName := ExtractFileNameOnly(SelLpk);
    for I := 0 to PackageEditingInterface.GetPackageCount - 1 do
      if CompareFilenames(PackageEditingInterface.GetPackages(I).Filename, SelLpk) = 0 then
        SelName := PackageEditingInterface.GetPackages(I).Name;
  end;
end;

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

var
  GRestartNotice : string = '';

procedure TServerRestarter.Tick(Sender: TObject);
begin
  GRestartTimer.Enabled := False;
  { the IDE is on its way out (a restart that is under way): nothing to bring back }
  if Application.Terminated then Exit;
  if GRestartNotice <> '' then McpAddMessage(mluImportant, GRestartNotice);
  if Assigned(GMcpRestartServer) then GMcpRestartServer();
end;

{ Main thread: bring the server back AMs from now, with ANotice in the Messages window
  when it is not empty.  A failed build: a moment from now (the answer of the call that
  failed is still being sent on the old server).  A build that went through: later, as a
  watchdog (see DoRebuild). }
procedure ScheduleServerRestart(AMs: Integer; const ANotice: string);
begin
  if GRestartTimer = nil then
  begin
    GServerRestarter := TServerRestarter.Create;
    GRestartTimer := TTimer.Create(nil);
    GRestartTimer.Enabled := False;
    GRestartTimer.OnTimer := @GServerRestarter.Tick;
  end;
  GRestartNotice := ANotice;
  GRestartTimer.Enabled := False;
  GRestartTimer.Interval := AMs;
  GRestartTimer.Enabled := True;
end;

constructor TBuildSyncHelper.Create;
begin
  inherited Create;
  Unsaved := TStringList.Create;
  Diverged := TStringList.Create;
  Closed  := TStringList.Create;
end;

destructor TBuildSyncHelper.Destroy;
begin
  Diverged.Free;
  Unsaved.Free;
  Closed.Free;
  inherited Destroy;
end;

{ Can the IDE save APkg without asking anything?  A package that was never saved
  has no file to write, and one with a file missing on disk makes the IDE ask what
  to do: a question nobody answers while the server waits for this call. }
function PackageSavesQuietly(APkg: TIDEPackage): Boolean;
var
  I  : Integer;
  FN : string;
begin
  Result := False;
  if APkg.IsVirtual or APkg.ReadOnly then Exit;
  for I := 0 to APkg.FileCount - 1 do
  begin
    FN := APkg.Files[I].GetFullFilename;
    if (APkg.Files[I].FileType = pftVirtualUnit) or (Pos('$(', FN) > 0) then Continue;
    if not FileExists(FN) then Exit;
  end;
  Result := True;
end;

{ Main thread: which open editors and packages hold unsaved changes?  They are saved
  when the caller said so (save_unsaved); a rebuild would drop an editor's text, and
  an unsaved package makes the IDE stop on a "Save package?" question with the server
  already down. }
procedure TBuildSyncHelper.CheckUnsaved;
var
  I       : Integer;
  Ed      : TSourceEditorInterface;
  Pkg     : TIDEPackage;
  Savable : Boolean;
  Lazy    : TLazPackage;
begin
  Unsaved.Clear;
  Diverged.Clear;
  { First, before anything is saved: a package with unsaved changes whose file also
    changed on disk (a branch switch under an open package).  DoSaveAllPackages would
    write the IDE's older copy over the newer file, and the build would use it. }
  for I := 0 to PackageEditingInterface.GetPackageCount - 1 do
  begin
    Pkg := PackageEditingInterface.GetPackages(I);
    if not (Pkg is TLazPackage) or not Pkg.Modified or Pkg.IsVirtual then Continue;
    Lazy := TLazPackage(Pkg);
    if Assigned(Lazy.LPKSource) and Lazy.LPKSource.FileNeedsUpdate(True) then
      Diverged.Add(Pkg.Name + ' (' + Pkg.Filename + ')');
  end;
  if Diverged.Count > 0 then Exit;
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

  { Packages, after the editors: saving a package writes its modified files too.
    DoSaveAllPackages takes every modified package, so it is called only when none of
    them could make the IDE ask something; otherwise they are all reported below. }
  if SaveUnsaved then
  begin
    Savable := False;
    for I := 0 to PackageEditingInterface.GetPackageCount - 1 do
    begin
      Pkg := PackageEditingInterface.GetPackages(I);
      if not Pkg.Modified then Continue;
      Savable := PackageSavesQuietly(Pkg);
      if not Savable then Break;
    end;
    if Savable then
      PackageEditingInterface.DoSaveAllPackages([]);
  end;
  for I := 0 to PackageEditingInterface.GetPackageCount - 1 do
  begin
    Pkg := PackageEditingInterface.GetPackages(I);
    if not Pkg.Modified then Continue;
    if Pkg.IsVirtual then
      Unsaved.Add('package ' + Pkg.Name + ' (never saved)')
    else
      Unsaved.Add('package ' + Pkg.Name + ' (' + Pkg.Filename + ')');
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
  Item : string;
begin
  for Item in Closed do
    LazarusIDE.DoOpenEditorFile(Item, -1, -1, [ofOnlyIfExists, ofQuiet]);
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
    if RaisedText <> '' then
    begin
      Obj.Add('message', 'The IDE raised an exception while starting the build, so the IDE ' +
        'was NOT restarted (' + RaisedText + '). The MCP server is back in a few seconds on ' +
        'the same port and token; the editors that were open are open again. If no project ' +
        'is open (the IDE shows its Project Wizard), open one with project_open and run ' +
        ToolName + ' again.');
      Obj.Add('exception', RaisedText);
    end
    else
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
  { The server is down from here.  If the build or the restart then waits for an answer in
    a dialog nobody gives, the call below never returns: this brings the server back after
    10 minutes (a build here takes about one) and says why.  The call returning replaces it
    with a shorter watchdog, see below. }
  ScheduleServerRestart(600000,
    'MCP Assistant: ' + ToolName + ' did not finish within 10 minutes (a dialog waiting ' +
    'for an answer?). The server is back in this IDE; the rebuild is not done.');
  RaisedText := '';
  PkgList := TObjectList.Create(True);
  try
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
   except
    { the server is already stopped: an exception that left here would leave the IDE
      without one and the caller with a reply nobody can read (2026-11-16, asked from the
      Project Wizard) }
    on E: Exception do
    begin
      RebuildOk  := False;
      RaisedText := E.ClassName + ': ' + E.Message;
      McpAddMessage(mluImportant, 'MCP Assistant: ' + ToolName + ' raised ' + RaisedText);
    end;
   end;
  finally
    PkgList.Free;
  end;
  if not RebuildOk then
  begin
    { no restart is coming: this IDE stays, so put it back as it was }
    ReopenClosed;
    CollectFailure;
    ScheduleServerRestart(2500, '');
  end
  else
    { The IDE restarts itself on success, but only when it is set to restart after a build
      and the restart is not cancelled (a dialog, a project it wants to save): else the
      build is done, this IDE stays and the server is already stopped, for good.  If this
      process is still here 30 s after the call returned, no restart is coming. }
    ScheduleServerRestart(30000,
      'MCP Assistant: ' + ToolName + ' built the IDE but it did not restart (Tools > ' +
      'Configure "Build Lazarus" > "Restart after build" off, or the restart was cancelled). ' +
      'The server is back in this IDE; the rebuilt code is not running yet.');
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

  { In-flight guard: refuse a concurrent rebuild.  It comes before the first write to
    GBuildHelper, which one running rebuild uses: a call that is refused must not touch
    it, and two package_install calls must not fill its strings at the same time. }
  if InterlockedCompareExchange(GRebuildActive, 1, 0) <> 0 then
  begin
    Ctx.Error  := True;
    Ctx.Result := 'A rebuild of the IDE is already in progress.';
    Exit;
  end;
  try

  LpkPath := '';
  if Assigned(Ctx.Params) then
    LpkPath := Ctx.Params.Get('lpk_path', '');
  UninstallName := '';
  if (Name = 'package_install') or (Name = 'package_uninstall') then
  begin
    GBuildHelper.SelLpk  := Trim(LpkPath);
    GBuildHelper.SelName := '';
    GBuildHelper.SelInstall := Name = 'package_install';
    if Assigned(Ctx.Params) then GBuildHelper.SelName := Trim(Ctx.Params.Get('package_name', ''));
    if (GBuildHelper.SelLpk = '') and (GBuildHelper.SelName = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'package_name or lpk_path required'; Exit;
    end;
    TThread.Synchronize(nil, @GBuildHelper.ResolveSelector);
    if GBuildHelper.SelError <> '' then
    begin
      Ctx.Error := True; Ctx.Result := GBuildHelper.SelError; Exit;
    end;
    if Name = 'package_install' then LpkPath := GBuildHelper.SelLpk
    else begin LpkPath := ''; UninstallName := GBuildHelper.SelName; end;
  end;
  if (Name = 'ide_rebuild') and (LpkPath <> '') then
  begin
    Ctx.Error  := True;
    Ctx.Result := 'ide_rebuild only rebuilds; install a package with package_install.';
    Exit;
  end;

  GBuildHelper.LpkPath    := LpkPath;
  GBuildHelper.UninstallName := UninstallName;
  GBuildHelper.ToolName   := Name;
  GBuildHelper.StopServer := Ctx.StopServer;
  GBuildHelper.SaveUnsaved := Assigned(Ctx.Params) and Ctx.Params.Get('save_unsaved', False);
  GBuildHelper.SkipCompile := Assigned(Ctx.Params) and Ctx.Params.Get('skip_compile', False);

  { With no project open (the IDE shows its Project Wizard) the IDE's own build raises an
    access violation, after this server has been stopped. }
  TThread.Synchronize(nil, @GBuildHelper.ReadHasProject);
  if not GBuildHelper.HasProject then
  begin
    Ctx.Error  := True;
    Ctx.Result := Name + ' needs an open project: the IDE shows its Project Wizard, and its ' +
                  'build fails without a project. Open one with project_open, then call ' +
                  Name + ' again. Nothing was changed.';
    Exit;
  end;

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
  if GBuildHelper.Diverged.Count > 0 then
  begin
    Ctx.Error  := True;
    Ctx.Result := '{"status":"not_started","message":"Nothing was changed. These packages have ' +
      'unsaved changes in the IDE and the file on disk changed too (a branch switch, a pull): ' +
      'saving would overwrite the newer file, and the build would use the older copy: ' +
      StringReplace(Trim(GBuildHelper.Diverged.Text), LineEnding, '; ', [rfReplaceAll]) +
      '. Take the disk version with package_open reload=true (the IDE''s changes are lost), ' +
      'or keep the IDE''s with package_save (the disk file is overwritten)."}';
    Exit;
  end;
  if GBuildHelper.Unsaved.Count > 0 then
  begin
    Ctx.Error  := True;
    Ctx.Result := '{"status":"not_started","message":"Nothing was changed. These files and ' +
      'packages have unsaved changes; the rebuild closes every editor without asking, and an ' +
      'unsaved package stops it on a question: ' +
      StringReplace(Trim(GBuildHelper.Unsaved.Text), LineEnding, '; ', [rfReplaceAll]) +
      '. Save them (editor_save, package_save), or pass save_unsaved=true to have ' +
      'them saved first."}';
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
    'optionally with new command-line arguments. Waits up to timeout_s (default 10) and ' +
    'answers {success, running, pid, exit_code, stdout, stderr}; when the program printed ' +
    'a heaptrc report (project_set_settings heaptrc=true, then rebuild) the answer also ' +
    'has heap_report {unfreed_blocks, unfreed_bytes, leaked, leaks[] with address, size ' +
    'and stack}; a program still running ' +
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
    'an editor or a package has unsaved changes (save_unsaved) or the package does not compile ' +
    '(skip_compile); ' +
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
