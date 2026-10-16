{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpRunProgram;

{ Running the project without the debugger, with its output and exit code (ADR-016).

  project_run arms a handler on the IDE's "run without debug, after building" hook and
  calls DoRunProjectWithoutDebug; the handler starts the program on pipes and takes
  the run over (Handled).  Unarmed, the handler does nothing, so the user's Run menu is
  unchanged.  One reader thread polls both pipes into capped buffers; the worker thread
  of the MCP call waits for the end of the program, or for its output.

  Main thread: McpRunLaunch.  Worker thread: McpRunFinish, project_run_output. }

{$mode objfpc}{$H+}

interface

uses
  fpjson;

{ Main thread.  Stores 'args' in the run parameters when given, builds and starts the
  program.  Answers success, launched and pid, or success=false and an error text. }
function McpRunLaunch(Args: TJSONObject; out Err: Boolean): string;

{ Worker thread.  LaunchText is McpRunLaunch's answer; when the program started, waits up
  to WaitSeconds for it to end and answers with its output and exit code. }
function McpRunFinish(const LaunchText: string; WaitSeconds: Integer): string;

implementation

uses
  Classes, SysUtils, SyncObjs, process, pipes, jsonparser, Controls, Forms,
  LazIDEIntf, ProjectIntf, MacroIntf, LazFileUtils, LazUTF8,
  McpToolContext;

const
  MaxBuffer = 256 * 1024;   { unread bytes kept per stream; the oldest are dropped }
  MaxWait = 300;

type
  TRunThread = class(TThread)
  private
    FProc      : TProcess;
    FLock      : TCriticalSection;
    FOut, FErr : string;     { read from the pipes, not yet handed out }
    FTruncated : Boolean;
    FDone      : TEvent;
    FExitCode  : Integer;
    FPid       : Integer;
    function Pump(Stream: TInputPipeStream; var Buf: string): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AProc: TProcess);
    destructor Destroy; override;
    procedure Take(out AOut, AErr: string; out ATruncated: Boolean);
    function Pending: Boolean;
    function WaitDone(Ms: Integer): Boolean;
    procedure Stop;
    property Pid: Integer read FPid;
    property ExitCode: Integer read FExitCode;
  end;

  TLaunchHandler = class
  public
    Armed       : Boolean;
    LaunchError : string;
    Launched    : Boolean;
    function OnInit(Sender: TObject; var Handled: Boolean): TModalResult;
    procedure NotifyFinished;
  end;

var
  GLock    : TCriticalSection;
  GRun     : TRunThread;       { the latest run; kept after it ends, for its exit code }
  GHandler : TLaunchHandler;
  GHooked  : Boolean;

{ ── The run ──────────────────────────────────────────────────────────────── }

constructor TRunThread.Create(AProc: TProcess);
begin
  FProc := AProc;
  FPid  := Integer(AProc.ProcessID);
  FLock := TCriticalSection.Create;
  FDone := TEvent.Create(nil, True, False, '');
  inherited Create(False);
end;

destructor TRunThread.Destroy;
begin
  FProc.Free;
  FDone.Free;
  FLock.Free;
  inherited Destroy;
end;

function TRunThread.Pump(Stream: TInputPipeStream; var Buf: string): Boolean;
var
  Avail, N, Old: Integer;
begin
  Result := False;
  while Stream.NumBytesAvailable > 0 do
  begin
    Avail := Stream.NumBytesAvailable;
    if Avail > 65536 then Avail := 65536;
    FLock.Enter;
    try
      Old := Length(Buf);
      SetLength(Buf, Old + Avail);
      N := Stream.Read(Buf[Old + 1], Avail);
      SetLength(Buf, Old + N);
      if Length(Buf) > MaxBuffer then
      begin
        Delete(Buf, 1, Length(Buf) - MaxBuffer);
        FTruncated := True;
      end;
    finally
      FLock.Leave;
    end;
    if N <= 0 then Break;
    Result := True;
  end;
end;

procedure TRunThread.Execute;
var
  Alive, Got: Boolean;
