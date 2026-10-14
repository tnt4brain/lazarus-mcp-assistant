{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsDebugger;

{ Debugger tools: set_breakpoint, remove_breakpoint, list_breakpoints,
  get_debug_state,
  run_debugger, pause_debugger, stop_debugger,
  step_over, step_into, step_out, run_to_line,
  get_call_stack, evaluate_expression,
  get_local_variables, set_local_variable.

  Threading model:
    Non-blocking tools  — dispatched via DispatchDebuggerTool, which runs on
                          the IDE main thread (normal SyncCallTool path).
    Blocking tools      — dispatched via DispatchDebuggerBlockingTool, which
                          runs on the MCP worker thread and issues IDE commands
                          through TThread.Synchronize while polling DebugBoss.State
                          on the worker thread between commands. }

{$mode objfpc}{$H+}

interface

implementation

uses
  Classes, SysUtils,
  LazIDEIntf, LazFileUtils, SrcEditorIntf,
  BaseDebugManager,
  LazDebuggerIntfBaseTypes,  { TDBGState }
  LazDebuggerIntf,           { TDebuggerDataState (ddsValid, ddsRequested, …) }
  DbgIntfDebuggerBase,       { TDBGType, TDBGEvaluateResultCallback }
  Debugger,                  { TIDEBreakPoint, TIDEBreakPoints }
  fpjson,
  McpIdeListeners,           { GMcpLastExceptionLabel }
  McpToolContext;


{ ── Sync helper class ────────────────────────────────────────────────────── }
{ Each method is safe to pass to TThread.Synchronize.
  Fields act as in/out parameters for the synchronised operation.
  Only one debug operation runs at a time (MCP calls are serialised), so a
  single shared instance is sufficient. }

type
  TDbgSyncHelper = class
  public
    { ReadState output }
    OutState    : TDBGState;
    OutFileName : string;
    OutLine     : Integer;
    { IssueCmd input }
    InCmd       : Integer;  { 0=run 1=pause 2=stop 3=stepover 4=stepinto 5=stepout }
    { Breakpoint in/out }
    InBpFile    : string;
    InBpLine    : Integer;
    InBpEnabled : Boolean;
    OutBp       : TIDEBreakPoint;
    OutBpFound  : Boolean;
    { Evaluate in/out }
    InEvalExpr     : string;
    OutEvalRes     : string;
    OutEvalType    : string;
    OutEvalOk      : Boolean;
    FEvalFired     : Boolean;
    OutEvalStarted : Boolean;  { True = DebugBoss.Evaluate returned True }
    { CallStack in/out }
    InMaxFrames   : Integer;
    OutCSThreadId : Integer;
    OutCSCount    : Integer;  { -1 = count not known yet; else frames to return }
    OutCSReady    : Boolean;
    OutCSJSON     : string;
    { Local variables in/out }
    InLocalsFrame  : Integer;
    OutLocalsThread: Integer;
    OutLocalsReady : Boolean;
    OutLocalsJSON  : string;
    { Methods }
    procedure ReadState;
    procedure IssueCmd;
    procedure AddBreakpoint;
    procedure RemoveBreakpoint;
    procedure EvaluateCallback(Sender: TObject; ASuccess: Boolean;
      ResultText: string; ResultDBGType: TDBGType);
    procedure DoEvaluateAndWait;  { single Synchronize: starts eval + waits on main thread }
    procedure InitCallStack;
    procedure ReadCallStack;
    procedure InitLocals;
    procedure ReadLocals;
  end;

procedure TDbgSyncHelper.ReadState;
var
  Ed : TSourceEditorInterface;
begin
  OutState    := dsNone;
  OutFileName := '';
  OutLine     := 0;
  if not Assigned(DebugBoss) then Exit;
  OutState := DebugBoss.State;
  if OutState = dsPause then
  begin
    Ed := SourceEditorManagerIntf.ActiveEditor;
    if Assigned(Ed) then
    begin
      OutFileName := Ed.FileName;
      OutLine     := Ed.CursorTextXY.Y;
    end;
  end;
end;

procedure TDbgSyncHelper.IssueCmd;
begin
  case InCmd of
    { Run/continue: use the full F9 path so a fresh session initializes the
      debugger backend and sets ToolStatus=itDebugger before calling
      StartDebugging. DebugBoss.RunDebugger alone requires ToolStatus to already
      be itDebugger, which is not the case when starting from dsNone. }
    0 : LazarusIDE.DoRunProjectWithDebug;
    1 : begin if Assigned(DebugBoss) then DebugBoss.DoPauseProject; end;
    2 : begin if Assigned(DebugBoss) then DebugBoss.DoStopProject; end;
    3 : begin if Assigned(DebugBoss) then DebugBoss.DoStepOverProject; end;
    4 : begin if Assigned(DebugBoss) then DebugBoss.DoStepIntoProject; end;
    5 : begin if Assigned(DebugBoss) then DebugBoss.DoStepOutProject; end;
  end;
end;

procedure TDbgSyncHelper.AddBreakpoint;
begin
  OutBp := nil;
  if not Assigned(DebugBoss) or not Assigned(DebugBoss.BreakPoints) then Exit;
  OutBp := DebugBoss.BreakPoints.Add(InBpFile, InBpLine);
  if Assigned(OutBp) then
    OutBp.Enabled := InBpEnabled;
end;

procedure TDbgSyncHelper.RemoveBreakpoint;
var
  I  : Integer;
  BP : TIDEBreakPoint;
begin
  OutBpFound := False;
  if not Assigned(DebugBoss) or not Assigned(DebugBoss.BreakPoints) then Exit;
  for I := DebugBoss.BreakPoints.Count - 1 downto 0 do
  begin
    BP := DebugBoss.BreakPoints.Items[I];
    if SameText(BP.Source, InBpFile) and (BP.Line = InBpLine) then
    begin
      BP.Free;
      OutBpFound := True;
      Break;
    end;
  end;
end;

procedure TDbgSyncHelper.EvaluateCallback(Sender: TObject; ASuccess: Boolean;
  ResultText: string; ResultDBGType: TDBGType);
begin
  FEvalFired  := True;
  OutEvalOk   := ASuccess;
  OutEvalRes  := ResultText;
  if Assigned(ResultDBGType) then
    OutEvalType := ResultDBGType.TypeName
  else
    OutEvalType := '';
end;

procedure TDbgSyncHelper.DoEvaluateAndWait;
{ Runs on the main thread via TThread.Synchronize.  Starts the async evaluation
  and returns immediately — the HTTP thread polls FEvalFired while the main
  thread's own event loop delivers DoCallback_DecRef via ProcessAsyncCallQueue.
  OutEvalStarted records whether DebugBoss.Evaluate returned True. }
begin
  OutEvalOk      := False;
  OutEvalRes     := '';
  OutEvalType    := '';
  FEvalFired     := False;
  OutEvalStarted := False;
  if not Assigned(DebugBoss) then
  begin
    FEvalFired := True;
    OutEvalRes := 'DebugBoss not assigned';
    Exit;
  end;
  try
    OutEvalStarted := DebugBoss.Evaluate(InEvalExpr, @EvaluateCallback);
    if not OutEvalStarted then
    begin
      FEvalFired := True;
      OutEvalRes := 'Evaluate returned False (dcEvaluate not in Commands or ToolStatus<>itDebugger)';
    end;
  except on E: Exception do
  begin
    FEvalFired := True;
    OutEvalRes := 'Exception: ' + E.Message;
  end;
  end;
  { Return immediately; the main thread's Application.Run loop will call
    ProcessAsyncCallQueue which delivers DoCallback_DecRef → EvaluateCallback. }
end;

procedure TDbgSyncHelper.InitCallStack;
{ Trigger async call-stack load for the current thread.
  CountLimited → HasAtLeastCount → RequestAtLeastCount: this only updates the
  stack's "at least N" info.  CountValidity stays ddsUnknown unless the backend
  happened to read every frame, so ReadCallStack must not wait on it alone. }
var
  Stack : TIdeCallStack;
  TId   : Integer;
begin
  OutCSReady    := False;
  OutCSThreadId := 0;
  OutCSCount    := -1;
  OutCSJSON     := '';
  if not Assigned(DebugBoss) or not Assigned(DebugBoss.CallStack) then Exit;
  if Assigned(DebugBoss.Threads) and
     Assigned(DebugBoss.Threads.CurrentThreads) then
    TId := DebugBoss.Threads.CurrentThreads.CurrentThreadId
  else
    TId := 0;
  OutCSThreadId := TId;
  Stack := DebugBoss.CallStack.CurrentCallStackList.EntriesForThreads[TId];
  if not Assigned(Stack) then Exit;
  Stack.CountLimited(InMaxFrames + 1);  { trigger async load }
end;

procedure TDbgSyncHelper.ReadCallStack;
{ Called from blocking worker via Synchronize until OutCSReady = True.
  Two async phases, each triggered exactly once:
    1. count  — InitCallStack requested "at least InMaxFrames+1" frames; wait
                until either the full count or that minimum is known.
    2. frames — PrepareRange creates the entries as ddsRequested and queues
                one worker per frame; wait until none is still pending.
  Both checks below only read state: HasAtLeastCount re-requests only while its
  validity is ddsUnknown (never the case after InitCallStack), and Entries[I]
  on an entry PrepareRange already created is a plain lookup. }
var
  Stack  : TIdeCallStack;
  Entry  : TIdeCallStackEntry;
  Arr    : TJSONArray;
  EObj   : TJSONObject;
  I      : Integer;
begin
  OutCSReady := False;
  if not Assigned(DebugBoss) or not Assigned(DebugBoss.CallStack) then
  begin
    OutCSReady := True;  { nothing available — stop polling }
    OutCSJSON  := '[]';
    Exit;
  end;
  Stack := DebugBoss.CallStack.CurrentCallStackList.EntriesForThreads[OutCSThreadId];
  if not Assigned(Stack) then
  begin
    OutCSReady := True;
    OutCSJSON  := '[]';
    Exit;
  end;

  { Phase 1 — frame count }
  if OutCSCount < 0 then
  begin
    case Stack.CountValidity of
      ddsValid:
        if Stack.Count < InMaxFrames then
          OutCSCount := Stack.Count
        else
          OutCSCount := InMaxFrames;
      ddsInvalid, ddsError:
        OutCSCount := 0;
    else
      if Stack.HasAtLeastCount(InMaxFrames + 1) = nbTrue then
        OutCSCount := InMaxFrames
      else
        Exit;  { still loading; caller retries }
    end;
    if OutCSCount > 0 then
      Stack.PrepareRange(0, OutCSCount);  { trigger async frame load, once }
    Exit;  { frames are read on the next poll }
  end;

  { Phase 2 — frame details }
  for I := 0 to OutCSCount - 1 do
  begin
    Entry := Stack.Entries[I];
    if Assigned(Entry) and
       (Entry.Validity in [ddsUnknown, ddsRequested, ddsEvaluating]) then
      Exit;  { still loading; caller retries }
  end;

  Arr := TJSONArray.Create;
  try
    for I := 0 to OutCSCount - 1 do
    begin
      Entry := Stack.Entries[I];
      if Entry = nil then Continue;
      EObj := TJSONObject.Create;
      EObj.Add('index',    I);
      EObj.Add('file',     Entry.Source);
      EObj.Add('line',     Entry.Line);
      EObj.Add('function', Entry.FunctionName);
      EObj.Add('address',  Format('$%x', [Entry.Address]));
      Arr.Add(EObj);
    end;
    OutCSJSON  := Arr.AsJSON;
    OutCSReady := True;
  finally
    Arr.Free;
  end;
end;

procedure TDbgSyncHelper.InitLocals;
var
  TId    : Integer;
  Locals : TIDELocals;
begin
  OutLocalsReady  := False;
  OutLocalsJSON   := '[]';
  OutLocalsThread := 0;
  if not Assigned(DebugBoss) or not Assigned(DebugBoss.Locals) then
  begin
    OutLocalsReady := True; Exit;
  end;
  if Assigned(DebugBoss.Threads) and
     Assigned(DebugBoss.Threads.CurrentThreads) then
    TId := DebugBoss.Threads.CurrentThreads.CurrentThreadId
  else
    TId := 0;
  OutLocalsThread := TId;
  Locals := DebugBoss.Locals.CurrentLocalsList[TId, InLocalsFrame];
  if Assigned(Locals) then
    Locals.Count;  { trigger async load }
end;

procedure TDbgSyncHelper.ReadLocals;
var
  Locals : TIDELocals;
  LVal   : TIdeLocalsValue;
  Arr    : TJSONArray;
  LObj   : TJSONObject;
  I      : Integer;
begin
  OutLocalsReady := False;
  if not Assigned(DebugBoss) or not Assigned(DebugBoss.Locals) then
  begin
    OutLocalsReady := True; Exit;
  end;
  Locals := DebugBoss.Locals.CurrentLocalsList[OutLocalsThread, InLocalsFrame];
  if not Assigned(Locals) then
  begin
    OutLocalsReady := True;
    OutLocalsJSON  := '[]';
    Exit;
  end;
  if Locals is TCurrentLocals then
  begin
    case TCurrentLocals(Locals).Validity of
      ddsValid   : ;  { fall through to build JSON }
      ddsInvalid :
      begin
        OutLocalsReady := True;  { terminal failure — stop polling }
        Exit;
      end;
    else
      Exit;  { ddsUnknown/ddsRequested/ddsEvaluating — still loading, caller retries }
    end;
  end;
  Arr := TJSONArray.Create;
  try
    for I := 0 to Locals.Count - 1 do
    begin
      LVal := TIdeLocalsValue(Locals.Entries[I]);
      LObj := TJSONObject.Create;
      LObj.Add('name',  LVal.DisplayName);
      LObj.Add('value', LVal.Value);
      Arr.Add(LObj);
    end;
    OutLocalsJSON  := Arr.AsJSON;
    OutLocalsReady := True;
  finally
    Arr.Free;
  end;
end;

var
  GSyncHelper : TDbgSyncHelper = nil;

{ ── Internal helpers ─────────────────────────────────────────────────────── }

function DbgStateStr(S: TDBGState): string;
begin
  case S of
    dsNone, dsIdle         : Result := 'idle';
    dsStop                 : Result := 'stopped';
    dsPause                  : Result := 'paused';
    dsInternalPause          : Result := 'running';  { internal pause; IDE auto-continues }
    dsInit, dsRun          : Result := 'running';
    dsError                : Result := 'error';
    dsDestroying           : Result := 'stopped';
  else                       Result := 'idle';
  end;
end;

function MakeStateJSON(S: TDBGState; const AFile: string;
  ALine: Integer; const AReason: string): string;
var
  Obj : TJSONObject;
begin
  Obj := TJSONObject.Create;
  try
    Obj.Add('state',  DbgStateStr(S));
    Obj.Add('file',   AFile);
    Obj.Add('line',   ALine);
    Obj.Add('reason', AReason);
    Result := Obj.AsJSON;
  finally
    Obj.Free;
  end;
end;

procedure DoIssueCmd(ACmd: Integer);
begin
  GSyncHelper.InCmd := ACmd;
  TThread.Synchronize(nil, @GSyncHelper.IssueCmd);
end;

{ Wait up to WaitMs for the debugger to reach an active state (dsInit/dsRun/
  dsPause/dsInternalPause).  Returns true when an active state was detected.
  Checking for NOT-idle is wrong when starting from dsStop: dsStop is neither
  dsNone nor dsIdle, so the old code exited immediately with the pre-launch state. }
function WaitForLaunch(WaitMs: Integer): Boolean;
const
  Interval = 50;
var
  Elapsed : Integer;
begin
  Result  := False;
  Elapsed := 0;
  repeat
    Sleep(Interval);
    Inc(Elapsed, Interval);
    TThread.Synchronize(nil, @GSyncHelper.ReadState);
    if GSyncHelper.OutState in [dsInit, dsRun, dsPause, dsInternalPause] then
    begin
      Result := True;
      Exit;
    end;
  until Elapsed >= WaitMs;
end;

{ Poll until debugger leaves the running state or timeout expires.
  The caller must have already issued the command.
  Set AWaitLaunch=True for run_debugger to skip the pre-launch idle window. }
function PollForPause(TimeoutMs: Integer;
  out FinalFile: string; out FinalLine: Integer;
  AWaitLaunch: Boolean = False;
  ALaunchWaitMs: Integer = 5000): TDBGState;
const
  InitialWaitMs  = 150;  { let the command take effect }
  PollIntervalMs = 100;
var
  Elapsed : Integer;
begin
  if AWaitLaunch then
  begin
    if not WaitForLaunch(ALaunchWaitMs) then
    begin
      FinalFile := '';
      FinalLine := 0;
      Result    := dsStop;
      Exit;
    end;
  end
  else
    Sleep(InitialWaitMs);
  Elapsed := InitialWaitMs;
  repeat
    TThread.Synchronize(nil, @GSyncHelper.ReadState);
    if GSyncHelper.OutState in [dsPause, dsStop, dsError, dsNone, dsIdle, dsDestroying] then
    begin
      FinalFile := GSyncHelper.OutFileName;
      FinalLine := GSyncHelper.OutLine;
      Result    := GSyncHelper.OutState;
      Exit;
    end;
    if Elapsed >= TimeoutMs then
    begin
      FinalFile := '';
      FinalLine := 0;
      Result    := dsRun;
      Exit;
    end;
    Sleep(PollIntervalMs);
    Inc(Elapsed, PollIntervalMs);
  until False;
end;

{ ── Non-blocking dispatch (main thread via SyncCallTool) ─────────────────── }

function DispatchDebuggerTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  Obj   : TJSONObject;
  Arr   : TJSONArray;
  BpObj : TJSONObject;
  BP    : TIDEBreakPoint;
  I     : Integer;
begin
  Result := False;

  if Name = 'get_debug_state' then
  begin
    Result := True;
    GSyncHelper.ReadState;   { already on main thread }
    Obj := TJSONObject.Create;
    try
      Obj.Add('state',  DbgStateStr(GSyncHelper.OutState));
      Obj.Add('file',   GSyncHelper.OutFileName);
      Obj.Add('line',   GSyncHelper.OutLine);
      Obj.Add('reason', '');
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'set_breakpoint' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('file_path', '') = '') then
    begin Ctx.Error := True; Ctx.Result := 'file_path required'; Exit; end;
    if not Assigned(DebugBoss) then
    begin Ctx.Error := True; Ctx.Result := 'Debugger not available'; Exit; end;
    GSyncHelper.InBpFile    := Ctx.Params.Get('file_path', '');
    GSyncHelper.InBpLine    := Ctx.Params.Get('line', 0);
    GSyncHelper.InBpEnabled := Ctx.Params.Get('enabled', True);
    GSyncHelper.AddBreakpoint;   { already on main thread }
    if not Assigned(GSyncHelper.OutBp) then
    begin Ctx.Error := True; Ctx.Result := 'Failed to add breakpoint'; Exit; end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('file',    GSyncHelper.InBpFile);
      Obj.Add('line',    GSyncHelper.InBpLine);
      Obj.Add('enabled', GSyncHelper.InBpEnabled);
      Ctx.Result := Obj.AsJSON;
    finally Obj.Free; end;
  end

  else if Name = 'remove_breakpoint' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('file_path', '') = '') then
    begin Ctx.Error := True; Ctx.Result := 'file_path required'; Exit; end;
    GSyncHelper.InBpFile  := Ctx.Params.Get('file_path', '');
    GSyncHelper.InBpLine  := Ctx.Params.Get('line', 0);
    GSyncHelper.OutBpFound := False;
    GSyncHelper.RemoveBreakpoint;   { already on main thread }
    Obj := TJSONObject.Create;
    try
      Obj.Add('removed', GSyncHelper.OutBpFound);
      if not GSyncHelper.OutBpFound then
        Obj.Add('reason', 'not found');
      Ctx.Result := Obj.AsJSON;
    finally Obj.Free; end;
  end

  else if Name = 'list_breakpoints' then
  begin
    Result := True;
    Arr := TJSONArray.Create;
    try
      if Assigned(DebugBoss) and Assigned(DebugBoss.BreakPoints) then
        for I := 0 to DebugBoss.BreakPoints.Count - 1 do
        begin
          BP    := DebugBoss.BreakPoints.Items[I];
          BpObj := TJSONObject.Create;
          BpObj.Add('file',      BP.Source);
          BpObj.Add('line',      BP.Line);
          BpObj.Add('enabled',   BP.Enabled);
          BpObj.Add('hit_count', BP.HitCount);
          case BP.Valid of
            vsValid    : BpObj.Add('valid', 'valid');
            vsInvalid  : BpObj.Add('valid', 'invalid');
            vsPending  : BpObj.Add('valid', 'pending');
          else            BpObj.Add('valid', 'unknown');
          end;
          Arr.Add(BpObj);
        end;
      Ctx.Result := Arr.AsJSON;
    finally Arr.Free; end;
  end

  else if Name = 'stop_debugger' then
  begin
    Result := True;
    if Assigned(DebugBoss) then
      DebugBoss.DoStopProject;   { non-blocking, already on main thread }
    Ctx.Result := MakeStateJSON(dsStop, '', 0, '');
  end

  else if Name = 'set_local_variable' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('name', '') = '') then
    begin Ctx.Error := True; Ctx.Result := 'name required'; Exit; end;
    if not Assigned(DebugBoss) or (DebugBoss.State <> dsPause) then
    begin Ctx.Error := True; Ctx.Result := 'Debugger is not paused'; Exit; end;
    Obj := TJSONObject.Create;
    try
      if DebugBoss.Modify(Ctx.Params.Get('name', ''),
                          Ctx.Params.Get('value', '')) then
      begin
        Obj.Add('modified', True);
        Obj.Add('name',  Ctx.Params.Get('name', ''));
        Obj.Add('value', Ctx.Params.Get('value', ''));
      end
      else
      begin
        Ctx.Error := True;
        Obj.Add('error',
          'Modify rejected — dcModify not in Commands or debugger not ready');
      end;
      Ctx.Result := Obj.AsJSON;
    finally Obj.Free; end;
  end;

