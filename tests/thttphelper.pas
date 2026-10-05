{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit THttpHelper;

{ Shared globals and HTTP helpers for the MCP server test suites.
  Populated by the test program entry point before any suite runs. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fphttpclient, Classes;

var
  GServerPort  : Word    = 0;
  GServerToken : string  = '';
  GServerAvail : Boolean = False;

type
  THttpResult = record
    Code : Integer; // HTTP status code, or -1 on network error
    Body : string;
  end;

{ POST /mcp with the correct Authorization header and Content-Type. }
function McpPost(const JSON: string): THttpResult;

{ POST /mcp with an arbitrary Authorization value (for auth tests). }
function McpPostAuth(const JSON, AuthHeader: string): THttpResult;

{ GET /mcp (should return 405 Method Not Allowed). }
function McpGet: THttpResult;

{ POST /mcp with an Origin header (should trigger 403 DNS-rebinding guard). }
function McpPostWithOrigin(const JSON, Origin: string): THttpResult;

{ POST to an arbitrary path on the server. }
function McpPostPath(const Path, JSON: string): THttpResult;

implementation

function DoPost(const Path, JSON, AuthHeader, Origin: string): THttpResult;
var
  Http : TFPHTTPClient;
  Req  : TStringStream;
  Resp : TStringStream;
begin
  Result.Code := -1;
  Result.Body := '';
  Http := TFPHTTPClient.Create(nil);
  Req  := TStringStream.Create(JSON);
  Resp := TStringStream.Create('');
  try
    Http.IOTimeout := 3000;
    if AuthHeader <> '' then
      Http.AddHeader('Authorization', AuthHeader);
    Http.AddHeader('Content-Type', 'application/json');
    if Origin <> '' then
      Http.AddHeader('Origin', Origin);
    Http.RequestBody := Req;
    try
      Http.Post(Format('http://127.0.0.1:%d%s', [GServerPort, Path]), Resp);
      Result.Code := Http.ResponseStatusCode;
      Result.Body := Resp.DataString;
    except
      Result.Code := -1;
    end;
  finally
    Req.Free;
    Resp.Free;
    Http.Free;
  end;
end;

function McpPost(const JSON: string): THttpResult;
begin
  Result := DoPost('/mcp', JSON, 'Bearer ' + GServerToken, '');
end;

function McpPostAuth(const JSON, AuthHeader: string): THttpResult;
begin
  Result := DoPost('/mcp', JSON, AuthHeader, '');
end;

function McpGet: THttpResult;
var
  Http : TFPHTTPClient;
  Resp : TStringStream;
begin
  Result.Code := -1;
  Result.Body := '';
  Http := TFPHTTPClient.Create(nil);
  Resp := TStringStream.Create('');
  try
    Http.IOTimeout := 3000;
    Http.AddHeader('Authorization', 'Bearer ' + GServerToken);
    // TFPHTTPClient raises for non-2xx; swallow so we can read the status code.
    try
      Http.Get(Format('http://127.0.0.1:%d/mcp', [GServerPort]), Resp);
    except
    end;
    Result.Code := Http.ResponseStatusCode;
    if Result.Code = 0 then Result.Code := -1;
    Result.Body := Resp.DataString;
  finally
    Resp.Free;
    Http.Free;
  end;
end;

function McpPostWithOrigin(const JSON, Origin: string): THttpResult;
begin
  Result := DoPost('/mcp', JSON, 'Bearer ' + GServerToken, Origin);
end;

function McpPostPath(const Path, JSON: string): THttpResult;
begin
  Result := DoPost(Path, JSON, 'Bearer ' + GServerToken, '');
end;

end.
