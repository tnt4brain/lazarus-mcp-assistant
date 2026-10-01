{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpIdeServer;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fphttpserver, httpdefs, fpjson, jsonparser,
  LazIDEIntf, LazLogger, McpIdeListeners, McpIdeState;

type
  { Re-publishes Address so callers can bind to 127.0.0.1 }
  TMcpHttpServer = class(TFPHttpServer)
  published
    property Address;
  end;

  TMcpServerThread = class(TThread)
  private
    FServer : TMcpHttpServer;
    FToken  : string;
    FPort   : Word;
    { Synchronize workspace — only valid during an active Synchronize call }
    FSyncToolName : string;
    FSyncParams   : TJSONObject; // borrowed reference, server thread owns it
    FSyncResult   : string;      // output set by main thread
    FSyncError    : Boolean;     // True when SyncCallTool encountered an error
    procedure HandleRequest(Sender: TObject;
                            var ARequest  : TFPHTTPConnectionRequest;
                            var AResponse : TFPHTTPConnectionResponse);
    function  HandleRPC(const Body: string): string;
    function  HandleInitialize(ID: TJSONData; Params: TJSONObject): string;
    function  HandlePing(ID: TJSONData): string;
    function  HandleToolsList(ID: TJSONData): string;
    function  HandleToolsCall(ID: TJSONData; Params: TJSONObject): string;
    function  RPCResult(ID: TJSONData; ResultObj: TJSONObject): string;
    function  RPCError(ID: TJSONData; ErrCode: Integer;
                       const Msg: string): string;
    procedure SyncCallTool; // runs on main thread via Synchronize
  protected
    procedure Execute; override;
  public
    constructor Create(const AToken: string; APort: Word);
    destructor  Destroy; override;
    procedure StopServer;
    property Token : string read FToken;
    property Port  : Word   read FPort;
  end;

var
  McpServerThread : TMcpServerThread = nil;

procedure InitializeMcpServer;
procedure FinalizeMcpServer;
procedure RegisterIDECloseHook;
function  IsServerRunning : Boolean;
function  GetServerPort   : Word;
function  GetServerToken  : string;
function  WriteMcpConfig  : string; // returns temp config file path

implementation

uses
  SrcEditorIntf, ProjectIntf, LazFileUtils, Sockets, fphttpclient;

{ ── Low-level socket helpers ────────────────────────────────────────────── }

{ Swap a 16-bit integer between host and network byte order (identical in both
  directions on little-endian x86; avoids using the deprecated ShortHostToNet). }
function Swap16(v: Word): Word; inline;
begin
  Result := ((v and $00FF) shl 8) or (v shr 8);
end;

{ Probe-bind 127.0.0.1:0 to let the OS choose a free port.
  Returns 0 on failure. }
function FindFreePort: Word;
var
  S    : LongInt;
  Addr : TInetSockAddr;
  Len  : LongInt;
begin
  Result := 0;
  S := fpSocket(AF_INET, SOCK_STREAM, 0);
  if S < 0 then Exit;
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family          := AF_INET;
  Addr.sin_port            := 0;       // OS assigns
  Addr.sin_addr.s_bytes[1] := 127;    // 127.0.0.1, bytes in wire order
  Addr.sin_addr.s_bytes[2] := 0;
  Addr.sin_addr.s_bytes[3] := 0;
  Addr.sin_addr.s_bytes[4] := 1;
  if fpBind(S, @Addr, SizeOf(Addr)) = 0 then
  begin
    Len := SizeOf(Addr);
    if fpGetSockName(S, @Addr, @Len) = 0 then
      Result := Swap16(Addr.sin_port); // network → host
  end;
  CloseSocket(S);
end;

{ Open and immediately close a TCP connection to 127.0.0.1:APort.
  Used to unblock accept() after StopAccepting(False) sets the flag. }
procedure MakeDummyConnect(APort: Word);
var
  S    : LongInt;
  Addr : TInetSockAddr;
begin
  S := fpSocket(AF_INET, SOCK_STREAM, 0);
  if S < 0 then Exit;
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family          := AF_INET;
  Addr.sin_port            := Swap16(APort); // host → network
  Addr.sin_addr.s_bytes[1] := 127;
  Addr.sin_addr.s_bytes[2] := 0;
  Addr.sin_addr.s_bytes[3] := 0;
  Addr.sin_addr.s_bytes[4] := 1;
  fpConnect(S, @Addr, SizeOf(Addr));
  CloseSocket(S);
end;

{ ── Token generation ─────────────────────────────────────────────────────── }

function GenerateToken: string;
var
  G1, G2 : TGUID;
  S      : string;
  I      : Integer;
begin
  CreateGUID(G1);
  CreateGUID(G2);
  S := GUIDToString(G1) + GUIDToString(G2);
  Result := '';
  for I := 1 to Length(S) do
    if S[I] in ['0'..'9', 'A'..'F', 'a'..'f'] then
      Result := Result + S[I];
end;

{ ── Ping check ───────────────────────────────────────────────────────────── }

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
    Http.AddHeader('Content-Type',  'application/json');
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

{ ── TMcpServerThread ─────────────────────────────────────────────────────── }

constructor TMcpServerThread.Create(const AToken: string; APort: Word);
begin
  inherited Create(True); // start suspended
  FToken := AToken;
  FPort  := APort;
  FServer := TMcpHttpServer.Create(nil);
  FServer.Address   := '127.0.0.1';
  FServer.Port      := APort;
  FServer.Threaded  := False;
  FServer.OnRequest := @HandleRequest;
  FServer.QueueSize := 5;
end;

destructor TMcpServerThread.Destroy;
begin
  FServer.Free;
  inherited Destroy;
end;

procedure TMcpServerThread.Execute;
begin
  try
    FServer.Active := True; // blocks until StopAccepting is called
  except
    on E: Exception do
      DebugLn('[MCP Server] Server thread error: ' + E.Message);
  end;
  DebugLn('[MCP Server] Server thread exiting.');
end;

procedure TMcpServerThread.StopServer;
begin
  if FServer.Active then
    FServer.Active := False; // calls StopAccepting(False)
  MakeDummyConnect(FPort);   // unblocks the blocking accept()
end;

{ ── HTTP request handler ─────────────────────────────────────────────────── }

procedure TMcpServerThread.HandleRequest(Sender: TObject;
  var ARequest  : TFPHTTPConnectionRequest;
  var AResponse : TFPHTTPConnectionResponse);
var
  ResponseBody : string;
begin
  // Only POST /mcp is accepted
  if ARequest.Method <> 'POST' then
  begin
    AResponse.Code := 405;
    AResponse.SetCustomHeader('Allow', 'POST');
    Exit;
  end;
  if ARequest.PathInfo <> '/mcp' then
  begin
    AResponse.Code := 404;
    Exit;
  end;
  // DNS-rebinding guard: reject browser-origin requests
  if ARequest.GetCustomHeader('Origin') <> '' then
  begin
    AResponse.Code := 403;
    Exit;
  end;
  // Bearer-token auth
  if ARequest.Authorization <> 'Bearer ' + FToken then
  begin
    AResponse.Code := 401;
    AResponse.SetCustomHeader('WWW-Authenticate', 'Bearer realm="lazarus-mcp"');
    Exit;
  end;

  try
    ResponseBody := HandleRPC(ARequest.Content);
  except
    on E: Exception do
    begin
      AResponse.Code        := 200;
      AResponse.ContentType := 'application/json';
      AResponse.Content     :=
        '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":' +
        '"Internal error: ' + StringReplace(E.Message, '"', '\"', [rfReplaceAll]) + '"}}';
      Exit;
    end;
  end;

  if ResponseBody = '' then
    // MCP notification (no id field) — respond 202, no body
    AResponse.Code := 202
  else
  begin
    AResponse.Code        := 200;
    AResponse.ContentType := 'application/json';
    AResponse.Content     := ResponseBody;
  end;
end;

{ ── JSON-RPC dispatch ─────────────────────────────────────────────────────── }

function TMcpServerThread.HandleRPC(const Body: string): string;
var
  Data   : TJSONData;
  Req    : TJSONObject;
  Method : string;
  ID     : TJSONData;
  Params : TJSONObject;
begin
  Result := '';
  try
    Data := GetJSON(Body);
  except
    on E: Exception do
    begin
      Result := '{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}';
      Exit;
    end;
  end;

  try
    if not (Data is TJSONObject) then
    begin
      Result := '{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Not an object"}}';
      Exit;
    end;
    Req    := TJSONObject(Data);
    ID     := Req.Find('id');
    Params := TJSONObject(Req.Find('params'));

    // Notification: no id field; respond 202 (caller uses empty body)
    if not Assigned(ID) then
    begin
      Result := ''; // 202 Accepted
      Exit;
    end;

    Method := Req.Get('method', '');
    if      Method = 'initialize'  then Result := HandleInitialize(ID, Params)
    else if Method = 'ping'        then Result := HandlePing(ID)
    else if Method = 'tools/list'  then Result := HandleToolsList(ID)
    else if Method = 'tools/call'  then Result := HandleToolsCall(ID, Params)
    else
      Result := RPCError(ID, -32601, 'Method not found');
  finally
    Data.Free;
  end;
end;

{ ── JSON-RPC helpers ─────────────────────────────────────────────────────── }

function TMcpServerThread.RPCResult(ID: TJSONData;
  ResultObj: TJSONObject): string;
var
  Resp : TJSONObject;
begin
  Resp := TJSONObject.Create;
  try
    Resp.Add('jsonrpc', '2.0');
    Resp.Add('id',     ID.Clone);
    Resp.Add('result', ResultObj); // takes ownership
    Result := Resp.FormatJSON;
  finally
    Resp.Free;
  end;
end;

function TMcpServerThread.RPCError(ID: TJSONData; ErrCode: Integer;
  const Msg: string): string;
var
  Resp : TJSONObject;
  Err  : TJSONObject;
begin
  Resp := TJSONObject.Create;
  Err  := TJSONObject.Create;
  try
    Err.Add('code',    ErrCode);
    Err.Add('message', Msg);
    Resp.Add('jsonrpc', '2.0');
    if Assigned(ID) then
      Resp.Add('id', ID.Clone)
    else
      Resp.Add('id', TJSONNull.Create);
    Resp.Add('error', Err); // takes ownership of Err
    Result := Resp.FormatJSON;
  finally
    Resp.Free;
  end;
end;

{ ── MCP method handlers ──────────────────────────────────────────────────── }

function TMcpServerThread.HandleInitialize(ID: TJSONData;
  Params: TJSONObject): string;
var
  Res      : TJSONObject;
  Caps     : TJSONObject;
  ToolsCap : TJSONObject;
  SrvInfo  : TJSONObject;
  ProtoVer : string;
begin
  // Echo back client's protocolVersion; fall back to our minimum
  ProtoVer := '2024-11-05';
  if Assigned(Params) and Assigned(Params.Find('protocolVersion')) then
    ProtoVer := Params.Strings['protocolVersion'];

  ToolsCap := TJSONObject.Create;  // empty tools capability object
  Caps := TJSONObject.Create;
  Caps.Add('tools', ToolsCap);

  SrvInfo := TJSONObject.Create;
  SrvInfo.Add('name',    'lazarus-ide');
  SrvInfo.Add('version', '0.1.0');

  Res := TJSONObject.Create;
  Res.Add('protocolVersion', ProtoVer);
  Res.Add('capabilities',   Caps);
  Res.Add('serverInfo',     SrvInfo);

  Result := RPCResult(ID, Res); // RPCResult owns Res
end;

function TMcpServerThread.HandlePing(ID: TJSONData): string;
var
  Res : TJSONObject;
begin
  Res := TJSONObject.Create; // empty object {}
  Result := RPCResult(ID, Res);
end;

function TMcpServerThread.HandleToolsList(ID: TJSONData): string;

  function MakeTool(const AName, ADesc: string;
    Props: TJSONObject; Req: TJSONArray): TJSONObject;
  var
    Schema : TJSONObject;
  begin
    Schema := TJSONObject.Create;
    Schema.Add('type',       'object');
    Schema.Add('properties', Props);  // ownership
    Schema.Add('required',   Req);    // ownership
    Result := TJSONObject.Create;
    Result.Add('name',        AName);
    Result.Add('description', ADesc);
    Result.Add('inputSchema', Schema);
  end;

var
  Tools    : TJSONArray;
  Res      : TJSONObject;
  SPath    : TJSONObject;
  PathDef  : TJSONObject;
  SPReq    : TJSONArray;
begin
  Tools := TJSONArray.Create;

  // get_active_file — no args
  Tools.Add(MakeTool('get_active_file',
    'Return the active editor file name and its current buffer content.',
    TJSONObject.Create, TJSONArray.Create));

  // get_project_files — no args
  Tools.Add(MakeTool('get_project_files',
    'Return the list of source files in the active project.',
    TJSONObject.Create, TJSONArray.Create));

  // get_file_content — requires path
  PathDef := TJSONObject.Create;
  PathDef.Add('type',        'string');
  PathDef.Add('description', 'Absolute path to the file');
  SPath := TJSONObject.Create;
  SPath.Add('path', PathDef); // PathDef ownership → SPath
  SPReq := TJSONArray.Create;
  SPReq.Add('path');
  Tools.Add(MakeTool('get_file_content',
    'Read the content of any file by its absolute path.',
    SPath, SPReq));

  // get_compiler_errors — no args
  Tools.Add(MakeTool('get_compiler_errors',
    'Return the current build compiler errors and warnings.',
    TJSONObject.Create, TJSONArray.Create));

  Res := TJSONObject.Create;
  Res.Add('tools', Tools);
  Result := RPCResult(ID, Res);
end;

function TMcpServerThread.HandleToolsCall(ID: TJSONData;
  Params: TJSONObject): string;
var
  ToolName : string;
  Args     : TJSONObject;
  Content  : TJSONArray;
  TextNode : TJSONObject;
  Res      : TJSONObject;
  Err      : Boolean;
  Text     : string;
  Lines    : TStringList;
begin
  if not Assigned(Params) then
    Exit(RPCError(ID, -32602, 'Missing params'));

  ToolName := Params.Get('name', '');
  Args     := TJSONObject(Params.Find('arguments'));

  Err  := False;
  Text := '';

  if ToolName = 'get_file_content' then
  begin
    // Disk read — safe to do in server thread
    if not Assigned(Args) or (Args.Get('path', '') = '') then
    begin
      Text := 'Error: path argument required';
      Err  := True;
    end else
    begin
      Lines := TStringList.Create;
      try
        try
          Lines.LoadFromFile(Args.Strings['path']);
          Text := Lines.Text;
        except
          on E: Exception do
          begin
            Text := 'Error reading file: ' + E.Message;
            Err  := True;
          end;
        end;
      finally
        Lines.Free;
      end;
    end;
  end
  else if (ToolName = 'get_active_file') or
          (ToolName = 'get_project_files') or
          (ToolName = 'get_compiler_errors') then
  begin
    // IDE APIs — must run on main thread
    FSyncToolName := ToolName;
    FSyncParams   := Args;
    FSyncResult   := '';
    FSyncError    := False;
    TThread.Synchronize(Self, @SyncCallTool);
    Text := FSyncResult;
    Err  := FSyncError;
  end
  else
  begin
    Text := 'Unknown tool: ' + ToolName;
    Err  := True;
  end;

  TextNode := TJSONObject.Create;
  TextNode.Add('type', 'text');
  TextNode.Add('text', Text);
  Content := TJSONArray.Create;
  Content.Add(TextNode);

  Res := TJSONObject.Create;
  Res.Add('content', Content);
  Res.Add('isError', Err);
  Result := RPCResult(ID, Res);
end;

{ ── Main-thread tool dispatcher ──────────────────────────────────────────── }

procedure TMcpServerThread.SyncCallTool;
var
  Ed      : TSourceEditorInterface;
  Obj     : TJSONObject;
  Files   : TJSONArray;
  Proj    : TLazProject;
  Errors  : TJSONArray;
  PasName : string;
  I       : Integer;
begin
  FSyncError := False;
  try
    if FSyncToolName = 'get_active_file' then
    begin
      Ed := SourceEditorManagerIntf.ActiveEditor;
      if not Assigned(Ed) then
      begin
        FSyncError  := True;
        FSyncResult := 'No active editor';
        Exit;
      end;
      { Form designer is active: return both .lfm and .pas so Claude can pick }
      if CompareFileExt(Ed.FileName, '.lfm', False) = 0 then
      begin
        PasName := ChangeFileExt(Ed.FileName, '.pas');
        Obj := TJSONObject.Create;
        try
          Obj.Add('note', 'The active editor is a form file. ' +
                          'Both the form definition and its Pascal unit are provided.');
          Obj.Add('form_filename', Ed.FileName);
          Obj.Add('form_content',  Ed.Lines.Text);
          for I := 0 to SourceEditorManagerIntf.SourceEditorCount - 1 do
            if CompareFilenames(SourceEditorManagerIntf.SourceEditors[I].FileName,
                                PasName) = 0 then
            begin
              Obj.Add('unit_filename', PasName);
              Obj.Add('unit_content',
                      SourceEditorManagerIntf.SourceEditors[I].Lines.Text);
              Break;
            end;
          FSyncResult := Obj.AsJSON;
        finally
          Obj.Free;
        end;
        Exit;
      end;
      Obj := TJSONObject.Create;
      try
        Obj.Add('filename',    Ed.FileName);
        Obj.Add('content',     Ed.Lines.Text);
        Obj.Add('cursor_line', Ed.CursorTextXY.Y);
        Obj.Add('cursor_col',  Ed.CursorTextXY.X);
        FSyncResult := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    end

    else if FSyncToolName = 'get_project_files' then
    begin
      Files := TJSONArray.Create;
      try
        if Assigned(LazarusIDE) then
        begin
          Proj := LazarusIDE.ActiveProject;
          if Assigned(Proj) then
            for I := 0 to Proj.FileCount - 1 do
              if Proj.Files[I].IsPartOfProject then
                Files.Add(Proj.Files[I].Filename);
        end;
        FSyncResult := Files.AsJSON;
      finally
        Files.Free;
      end;
    end

    else if FSyncToolName = 'get_compiler_errors' then
    begin
      if Assigned(McpHookManager) then
        Errors := McpHookManager.CurrentCompilerErrors
      else
        Errors := nil;
      if Assigned(Errors) then
        FSyncResult := Errors.AsJSON
      else
        FSyncResult := '[]';
    end;

  except
    on E: Exception do
    begin
      FSyncError  := True;
      FSyncResult := E.Message;
    end;
  end;
end;

{ ── Module lifecycle ─────────────────────────────────────────────────────── }

function IsServerRunning: Boolean;
begin
  Result := Assigned(McpServerThread) and not McpServerThread.Finished;
end;

function GetServerPort: Word;
begin
  if Assigned(McpServerThread) then
    Result := McpServerThread.Port
  else
    Result := 0;
end;

function GetServerToken: string;
begin
  if Assigned(McpServerThread) then
    Result := McpServerThread.Token
  else
    Result := '';
end;

procedure InitializeMcpServer;
var
  Port  : Word;
  Token : string;
begin
  if IsServerRunning then Exit;

  Port := FindFreePort;
  if Port = 0 then
  begin
    DebugLn('[MCP Server] Could not allocate a free port.');
    Exit;
  end;

  Token           := GenerateToken;
  McpServerThread := TMcpServerThread.Create(Token, Port);
  McpServerThread.Start;

  // Brief pause, then verify the server is reachable before declaring success
  Sleep(300);
  if not PingServer(Port, Token) then
  begin
    DebugLn('[MCP Server] Ping check failed; tearing down.');
    McpServerThread.StopServer;
    while not McpServerThread.Finished do
      CheckSynchronize(10);
    FreeAndNil(McpServerThread);
    Exit;
  end;

  DebugLn(Format('[MCP Server] Listening on 127.0.0.1:%d.', [Port]));
end;

procedure FinalizeMcpServer;
begin
  if not Assigned(McpServerThread) then Exit;
  McpServerThread.StopServer;
  while not McpServerThread.Finished do
    CheckSynchronize(10);
  FreeAndNil(McpServerThread);
  DebugLn('[MCP Server] Finalized.');
end;

function WriteMcpConfig: string;
var
  Config  : TJSONObject;
  Servers : TJSONObject;
  Srv     : TJSONObject;
  Headers : TJSONObject;
  SL      : TStringList;
  Path    : string;
begin
  Result := '';
  if not IsServerRunning then Exit;

  Path := IncludeTrailingPathDelimiter(GetTempDir) +
          Format('lazarus-mcp-%d.json', [GetServerPort]);

  Headers := TJSONObject.Create;
  Headers.Add('Authorization', 'Bearer ' + GetServerToken);

  Srv := TJSONObject.Create;
  Srv.Add('type',    'http');
  Srv.Add('url',     Format('http://127.0.0.1:%d/mcp', [GetServerPort]));
  Srv.Add('headers', Headers);

  Servers := TJSONObject.Create;
  Servers.Add('lazarus-ide', Srv);

  Config := TJSONObject.Create;
  Config.Add('mcpServers', Servers);

  SL := TStringList.Create;
  try
    SL.Text := Config.FormatJSON;
    try
      SL.SaveToFile(Path);
      Result := Path;
      DebugLn('[MCP Server] Config written: ' + Path);
    except
      on E: Exception do
        DebugLn('[MCP Server] Could not write config: ' + E.Message);
    end;
  finally
    SL.Free;
    Config.Free;
  end;
end;

{ ── IDE close hook ───────────────────────────────────────────────────────── }

type
  TMcpIDEHook = class
    procedure OnIDEClose(Sender: TObject);
  end;

procedure TMcpIDEHook.OnIDEClose(Sender: TObject);
begin
  FinalizeMcpServer;
end;

var
  IDEHook: TMcpIDEHook = nil;

procedure RegisterIDECloseHook;
begin
  if not Assigned(IDEHook) then
    IDEHook := TMcpIDEHook.Create;
  if Assigned(LazarusIDE) then
    LazarusIDE.AddHandlerOnIDEClose(@IDEHook.OnIDEClose);
end;

initialization
finalization
  FinalizeMcpServer; // safety net — normally called by the IDE-close hook
  FreeAndNil(IDEHook);
end.