end;

{ ── Blocking dispatch (MCP worker thread) ───────────────────────────────── }

{ Evaluate AExpr asynchronously (3 s timeout). Returns True on success.
  Result value is in GSyncHelper.OutEvalRes / OutEvalOk on return. }
function EvalExpr(const AExpr: string): Boolean;
var
  T, E : Integer;
begin
  GSyncHelper.InEvalExpr := AExpr;
  TThread.Synchronize(nil, @GSyncHelper.DoEvaluateAndWait);
  T := 3000; E := 0;
  while not GSyncHelper.FEvalFired and (E < T) do
  begin Sleep(50); Inc(E, 50); end;
  Result := GSyncHelper.FEvalFired and GSyncHelper.OutEvalOk;
end;

function DispatchDebuggerBlockingTool(const Name: string;
  var Ctx: TMcpToolCall): Boolean;
var
  TimeoutMs : Integer;
  Elapsed   : Integer;
  S         : TDBGState;
  FinalFile : string;
  FinalLine : Integer;
  Obj       : TJSONObject;
  ExcLbl    : string;  { raw exception dialog label }
  ExcTmp    : string;  { scratch for parsing }
  ExcPos    : Integer;
  ExcQ      : Integer;
  ExcClass   : string;
  ExcMsg     : string;
  ExcLineNum : Integer;

  procedure Finish(const AReason: string);
  var
    R : string;
  begin
    if S = dsRun then R := 'timeout' else R := AReason;
    Ctx.Result := MakeStateJSON(S, FinalFile, FinalLine, R);
  end;

