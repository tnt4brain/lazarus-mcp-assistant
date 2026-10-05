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
    FSyncResult          : string;      // output set by main thread
    FSyncError           : Boolean;     // True when SyncCallTool encountered an error
    FSyncConnectionClose : Boolean;     // True → add Connection: close to response
    FSyncFileList : string;      // JSON file list passed into two-phase tools
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
  LazFileUtils, Sockets, fphttpclient,
  StrUtils,
  McpUtils, McpToolContext, McpToolHelpers;




{ ── Low-level socket helpers ────────────────────────────────────────────── }

{ Swap a 16-bit integer between host and network byte order (identical in both
  directions on little-endian x86; avoids using the deprecated ShortHostToNet). }
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
  // rebuild_ide causes the IDE to exit — close the TCP connection cleanly so
  // the port is fully released before the new IDE instance tries to bind it.
  if FSyncConnectionClose then
    AResponse.SetCustomHeader('Connection', 'close');
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
  SrvInfo.Add('version', '0.6.0');

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
var
  Tools : TJSONArray;
  Res   : TJSONObject;
begin
  Tools := TJSONArray.Create;
  McpRegisterSchemas(Tools);
  Res := TJSONObject.Create;
  Res.Add('tools', Tools);
  Result := RPCResult(ID, Res);
end;

function TMcpServerThread.HandleToolsCall(ID: TJSONData;
  Params: TJSONObject): string;
var
  ToolName    : string;
  Args        : TJSONObject;
  Content     : TJSONArray;
  TextNode    : TJSONObject;
  Res         : TJSONObject;
  Err         : Boolean;
  Text        : string;
  ResolvedLpi : string;
  DirData     : TJSONData;
  ProjDir     : string;
begin
  if not Assigned(Params) then
    Exit(RPCError(ID, -32602, 'Missing params'));

  ToolName := Params.Get('name', '');
  Args     := TJSONObject(Params.Find('arguments'));

  Err  := False;
  Text := '';

  if ToolName = 'get_unit_interface' then
  begin
    if not Assigned(Args) or (Args.Get('file', '') = '') then
    begin
      Text := 'Error: file argument required';
      Err  := True;
    end else
      Text := McpGetUnitInterface(Args.Strings['file'], Err);
  end
  else if ToolName = 'compile_plugin' then
  begin
    if not Assigned(Args) or (Args.Get('lpk_path', '') = '') then
    begin
      Text := 'Error: lpk_path required';
      Err  := True;
    end else
      Text := McpRunLazbuild(Args.Strings['lpk_path'], Err);
  end
  else if ToolName = 'run_tests' then
  begin
    ResolvedLpi := IfThen(Assigned(Args), Args.Get('test_project', ''), '');
    if ResolvedLpi = '' then
    begin
      // Resolve default .lpi path on the main thread
      FSyncToolName := 'get_project_directory';
      FSyncParams   := nil;
      FSyncResult   := '';
      FSyncError    := False;
      TThread.Synchronize(Self, @SyncCallTool);
      if FSyncError or (FSyncResult = '') then
      begin
        Text := 'Could not determine project directory for default test_project path';
        Err  := True;
      end else
      begin
        DirData := GetJSON(FSyncResult);
        try
          if DirData is TJSONObject then
            ProjDir := TJSONObject(DirData).Get('directory', '')
          else
            ProjDir := '';
        finally
          DirData.Free;
        end;
        if ProjDir <> '' then
          ResolvedLpi := IncludeTrailingPathDelimiter(ProjDir) +
                         'tests' + PathDelim + 'mcpserver_tests.lpi';
      end;
    end;
    if not Err then
      Text := McpRunTests(ResolvedLpi,
        IfThen(Assigned(Args), Args.Get('junit_out', ''), ''), Err);
  end
  else if ToolName = 'search_in_project' then
  begin
    FSyncToolName := 'get_project_files';
    FSyncParams   := nil;
    FSyncResult   := '';
    FSyncError    := False;
    TThread.Synchronize(Self, @SyncCallTool);
    if FSyncError then
    begin
      Text := FSyncResult;
      Err  := True;
    end else
    begin
      if Assigned(Args) then
        Text := McpDoSearchInProject(FSyncResult, Args.Get('query', ''))
      else
        Text := McpDoSearchInProject(FSyncResult, '');
      Err  := False;
    end;
  end
  else if (ToolName = 'find_all_references') or (ToolName = 'rename_identifier') then
  begin
    // Step 1: get project file list on main thread
    FSyncToolName := 'get_project_files';
    FSyncParams   := nil;
    FSyncResult   := '';
    FSyncError    := False;
    TThread.Synchronize(Self, @SyncCallTool);
    if FSyncError then
    begin
      Text := FSyncResult;
      Err  := True;
    end else
    begin
      // Step 2: run Codetools on main thread; pass file list in FSyncFileList
      FSyncFileList := FSyncResult;
      FSyncToolName := ToolName;
      FSyncParams   := Args;
      FSyncResult   := '';
      FSyncError    := False;
      TThread.Synchronize(Self, @SyncCallTool);
      Text := FSyncResult;
      Err  := FSyncError;
    end;
  end
  else
  begin
    // Default: IDE API — must run on main thread.
    // Unknown tools are caught inside SyncCallTool.
    FSyncToolName        := ToolName;
    FSyncParams          := Args;
    FSyncResult          := '';
    FSyncError           := False;
    FSyncConnectionClose := False;
    TThread.Synchronize(Self, @SyncCallTool);
    Text := FSyncResult;
    Err  := FSyncError;
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


