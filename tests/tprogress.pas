{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TProgress;

{ ADR-036: progress notifications (a long call answers as a stream) and notifications/cancelled.
  The calls are made with __test_slow__, a hook that sleeps for N seconds, says "step N" and stops
  when the call is cancelled; it exists only when the IDE was started with MCP_TEST_HOOKS=1, so
  without it these tests are ignored. }

{$mode objfpc}{$H+}

interface

uses
  Classes, fpcunit, testregistry, THttpHelper;

type
  { one tools/call on a thread of its own }
  TSlowCall = class(TThread)
  private
    FJson    : string;
    FHeaders : array of string;
  public
    Res      : THttpResult;
    RespHdrs : TStringList;
    Seconds  : Double;     { how long the HTTP call took }
    constructor Create(const AJson: string; const AHeaders: array of string);
    destructor Destroy; override;
    procedure Execute; override;
  end;

  TTestProgress = class(TTestCase)
  protected
    procedure SetUp; override;
  published
    procedure TestNoTokenIsPlainJson;
    procedure TestShortCallWithTokenIsPlainJson;
    procedure TestLongCallWithTokenStreams;
    procedure TestCancelEndsTheCall;
    procedure TestCancelReachesTheMainThread;
    procedure TestForeignUnknownAndLateCancelChangeNothing;
    procedure TestCancelAbortsABuild;
    procedure TestWriteToolIsRefusedInsideAnotherCall;
    procedure TestRegistryIsEmptyAfterwards;
    procedure TestServerDiscoverIsMethodNotFound;
  end;

implementation

uses
  SysUtils, DateUtils, fpjson, jsonparser;

const
  ACCEPT = 'Accept: application/json, text/event-stream';

function SlowJson(AId, ASeconds: Integer; const AToken: string): string;
begin
  Result := '{"jsonrpc":"2.0","id":' + IntToStr(AId) + ',"method":"tools/call","params":{' +
    '"name":"__test_slow__","arguments":{"seconds":' + IntToStr(ASeconds) + '}';
  if AToken <> '' then
    Result := Result + ',"_meta":{"progressToken":' + AToken + '}';
  Result := Result + '}}';
end;

constructor TSlowCall.Create(const AJson: string; const AHeaders: array of string);
var
  I : Integer;
begin
  FJson := AJson;
  SetLength(FHeaders, Length(AHeaders));
  for I := 0 to High(AHeaders) do FHeaders[I] := AHeaders[I];
  RespHdrs := TStringList.Create;
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TSlowCall.Destroy;
begin
  RespHdrs.Free;
  inherited Destroy;
end;

procedure TSlowCall.Execute;
var
  T : QWord;
begin
  T := GetTickCount64;
  Res := McpRequest('POST', FJson, FHeaders, RespHdrs);
  Seconds := (GetTickCount64 - T) / 1000;
end;

procedure TTestProgress.SetUp;
begin
  if not GServerAvail then Ignore('no MCP server');
  if GetEnvironmentVariable('MCP_TEST_HOOKS') <> '1' then
    Ignore('set MCP_TEST_HOOKS=1 for both the IDE and this test process to run this suite');
end;

procedure TTestProgress.TestNoTokenIsPlainJson;
var
  C : TSlowCall;
begin
  C := TSlowCall.Create(SlowJson(5, 1, ''), [ACCEPT]);
  try
    C.WaitFor;
    AssertEquals(200, C.Res.Code);
    AssertTrue('application/json', Pos('application/json', HeaderValue(C.RespHdrs, 'Content-Type')) > 0);
    AssertTrue('result', Pos('finished 1 steps', C.Res.Body) > 0);
  finally
    C.Free;
  end;
end;

procedure TTestProgress.TestShortCallWithTokenIsPlainJson;
var
  C : TSlowCall;
begin
  C := TSlowCall.Create(SlowJson(6, 1, '"tok-short"'), [ACCEPT]);
  try
    C.WaitFor;
    AssertTrue('application/json', Pos('application/json', HeaderValue(C.RespHdrs, 'Content-Type')) > 0);
    AssertTrue('no event framing', Pos('event:', C.Res.Body) = 0);
    AssertTrue('result', Pos('finished 1 steps', C.Res.Body) > 0);
  finally
    C.Free;
  end;
end;

procedure TTestProgress.TestLongCallWithTokenStreams;
var
  C : TSlowCall;
  P, Q : Integer;
  Last : string;
begin
  C := TSlowCall.Create(SlowJson(7, 7, '"tok-long"'), [ACCEPT]);
  try
    C.WaitFor;
    AssertEquals(200, C.Res.Code);
    AssertTrue('text/event-stream', Pos('text/event-stream', HeaderValue(C.RespHdrs, 'Content-Type')) > 0);
    P := Pos('notifications/progress', C.Res.Body);
    AssertTrue('a progress event: ' + C.Res.Body, P > 0);
    AssertTrue('the token is echoed as sent', Pos('"progressToken":"tok-long"', C.Res.Body) > 0);
    AssertTrue('the tool''s own message', Pos('step ', Copy(C.Res.Body, P, 400)) > 0);
    { the result is the last event }
    Q := Pos('"id":7', C.Res.Body);
    AssertTrue('the result with the call''s id: ' + C.Res.Body, Q > P);
    Last := Copy(C.Res.Body, LastDelimiter(#10, TrimRight(C.Res.Body)) + 1, MaxInt);
    AssertTrue('last data line is the result: ' + Last, Pos('finished 7 steps', Last) > 0);
  finally
    C.Free;
  end;
end;

procedure TTestProgress.TestCancelEndsTheCall;
var
  C    : TSlowCall;
  Sess : string;
  R    : THttpResult;
begin
  Sess := McpNewSession;
  C := TSlowCall.Create(SlowJson(21, 30, '11'), [ACCEPT, 'Mcp-Session-Id: ' + Sess]);
  try
    Sleep(1000);
    R := McpRequest('POST', '{"jsonrpc":"2.0","method":"notifications/cancelled","params":' +
      '{"requestId":21,"reason":"test"}}', ['Mcp-Session-Id: ' + Sess], nil);
    AssertEquals('the notification is answered 202', 202, R.Code);
    C.WaitFor;
    AssertTrue('ended within 3 s of the cancel, took ' + FloatToStr(C.Seconds), C.Seconds < 5);
    AssertTrue('says cancelled: ' + C.Res.Body, Pos('Cancelled by the client', C.Res.Body) > 0);
    AssertTrue('an error result: ' + C.Res.Body, Pos('"isError":true', C.Res.Body) > 0);
    AssertTrue('the tool stopped, not ran on: ' + C.Res.Body, Pos('stopped at step', C.Res.Body) > 0);
  finally
    C.Free;
  end;
end;

{ a tool that runs on the IDE's main thread sees the cancel as well }
procedure TTestProgress.TestCancelReachesTheMainThread;
var
  C    : TSlowCall;
  Sess : string;
  R    : THttpResult;
begin
  Sess := McpNewSession;
  C := TSlowCall.Create(StringReplace(SlowJson(61, 30, ''), '__test_slow__',
         '__test_slow_main__', []), [ACCEPT, 'Mcp-Session-Id: ' + Sess]);
  try
    Sleep(1000);
    R := McpRequest('POST', '{"jsonrpc":"2.0","method":"notifications/cancelled","params":' +
      '{"requestId":61}}', ['Mcp-Session-Id: ' + Sess], nil);
    AssertEquals(202, R.Code);
    C.WaitFor;
    AssertTrue('ended soon after the cancel, took ' + FloatToStr(C.Seconds), C.Seconds < 5);
    AssertTrue('says cancelled: ' + C.Res.Body, Pos('Cancelled by the client', C.Res.Body) > 0);
    AssertTrue('the tool stopped: ' + C.Res.Body, Pos('stopped at step', C.Res.Body) > 0);
  finally
    C.Free;
  end;
end;

{ While the main thread is inside a call that handles the IDE's messages (a build does), a second call
  runs inside it.  A tool that changes things is refused then; read-only tools and the escape hatches
  are served.  editor_close would close the active editor if it ran: it must not. }
procedure TTestProgress.TestWriteToolIsRefusedInsideAnotherCall;
var
  C    : TSlowCall;
  Sess : string;
  W, Rd, Ans : string;
begin
  Sess := McpNewSession;
  C := TSlowCall.Create(StringReplace(SlowJson(71, 4, ''),
         '"__test_slow__","arguments":{"seconds":4}',
         '"__test_slow_main__","arguments":{"seconds":4,"pump":true}', []),
         [ACCEPT, 'Mcp-Session-Id: ' + Sess]);
  try
    Sleep(1000);
    W   := CallToolText('editor_close', '{}', []);
    Rd  := CallToolText('ide_ping', '{}', []);
    Ans := CallToolText('ide_answer_dialog', '{"answer":"x"}', []);
    C.WaitFor;
    AssertTrue('the write tool is refused: ' + W, Pos('was not run', W) > 0);
    AssertTrue('and names the call it waits for: ' + W, Pos('__test_slow_main__', W) > 0);
    AssertTrue('a read-only tool is served: ' + Rd, Pos('was not run', Rd) = 0);
    AssertTrue('so is ide_answer_dialog: ' + Ans, Pos('was not run', Ans) = 0);
    AssertTrue('the slow call itself ended normally: ' + C.Res.Body, Pos('finished 4 steps', C.Res.Body) > 0);
  finally
    C.Free;
  end;
end;

procedure TTestProgress.TestForeignUnknownAndLateCancelChangeNothing;
var
  C    : TSlowCall;
  Sess, Other : string;
  R    : THttpResult;
begin
  Sess  := McpNewSession;
  Other := McpNewSession;
  C := TSlowCall.Create(SlowJson(31, 3, ''), [ACCEPT, 'Mcp-Session-Id: ' + Sess]);
  try
    Sleep(500);
    { another session's cancel, and an id that does not exist }
    R := McpRequest('POST', '{"jsonrpc":"2.0","method":"notifications/cancelled","params":' +
      '{"requestId":31}}', ['Mcp-Session-Id: ' + Other], nil);
    AssertEquals(202, R.Code);
    R := McpRequest('POST', '{"jsonrpc":"2.0","method":"notifications/cancelled","params":' +
      '{"requestId":999}}', ['Mcp-Session-Id: ' + Sess], nil);
    AssertEquals(202, R.Code);
    C.WaitFor;
    AssertTrue('ran to the end: ' + C.Res.Body, Pos('finished 3 steps', C.Res.Body) > 0);
    AssertTrue('not an error: ' + C.Res.Body, Pos('"isError":false', C.Res.Body) > 0);
  finally
    C.Free;
  end;
  { late: the call is over }
  R := McpRequest('POST', '{"jsonrpc":"2.0","method":"notifications/cancelled","params":' +
    '{"requestId":31}}', ['Mcp-Session-Id: ' + Sess], nil);
  AssertEquals(202, R.Code);
end;

{ A clean build of the plugin's own package is cancelled 1.5 s after it started: the IDE's build is
  aborted (LazarusIDE.AbortBuild, queued to the main thread, which runs it inside the build).  Opt-in:
  it leaves the package half built until the compile at the end. }
procedure TTestProgress.TestCancelAbortsABuild;
var
  C    : TSlowCall;
  Sess : string;
  R    : THttpResult;
begin
  if GetEnvironmentVariable('MCP_DEBUG_TESTS') <> '1' then
    Ignore('set MCP_DEBUG_TESTS=1 to run this test (it cleans and aborts a build of the plugin package)');
  Sess := McpNewSession;
  C := TSlowCall.Create('{"jsonrpc":"2.0","id":51,"method":"tools/call","params":{' +
    '"name":"package_compile","arguments":{"package_name":"LazMcpAssistant","clean":true},' +
    '"_meta":{"progressToken":12}}}', [ACCEPT, 'Mcp-Session-Id: ' + Sess]);
  try
    Sleep(1500);
    R := McpRequest('POST', '{"jsonrpc":"2.0","method":"notifications/cancelled","params":' +
      '{"requestId":51}}', ['Mcp-Session-Id: ' + Sess], nil);
    AssertEquals(202, R.Code);
    C.WaitFor;
    AssertTrue('the build ended soon after the cancel, took ' + FloatToStr(C.Seconds), C.Seconds < 20);
    AssertTrue('says cancelled: ' + C.Res.Body, Pos('Cancelled by the client', C.Res.Body) > 0);
  finally
    C.Free;
    { leave the package built }
    CallToolText('package_compile', '{"package_name":"LazMcpAssistant"}', []);
  end;
end;

procedure TTestProgress.TestRegistryIsEmptyAfterwards;
var
  Before, After : string;
  R : THttpResult;
begin
  { the call that asks is itself in the registry (and the one that runs this suite, if any):
    what matters is that finished calls leave nothing behind }
  Before := CallToolText('__test_calls__', '{}', []);
  R := McpRequest('POST', SlowJson(41, 1, '1'), [ACCEPT], nil);
  AssertEquals(200, R.Code);
  R := McpRequest('POST', SlowJson(42, 1, ''), [], nil);
  AssertEquals(200, R.Code);
  After := CallToolText('__test_calls__', '{}', []);
  AssertEquals(Before, After);
end;

procedure TTestProgress.TestServerDiscoverIsMethodNotFound;
var
  R : THttpResult;
  D : TJSONData;
begin
  R := McpPost('{"jsonrpc":"2.0","id":9,"method":"server/discover"}');
  AssertEquals(200, R.Code);
  D := GetJSON(R.Body);
  try
    AssertEquals(-32601, TJSONObject(D).Objects['error'].Get('code', 0));
    AssertEquals(9, TJSONObject(D).Get('id', 0));
  finally
    D.Free;
  end;
end;

initialization
  RegisterTest(TTestProgress);

end.
