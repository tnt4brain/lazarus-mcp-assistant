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
    procedure TestLeaseExpiresAndStopsSession;
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
  GSessA := Format('mcp-test-a-%d', [Random(1000000)]);
  GSessB := Format('mcp-test-b-%d', [Random(1000000)]);
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

procedure TTestDebugger.TearDown;
var
  M : string;
begin
  { whatever a test left behind: stop, drop the breakpoints, free the lease }
  Call(GSessA, 'debug_stop', '{}');
  for M in ['work', 'inc', 'sleep'] do
    Call(GSessA, 'debug_remove_breakpoint', BpArgs(MarkLine(M)));
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

  T := Call(GSessA, 'debug_step_over', '{}');
  CheckEquals(IntToStr(MarkLine('inc')), JPath(T, 'line'), 'step over: ' + T);

  T := Call(GSessA, 'debug_evaluate', '{"expression":"Counter"}');
  CheckTrue(Pos('41', JPath(T, 'value')) > 0, 'Counter after the first line: ' + T);

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

initialization
  Randomize;
end.
