{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TDebugger;

{ TTestDebugger — opt-in tests of debugging through MCP: breakpoints, the
  exception coming back without a dialog (ADR-011), the debug lease and the
  debugger lock (ADR-012).  They debug tests/debuggee/mcpdebuggee.lpi.

  Opt-in, because they switch the IDE's project and take about half a minute:
    - MCP_DEBUG_TESTS=1: the suite opens the debuggee project with
      project_open and reopens the previous project afterwards;
    - or open mcpdebuggee.lpi in the IDE yourself; then the suite runs (e.g.
      from ide_run_tests) and leaves the project as it is.
  Two clients are simulated with two Mcp-Session-Id values. }

{$mode objfpc}{$H+}

interface

uses
  Classes, fpcunit, testregistry, testdecorator, THttpHelper;

type
  TTestDebugger = class(TTestCase)
  protected
    procedure TearDown; override;
  published
    procedure TestBreakpointStepEvaluate;
    procedure TestExceptionWithoutDialog;
    procedure TestLeaseRefusesOtherClient;
    procedure TestLockSerialisesDebugCalls;
    procedure TestPauseLeavesBreakInThread;
    procedure TestLeaseExpiresAndStopsSession;
    { v0.9: breakpoint kinds and frames }
    procedure TestConditionalBreakpoint;
    procedure TestPassCount;
    procedure TestRunToLineKeepsUserBreakpoint;
    procedure TestDataBreakpoint;
    procedure TestSymbolBreakpoint;
    procedure TestFrames;
    procedure TestThreads;
    procedure TestRegistersAndDisassembly;
  end;

  { Opens the debuggee project before the suite and the previous one after. }
  TDebuggeeSetup = class(TTestSetup)
  protected
    procedure OneTimeSetup; override;
    procedure OneTimeTearDown; override;
  end;

function DebuggeeLpi: string;

{ Is the debuggee the IDE's active project? }
function DebuggeeIsActive: Boolean;

implementation

uses
  SysUtils, DateUtils, fpjson, jsonparser;

var
  GSessA, GSessB : string;   { the two simulated clients }
  GPrevProject   : string;   { reopened by OneTimeTearDown; '' = leave as is }

function DebuggeeLpi: string;
begin
  Result := ExtractFilePath(ExpandFileName(ParamStr(0))) +
            'debuggee' + PathDelim + 'mcpdebuggee.lpi';
end;

function DebuggeeSrc: string;
begin
  Result := ChangeFileExt(DebuggeeLpi, '.lpr');
end;

{ 1-based line of the source line containing 'MARK:<AName>' }
function MarkLine(const AName: string): Integer;
var
  SL : TStringList;
  I  : Integer;
begin
  Result := 0;
  SL := TStringList.Create;
  try
    SL.LoadFromFile(DebuggeeSrc);
    for I := 0 to SL.Count - 1 do
      if Pos('MARK:' + AName, SL[I]) > 0 then
        Exit(I + 1);
  finally
    SL.Free;
  end;
  raise Exception.Create('marker not found: ' + AName);
end;

function Call(const ASession, ATool, AArgs: string): string;
begin
  Result := CallToolText(ATool, AArgs, ['Mcp-Session-Id: ' + ASession]);
end;

function IsError(const T: string): Boolean;
begin
  Result := (Pos('TOOL ERROR', T) = 1) or (Pos('RPC ERROR', T) = 1) or (Pos('HTTP ', T) = 1);
end;

{ Value at a dotted path in the JSON text T, as a string ('' if absent). }
function JPath(const T, APath: string): string;
var
  D, V : TJSONData;
begin
  Result := '';
  if IsError(T) then Exit;
  try
    D := GetJSON(T);
  except
    Exit;
  end;
  try
    V := D.FindPath(APath);
    if Assigned(V) and not (V.JSONType in [jtObject, jtArray, jtNull]) then
      Result := V.AsString
    else if Assigned(V) then
      Result := V.AsJSON;
  finally
    D.Free;
  end;
end;

function ActiveProjectFile: string;
begin
  Result := JPath(CallToolText('project_get_settings', '{}', []), 'project_file');
end;

function DebuggeeIsActive: Boolean;
begin
  Result := SameFileName(ExpandFileName(ActiveProjectFile), ExpandFileName(DebuggeeLpi));
end;

function BpArgs(ALine: Integer): string;
begin
  Result := '{"file_path":' + JsonStr(DebuggeeSrc) + ',"line":' + IntToStr(ALine) + '}';
end;

function StateOf(const ASession: string): string;
begin
  Result := JPath(Call(ASession, 'debug_get_state', '{}'), 'state');
end;

{ Wait until no session is live and no client holds the lease. }
procedure WaitQuiet(ATimeoutMs: Integer);
var
  T     : string;
  Until_: TDateTime;
begin
  Until_ := IncMilliSecond(Now, ATimeoutMs);
  repeat
    T := Call(GSessB, 'debug_get_state', '{}');
    if ((JPath(T, 'state') = 'idle') or (JPath(T, 'state') = 'stopped')) and
       (Pos('"lease"', T) = 0) then
      Exit;
    Sleep(250);
  until Now > Until_;
end;

{ ── Suite setup ──────────────────────────────────────────────────────────── }

procedure TDebuggeeSetup.OneTimeSetup;
var
  T : string;
begin
  GSessA := McpNewSession;  { the server answers 404 to made-up ids }
  GSessB := McpNewSession;
  GPrevProject := '';
  if DebuggeeIsActive then Exit;
  GPrevProject := ActiveProjectFile;
  T := CallToolText('project_open', '{"file_path":' + JsonStr(DebuggeeLpi) + '}', []);
  if IsError(T) then
    raise Exception.Create('Could not open the debuggee project: ' + T);
end;

procedure TDebuggeeSetup.OneTimeTearDown;
var
  T : string;
begin
  Call(GSessA, 'debug_stop', '{}');
  WaitQuiet(5000);
  if GPrevProject = '' then Exit;
  { Breakpoint changes mark the project modified, and project_open won't
    leave a modified project.  The breakpoints are gone again, so saving the
    fixture (project_set_settings without arguments) leaves the .lpi as it was. }
  CallToolText('project_set_settings', '{}', []);
  T := CallToolText('project_open', '{"file_path":' + JsonStr(GPrevProject) + '}', []);
  if IsError(T) then
    raise Exception.Create('Could not reopen ' + GPrevProject + ': ' + T);
end;

{ ── Tests ────────────────────────────────────────────────────────────────── }

{ Remove every breakpoint, of every kind, as debug_list_breakpoints shows
  them.  Address breakpoints in particular must not outlive the session: they
  are saved with the project and the address means nothing next time. }
procedure RemoveAllBreakpoints(const ASession: string);
var
  D  : TJSONData;
  B  : TJSONObject;
  I  : Integer;
  Kd : string;
begin
  try
    D := GetJSON(Call(ASession, 'debug_list_breakpoints', '{}'));
  except
    Exit;
  end;
  try
    if not (D is TJSONArray) then Exit;
    for I := 0 to TJSONArray(D).Count - 1 do
    begin
      B  := TJSONArray(D).Objects[I];
      Kd := B.Get('kind', 'source');
      if Kd = 'address' then
        Call(ASession, 'debug_remove_breakpoint',
             '{"address":' + JsonStr(B.Get('address', '')) + '}')
      else if Kd = 'data' then
        Call(ASession, 'debug_remove_breakpoint',
             '{"data":' + JsonStr(B.Get('data', '')) + ',"scope":' + JsonStr(B.Get('scope', '')) +
             ',"watch":' + JsonStr(B.Get('watch', '')) + '}')
      else
        Call(ASession, 'debug_remove_breakpoint',
             '{"file_path":' + JsonStr(B.Get('file', '')) + ',"line":' +
             IntToStr(B.Get('line', 0)) + '}');
    end;
  finally
    D.Free;
  end;
end;

procedure TTestDebugger.TearDown;
begin
  { whatever a test left behind: stop, drop the breakpoints, free the lease }
  Call(GSessA, 'debug_stop', '{}');
  RemoveAllBreakpoints(GSessA);
  Call(GSessA, 'debug_remove_watch', '{"expression":"*"}');  { watches persist too }
  WaitQuiet(5000);
end;

procedure TTestDebugger.TestBreakpointStepEvaluate;
var
  T : string;
begin
  T := Call(GSessA, 'debug_set_breakpoint', BpArgs(MarkLine('work')));
  CheckFalse(IsError(T), 'set breakpoint: ' + T);
  T := Call(GSessA, 'debug_run', '{"timeout_s":60,"lease_idle_timeout":60}');
  CheckEquals('paused', JPath(T, 'state'), 'run: ' + T);
  CheckEquals(IntToStr(MarkLine('work')), JPath(T, 'line'), 'stops at the breakpoint: ' + T);
  CheckEquals('breakpoint', JPath(T, 'reason'), 'a breakpoint, not a plain run: ' + T);

  T := Call(GSessA, 'debug_step_over', '{}');
  CheckEquals(IntToStr(MarkLine('inc')), JPath(T, 'line'), 'step over: ' + T);
  CheckEquals('step', JPath(T, 'reason'), T);

  T := Call(GSessA, 'debug_evaluate', '{"expression":"Counter"}');
  CheckTrue(Pos('41', JPath(T, 'value')) > 0, 'Counter after the first line: ' + T);
  CheckTrue(JPath(T, 'type') <> '', 'a variable has its type: ' + T);
  T := Call(GSessA, 'debug_evaluate', '{"expression":"Counter + 1"}');
  CheckEquals('42', JPath(T, 'value'), T);
  CheckEquals(0, Pos('"type"', T), 'a computed value has no type, not an empty one: ' + T);

  T := Call(GSessA, 'debug_stop', '{}');
  CheckFalse(IsError(T), 'stop: ' + T);
end;

procedure TTestDebugger.TestExceptionWithoutDialog;
var
  T : string;
begin
  T := Call(GSessA, 'debug_run', '{"timeout_s":60,"lease_idle_timeout":60}');
  CheckEquals('exception', JPath(T, 'reason'), 'run to the exception: ' + T);
  CheckEquals('mcp debuggee exception', JPath(T, 'exception.message'), T);
  CheckEquals('Exception', JPath(T, 'exception.class'), T);

  T := Call(GSessA, 'debug_get_state', '{}');
  CheckEquals('', JPath(T, 'waiting_for'), 'no IDE dialog is waiting: ' + T);
end;

procedure TTestDebugger.TestLeaseRefusesOtherClient;
var
  T : string;
begin
  Call(GSessA, 'debug_set_breakpoint', BpArgs(MarkLine('work')));
  T := Call(GSessA, 'debug_run', '{"timeout_s":60,"lease_idle_timeout":60}');
  CheckEquals('paused', JPath(T, 'state'), 'A runs to the breakpoint: ' + T);

  { B may not drive or disturb A's session ... }
  T := Call(GSessB, 'debug_step_over', '{}');
  CheckEquals(1, Pos('TOOL ERROR: Refused: the debug session belongs to', T), 'B steps: ' + T);
  T := Call(GSessB, 'project_build', '{}');
  CheckEquals(1, Pos('TOOL ERROR: Refused', T), 'B builds: ' + T);
  T := Call(GSessB, 'project_open', '{"file_path":' + JsonStr(DebuggeeLpi) + '}');
  CheckEquals(1, Pos('TOOL ERROR: Refused', T), 'B opens a project: ' + T);

  { ... but may read it }
  T := Call(GSessB, 'debug_get_state', '{}');
  CheckEquals('paused', JPath(T, 'state'), 'B reads the state: ' + T);
  CheckTrue(Pos('"owner"', T) > 0, 'and sees the lease: ' + T);
  T := Call(GSessB, 'debug_evaluate', '{"expression":"Counter"}');
  CheckFalse(IsError(T), 'B evaluates: ' + T);

  { once A stops, the debugger is free for B }
  Call(GSessA, 'debug_stop', '{}');
  WaitQuiet(5000);
  T := Call(GSessB, 'debug_set_breakpoint', BpArgs(MarkLine('inc')));
  CheckFalse(IsError(T), 'B after A stopped: ' + T);
  Call(GSessB, 'debug_remove_breakpoint', BpArgs(MarkLine('inc')));
end;

type
  TRunThread = class(TThread)
  public
    Session : string;
    Result_ : string;
    Done    : Boolean;
    procedure Execute; override;
  end;

procedure TRunThread.Execute;
begin
  Result_ := Call(Session, 'debug_run', '{"timeout_s":60}');
  Done := True;
end;

procedure TTestDebugger.TestLockSerialisesDebugCalls;
var
  T      : string;
  Th     : TRunThread;
  Start  : TDateTime;
  Ms     : Int64;
begin
  Call(GSessA, 'debug_set_breakpoint', BpArgs(MarkLine('work')));
  T := Call(GSessA, 'debug_run', '{"timeout_s":60,"lease_idle_timeout":60}');
  CheckEquals('paused', JPath(T, 'state'), 'paused at the breakpoint: ' + T);
  Call(GSessA, 'debug_remove_breakpoint', BpArgs(MarkLine('work')));

  { continue in the background: the program sleeps 3 s, then raises }
  Th := TRunThread.Create(True);
  try
    Th.Session := GSessA;
    Th.Start;
    Sleep(500);

    { debug_get_state is exempt from the lock and answers at once }
    Start := Now;
    T  := Call(GSessA, 'debug_get_state', '{}');
    Ms := MilliSecondsBetween(Now, Start);
    CheckEquals('running', JPath(T, 'state'), 'state while debug_run blocks: ' + T);
    CheckTrue(Ms < 1500, Format('debug_get_state took %d ms', [Ms]));

    { debug_evaluate waits until debug_run is done }
    T := Call(GSessA, 'debug_evaluate', '{"expression":"Counter"}');
    CheckTrue(Th.Done, 'debug_evaluate returned before the running debug_run: ' + T);
    Th.WaitFor;
    CheckEquals('exception', JPath(Th.Result_, 'reason'), 'debug_run: ' + Th.Result_);
  finally
    Th.WaitFor;
    Th.Free;
  end;
end;

{ debug_pause on Windows: the debugger's own break-in thread must not stay current;
  the call stack is the program's (the main thread sleeping), down to its source. }
procedure TTestDebugger.TestPauseLeavesBreakInThread;
var
  T  : string;
begin
  Call(GSessA, 'debug_set_breakpoint', BpArgs(MarkLine('work')));
  T := Call(GSessA, 'debug_run', '{"timeout_s":60,"lease_idle_timeout":60}');
  CheckEquals('paused', JPath(T, 'state'), 'paused at the breakpoint: ' + T);
  Call(GSessA, 'debug_remove_breakpoint', BpArgs(MarkLine('work')));
  { continue: the program sleeps 3 s, then raises; the run gives up after 1 s and
    leaves it running, which is when a client pauses it }
  T := Call(GSessA, 'debug_run', '{"timeout_s":1}');
  CheckEquals('timeout', JPath(T, 'reason'), 'still running: ' + T);
  try
    T := Call(GSessA, 'debug_pause', '{}');
    CheckEquals('paused', JPath(T, 'state'), 'pause: ' + T);
    CheckEquals('paused', JPath(T, 'reason'), T);
    {$IFDEF WINDOWS}
    CheckTrue(Pos('"thread"', T) > 0, 'moved off the break-in thread: ' + T);
    {$ENDIF}
    T := Call(GSessA, 'debug_get_call_stack', '{}');
    CheckFalse(IsError(T), T);
    CheckTrue(Pos('mcpdebuggee.lpr', T) > 0, 'the program''s own stack, not the break-in thread''s: ' + T);
    CheckEquals(0, Pos('RtlUserThreadStart', T), T);
  finally
    Call(GSessA, 'debug_stop', '{}');
  end;
end;

procedure TTestDebugger.TestLeaseExpiresAndStopsSession;
var
  T      : string;
  Start  : TDateTime;
  Ms     : Int64;
  Ended  : Boolean;
begin
  Call(GSessA, 'debug_set_breakpoint', BpArgs(MarkLine('work')));
  T := Call(GSessA, 'debug_run', '{"timeout_s":60,"lease_idle_timeout":10}');
  CheckEquals('paused', JPath(T, 'state'), 'paused at the breakpoint: ' + T);
  Call(GSessA, 'debug_remove_breakpoint', BpArgs(MarkLine('work')));

  { A goes quiet; B only reads, which doesn't keep A's lease alive }
  Start := Now;
  Ended := False;
  repeat
    Sleep(1000);
    T := StateOf(GSessB);
    Ended := (T = 'idle') or (T = 'stopped');
  until Ended or (MilliSecondsBetween(Now, Start) > 25000);
  Ms := MilliSecondsBetween(Now, Start);
  CheckTrue(Ended, 'the session was stopped when the lease expired');
  CheckTrue(Ms >= 8000, Format('not before the 10 s idle timeout (%d ms)', [Ms]));

  T := CallToolText('ide_get_messages', '{}', []);
  CheckTrue(Pos('expired after 10 s without calls; session stopped', T) > 0,
    'the expiry is logged in the Messages window: ' + Copy(T, 1, 400));
end;

{ ── v0.9: breakpoint kinds and frames ──────────────────────────────────── }

function LoopBp(const AExtra: string): string;
begin
  Result := '{"file_path":' + JsonStr(DebuggeeSrc) + ',"line":' +
            IntToStr(MarkLine('loop')) + AExtra + '}';
end;

function EvalI(const ASession: string): string;
begin
  Result := JPath(Call(ASession, 'debug_evaluate', '{"expression":"I"}'), 'value');
end;

procedure TTestDebugger.TestConditionalBreakpoint;
var
  T : string;
begin
  T := Call(GSessA, 'debug_set_breakpoint', LoopBp(',"condition":"I = 3"'));
  CheckEquals('I = 3', JPath(T, 'condition'), 'set: ' + T);
  T := Call(GSessA, 'debug_run', '{"timeout_s":60,"lease_idle_timeout":60}');
  CheckEquals('paused', JPath(T, 'state'), 'run: ' + T);
  CheckEquals('3', EvalI(GSessA), 'paused only when the condition holds');
end;

procedure TTestDebugger.TestPassCount;
var
  T : string;
begin
  T := Call(GSessA, 'debug_set_breakpoint', LoopBp(',"pass_count":4'));
  CheckEquals('4', JPath(T, 'pass_count'), 'set: ' + T);
  Call(GSessA, 'debug_run', '{"timeout_s":60,"lease_idle_timeout":60}');
  CheckEquals('4', EvalI(GSessA), 'first pause on the 4th hit');
  Call(GSessA, 'debug_run', '{"timeout_s":60}');
  CheckEquals('5', EvalI(GSessA), 'and on every hit after it');
end;

procedure TTestDebugger.TestRunToLineKeepsUserBreakpoint;
var
  T : string;
begin
  Call(GSessA, 'debug_set_breakpoint', LoopBp(',"condition":"I = 2"'));
  T := Call(GSessA, 'debug_run_to_line', LoopBp(',"timeout_s":60'));
  CheckEquals('paused', JPath(T, 'state'), 'run_to_line: ' + T);
  CheckEquals('2', EvalI(GSessA), 'the existing breakpoint''s condition applied');
  T := Call(GSessA, 'debug_list_breakpoints', '{}');
  CheckTrue(Pos('"condition" : "I = 2"', T) > 0,
    'the user''s breakpoint is still there, condition intact: ' + T);
end;

procedure TTestDebugger.TestDataBreakpoint;
var
  T : string;
begin
  T := Call(GSessA, 'debug_set_breakpoint', '{"data":"Counter"}');
  CheckEquals('data', JPath(T, 'kind'), 'set: ' + T);
  CheckEquals('write', JPath(T, 'watch'), T);
  T := Call(GSessA, 'debug_run', '{"timeout_s":60,"lease_idle_timeout":60}');
  CheckEquals('paused', JPath(T, 'state'), 'first write: ' + T);
  CheckEquals('41', JPath(Call(GSessA, 'debug_evaluate', '{"expression":"Counter"}'), 'value'));
  T := Call(GSessA, 'debug_run', '{"timeout_s":60}');
  CheckEquals('paused', JPath(T, 'state'), 'second write: ' + T);
  CheckEquals('42', JPath(Call(GSessA, 'debug_evaluate', '{"expression":"Counter"}'), 'value'));
end;

procedure TTestDebugger.TestSymbolBreakpoint;
var
  T : string;
begin
  T := Call(GSessA, 'debug_set_breakpoint', '{"address":"Sum"}');
  CheckEquals(1, Pos('TOOL ERROR', T), 'a symbol needs a paused session: ' + T);

  Call(GSessA, 'debug_set_breakpoint', BpArgs(MarkLine('work')));
  Call(GSessA, 'debug_run', '{"timeout_s":60,"lease_idle_timeout":60}');
  T := Call(GSessA, 'debug_set_breakpoint', '{"address":"Counter"}');
  CheckTrue(Pos('is data', T) > 0, 'a variable is refused, not patched: ' + T);
  T := Call(GSessA, 'debug_set_breakpoint', '{"address":"Beep"}');
  CheckTrue(Pos('debug info', T) > 0, 'no debug info, no symbol: ' + T);
  T := Call(GSessA, 'debug_set_breakpoint', '{"address":"Sum"}');
  CheckEquals('address', JPath(T, 'kind'), 'resolved while paused: ' + T);
  CheckEquals(1, Pos('$', JPath(T, 'address')), 'as a number: ' + T);
  Call(GSessA, 'debug_remove_breakpoint', BpArgs(MarkLine('work')));

  T := Call(GSessA, 'debug_run', '{"timeout_s":60}');
  CheckEquals('paused', JPath(T, 'state'), 'run to Sum: ' + T);
  T := Call(GSessA, 'debug_get_call_stack', '{"max_frames":1}');
  CheckTrue(Pos('"Sum', T) > 0, 'paused at Sum''s entry: ' + T);
end;

procedure TTestDebugger.TestFrames;
var
  T : string;
begin
  Call(GSessA, 'debug_set_breakpoint', LoopBp(',"condition":"I = 2"'));
  Call(GSessA, 'debug_run', '{"timeout_s":60,"lease_idle_timeout":60}');

  { frame for one evaluation only }
  T := Call(GSessA, 'debug_evaluate', '{"expression":"ALimit"}');
  CheckEquals('5', JPath(T, 'value'), 'frame 0 (Sum): ' + T);
  T := Call(GSessA, 'debug_evaluate', '{"expression":"ALimit","frame":1}');
  CheckEquals(1, Pos('TOOL ERROR', T), 'ALimit is not visible in frame 1: ' + T);
  T := Call(GSessA, 'debug_evaluate', '{"expression":"Total","frame":1}');
  CheckEquals('1', JPath(T, 'value'), 'a global in frame 1: ' + T);
  CheckEquals('$main', JPath(T, 'frame.function'), T);
  T := Call(GSessA, 'debug_evaluate', '{"expression":"ALimit"}');
  CheckEquals('5', JPath(T, 'value'), 'the selection was restored: ' + T);
  T := Call(GSessA, 'debug_evaluate', '{"expression":"ALimit","frame":7}');
  CheckTrue(Pos('Frame 7 does not exist', T) > 0, 'no such frame: ' + T);

  { locals and watches read a given frame directly }
  T := Call(GSessA, 'debug_get_locals', '{"frame":0}');
  CheckTrue((Pos('"ALimit"', T) > 0) and (Pos('"I"', T) > 0), 'Sum''s locals: ' + T);
  Call(GSessA, 'debug_add_watch', '{"expression":"ALimit"}');
  T := Call(GSessA, 'debug_list_watches', '{"frame":0}');
  CheckEquals('5', JPath(T, 'watches[0].value'), 'watch in frame 0: ' + T);
  T := Call(GSessA, 'debug_list_watches', '{"frame":1}');
  CheckNotEquals('', JPath(T, 'watches[0].error'), 'watch in frame 1: ' + T);

  { selection that stays }
  T := Call(GSessA, 'debug_select_frame', '{"frame":1}');
  CheckEquals('1', JPath(T, 'frame.index'), 'select frame 1: ' + T);
  T := Call(GSessA, 'debug_evaluate', '{"expression":"ALimit"}');
  CheckEquals(1, Pos('TOOL ERROR', T), 'later evaluations use frame 1: ' + T);
  Call(GSessA, 'debug_select_frame', '{"frame":0}');
  T := Call(GSessA, 'debug_evaluate', '{"expression":"ALimit"}');
  CheckEquals('5', JPath(T, 'value'), 'back in frame 0: ' + T);

  { selecting drives the session: another client may not }
  T := Call(GSessB, 'debug_select_frame', '{"frame":1}');
  CheckEquals(1, Pos('TOOL ERROR: Refused', T), 'B selects a frame: ' + T);
end;

{ id of the thread debug_list_threads marks current, '' if none }
function CurrentThread(const ASession: string): string;
var
  D : TJSONData;
  I : Integer;
begin
  Result := '';
  try
    D := GetJSON(Call(ASession, 'debug_list_threads', '{}'));
  except
    Exit;
  end;
  try
    if D is TJSONArray then
      for I := 0 to TJSONArray(D).Count - 1 do
        if TJSONArray(D).Objects[I].Get('current', False) then
          Exit(IntToStr(TJSONArray(D).Objects[I].Get('id', 0)));
  finally
    D.Free;
  end;
end;

procedure TTestDebugger.TestThreads;
{ The RTL starts worker threads (waiting in ntdll); the program runs in the
  main one.  Select a worker, evaluate in the main thread for one call, and
  check that the worker is still selected afterwards. }
var
  T, MainId, WorkerId : string;
  D : TJSONData;
  I : Integer;
begin
  Call(GSessA, 'debug_set_breakpoint', LoopBp(',"condition":"I = 2"'));
  Call(GSessA, 'debug_run', '{"timeout_s":60,"lease_idle_timeout":60}');
  T := Call(GSessA, 'debug_list_threads', '{}');
  MainId := '';
  WorkerId := '';
  D := GetJSON(T);
  try
    for I := 0 to TJSONArray(D).Count - 1 do
      with TJSONArray(D).Objects[I] do
        if Get('current', False) then
          MainId := IntToStr(Get('id', 0))
        else if WorkerId = '' then
          WorkerId := IntToStr(Get('id', 0));
  finally
    D.Free;
  end;
  if WorkerId = '' then
    Ignore('the debuggee has no second thread here: ' + T);

  T := Call(GSessA, 'debug_select_frame', '{"thread":' + WorkerId + ',"frame":0}');
  CheckEquals(WorkerId, JPath(T, 'thread'), 'worker selected: ' + T);
  T := Call(GSessA, 'debug_get_call_stack', '{"max_frames":1}');
  CheckEquals(0, Pos('"Sum', T), 'the stack is the worker''s now: ' + T);

  T := Call(GSessA, 'debug_evaluate', '{"expression":"ALimit","thread":' + MainId + ',"frame":0}');
  CheckEquals('5', JPath(T, 'value'), 'main thread for one evaluation: ' + T);
  CheckEquals(WorkerId, CurrentThread(GSessA), 'the worker is selected again afterwards');

  T := Call(GSessA, 'debug_select_frame', '{"thread":' + MainId + ',"frame":0}');
  CheckEquals(MainId, JPath(T, 'thread'), 'back to the main thread: ' + T);
  T := Call(GSessA, 'debug_evaluate', '{"expression":"ALimit"}');
  CheckEquals('5', JPath(T, 'value'), T);
end;

{ The "at" instruction of a debug_disassemble result, as JSON; '' if none. }
function AtInstruction(const T: string): string;
var
  D   : TJSONData;
  Arr : TJSONData;
  I   : Integer;
begin
  Result := '';
  if IsError(T) then Exit;
  D := GetJSON(T);
  try
    Arr := D.FindPath('instructions');
    if Arr is TJSONArray then
      for I := 0 to TJSONArray(Arr).Count - 1 do
        if TJSONArray(Arr).Objects[I].Get('at', False) then
          Exit(TJSONArray(Arr).Objects[I].AsJSON);
  finally
    D.Free;
  end;
end;

procedure TTestDebugger.TestRegistersAndDisassembly;
var
  T, Pc, Frame0, At : string;
begin
  T := Call(GSessA, 'debug_get_registers', '{}');
  CheckTrue(Pos('not paused', T) > 0, 'registers need a pause: ' + T);

  Call(GSessA, 'debug_set_breakpoint', LoopBp(',"condition":"I = 2"'));
  Call(GSessA, 'debug_run', '{"timeout_s":60,"lease_idle_timeout":60}');

  { a caller's registers first, before anything has loaded the stack }
  T := Call(GSessA, 'debug_get_registers', '{"frame":1}');
  CheckFalse(IsError(T), 'registers of frame 1 on a fresh pause: ' + T);
  T := Call(GSessA, 'debug_get_registers', '{"frame":50}');
  CheckTrue(Pos('Frame 50 does not exist', T) > 0, 'no such frame: ' + T);

  { registers: the instruction pointer is the frame's address }
  T := Call(GSessA, 'debug_get_registers', '{"thread":' + CurrentThread(GSessA) + '}');
  CheckFalse(IsError(T), 'registers: ' + T);
  Frame0 := JPath(Call(GSessA, 'debug_get_call_stack', '{"max_frames":1}'), '[0].address');
  Pc := '';
  if Pos('"rip"', T) > 0 then
    Pc := Copy(T, Pos('"rip"', T), 80)
  else if Pos('"eip"', T) > 0 then
    Pc := Copy(T, Pos('"eip"', T), 80);
  if Pc = '' then
    Ignore('not an x86 target: ' + T);
  CheckTrue(Pos(LowerCase(Copy(Frame0, 2, MaxInt)), LowerCase(Pc)) > 0,
    'rip/eip = frame 0 address ' + Frame0 + ': ' + Pc);

  { a filtered list: the instruction pointer and stack pointer only }
  T := Call(GSessA, 'debug_get_registers', '{"names":["RIP","rsp"]}');
  CheckFalse(IsError(T), T);
  if Pc <> '' then
  begin
    CheckTrue((Pos('"rip"', T) > 0) and (Pos('"rsp"', T) > 0) and (Pos('"rax"', T) = 0), T);
    CheckTrue(Length(T) < 600, 'short: ' + IntToStr(Length(T)));
    T := Call(GSessA, 'debug_get_registers', '{"general":true}');
    CheckTrue((Pos('"rip"', T) > 0) and (Length(T) < 4000), 'general registers only: ' + IntToStr(Length(T)));
  end;

  { disassembly at the frame, at a symbol, and at the caller's return address }
  T := Call(GSessA, 'debug_disassemble', '{}');
  At := AtInstruction(T);
  CheckTrue(Pos(JsonStr(Frame0), At) > 0, 'at the stop address ' + Frame0 + ': ' + T);
  CheckTrue(Pos('sum', LowerCase(At)) > 0, 'in Sum: ' + At);
  CheckTrue(Pos('mcpdebuggee.lpr', LowerCase(T)) > 0, 'with source lines: ' + T);

  T := Call(GSessA, 'debug_disassemble', '{"address":"Sum","lines_before":0,"lines_after":3}');
  At := AtInstruction(T);
  CheckTrue(Pos('sum', LowerCase(At)) > 0, 'Sum resolved: ' + T);
  CheckEquals(0, Pos('+', JPath(At, 'function')), 'at Sum''s entry: ' + At);

  T := Call(GSessA, 'debug_disassemble', '{"frame":1,"lines_before":2,"lines_after":2}');
  At := AtInstruction(T);
  CheckTrue(Pos('main', LowerCase(JPath(At, 'function'))) > 0, 'frame 1 is in main: ' + T);
end;

initialization
  Randomize;
end.