begin
  repeat
    Alive := FProc.Running;
    Got := Pump(FProc.Output, FOut);
    if Pump(FProc.Stderr, FErr) then Got := True;
    if not Alive and not Got then Break;
    if not Got then Sleep(10);
  until False;
  FExitCode := Integer(FProc.ExitCode);
  FDone.SetEvent;
  { the IDE's own run reports its end to the hooks on the main thread }
  if Assigned(GHandler) then
    Queue(@GHandler.NotifyFinished);
end;

{ The start of a character cut by the end of the buffer stays for the next read. }
function CompleteUtf8Length(const S: string): Integer;
var
  I, Need: Integer;
begin
  Result := Length(S);
  I := Length(S);
  while (I > 0) and (Length(S) - I < 3) and (Ord(S[I]) and $C0 = $80) do Dec(I);
  if I = 0 then Exit;
  case Ord(S[I]) of
    $C0..$DF: Need := 2;
    $E0..$EF: Need := 3;
    $F0..$F7: Need := 4;
  else
    Exit;
  end;
  if Length(S) - I + 1 < Need then Result := I - 1;
end;

procedure TRunThread.Take(out AOut, AErr: string; out ATruncated: Boolean);
var
  Ended: Boolean;
  Cut: Integer;
begin
  Ended := FDone.WaitFor(0) = wrSignaled;
  FLock.Enter;
  try
    Cut := Length(FOut);
    if not Ended then Cut := CompleteUtf8Length(FOut);
    AOut := Copy(FOut, 1, Cut);
    Delete(FOut, 1, Cut);
    Cut := Length(FErr);
    if not Ended then Cut := CompleteUtf8Length(FErr);
    AErr := Copy(FErr, 1, Cut);
    Delete(FErr, 1, Cut);
    ATruncated := FTruncated;
    FTruncated := False;
  finally
    FLock.Leave;
  end;
  { a program may write anything; the answer is JSON }
  UTF8FixBroken(AOut);
  UTF8FixBroken(AErr);
end;

function TRunThread.Pending: Boolean;
begin
  FLock.Enter;
  try
    Result := (FOut <> '') or (FErr <> '');
  finally
    FLock.Leave;
  end;
end;

function TRunThread.WaitDone(Ms: Integer): Boolean;
begin
  Result := FDone.WaitFor(Ms) = wrSignaled;
end;

procedure TRunThread.Stop;
begin
  if not WaitDone(0) then
  try
    FProc.Terminate(1);
  except
    { it ended meanwhile }
  end;
end;

function RunIsActive: Boolean;
begin
  Result := Assigned(GRun) and not GRun.WaitDone(0);
end;

{ ── Starting the program (main thread, inside the IDE's run) ─────────────── }

function RunMode(Proj: TLazProject): TAbstractRunParamsOptionsMode;
begin
  Result := Proj.RunParameters.Find(Proj.RunParameters.ActiveModeName);
  if Result = nil then
    Result := Proj.RunParameters.GetOrCreate('default');
end;

function Substitute(const S: string; out Ok: Boolean): string;
begin
  Result := S;
  Ok := Assigned(IDEMacros) and IDEMacros.SubstituteMacros(Result);
  if not Ok then Result := '';
end;

{ The program as the IDE would start it: target file, the active run mode's arguments,
  working directory and environment.  Not ported (ADR-016): HideIDEOnRun, a launching
  application, macOS bundles, console window placement. }
function StartProgram(out ErrMsg: string): TRunThread;
var
  Proj    : TLazProject;
  Mode    : TAbstractRunParamsOptionsMode;
  Exe, Dir, CmdLine, Line : string;
  Ok      : Boolean;
  Params  : TStringList;
  Proc    : TProcess;
  I, P    : Integer;
begin
  Result := nil;
  ErrMsg := '';
  Proj := LazarusIDE.ActiveProject;
  if Proj = nil then
  begin
    ErrMsg := 'No active project';
    Exit;
  end;
  Exe := Substitute('$(TargetFile)', Ok);
  if not Ok or (Exe = '') then
  begin
    ErrMsg := 'The project has no target file';
    Exit;
  end;
  if not FileExists(Exe) then
  begin
    ErrMsg := 'The program was not found: ' + Exe;
    Exit;
  end;
  Mode := RunMode(Proj);
  CmdLine := Substitute(Mode.CmdLineParams, Ok);
  if not Ok then
  begin
    ErrMsg := 'The command-line parameters use an unknown macro: ' + Mode.CmdLineParams;
    Exit;
  end;
  Dir := Substitute(Mode.WorkingDirectory, Ok);
  if not Ok then
  begin
    ErrMsg := 'The working directory uses an unknown macro: ' + Mode.WorkingDirectory;
    Exit;
  end;
  if (Dir <> '') and not FilenameIsAbsolute(Dir) then
    Dir := CreateAbsolutePath(Dir, ExtractFilePath(Proj.ProjectInfoFile));
  if Dir = '' then
    Dir := ExtractFilePath(Exe);
  if not DirectoryExists(Dir) then
  begin
    ErrMsg := 'The working directory does not exist: ' + Dir;
    Exit;
  end;

  Params := TStringList.Create;
  Proc   := TProcess.Create(nil);
  try
    SplitCmdLineParams(CmdLine, Params);
    Proc.Executable       := Exe;
    Proc.Parameters.Assign(Params);
    Proc.CurrentDirectory := Dir;
    Proc.Options          := [poUsePipes, poNoConsole];
    { the IDE's environment rules: system variables unless switched off, then the
      overrides, an empty value removing the variable }
    if Mode.IncludeSystemVariables then
      for I := 1 to GetEnvironmentVariableCount do
        Proc.Environment.Add(GetEnvironmentString(I));
    for I := 0 to Mode.UserOverrides.Count - 1 do
    begin
      Line := Mode.UserOverrides[I];
      P := Pos('=', Line);
      if P < 2 then Continue;
      if Copy(Line, P + 1, MaxInt) = '' then
      begin
        if Proc.Environment.IndexOfName(Copy(Line, 1, P - 1)) >= 0 then
          Proc.Environment.Delete(Proc.Environment.IndexOfName(Copy(Line, 1, P - 1)));
      end else
        Proc.Environment.Values[Copy(Line, 1, P - 1)] := Copy(Line, P + 1, MaxInt);
    end;
    try
      Proc.Execute;
    except
      on E: Exception do
      begin
        ErrMsg := 'Could not start ' + Exe + ': ' + E.Message;
        Exit;
      end;
    end;
    { the program has no input: reading stdin ends at once instead of waiting }
    Proc.CloseInput;
    Result := TRunThread.Create(Proc);
    Proc := nil;   { the thread owns it }
  finally
    Proc.Free;
    Params.Free;
  end;
end;

function TLaunchHandler.OnInit(Sender: TObject; var Handled: Boolean): TModalResult;
var
  Run: TRunThread;
begin
  Result := mrOK;
  if not Armed then Exit;
  Handled := True;
  Run := StartProgram(LaunchError);
  if Run = nil then
  begin
    Result := mrCancel;
    Exit;
  end;
  GLock.Enter;
  try
    GRun := Run;
  finally
    GLock.Leave;
  end;
  Launched := True;
end;

procedure TLaunchHandler.NotifyFinished;
begin
  if Assigned(LazarusIDE) then
    LazarusIDE.DoCallRunFinishedHandler;
end;

{ ── project_run ──────────────────────────────────────────────────────────── }

{ A finished run is freed when the next one starts (its exit code is kept until then). }
procedure ReleaseFinishedRun;
var
  Old: TRunThread;
begin
  GLock.Enter;
  try
    Old := GRun;
    if Assigned(Old) and Old.WaitDone(0) then GRun := nil else Old := nil;
  finally
    GLock.Leave;
  end;
  if Assigned(Old) then
  begin
    Old.WaitFor;
    Old.Free;
  end;
end;

function McpRunLaunch(Args: TJSONObject; out Err: Boolean): string;
var
  Obj  : TJSONObject;
  Res  : TModalResult;
  Proj : TLazProject;
begin
  Err := False;
  if not Assigned(LazarusIDE) then
  begin
    Err := True;
    Exit('No IDE available');
  end;
  if RunIsActive then
  begin
    Err := True;
    Exit('A program started by project_run is still running (pid ' +
         IntToStr(GRun.Pid) + '): read it with project_run_output, or stop it with ' +
         'project_run_output stop=true');
  end;
  if Assigned(Args) and (Args.IndexOfName('args') >= 0) then
  begin
    Proj := LazarusIDE.ActiveProject;
    if not Assigned(Proj) then
    begin
      Err := True;
      Exit('No active project');
    end;
    { stored in the project's run parameters, so debug runs use them too }
    RunMode(Proj).CmdLineParams := Args.Get('args', '');
  end;
  ReleaseFinishedRun;
  if not GHooked then
  begin
    LazarusIDE.AddHandlerOnRunWithoutDebugInit(@GHandler.OnInit, True);
    GHooked := True;
  end;
  GHandler.LaunchError := '';
  GHandler.Launched    := False;
  GHandler.Armed       := True;
  try
    Res := LazarusIDE.DoRunProjectWithoutDebug;
  finally
    GHandler.Armed := False;
  end;
  Obj := TJSONObject.Create;
  try
    Obj.Add('success', GHandler.Launched);
    Obj.Add('launched', GHandler.Launched);
    if GHandler.Launched then
      Obj.Add('pid', GRun.Pid)
    else if GHandler.LaunchError <> '' then
      Obj.Add('error', GHandler.LaunchError)
    else if Res <> mrOK then
      Obj.Add('error', 'The build failed or was cancelled: see project_get_compiler_errors ' +
                       'and ide_get_messages');
    Result := Obj.AsJSON;
  finally
    Obj.Free;
  end;
end;

{ ── Reporting (worker thread) ────────────────────────────────────────────── }

function ReportJSON(Run: TRunThread; Launch: TJSONObject): string;
var
  Obj: TJSONObject;
  SOut, SErr: string;
  Trunc: Boolean;
  Done: Boolean;
begin
  Done := Run.WaitDone(0);
  Run.Take(SOut, SErr, Trunc);
  Obj := TJSONObject.Create;
  try
    if Assigned(Launch) then
      Obj.Add('success', True);
    Obj.Add('running', not Done);
    Obj.Add('pid', Run.Pid);
    if Done then
      Obj.Add('exit_code', Run.ExitCode);
    Obj.Add('stdout', SOut);
    Obj.Add('stderr', SErr);
    if Trunc then
      Obj.Add('truncated', True);
    Result := Obj.AsJSON;
  finally
    Obj.Free;
  end;
end;

function ClampWait(Seconds: Integer): Integer;
begin
  if Seconds < 0 then Seconds := 0;
  if Seconds > MaxWait then Seconds := MaxWait;
  Result := Seconds;
end;

function CurrentRun: TRunThread;
begin
  GLock.Enter;
  try
    Result := GRun;
  finally
    GLock.Leave;
  end;
end;

function McpRunFinish(const LaunchText: string; WaitSeconds: Integer): string;
var
  Data: TJSONData;
  Run : TRunThread;
begin
  Result := LaunchText;
  Data := nil;
  try
    try
      Data := GetJSON(LaunchText);
    except
      Exit;   { an error text, not the launch answer }
    end;
    if not (Data is TJSONObject) or not TJSONObject(Data).Get('launched', False) then
      Exit;
    Run := CurrentRun;
    if Run = nil then Exit;
    Run.WaitDone(ClampWait(WaitSeconds) * 1000);
    Result := ReportJSON(Run, TJSONObject(Data));
  finally
    Data.Free;
  end;
end;

{ ── project_run_output ───────────────────────────────────────────────────── }

const
  SCHEMA_RUN_OUTPUT =
    '{"type":"object","properties":{' +
    '"wait_seconds":{"type":"integer","description":"Wait up to this long (0..300, default 0) ' +
    'for the program to end or write something"},' +
    '"stop":{"type":"boolean","description":"Terminate the program first"}}}';

function DispatchRunOutputTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  Run  : TRunThread;
  Wait, Waited : Integer;
begin
  Result := Name = 'project_run_output';
  if not Result then Exit;
  Run := CurrentRun;
  if Run = nil then
  begin
    Ctx.Error  := True;
    Ctx.Result := 'No program has been started by project_run';
    Exit;
  end;
  if Assigned(Ctx.Params) and Ctx.Params.Get('stop', False) then
  begin
    Run.Stop;
    Run.WaitDone(3000);
  end;
  Wait := 0;
  if Assigned(Ctx.Params) then
    Wait := ClampWait(Ctx.Params.Get('wait_seconds', 0)) * 1000;
  Waited := 0;
  while (Waited < Wait) and not Run.WaitDone(0) and not Run.Pending do
  begin
    Sleep(50);
    Inc(Waited, 50);
  end;
  Ctx.Result := ReportJSON(Run, nil);
end;

procedure RegisterRunSchemas(Tools: TJSONArray);
begin
  Tools.Add(MakeTool('project_run_output',
    'Output of the program started by project_run: what it wrote to stdout and stderr ' +
    'since the last read, and its exit_code once it has ended. wait_seconds waits for the ' +
    'end of the program or for new output; stop=true terminates it. The last run is ' +
    'kept until the next project_run.',
    SCHEMA_RUN_OUTPUT, MCP_ANN_WRITE));
end;

procedure Shutdown;
var
  Run: TRunThread;
begin
  Run := GRun;
  GRun := nil;
  if Assigned(Run) then
  begin
    Run.Stop;
    Run.WaitFor;
    Run.Free;
  end;
  if GHooked and Assigned(LazarusIDE) then
    LazarusIDE.RemoveHandlerOnRunWithoutDebugInit(@GHandler.OnInit);
  GHooked := False;
  TThread.RemoveQueuedEvents(TThreadMethod(@GHandler.NotifyFinished));
end;

initialization
  GLock    := TCriticalSection.Create;
  GHandler := TLaunchHandler.Create;
  RegisterMcpBlockingGroup(@DispatchRunOutputTool);
  RegisterMcpSchemas(@RegisterRunSchemas);

finalization
  Shutdown;
  GHandler.Free;
  GLock.Free;

end.
