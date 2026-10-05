{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
program mcpserver_tests;

{ MCP Server test runner.
  Standalone utility tests always run.
  Protocol and auth tests require the Lazarus MCP server to be running
  (start Lazarus IDE; the server starts automatically). }

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, fphttpclient,
  fpcunit, testregistry,
  consoletestrunner,
  THttpHelper,
  TUtils, TProtocol, TAuth, TTestInfra;

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
  ConfigPath := GetEnvironmentVariable('LOCALAPPDATA') +
                '\lazarus\mcpassistantoptions.xml';
  if not FileExists(ConfigPath) then Exit;
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
  App  : TTestRunner;
  Port : Word;
  Tok  : string;

begin
  // TTestUtils is registered via its own initialization block (tutils.pas).
  // Conditionally run protocol/auth tests when the server is reachable.
  if ReadServerConfig(Port, Tok) and PingServer(Port, Tok) then
  begin
    GServerPort  := Port;
    GServerToken := Tok;
    GServerAvail := True;
    WriteLn('Server on port ', Port, ' — protocol and auth tests enabled.');
    GetTestRegistry.AddTest(TTestProtocol.Suite);
    GetTestRegistry.AddTest(TTestAuth.Suite);
  end
  else
    WriteLn('Server not running — protocol/auth tests skipped.');
  WriteLn;

  DefaultFormat        := fPlain;
  DefaultRunAllTests   := True;
  App := TTestRunner.Create(nil);
  try
    App.Title := 'MCP Server Tests';
    App.Initialize;
    App.Run;
  finally
    App.Free;
  end;
end.
