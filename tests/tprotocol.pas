{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TProtocol;

{ TTestProtocol — FPCUnit tests for JSON-RPC 2.0 protocol compliance.
  Requires a running MCP server (GServerAvail = True). }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, THttpHelper;

type
  TTestProtocol = class(TTestCase)
  published
    procedure TestPingReturnsOk;
    procedure TestInitializeReturnsProtocolVersion;
    procedure TestToolsListReturnsArray;
    procedure TestToolsListRequiredFields;
    procedure TestToolsListHasPackageTools;
    procedure TestUnknownMethodReturnsError32601;
    procedure TestMalformedJsonReturnsError32700;
    procedure TestResponseIdEchoesNumericId;
    procedure TestResponseIdEchoesStringId;
    procedure TestNotificationReturns202;
  end;

implementation

uses
  SysUtils, fpjson, jsonparser;

const
  PING_REQ = '{"jsonrpc":"2.0","id":1,"method":"ping"}';

function ParseJSON(const S: string): TJSONObject;
var
  D : TJSONData;
begin
  D := GetJSON(S);
  if not (D is TJSONObject) then
  begin
    D.Free;
    raise EAssertionFailedError.Create('Response is not a JSON object: ' + S);
  end;
  Result := TJSONObject(D);
end;

procedure TTestProtocol.TestPingReturnsOk;
var
  R   : THttpResult;
  Obj : TJSONObject;
begin
  R := McpPost(PING_REQ);
  CheckEquals(200, R.Code, 'ping must return HTTP 200');
  Obj := ParseJSON(R.Body);
  try
    CheckEquals('2.0', Obj.Get('jsonrpc', ''), 'jsonrpc field must be "2.0"');
    CheckFalse(Obj.Find('error') <> nil, 'ping must not return an error field');
    CheckTrue(Obj.Find('result') <> nil, 'ping must return a result field');
    CheckEquals(1, Obj.Get('id', 0), 'id must echo the request id');
  finally
    Obj.Free;
  end;
end;

procedure TTestProtocol.TestInitializeReturnsProtocolVersion;
var
  R   : THttpResult;
  Obj : TJSONObject;
  Res : TJSONObject;
begin
  R := McpPost('{"jsonrpc":"2.0","id":2,"method":"initialize",' +
               '"params":{"protocolVersion":"2024-11-05",' +
               '"clientInfo":{"name":"test","version":"1.0"}}}');
  CheckEquals(200, R.Code, 'initialize must return HTTP 200');
  Obj := ParseJSON(R.Body);
  try
    CheckEquals('2.0', Obj.Get('jsonrpc', ''), 'jsonrpc field must be "2.0"');
    CheckTrue(Obj.Find('result') <> nil, 'initialize must return a result field');
    Res := TJSONObject(Obj.Find('result'));
    CheckTrue(Res.Find('protocolVersion') <> nil,
      'initialize result must contain protocolVersion');
    CheckTrue(Res.Find('serverInfo') <> nil,
      'initialize result must contain serverInfo');
  finally
    Obj.Free;
  end;
end;

procedure TTestProtocol.TestToolsListReturnsArray;
var
  R    : THttpResult;
  Obj  : TJSONObject;
  Res  : TJSONObject;
  Tools: TJSONData;
begin
  R := McpPost('{"jsonrpc":"2.0","id":3,"method":"tools/list"}');
  CheckEquals(200, R.Code, 'tools/list must return HTTP 200');
  Obj := ParseJSON(R.Body);
  try
    Res := TJSONObject(Obj.Find('result'));
    CheckTrue(Assigned(Res), 'tools/list must return a result object');
    Tools := Res.Find('tools');
    CheckTrue(Assigned(Tools), 'result must have a "tools" field');
    CheckTrue(Tools is TJSONArray, '"tools" must be an array');
    CheckTrue(TJSONArray(Tools).Count > 0, '"tools" array must not be empty');
  finally
    Obj.Free;
  end;
end;

procedure TTestProtocol.TestToolsListRequiredFields;
var
  R     : THttpResult;
  Obj   : TJSONObject;
  Res   : TJSONObject;
  Tools : TJSONArray;
  Tool  : TJSONObject;
  I     : Integer;
begin
  R := McpPost('{"jsonrpc":"2.0","id":4,"method":"tools/list"}');
  CheckEquals(200, R.Code, 'tools/list must return HTTP 200');
  Obj := ParseJSON(R.Body);
  try
    Res   := TJSONObject(Obj.Find('result'));
    Tools := TJSONArray(Res.Find('tools'));
    for I := 0 to Tools.Count - 1 do
    begin
      Tool := TJSONObject(Tools[I]);
      CheckTrue(Tool.Find('name') <> nil,
        Format('Tool[%d] missing "name" field', [I]));
      CheckTrue(Tool.Find('description') <> nil,
        Format('Tool[%d] "%s" missing "description" field',
          [I, Tool.Get('name', '')]));
      CheckTrue(Tool.Find('inputSchema') <> nil,
        Format('Tool[%d] "%s" missing "inputSchema" field',
          [I, Tool.Get('name', '')]));
    end;
  finally
    Obj.Free;
  end;
end;

procedure TTestProtocol.TestToolsListHasPackageTools;
var
  R        : THttpResult;
  Obj      : TJSONObject;
  Res      : TJSONObject;
  Tools    : TJSONArray;
  I        : Integer;
  Names    : array[0..3] of string;
  Found    : array[0..3] of Boolean;
  AllFound : Boolean;
  Missing  : string;
  N        : Integer;
begin
  Names[0] := 'project_add_package';
  Names[1] := 'project_remove_package';
  Names[2] := 'package_install';
  Names[3] := 'package_uninstall';
  Found[0] := False; Found[1] := False; Found[2] := False; Found[3] := False;

  R := McpPost('{"jsonrpc":"2.0","id":5,"method":"tools/list"}');
  CheckEquals(200, R.Code, 'tools/list must return HTTP 200');
  Obj := ParseJSON(R.Body);
  try
    Res   := TJSONObject(Obj.Find('result'));
    Tools := TJSONArray(Res.Find('tools'));
    for I := 0 to Tools.Count - 1 do
      for N := 0 to 3 do
        if TJSONObject(Tools[I]).Get('name', '') = Names[N] then
          Found[N] := True;
  finally
    Obj.Free;
  end;

  AllFound := True;
  Missing  := '';
  for N := 0 to 3 do
    if not Found[N] then
    begin
      AllFound := False;
      if Missing <> '' then Missing := Missing + ', ';
      Missing := Missing + Names[N];
    end;
  CheckTrue(AllFound, 'FR-004 tools missing from tools/list: ' + Missing);
end;

procedure TTestProtocol.TestUnknownMethodReturnsError32601;
var
  R   : THttpResult;
  Obj : TJSONObject;
  Err : TJSONObject;
begin
  R := McpPost('{"jsonrpc":"2.0","id":6,"method":"no_such_method"}');
  CheckEquals(200, R.Code, 'Unknown method must still return HTTP 200');
  Obj := ParseJSON(R.Body);
  try
    Err := TJSONObject(Obj.Find('error'));
    CheckTrue(Assigned(Err), 'Unknown method must return an error object');
    CheckEquals(-32601, Err.Get('code', 0), 'Unknown method must use code -32601');
  finally
    Obj.Free;
  end;
end;

procedure TTestProtocol.TestMalformedJsonReturnsError32700;
var
  R   : THttpResult;
  Obj : TJSONObject;
  Err : TJSONObject;
begin
  R := McpPost('{not valid json at all');
  // Server may return 200 with JSON-RPC error, or 400. Accept either.
  CheckTrue((R.Code = 200) or (R.Code = 400), 'Malformed JSON should return 200 or 400');
  if R.Code = 200 then
  begin
    Obj := ParseJSON(R.Body);
    try
      Err := TJSONObject(Obj.Find('error'));
      CheckTrue(Assigned(Err), 'Malformed JSON must return an error object');
      CheckEquals(-32700, Err.Get('code', 0), 'Malformed JSON must use code -32700');
    finally
      Obj.Free;
    end;
  end;
end;

procedure TTestProtocol.TestResponseIdEchoesNumericId;
var
  R   : THttpResult;
  Obj : TJSONObject;
begin
  R := McpPost('{"jsonrpc":"2.0","id":42,"method":"ping"}');
  CheckEquals(200, R.Code);
  Obj := ParseJSON(R.Body);
  try
    CheckEquals(42, Obj.Get('id', -1), 'Response id must echo numeric request id 42');
  finally
    Obj.Free;
  end;
end;

procedure TTestProtocol.TestResponseIdEchoesStringId;
var
  R   : THttpResult;
  Obj : TJSONObject;
begin
  R := McpPost('{"jsonrpc":"2.0","id":"req-abc","method":"ping"}');
  CheckEquals(200, R.Code);
  Obj := ParseJSON(R.Body);
  try
    CheckEquals('req-abc', Obj.Get('id', ''),
      'Response id must echo string request id "req-abc"');
  finally
    Obj.Free;
  end;
end;

procedure TTestProtocol.TestNotificationReturns202;
var
  R : THttpResult;
begin
  // A JSON-RPC notification has no "id" field; the server must respond 202.
  R := McpPost('{"jsonrpc":"2.0","method":"ping"}');
  CheckEquals(202, R.Code,
    'JSON-RPC notification (no id) must return HTTP 202 with no body');
end;

initialization
  // Registered conditionally by mcpserver_tests.lpr when server is available.
end.
