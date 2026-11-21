{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpSelfTest;

{ The questions a client asks the server, asked by the plugin itself (ADR-032): the server
  answers initialize with the token, lists its tools, refuses a wrong token and passes a call
  through to the IDE's main thread.  One line per check, with the reason when it fails.

  No IDE dependency (RTL, fpjson and fphttpclient), so the test program runs it against the
  live server.  Blocks until done, so call it from a thread of its own: check 5 needs the
  IDE's main thread. }

{$mode objfpc}{$H+}

interface

type
  TMcpCheckState = (csOk, csFailed, csSkipped);

  TMcpSelfTestCheck = record
    Name   : string;
    State  : TMcpCheckState;
    Detail : string;
  end;

  TMcpSelfTestChecks = array of TMcpSelfTestCheck;

{ AHost:APort is where clients connect; AToken the primary token.  The token is sent to that
  address only. }
function McpRunSelfTest(const AHost: string; APort: Word; const AToken: string): TMcpSelfTestChecks;

{ One line per check ("ok", "FAILED", "skipped"), then a verdict line. }
function McpSelfTestText(const AChecks: TMcpSelfTestChecks): string;

function McpSelfTestPassed(const AChecks: TMcpSelfTestChecks): Boolean;

implementation

uses
  Classes, SysUtils, fpjson, jsonparser, fphttpclient;

const
  INIT_BODY =
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18",' +
    '"capabilities":{},"clientInfo":{"name":"lazarus-mcp-assistant connection test","version":"1"}}}';

{ POST (or DELETE when ABody is '') to the server; ACode -1 and AText the reason when it could
  not be reached }
procedure Send(const AMethod, AUrl, AToken, ASession, ABody: string; ATimeoutMs: Integer;
  out ACode: Integer; out AText, ASessionOut: string);
var
  Http : TFPHTTPClient;
  Req  : TStringStream;
  Resp : TStringStream;
  I    : Integer;
begin
  ACode := -1;
  AText := '';
  ASessionOut := '';
  Http := TFPHTTPClient.Create(nil);
  Req  := TStringStream.Create(ABody);
  Resp := TStringStream.Create('');
  try
    Http.IOTimeout := ATimeoutMs;
    Http.ConnectTimeout := 3000;
    if AToken <> '' then Http.AddHeader('Authorization', 'Bearer ' + AToken);
    if ABody <> '' then Http.AddHeader('Content-Type', 'application/json');
    if ASession <> '' then Http.AddHeader('Mcp-Session-Id', ASession);
    if ABody <> '' then Http.RequestBody := Req;
    try
      Http.HTTPMethod(AMethod, AUrl, Resp, [200, 202, 204, 400, 401, 403, 404, 405]);
      ACode := Http.ResponseStatusCode;
      AText := Resp.DataString;
      for I := 0 to Http.ResponseHeaders.Count - 1 do
        if LowerCase(Copy(Http.ResponseHeaders[I], 1, 15)) = 'mcp-session-id:' then
          ASessionOut := Trim(Copy(Http.ResponseHeaders[I], 16, MaxInt));
    except
      on E: Exception do AText := E.Message;
    end;
  finally
    Req.Free;
    Resp.Free;
    Http.Free;
  end;
end;

function JsonOf(const AText: string): TJSONObject;
var
  D : TJSONData;
begin
  Result := nil;
  try
    D := GetJSON(AText);
  except
    Exit;
  end;
  if D is TJSONObject then Result := TJSONObject(D) else D.Free;
end;

function McpRunSelfTest(const AHost: string; APort: Word; const AToken: string): TMcpSelfTestChecks;
var
  Url, Text, Sess, Dummy : string;
  Code    : Integer;
  Alive   : Boolean;
  Obj, R  : TJSONObject;
  Tools   : TJSONData;

  procedure Add(const AName: string; AState: TMcpCheckState; const ADetail: string);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].Name   := AName;
    Result[High(Result)].State  := AState;
    Result[High(Result)].Detail := ADetail;
  end;

  procedure Skip(const AName: string);
  begin
    Add(AName, csSkipped, 'not tried: the server did not answer the first check');
  end;

begin
  Result := nil;
  Url := Format('http://%s:%d/mcp', [AHost, APort]);

  { 1 + 2: reach the server and open a session with the token }
  Send('POST', Url, AToken, '', INIT_BODY, 5000, Code, Text, Sess);
  Alive := Code > 0;
  if not Alive then
  begin
    Add('The server answers at ' + Url, csFailed,
      'no connection (' + Text + '). Is the IDE running, and is this the address and port ' +
      'the client uses? A client started before a rebuild or a restart keeps the old port.');
    Skip('The token is accepted (initialize)');
    Skip('The tool list is answered (tools/list)');
    Skip('A wrong token is refused');
    Skip('A call reaches the IDE (ide_ping)');
    Exit;
  end;
  Add('The server answers at ' + Url, csOk, 'HTTP ' + IntToStr(Code));

  Obj := JsonOf(Text);
  try
    if Code = 401 then
      Add('The token is accepted (initialize)', csFailed,
        'refused (401): the token the client sends is not this IDE''s. Copy it again from ' +
        'Tools > MCP Assistant, or check the client''s Authorization header.')
    else if Code <> 200 then
      Add('The token is accepted (initialize)', csFailed, 'HTTP ' + IntToStr(Code) + ': ' + Copy(Text, 1, 120))
    else if (Obj = nil) or (Obj.Find('result') = nil) then
      Add('The token is accepted (initialize)', csFailed,
        'HTTP 200 but no MCP answer: something other than the server (a proxy?) answered')
    else
    begin
      R := TJSONObject(Obj.Find('result'));
      Add('The token is accepted (initialize)', csOk,
        'protocol ' + R.Get('protocolVersion', '?') +
        '; session ' + BoolToStr(Sess <> '', 'opened', 'none (anonymous)'));
    end;
  finally
    Obj.Free;
  end;

  if (Result[High(Result)].State = csOk) then
  begin
    { 3 }
    Send('POST', Url, AToken, Sess, '{"jsonrpc":"2.0","id":2,"method":"tools/list"}', 10000,
      Code, Text, Dummy);
    Obj := JsonOf(Text);
    try
      Tools := nil;
      if (Obj <> nil) and (Obj.Find('result') <> nil) then
        Tools := TJSONObject(Obj.Find('result')).Find('tools');
      if (Code = 200) and (Tools is TJSONArray) then
        Add('The tool list is answered (tools/list)', csOk,
          Format('%d tools, %d bytes', [TJSONArray(Tools).Count, Length(Text)]))
      else
        Add('The tool list is answered (tools/list)', csFailed,
          'HTTP ' + IntToStr(Code) + ': ' + Copy(Text, 1, 120));
    finally
      Obj.Free;
    end;
  end
  else
    Add('The tool list is answered (tools/list)', csSkipped, 'not tried: the token was not accepted');

  { 4: the server must really check the token }
  Send('POST', Url, 'not-the-token', '', '{"jsonrpc":"2.0","id":3,"method":"ping"}', 5000,
    Code, Text, Dummy);
  if Code = 401 then
    Add('A wrong token is refused', csOk, 'HTTP 401')
  else
    Add('A wrong token is refused', csFailed,
      'HTTP ' + IntToStr(Code) + ': the server answered a request with a wrong token');

  { 5: a tools/call goes through the IDE's main thread }
  if Result[1].State = csOk then
  begin
    Send('POST', Url, AToken, Sess,
      '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"ide_ping","arguments":{}}}',
      20000, Code, Text, Dummy);
    if (Code = 200) and (Pos('\"status\":\"ok\"', Text) > 0) then
      Add('A call reaches the IDE (ide_ping)', csOk, 'answered')
    else if Code > 0 then
      Add('A call reaches the IDE (ide_ping)', csFailed,
        'HTTP ' + IntToStr(Code) + ': ' + Copy(Text, 1, 160) +
        '. The main thread may be blocked by a dialog (ide_get_open_dialogs).')
    else
      Add('A call reaches the IDE (ide_ping)', csFailed,
        'no answer within 20 s (' + Text + '): the IDE''s main thread is not responding, ' +
        'perhaps blocked by a dialog');
  end
  else
    Add('A call reaches the IDE (ide_ping)', csSkipped, 'not tried: the token was not accepted');

  { leave no session behind }
  if Sess <> '' then
    Send('DELETE', Url, AToken, Sess, '', 3000, Code, Text, Dummy);
end;

function McpSelfTestPassed(const AChecks: TMcpSelfTestChecks): Boolean;
var
  I : Integer;
begin
  Result := Length(AChecks) > 0;
  for I := 0 to High(AChecks) do
    if AChecks[I].State <> csOk then Result := False;
end;

function McpSelfTestText(const AChecks: TMcpSelfTestChecks): string;
const
  MARK : array[TMcpCheckState] of string = ('ok      ', 'FAILED  ', 'skipped ');
var
  I : Integer;
begin
  Result := '';
  for I := 0 to High(AChecks) do
    Result := Result + MARK[AChecks[I].State] + AChecks[I].Name + ': ' +
              AChecks[I].Detail + LineEnding;
  if McpSelfTestPassed(AChecks) then
    Result := Result + LineEnding + 'Everything a client needs works.'
  else
    Result := Result + LineEnding + 'Something a client needs does not work; see the first FAILED line.';
end;

end.