begin
  Result    := False;
  Elapsed   := 0;
  FinalFile := '';
  FinalLine := 0;
  Obj       := nil;

  if Name = 'run_debugger' then
  begin
    Result    := True;
    TimeoutMs := 30000;
    if Assigned(Ctx.Params) then
      TimeoutMs := Ctx.Params.Get('timeout_s', 30) * 1000;
    DoIssueCmd(0);
    S := PollForPause(TimeoutMs, FinalFile, FinalLine, True { AWaitLaunch }, 10000);
    Finish('run');
  end

  else if Name = 'pause_debugger' then
  begin
    Result    := True;
    TimeoutMs := 5000;
    DoIssueCmd(1);
    S := PollForPause(TimeoutMs, FinalFile, FinalLine);
    Finish('paused');
  end

  else if Name = 'step_over' then
  begin
    Result    := True;
    TimeoutMs := 10000;
    if Assigned(Ctx.Params) then
      TimeoutMs := Ctx.Params.Get('timeout_s', 10) * 1000;
    DoIssueCmd(3);
    S := PollForPause(TimeoutMs, FinalFile, FinalLine);
    Finish('step');
  end

  else if Name = 'step_into' then
  begin
    Result    := True;
    TimeoutMs := 10000;
    if Assigned(Ctx.Params) then
      TimeoutMs := Ctx.Params.Get('timeout_s', 10) * 1000;
    DoIssueCmd(4);
    S := PollForPause(TimeoutMs, FinalFile, FinalLine);
    Finish('step');
  end

  else if Name = 'step_out' then
  begin
    Result    := True;
    TimeoutMs := 30000;
    if Assigned(Ctx.Params) then
      TimeoutMs := Ctx.Params.Get('timeout_s', 30) * 1000;
    DoIssueCmd(5);
    S := PollForPause(TimeoutMs, FinalFile, FinalLine);
    Finish('step');
  end

  else if Name = 'run_to_line' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('file_path', '') = '') then
    begin Ctx.Error := True; Ctx.Result := 'file_path required'; Exit; end;
    TimeoutMs := 30000;
    if Assigned(Ctx.Params) then
      TimeoutMs := Ctx.Params.Get('timeout_s', 30) * 1000;
    { Add temp breakpoint on main thread }
    GSyncHelper.InBpFile    := Ctx.Params.Get('file_path', '');
    GSyncHelper.InBpLine    := Ctx.Params.Get('line', 0);
    GSyncHelper.InBpEnabled := True;
    TThread.Synchronize(nil, @GSyncHelper.AddBreakpoint);
    if not Assigned(GSyncHelper.OutBp) then
    begin Ctx.Error := True; Ctx.Result := 'Failed to add temp breakpoint'; Exit; end;
    { Run until pause }
    DoIssueCmd(0);
    S := PollForPause(TimeoutMs, FinalFile, FinalLine, True { AWaitLaunch }, 10000);
    { Remove the temp breakpoint }
    TThread.Synchronize(nil, @GSyncHelper.RemoveBreakpoint);
    Finish('breakpoint');
  end

  else if Name = 'evaluate_expression' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('expression', '') = '') then
    begin Ctx.Error := True; Ctx.Result := 'expression required'; Exit; end;
    TThread.Synchronize(nil, @GSyncHelper.ReadState);
    if GSyncHelper.OutState <> dsPause then
    begin Ctx.Error := True; Ctx.Result := 'Debugger is not paused'; Exit; end;
    GSyncHelper.InEvalExpr := Ctx.Params.Get('expression', '');
    { Start evaluation on the main thread (returns immediately). }
    TThread.Synchronize(nil, @GSyncHelper.DoEvaluateAndWait);
    { Poll: the main thread's Application.Run loop delivers DoCallback_DecRef
      via ProcessAsyncCallQueue — we just wait here for FEvalFired to flip. }
    TimeoutMs := 5000;
    Elapsed   := 0;
    while not GSyncHelper.FEvalFired and (Elapsed < TimeoutMs) do
    begin
      Sleep(50);
      Inc(Elapsed, 50);
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('expression', GSyncHelper.InEvalExpr);
      if GSyncHelper.OutEvalOk then
      begin
        Obj.Add('value', GSyncHelper.OutEvalRes);
        Obj.Add('type',  GSyncHelper.OutEvalType);
      end
      else if not GSyncHelper.FEvalFired then
      begin
        Ctx.Error := True;
        Obj.Add('error', 'Evaluation timed out (5 s) — Evaluate returned: ' +
          BoolToStr(GSyncHelper.OutEvalStarted, True));
      end
      else
      begin
        Ctx.Error := True;
        Obj.Add('error', 'Evaluation failed: ' + GSyncHelper.OutEvalRes);
      end;
      Ctx.Result := Obj.AsJSON;
    finally Obj.Free; end;
  end

  else if Name = 'get_call_stack' then
  begin
    Result := True;
    TThread.Synchronize(nil, @GSyncHelper.ReadState);
    if GSyncHelper.OutState <> dsPause then
    begin Ctx.Error := True; Ctx.Result := 'Debugger is not paused'; Exit; end;
    GSyncHelper.InMaxFrames := 20;
    if Assigned(Ctx.Params) then
      GSyncHelper.InMaxFrames := Ctx.Params.Get('max_frames', 20);
    TThread.Synchronize(nil, @GSyncHelper.InitCallStack);
    { Poll via Synchronize — each call reads CountValidity on main thread }
    TimeoutMs := 10000;
    Elapsed   := 0;
    while not GSyncHelper.OutCSReady and (Elapsed < TimeoutMs) do
    begin
      Sleep(100);
      Inc(Elapsed, 100);
      TThread.Synchronize(nil, @GSyncHelper.ReadCallStack);
    end;
    if not GSyncHelper.OutCSReady then
      GSyncHelper.OutCSJSON := '[]';  { timeout fallback }
    Ctx.Result := GSyncHelper.OutCSJSON;
  end

  else if Name = 'get_local_variables' then
  begin
    Result := True;
    TThread.Synchronize(nil, @GSyncHelper.ReadState);
    if GSyncHelper.OutState <> dsPause then
    begin Ctx.Error := True; Ctx.Result := 'Debugger is not paused'; Exit; end;
    GSyncHelper.InLocalsFrame := 0;
    if Assigned(Ctx.Params) then
      GSyncHelper.InLocalsFrame := Ctx.Params.Get('frame', 0);
    TThread.Synchronize(nil, @GSyncHelper.InitLocals);
    TimeoutMs := 5000;
    Elapsed   := 0;
    while not GSyncHelper.OutLocalsReady and (Elapsed < TimeoutMs) do
    begin
      Sleep(100);
      Inc(Elapsed, 100);
      TThread.Synchronize(nil, @GSyncHelper.ReadLocals);
    end;
    if not GSyncHelper.OutLocalsReady then
      GSyncHelper.OutLocalsJSON := '[]';
    Ctx.Result := GSyncHelper.OutLocalsJSON;
  end

  else if Name = 'exception_info' then
  begin
    Result := True;
    { GMcpLastExceptionLabel is written on the main thread (before the modal
      loop starts) and read here on the MCP worker thread.  No Synchronize
      needed — main thread has already left the write site by the time the
      modal loop is spinning and we receive the HTTP request. }
    ExcLbl := GMcpLastExceptionLabel;
    if ExcLbl = '' then
    begin
      { Dialog not showing — fall back to synchronised state check. }
      TThread.Synchronize(nil, @GSyncHelper.ReadState);
    end;
    Obj := TJSONObject.Create;
    try
      if ExcLbl <> '' then
      begin
        { Exception dialog is currently showing — parse the label text.
          Format (English, from lazarusidestrconsts):
            no message : 'Project %s raised exception class ''%s''.'
            with message: 'Project %s raised exception class ''%s'' with message:%s%s'
          where the %s%s at the end is LineEnding + ExceptionText. }
        Obj.Add('has_exception', True);
        { Extract class: text between "exception class '" and next "'" }
        ExcClass := '';
        ExcPos := Pos('exception class ''', ExcLbl);
        if ExcPos > 0 then
        begin
          ExcTmp := Copy(ExcLbl, ExcPos + Length('exception class '''), MaxInt);
          ExcQ   := Pos('''', ExcTmp);
          if ExcQ > 0 then ExcClass := Copy(ExcTmp, 1, ExcQ - 1);
        end;
        { Extract message: text after "with message:" stripped of leading newline }
        ExcMsg := '';
        ExcPos := Pos('with message:', ExcLbl);
        if ExcPos > 0 then
        begin
          ExcTmp := Copy(ExcLbl, ExcPos + Length('with message:'), MaxInt);
          while (Length(ExcTmp) > 0) and (ExcTmp[1] in [#10, #13]) do Delete(ExcTmp, 1, 1);
          { Stop before the location part which starts with LineEnding+LineEnding }
          ExcQ := Pos(LineEnding + LineEnding, ExcTmp);
          if ExcQ > 0 then ExcMsg := TrimRight(Copy(ExcTmp, 1, ExcQ - 1))
          else           ExcMsg := Trim(ExcTmp);
        end;
        { Extract file and line from "In file 'x' at line N" — present when
          the exception has source location info. }
        ExcTmp := '';
        ExcLineNum := 0;
        ExcPos := Pos('In file ''', ExcLbl);
        if ExcPos > 0 then
        begin
          ExcTmp := Copy(ExcLbl, ExcPos + Length('In file '''), MaxInt);
          ExcQ   := Pos('''', ExcTmp);
          if ExcQ > 0 then
          begin
            ExcTmp := Copy(ExcTmp, 1, ExcQ - 1);
            { Now find "at line " after the closing quote }
            ExcPos := Pos('at line ', ExcLbl);
            if ExcPos > 0 then
              ExcLineNum := StrToIntDef(
                Trim(Copy(ExcLbl, ExcPos + Length('at line '), 20)), 0);
          end;
        end;
        Obj.Add('file',    ExcTmp);
        Obj.Add('line',    ExcLineNum);
        Obj.Add('class',   ExcClass);
        Obj.Add('message', ExcMsg);
      end
      else
      begin
        { Dialog not showing.  Possible causes: debugger not running,
          user already clicked Break/Continue, or paused at a breakpoint. }
        Obj.Add('has_exception', False);
        if GSyncHelper.OutState = dsPause then
          Obj.Add('note', 'Debugger is paused (at a breakpoint or after Break was clicked). ' +
                          'Call exception_info while the exception dialog is still showing to get class and message.')
        else if GSyncHelper.OutState = dsNone then
          Obj.Add('note', 'Debugger is not running.')
        else
          Obj.Add('note', 'No exception dialog is currently visible.');
      end;
      Ctx.Result := Obj.AsJSON;
    finally Obj.Free; end;
  end;

end;

{ ── Schema constants ─────────────────────────────────────────────────────── }

const
  SCHEMA_SET_BREAKPOINT =
    '{"type":"object","properties":{' +
    '"file_path":{"type":"string","description":"Absolute path to the .pas file"},' +
    '"line":{"type":"integer","description":"1-based line number"},' +
    '"enabled":{"type":"boolean","description":"Default true"}},' +
    '"required":["file_path","line"]}';

  SCHEMA_REMOVE_BREAKPOINT =
    '{"type":"object","properties":{' +
    '"file_path":{"type":"string"},' +
    '"line":{"type":"integer"}},' +
    '"required":["file_path","line"]}';

  SCHEMA_NO_PARAMS =
    '{"type":"object","properties":{}}';

  SCHEMA_TIMEOUT_ONLY =
    '{"type":"object","properties":{' +
    '"timeout_s":{"type":"integer","description":"Seconds to wait; default varies"}}}';

  SCHEMA_RUN_DEBUGGER =
    '{"type":"object","properties":{' +
    '"timeout_s":{"type":"integer","description":"Seconds to wait for pause; default 30"}}}';

  SCHEMA_RUN_TO_LINE =
    '{"type":"object","properties":{' +
    '"file_path":{"type":"string"},' +
    '"line":{"type":"integer"},' +
    '"timeout_s":{"type":"integer","description":"Default 30"}},' +
    '"required":["file_path","line"]}';

  SCHEMA_EVALUATE_EXPRESSION =
    '{"type":"object","properties":{' +
    '"expression":{"type":"string","description":"Pascal expression to evaluate"}},' +
    '"required":["expression"]}';

  SCHEMA_GET_CALL_STACK =
    '{"type":"object","properties":{' +
    '"max_frames":{"type":"integer","description":"Maximum frames to return; default 20"}}}';

  SCHEMA_GET_LOCAL_VARIABLES =
    '{"type":"object","properties":{' +
    '"frame":{"type":"integer","description":"Stack frame index; default 0"}}}';

  SCHEMA_SET_LOCAL_VARIABLE =
    '{"type":"object","properties":{' +
    '"name":{"type":"string","description":"Variable or parameter name"},' +
    '"value":{"type":"string","description":"New value expressed as a string"}},' +
    '"required":["name","value"]}';

  SCHEMA_EXCEPTION_INFO =
    '{"type":"object","properties":{}}';

{ ── Schema registration ──────────────────────────────────────────────────── }

procedure RegisterDebuggerSchemas(Tools: TJSONArray);
begin
  { Group 1 — Breakpoints }
  Tools.Add(MakeTool('set_breakpoint',
    'Add a source line breakpoint. Does not require an active debug session.',
    SCHEMA_SET_BREAKPOINT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('remove_breakpoint',
    'Remove a breakpoint by file and line.',
    SCHEMA_REMOVE_BREAKPOINT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('list_breakpoints',
    'List all current breakpoints with file, line, enabled state, and hit count.',
    SCHEMA_NO_PARAMS, MCP_ANN_RO));
  { Group 2 — State query (escape hatch) }
  Tools.Add(MakeTool('get_debug_state',
    'Return the current debugger state and source location. ' +
    'Works in any state (idle, running, paused, stopped). ' +
    'Call this after a timed-out blocking tool to assess what is happening.',
    SCHEMA_NO_PARAMS, MCP_ANN_RO));
  { Group 3 — Session control (blocking) }
  Tools.Add(MakeTool('run_debugger',
    'Start a debug session or continue from pause (F9). Blocks until the ' +
    'program hits a breakpoint or stops. Returns state=timeout if timeout_s ' +
    'elapses while the program is still running.',
    SCHEMA_RUN_DEBUGGER, MCP_ANN_WRITE));
  Tools.Add(MakeTool('pause_debugger',
    'Pause a running debug session. Blocks until the program pauses.',
    SCHEMA_NO_PARAMS, MCP_ANN_WRITE));
  Tools.Add(MakeTool('stop_debugger',
    'Stop the debug session unconditionally. Non-blocking; safe in any ' +
    'state including after a timed-out step.',
    SCHEMA_NO_PARAMS, MCP_ANN_WRITE));
  Tools.Add(MakeTool('step_over',
    'Step over the current line (F8). Blocks until the debugger pauses at ' +
    'the next line.',
    SCHEMA_TIMEOUT_ONLY, MCP_ANN_WRITE));
  Tools.Add(MakeTool('step_into',
    'Step into the call at the current line (F7). Blocks until the debugger ' +
    'pauses.',
    SCHEMA_TIMEOUT_ONLY, MCP_ANN_WRITE));
  Tools.Add(MakeTool('step_out',
    'Step out of the current procedure (Shift+F8). Blocks until the debugger ' +
    'pauses after returning.',
    SCHEMA_TIMEOUT_ONLY, MCP_ANN_WRITE));
  Tools.Add(MakeTool('run_to_line',
    'Set a temporary breakpoint at (file_path, line), run the debugger, and ' +
    'block until that breakpoint is hit. Removes the temporary breakpoint on ' +
    'pause.',
    SCHEMA_RUN_TO_LINE, MCP_ANN_WRITE));
  { Group 4 — State inspection }
  Tools.Add(MakeTool('get_call_stack',
    'Return call stack frames when the debugger is paused. Returns up to ' +
    'max_frames frames with file, line, function name and address.',
    SCHEMA_GET_CALL_STACK, MCP_ANN_RO));
  Tools.Add(MakeTool('evaluate_expression',
    'Evaluate a Pascal expression in the current debug context. Debugger must ' +
    'be paused.',
    SCHEMA_EVALUATE_EXPRESSION, MCP_ANN_RO));
  Tools.Add(MakeTool('get_local_variables',
    'Return local variables and parameters in the current stack frame. ' +
    'Debugger must be paused.',
    SCHEMA_GET_LOCAL_VARIABLES, MCP_ANN_RO));
  Tools.Add(MakeTool('set_local_variable',
    'Modify a local variable or parameter in the current stack frame. ' +
    'Debugger must be paused. Call get_local_variables afterwards to verify.',
    SCHEMA_SET_LOCAL_VARIABLE, MCP_ANN_WRITE));
  Tools.Add(MakeTool('exception_info',
    'Return information about the current exception when the debugger is paused ' +
    'at an exception. Returns has_exception=false if not paused at an exception. ' +
    'Uses FPC RTL ExceptObject to read class name and message.',
    SCHEMA_EXCEPTION_INFO, MCP_ANN_RO));
end;

initialization
  GSyncHelper := TDbgSyncHelper.Create;
  RegisterMcpGroup(@DispatchDebuggerTool);
  RegisterMcpBlockingGroup(@DispatchDebuggerBlockingTool);
  RegisterMcpSchemas(@RegisterDebuggerSchemas);

finalization
  FreeAndNil(GSyncHelper);

end.
