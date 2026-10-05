{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TAuth;

{ TTestAuth — FPCUnit tests for Bearer token auth and HTTP gate-keeping.
  Requires a running MCP server (GServerAvail = True). }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, THttpHelper;

type
  TTestAuth = class(TTestCase)
  published
    procedure TestValidTokenReturns200;
    procedure TestWrongTokenReturns401;
    procedure TestMissingAuthHeaderReturns401;
    procedure TestGetMethodReturns405;
    procedure TestWrongPathReturns404;
    procedure TestOriginHeaderReturns403;
    procedure TestTokenNotEchoedInResponse;
  end;

implementation

uses
  SysUtils;

const
  PING_REQ = '{"jsonrpc":"2.0","id":1,"method":"ping"}';

procedure TTestAuth.TestValidTokenReturns200;
var
  R : THttpResult;
begin
  R := McpPost(PING_REQ);
  CheckEquals(200, R.Code, 'Valid token must return HTTP 200');
end;

procedure TTestAuth.TestWrongTokenReturns401;
var
  R : THttpResult;
begin
  R := McpPostAuth(PING_REQ, 'Bearer WRONG_TOKEN_000000000000000000000000000000000000');
  CheckEquals(401, R.Code, 'Wrong token must return HTTP 401');
end;

procedure TTestAuth.TestMissingAuthHeaderReturns401;
var
  R : THttpResult;
begin
  R := McpPostAuth(PING_REQ, '');  // no Authorization header
  CheckEquals(401, R.Code, 'Missing Authorization header must return HTTP 401');
end;

procedure TTestAuth.TestGetMethodReturns405;
var
  R : THttpResult;
begin
  R := McpGet;
  CheckEquals(405, R.Code, 'GET /mcp must return HTTP 405 Method Not Allowed');
end;

procedure TTestAuth.TestWrongPathReturns404;
var
  R : THttpResult;
begin
  R := McpPostPath('/not_mcp', PING_REQ);
  CheckEquals(404, R.Code, 'POST to wrong path must return HTTP 404');
end;

procedure TTestAuth.TestOriginHeaderReturns403;
var
  R : THttpResult;
begin
  R := McpPostWithOrigin(PING_REQ, 'http://evil.example.com');
  CheckEquals(403, R.Code,
    'Request with Origin header must return HTTP 403 (DNS-rebinding guard)');
end;

procedure TTestAuth.TestTokenNotEchoedInResponse;
var
  R : THttpResult;
begin
  R := McpPost(PING_REQ);
  CheckEquals(200, R.Code, 'Valid ping must return 200');
  CheckEquals(0, Pos(GServerToken, R.Body),
    'Server token must not appear in any response body');
end;

initialization
  // Registered conditionally by mcpserver_tests.lpr when server is available.
end.