procedure TMcpServerThread.SyncCallTool;
var
  Ctx     : TMcpToolCall;
  Handled : Boolean;
begin
  Ctx.Params          := FSyncParams;
  Ctx.FileList        := FSyncFileList;
  Ctx.Result          := '';
  Ctx.Error           := False;
  Ctx.ConnectionClose := False;
  Ctx.StopServer      := @Self.StopServer;
  try
    McpDispatch(FSyncToolName, Ctx, Handled);
    if not Handled then
    begin
      Ctx.Error  := True;
      Ctx.Result := 'Unknown tool: ' + FSyncToolName;
    end;
  except
    on E: Exception do
    begin
      Ctx.Error  := True;
      Ctx.Result := E.Message;
    end;
  end;
  FSyncResult          := Ctx.Result;
  FSyncError           := Ctx.Error;
  FSyncConnectionClose := Ctx.ConnectionClose;
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

  // Reuse persisted token so Claude Code sessions survive IDE restarts
  Token := McpSettings.ServerToken;
  if Token = '' then
  begin
    Token := GenerateToken;
    McpSettings.ServerToken := Token;
    McpSettings.SaveSettings;
  end;

  // Try to reuse the persisted port so the MCP URL stays identical
  Port := McpSettings.ServerPort;
  if (Port = 0) or not IsPortFree(Port) then
    Port := FindFreePort;
  if Port = 0 then
  begin
    DebugLn('[MCP Server] Could not allocate a free port.');
    Exit;
  end;

  McpServerThread := TMcpServerThread.Create(Token, Port);
  McpServerThread.Start;

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

  // Persist port so next restart reuses the same URL
  McpSettings.ServerPort := Port;
  McpSettings.SaveSettings;

  DebugLn(Format('[MCP Server] Listening on 127.0.0.1:%d.', [Port]));

  if McpSettings.LastConfigPath <> '' then
    WriteMcpConfig;
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

  // Use the same path Claude Code was launched with so it can re-read the URL
  // after a rebuild without drifting to a new filename.
  if McpSettings.LastConfigPath <> '' then
    Path := McpSettings.LastConfigPath
  else
    Path := IncludeTrailingPathDelimiter(GetTempDir) + 'lazarus-mcp.json';

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
      McpSettings.LastConfigPath := Path;
      McpSettings.SaveSettings;
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
