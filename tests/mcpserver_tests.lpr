{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
program mcpserver_tests;

{ MCP Server test runner.
  Standalone utility tests always run.
  Protocol and auth tests require the Lazarus MCP server to be running
  (start Lazarus IDE; the server starts automatically).

  Optional argument:  --junit-out=<path>
  Writes JUnit-compatible XML to the given path in addition to the
  normal plain-text console output.  Consumed by run_tests MCP tool. }

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, fphttpclient,
  fpcunit, testregistry, testutils,
  consoletestrunner, fpcunitreport, plaintestreport,
  THttpHelper,
  TUtils, TProtocol, TAuth, TTestInfra,
  TJUnitWriter, TProjectTools, TLauncher, TSettings, TSession, TToolSmoke,
  TConsent, TDebugger;

{ ── Test runner with optional JUnit XML side-output ─────────────────────── }

type
  TMcpTestRunner = class(TTestRunner)
  private
    FJUnitOut : string;
  protected
    procedure AppendLongOpts; override;
    function  ParseOptions: Boolean; override;
    procedure DoTestRun(ATest: TTest); override;
  public
    property JUnitOut: string read FJUnitOut write FJUnitOut;
  end;

procedure TMcpTestRunner.AppendLongOpts;
begin
  inherited;
  LongOpts.Add('junit-out:');
end;

function TMcpTestRunner.ParseOptions: Boolean;
var
  S : string;
begin
  Result := inherited ParseOptions;
  S := GetOptionValue('junit-out');
  if S <> '' then FJUnitOut := S;
end;

procedure TMcpTestRunner.DoTestRun(ATest: TTest);
var
  RWriter : TCustomResultsWriter;
  JWriter : TJUnitResultsWriter;
  JStream : TFileStream;
  Res     : TTestResult;
begin
  JWriter := nil;
  JStream := nil;
  RWriter := GetResultsWriter;
  Res     := TTestResult.Create;
  try
    RWriter.FileName := FileName;
    Res.AddListener(RWriter);
    if FJUnitOut <> '' then
    begin
      JStream := TFileStream.Create(FJUnitOut, fmCreate);
      JWriter := TJUnitResultsWriter.Create(JStream);
      Res.AddListener(JWriter);
    end;
    ATest.Run(Res);
    RWriter.WriteResult(Res);
    if Assigned(JWriter) then JWriter.FlushXML;
    ExitCode := Res.NumberOfFailures + Res.NumberOfErrors;
  finally
    Res.Free;
    RWriter.Free;
    if Assigned(JWriter) then JWriter.Free;
    if Assigned(JStream) then JStream.Free;
  end;
end;

{ ── Server discovery ─────────────────────────────────────────────────────── }

function ExtractXMLAttr(const XML, Attr: string): string;
var
  K : string;
  I : Integer;
begin
  Result := '';
  K := Attr + '="';
  I := Pos(K, XML);
  if I = 0 then Exit;
  Inc(I, Length(K));
  while (I <= Length(XML)) and (XML[I] <> '"') do
  begin
    Result := Result + XML[I];
    Inc(I);
  end;
end;

function ReadServerConfig(out APort: Word; out AToken: string): Boolean;
var
  ConfigPath : string;
  SL         : TStringList;
  XML        : string;
begin
  Result := False;
  APort  := 0;
  AToken := '';
  { MCP_OPTIONS_FILE overrides the default, e.g. for Lazarus run with --pcp }
  ConfigPath := GetEnvironmentVariable('MCP_OPTIONS_FILE');
  if ConfigPath = '' then
    {$IFDEF WINDOWS}
    ConfigPath := IncludeTrailingPathDelimiter(GetEnvironmentVariable('LOCALAPPDATA')) +
                  'lazarus' + PathDelim + 'mcpassistantoptions.xml';
    {$ELSE}
    ConfigPath := IncludeTrailingPathDelimiter(GetUserDir) +
                  '.lazarus' + PathDelim + 'mcpassistantoptions.xml';
    {$ENDIF}
  if not FileExists(ConfigPath) then Exit;
  GOptionsFile := ConfigPath;
  SL := TStringList.Create;
  try
    SL.LoadFromFile(ConfigPath);
    XML    := SL.Text;
    AToken := ExtractXMLAttr(XML, 'Token');
    APort  := StrToIntDef(ExtractXMLAttr(XML, 'Port'), 0);
    Result := (APort > 0) and (AToken <> '');
  finally
    SL.Free;
  end;
end;

function PingServer(APort: Word; const AToken: string): Boolean;
var
  Http    : TFPHTTPClient;
  ReqBody : TStringStream;
  RespBuf : TStringStream;
begin
  Result  := False;
  Http    := TFPHTTPClient.Create(nil);
  ReqBody := TStringStream.Create('{"jsonrpc":"2.0","id":0,"method":"ping"}');
  RespBuf := TStringStream.Create('');
  try
    Http.IOTimeout := 2000;
    Http.AddHeader('Authorization', 'Bearer ' + AToken);
    Http.AddHeader('Content-Type', 'application/json');
    Http.RequestBody := ReqBody;
    try
      Http.Post(Format('http://127.0.0.1:%d/mcp', [APort]), RespBuf);
      Result := Http.ResponseStatusCode = 200;
    except
      Result := False;
    end;
  finally
    ReqBody.Free;
    RespBuf.Free;
    Http.Free;
  end;
end;

{ ── Entry point ──────────────────────────────────────────────────────────── }

var
  App  : TMcpTestRunner;
  Port : Word;
  Tok  : string;

begin
  // TTestUtils, TTestJUnitWriter, TTestLauncher and TTestSettingsFile are
  // registered via their own initialization blocks.  The suites that talk to
  // the server are registered only when it is reachable.
  if ReadServerConfig(Port, Tok) and PingServer(Port, Tok) then
  begin
    GServerPort  := Port;
    GServerToken := Tok;
    GServerAvail := True;
    WriteLn('Server on port ', Port, ' — protocol and auth tests enabled.');
    GetTestRegistry.AddTest(TTestProtocol.Suite);
    GetTestRegistry.AddTest(TTestAuth.Suite);
    GetTestRegistry.AddTest(TTestProjectTools.Suite);
    GetTestRegistry.AddTest(TTestSession.Suite);
    GetTestRegistry.AddTest(TTestToolSmoke.Suite);
    GetTestRegistry.AddTest(TTestConsent.Suite);
    { opt-in: they switch the IDE's project and take about half a minute }
    if (GetEnvironmentVariable('MCP_DEBUG_TESTS') = '1') or DebuggeeIsActive then
      GetTestRegistry.AddTest(TDebuggeeSetup.Create(TTestDebugger.Suite))
    else
      WriteLn('Debugger tests skipped (set MCP_DEBUG_TESTS=1, or open ',
              'tests/debuggee/mcpdebuggee.lpi in the IDE).');
  end
  else
    WriteLn('Server not running — protocol/auth tests skipped.');
  WriteLn;

  DefaultFormat      := fPlain;
  DefaultRunAllTests := True;
  App := TMcpTestRunner.Create(nil);
  try
    App.Title := 'MCP Server Tests';
    App.Initialize;
    App.Run;
  finally
    App.Free;
  end;
end.
