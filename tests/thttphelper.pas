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
  GOptionsFile : string  = '';   { mcpassistantoptions.xml the server was found by }

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

{ AMethod /mcp with the correct token plus AHeaders ('Name: value' items).
  Any status code is returned rather than raised; ARespHeaders receives the
  response headers as 'Name: value' lines. }
function McpRequest(const AMethod, JSON: string; const AHeaders: array of string;
  ARespHeaders: TStrings): THttpResult;

{ Value of header AName in 'Name: value' lines, '' if absent. }
function HeaderValue(AHeaders: TStrings; const AName: string): string;

{ POST tools/call; the result's first text content, or 'TOOL ERROR: ...' /
  'RPC ERROR: ...' / 'HTTP <code>'. }
function CallToolText(const ToolName, ArgsJSON: string;
  const AHeaders: array of string): string;

{ S as a JSON string literal, quotes included. }
function JsonStr(const S: string): string;

{ A new MCP session: initialize's Mcp-Session-Id.  The server answers 404 to
  a session id it didn't hand out, so tests that act as clients start one. }
function McpNewSession: string;

implementation

uses
  fpjson, jsonparser;

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

function McpRequest(const AMethod, JSON: string; const AHeaders: array of string;
  ARespHeaders: TStrings): THttpResult;
var
  Http : TFPHTTPClient;
  Req  : TStringStream;
  Resp : TStringStream;
  I, P : Integer;
begin
  Result.Code := -1;
  Result.Body := '';
  Http := TFPHTTPClient.Create(nil);
  Req  := TStringStream.Create(JSON);
  Resp := TStringStream.Create('');
  try
    Http.IOTimeout := 90000;   { debug_run may block for its whole timeout_s }
    Http.AddHeader('Authorization', 'Bearer ' + GServerToken);
    Http.AddHeader('Content-Type', 'application/json');
    for I := Low(AHeaders) to High(AHeaders) do
    begin
      P := Pos(':', AHeaders[I]);
      Http.AddHeader(Copy(AHeaders[I], 1, P - 1), Trim(Copy(AHeaders[I], P + 1, MaxInt)));
    end;
    if JSON <> '' then
      Http.RequestBody := Req;
    try
      Http.HTTPMethod(AMethod, Format('http://127.0.0.1:%d/mcp', [GServerPort]), Resp, []);
      Result.Code := Http.ResponseStatusCode;
      Result.Body := Resp.DataString;
      if Assigned(ARespHeaders) then
        ARespHeaders.Assign(Http.ResponseHeaders);
    except
      Result.Code := -1;
    end;
  finally
    Req.Free;
    Resp.Free;
    Http.Free;
  end;
end;

function HeaderValue(AHeaders: TStrings; const AName: string): string;
var
  I, P : Integer;
begin
  Result := '';
  for I := 0 to AHeaders.Count - 1 do
  begin
    P := Pos(':', AHeaders[I]);
    if (P > 0) and SameText(Trim(Copy(AHeaders[I], 1, P - 1)), AName) then
      Exit(Trim(Copy(AHeaders[I], P + 1, MaxInt)));
  end;
end;

function CallToolText(const ToolName, ArgsJSON: string;
  const AHeaders: array of string): string;
var
  R       : THttpResult;
  D       : TJSONData;
  Obj     : TJSONObject;
  Res     : TJSONObject;
  Content : TJSONArray;
begin
  R := McpRequest('POST', '{"jsonrpc":"2.0","id":7,"method":"tools/call",' +
    '"params":{"name":"' + ToolName + '","arguments":' + ArgsJSON + '}}', AHeaders, nil);
  if R.Code <> 200 then
    Exit('HTTP ' + IntToStr(R.Code));
  D := GetJSON(R.Body);
  try
    Obj := D as TJSONObject;
    if Assigned(Obj.Find('error')) then
      Exit('RPC ERROR: ' + Obj.Objects['error'].Get('message', ''));
    Res     := Obj.Objects['result'];
    Content := Res.Arrays['content'];
    Result  := TJSONObject(Content[0]).Get('text', '');
    if Res.Get('isError', False) then
      Result := 'TOOL ERROR: ' + Result;
  finally
    D.Free;
  end;
end;

function JsonStr(const S: string): string;
begin
  Result := '"' + StringToJSONString(S) + '"';
end;

function McpNewSession: string;
var
  H : TStringList;
begin
  H := TStringList.Create;
  try
    McpRequest('POST', '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{' +
      '"protocolVersion":"2025-06-18","capabilities":{},' +
      '"clientInfo":{"name":"mcpserver_tests","version":"1"}}}', [], H);
    Result := HeaderValue(H, 'Mcp-Session-Id');
  finally
    H.Free;
  end;
end;

end.
