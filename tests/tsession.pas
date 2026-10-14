{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TSession;

{ TTestSession — client identity (ADR-012): the Mcp-Session-Id from
  initialize, the mcp_session cookie, anonymous callers, DELETE /mcp.
  Requires a running MCP server; ide_ping reports who the server thinks is
  calling. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, THttpHelper;

type
  TTestSession = class(TTestCase)
  published
    procedure TestInitializeHandsOutSessionId;
    procedure TestSessionHeaderIdentifiesCaller;
    procedure TestCookieIdentifiesCaller;
    procedure TestHeaderWinsOverCookie;
    procedure TestAnonymousIsOfferedCookie;
    procedure TestDeleteEndsSession;
    procedure TestDeleteNeedsToken;
  end;

implementation

uses
  Classes, SysUtils, fpjson, jsonparser;

const
  INIT_JSON = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{' +
    '"protocolVersion":"2025-06-18","capabilities":{},' +
    '"clientInfo":{"name":"mcpserver_tests","version":"1"}}}';

function PingClient(const AHeaders: array of string): string;
var
  T : string;
  D : TJSONData;
begin
  T := CallToolText('ide_ping', '{}', AHeaders);
  D := GetJSON(T);
  try
    Result := TJSONObject(D).Get('client', '');
  finally
    D.Free;
  end;
end;

function NewSession: string;
var
  H : TStringList;
begin
  H := TStringList.Create;
  try
    McpRequest('POST', INIT_JSON, [], H);
    Result := HeaderValue(H, 'Mcp-Session-Id');
  finally
    H.Free;
  end;
end;

procedure TTestSession.TestInitializeHandsOutSessionId;
var
  H  : TStringList;
  R  : THttpResult;
  Id : string;
begin
  H := TStringList.Create;
  try
    R := McpRequest('POST', INIT_JSON, [], H);
    CheckEquals(200, R.Code);
    Id := HeaderValue(H, 'Mcp-Session-Id');
    CheckTrue(Length(Id) >= 16, 'initialize returns Mcp-Session-Id, got "' + Id + '"');
    CheckTrue(Pos('mcp_session=' + Id + ';', HeaderValue(H, 'Set-Cookie')) = 1,
      'and the same id as a cookie: ' + HeaderValue(H, 'Set-Cookie'));
    CheckTrue(Pos('HttpOnly', HeaderValue(H, 'Set-Cookie')) > 0, 'cookie is HttpOnly');
    CheckNotEquals(Id, NewSession, 'each initialize gets a new id');
  finally
    H.Free;
  end;
end;

procedure TTestSession.TestSessionHeaderIdentifiesCaller;
var
  Id : string;
begin
  Id := NewSession;
  CheckEquals(Id, PingClient(['Mcp-Session-Id: ' + Id]));
end;

procedure TTestSession.TestCookieIdentifiesCaller;
begin
  CheckEquals('cookie-client-1', PingClient(['Cookie: x=1; mcp_session=cookie-client-1']));
end;

procedure TTestSession.TestHeaderWinsOverCookie;
begin
  CheckEquals('header-client',
    PingClient(['Mcp-Session-Id: header-client', 'Cookie: mcp_session=cookie-client']));
end;

procedure TTestSession.TestAnonymousIsOfferedCookie;
var
  H : TStringList;
  R : THttpResult;
begin
  CheckEquals('anonymous', PingClient([]));
  H := TStringList.Create;
  try
    R := McpRequest('POST', '{"jsonrpc":"2.0","id":2,"method":"ping"}', [], H);
    CheckEquals(200, R.Code);
    CheckTrue(Pos('mcp_session=', HeaderValue(H, 'Set-Cookie')) = 1,
      'anonymous callers are offered a cookie');
  finally
    H.Free;
  end;
end;

procedure TTestSession.TestDeleteEndsSession;
var
  Id : string;
  R  : THttpResult;
begin
  Id := NewSession;
  R  := McpRequest('DELETE', '', ['Mcp-Session-Id: ' + Id], nil);
  CheckEquals(200, R.Code, 'DELETE /mcp ends the session');
  { unknown ids are still accepted as they are (ADR-012: survives ide_rebuild) }
  CheckEquals(Id, PingClient(['Mcp-Session-Id: ' + Id]));
end;

procedure TTestSession.TestDeleteNeedsToken;
begin
  CheckEquals(401, McpPostAuth('', 'Bearer wrong').Code,
    'sanity: wrong token is refused');
  { McpRequest always sends the right token; build the wrong one by hand }
  CheckEquals(401, McpRequest('DELETE', '', ['Authorization: Bearer wrong'], nil).Code,
    'DELETE without the right token is refused');
end;

end.
