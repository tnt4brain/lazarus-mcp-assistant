{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpIdeServer;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fphttpserver, httpdefs, fpjson, jsonparser,
  Process,
  LazIDEIntf, LazLogger, PackageIntf,
  McpIdeListeners, McpIdeState;

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
    procedure HandleRequest(Sender: TObject;
                            var ARequest  : TFPHTTPConnectionRequest;
                            var AResponse : TFPHTTPConnectionResponse);
    { AClientId: the caller's identity (McpDebugLease).  ANewSession is set
      by initialize to the session id to return in Mcp-Session-Id. }
    function  HandleRPC(const Body, AClientId: string; out ANewSession: string): string;
    function  HandleInitialize(ID: TJSONData; Params: TJSONObject;
                               const AClientId: string; out ANewSession: string): string;
    function  HandlePing(ID: TJSONData): string;
    function  HandleToolsList(ID: TJSONData): string;
    function  HandleToolsCall(ID: TJSONData; Params: TJSONObject;
                              const AClientId: string): string;
    { Run a tool on the IDE main thread; safe to call from any request thread. }
    function  CallOnMain(const AToolName: string; AParams: TJSONObject;
                         const AClientId: string; out AErr: Boolean): string;
    function  HandleResourcesList(ID: TJSONData): string;
    function  HandleResourcesRead(ID: TJSONData; Params: TJSONObject): string;
    function  HandleResourcesTemplatesList(ID: TJSONData): string;
    function  HandleCompletionComplete(ID: TJSONData; Params: TJSONObject): string;
    function  HandlePromptsList(ID: TJSONData): string;
    function  HandlePromptsGet(ID: TJSONData; Params: TJSONObject): string;
    function  RPCResult(ID: TJSONData; ResultObj: TJSONObject): string;
    function  RPCError(ID: TJSONData; ErrCode: Integer;
                       const Msg: string): string;
    procedure HandleAllowConnect(Sender: TObject; ASocket: LongInt;
                                 var Allow: Boolean);

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
  {$IFDEF UNIX} BaseUnix, {$ENDIF}
  LazFileUtils, Sockets, ssockets, fphttpclient,

  StrUtils,
  IDEExternToolIntf, IDEMsgIntf,
  McpUtils, McpToolContext, McpToolHelpers, McpDebugGuard, McpDebugLease;



{ ── Low-level socket helpers ────────────────────────────────────────────── }

{ Swap a 16-bit integer between host and network byte order (identical in both
  directions on little-endian x86; avoids using the deprecated ShortHostToNet). }
{ Open and immediately close a TCP connection to 127.0.0.1:APort.
  Used to unblock accept() after StopAccepting(False) sets the flag. }
const
  McpServerVersion = '0.8';

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

{$IFDEF MSWINDOWS}
function SetHandleInformation(hObject: PtrUInt; dwMask, dwFlags: DWord): LongBool;
  stdcall; external 'kernel32' name 'SetHandleInformation';
{$ENDIF}

{ Stop child processes (the debuggee, fpc, lazbuild …) from inheriting a socket.
  An inherited copy keeps the TCP connection open after the server closes its
  own handle, so the client never sees FIN, reuses the connection for its next
  request, and waits forever for a reply nobody will send. }
procedure MakeSocketNonInheritable(ASocket: LongInt);
const
  HANDLE_FLAG_INHERIT = 1;
begin
  if ASocket < 0 then Exit;
  {$IFDEF MSWINDOWS}
  SetHandleInformation(PtrUInt(ASocket), HANDLE_FLAG_INHERIT, 0);
  {$ENDIF}
  {$IFDEF UNIX}
  FpFcntl(ASocket, F_SETFD, FD_CLOEXEC);
  {$ENDIF}
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
  FServer.Threaded  := True;   { each connection gets its own thread — required for blocking tools }
  FServer.OnRequest := @HandleRequest;
  FServer.OnAllowConnect := @HandleAllowConnect;
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

{ Value of cookie AName in a "a=1; b=2" Cookie header (fphttpserver does not
  fill CookieFields). }
function CookieValue(const AHeader, AName: string): string;
var
  Parts : TStringArray;
  I     : Integer;
  S     : string;
begin
  Result := '';
  Parts  := AHeader.Split([';']);
  for I := 0 to High(Parts) do
  begin
    S := Trim(Parts[I]);
    if SameText(Copy(S, 1, Length(AName) + 1), AName + '=') then
      Exit(Copy(S, Length(AName) + 2, MaxInt));
  end;
end;

{ Runs on the server thread right after accept().  The listening socket is
  not reachable before the first connection, so it is fixed up here too. }
procedure TMcpServerThread.HandleAllowConnect(Sender: TObject;
  ASocket: LongInt; var Allow: Boolean);
begin
  if Sender is TSocketServer then
    MakeSocketNonInheritable(TSocketServer(Sender).Socket);
  MakeSocketNonInheritable(ASocket);
  Allow := True;
end;

procedure TMcpServerThread.HandleRequest(Sender: TObject;
  var ARequest  : TFPHTTPConnectionRequest;
  var AResponse : TFPHTTPConnectionResponse);
var
  ResponseBody : string;
  ClientId     : string;
  NewSession   : string;
begin
  { fphttpserver (FPC 3.2.2) serves exactly one request per connection and then
    closes the socket.  Say so, otherwise HTTP/1.1 clients keep the connection
    alive and send their next request into a socket nobody reads any more. }
  AResponse.SetCustomHeader('Connection', 'close');

  // POST /mcp, plus DELETE /mcp to end a session
  if (ARequest.Method <> 'POST') and (ARequest.Method <> 'DELETE') then
  begin
    AResponse.Code := 405;
    AResponse.SetCustomHeader('Allow', 'POST, DELETE');
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

  { Who is calling (ADR-012): the Mcp-Session-Id we handed out, else our
    cookie.  Without either the caller is 'anonymous'; offer it a cookie so
    cookie-aware clients (curl -b/-c) get an identity of their own. }
  ClientId := ARequest.GetCustomHeader('Mcp-Session-Id');
  if ClientId = '' then
    ClientId := CookieValue(ARequest.Cookie, 'mcp_session');

  if ARequest.Method = 'DELETE' then
  begin
    McpForgetSession(ClientId);
    AResponse.Code := 200;
    Exit;
  end;

  if ClientId = '' then
  begin
    ClientId := ANONYMOUS_CLIENT;
    AResponse.SetCustomHeader('Set-Cookie', 'mcp_session=' + McpNewSessionId +
      '; Path=/mcp; HttpOnly; SameSite=Strict');
  end;

  try
    ResponseBody := HandleRPC(ARequest.Content, ClientId, NewSession);
    if NewSession <> '' then
    begin
      AResponse.SetCustomHeader('Mcp-Session-Id', NewSession);
      AResponse.SetCustomHeader('Set-Cookie', 'mcp_session=' + NewSession +
        '; Path=/mcp; HttpOnly; SameSite=Strict');
    end;
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

function TMcpServerThread.HandleRPC(const Body, AClientId: string;
  out ANewSession: string): string;
var
  Data   : TJSONData;
  Req    : TJSONObject;
  Method : string;
  ID     : TJSONData;
  Params : TJSONObject;
begin
  Result := '';
  ANewSession := '';
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
    if      Method = 'initialize'       then Result := HandleInitialize(ID, Params, AClientId, ANewSession)
    else if Method = 'ping'             then Result := HandlePing(ID)
    else if Method = 'tools/list'       then Result := HandleToolsList(ID)
    else if Method = 'tools/call'       then
    begin
      InterLockedIncrement(GMcpToolCallsActive);  { lets IDE modals be auto-answered }
      try
        Result := HandleToolsCall(ID, Params, AClientId);
      finally
        InterLockedDecrement(GMcpToolCallsActive);
      end;
    end
    else if Method = 'resources/list'   then Result := HandleResourcesList(ID)
    else if Method = 'resources/read'          then Result := HandleResourcesRead(ID, Params)
    else if Method = 'resources/templates/list' then Result := HandleResourcesTemplatesList(ID)
    else if Method = 'completion/complete'      then Result := HandleCompletionComplete(ID, Params)
    else if Method = 'prompts/list'             then Result := HandlePromptsList(ID)
    else if Method = 'prompts/get'              then Result := HandlePromptsGet(ID, Params)
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

type
  { One main-thread call.  Every request thread uses its own instance, so
    concurrent requests never share input or output fields. }
  TMcpMainCall = class
    ToolName : string;
    Ctx      : TMcpToolCall;
    LogMsg   : string;
    procedure Run;   { main thread }
    procedure Log;   { main thread }
  end;

procedure TMcpMainCall.Run;
var
  Handled : Boolean;
begin
  try
    McpDispatch(ToolName, Ctx, Handled);
    if not Handled then
    begin
      Ctx.Error  := True;
      Ctx.Result := 'Unknown tool: ' + ToolName;
    end;
  except
    on E: Exception do
    begin
      Ctx.Error  := True;
      Ctx.Result := E.Message;
    end;
  end;
end;

procedure TMcpMainCall.Log;
begin
  if Assigned(IDEMessagesWindow) then
    IDEMessagesWindow.AddCustomMessage(mluProgress, LogMsg, '', 0, 0, 'MCP Server');
end;

function TMcpServerThread.CallOnMain(const AToolName: string;
  AParams: TJSONObject; const AClientId: string; out AErr: Boolean): string;
var
  Call : TMcpMainCall;
begin
  Call := TMcpMainCall.Create;
  try
    Call.ToolName            := AToolName;
    Call.Ctx.Params          := AParams;
    Call.Ctx.Result          := '';
    Call.Ctx.Error           := False;
    Call.Ctx.ClientId        := AClientId;
    Call.Ctx.StopServer      := @Self.StopServer;
    TThread.Synchronize(nil, @Call.Run);
    Result := Call.Ctx.Result;
    AErr   := Call.Ctx.Error;
  finally
    Call.Free;
  end;
end;

function TMcpServerThread.HandleInitialize(ID: TJSONData;
  Params: TJSONObject; const AClientId: string; out ANewSession: string): string;
var
  Res      : TJSONObject;
  Caps     : TJSONObject;
  ToolsCap : TJSONObject;
  SrvInfo  : TJSONObject;
  ClientInfo : TJSONObject;
  ProtoVer   : string;
  ClientName : string;
  Call       : TMcpMainCall;
begin
  // Echo back client's protocolVersion; fall back to our minimum
  ProtoVer := '2024-11-05';
  if Assigned(Params) and Assigned(Params.Find('protocolVersion')) then
    ProtoVer := Params.Strings['protocolVersion'];

  { A new MCP session: its id identifies this client from now on (ADR-012) }
  ANewSession := McpNewSessionId;
  ClientName  := '';
  if Assigned(Params) then
  begin
    ClientInfo := TJSONObject(Params.Find('clientInfo'));
    if Assigned(ClientInfo) then
    begin
      ClientName := ClientInfo.Get('name', '?') + ' ' + ClientInfo.Get('version', '');
      Call := TMcpMainCall.Create;
      try
        Call.LogMsg := Format('Client "%s" connected (protocol %s, session %s).',
          [Trim(ClientName), ProtoVer, Copy(ANewSession, 1, 8)]);
        TThread.Synchronize(nil, @Call.Log);
      finally
        Call.Free;
      end;
    end;
  end;
  McpRegisterSession(ANewSession, Trim(ClientName));

  ToolsCap := TJSONObject.Create;  // empty tools capability object
  Caps := TJSONObject.Create;
  Caps.Add('tools',     ToolsCap);
  Caps.Add('resources',   TJSONObject.Create);
  Caps.Add('completions', TJSONObject.Create);
  Caps.Add('prompts',     TJSONObject.Create);

  SrvInfo := TJSONObject.Create;
  SrvInfo.Add('name',    'lazarus-ide');
  SrvInfo.Add('version', McpServerVersion);

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

function TMcpServerThread.HandleResourcesList(ID: TJSONData): string;
var
  Resources : TJSONArray;
  Res       : TJSONObject;
begin
  Resources := TJSONArray.Create;
  McpListResources(Resources);
  Res := TJSONObject.Create;
  Res.Add('resources', Resources);
  Result := RPCResult(ID, Res);
end;

function TMcpServerThread.HandleResourcesRead(ID: TJSONData;
  Params: TJSONObject): string;
var
  Uri      : string;
  FilePath : string;
  SL       : TStringList;
  Content  : string;
  Contents : TJSONArray;
  Item     : TJSONObject;
  Res      : TJSONObject;
begin
  if not Assigned(Params) then
    Exit(RPCError(ID, -32602, 'Missing params'));
  Uri := Params.Get('uri', '');
  if Uri = '' then
    Exit(RPCError(ID, -32602, 'uri required'));
  if Copy(Uri, 1, 7) = 'file://' then
  begin
    FilePath := Copy(Uri, 8, MaxInt);
    if (FilePath <> '') and (FilePath[1] = '/') then
      FilePath := Copy(FilePath, 2, MaxInt);
    if not FileExists(FilePath) then
      Exit(RPCError(ID, -32002, 'File not found: ' + FilePath));
    SL := TStringList.Create;
    try
      SL.LoadFromFile(FilePath);
      Content := SL.Text;
    finally
      SL.Free;
    end;
  end
  else
  begin
    if not McpReadResource(Uri, Content) then
      Exit(RPCError(ID, -32002, 'Resource not found: ' + Uri));
  end;
  Item := TJSONObject.Create;
  Item.Add('uri',      Uri);
  Item.Add('mimeType', 'text/plain');
  Item.Add('text',     Content);
  Contents := TJSONArray.Create;
  Contents.Add(Item);
  Res := TJSONObject.Create;
  Res.Add('contents', Contents);
  Result := RPCResult(ID, Res);
end;

function TMcpServerThread.HandleResourcesTemplatesList(ID: TJSONData): string;
var
  Tmpl      : TJSONObject;
  Templates : TJSONArray;
  Res       : TJSONObject;
begin
  Tmpl := TJSONObject.Create;
  Tmpl.Add('uriTemplate', 'file://{+path}');
  Tmpl.Add('name',        'File');
  Tmpl.Add('description', 'Read any file by absolute path. ' +
    'Windows example: file://C:/path/to/unit.pas');
  Tmpl.Add('mimeType',    'text/plain');
  Templates := TJSONArray.Create;
  Templates.Add(Tmpl);
  Res := TJSONObject.Create;
  Res.Add('resourceTemplates', Templates);
  Result := RPCResult(ID, Res);
end;

function TMcpServerThread.HandleCompletionComplete(ID: TJSONData;
  Params: TJSONObject): string;
var
  Ref      : TJSONObject;
  Argument : TJSONObject;
  RefType  : string;
  ArgName  : string;
  ArgValue : string;
  Values   : TJSONArray;
  Comp     : TJSONObject;
  Res      : TJSONObject;
  FilesData: TJSONData;
  FileArr  : TJSONArray;
  FileItem : TJSONData;
  I        : Integer;
  FilePath : string;
  LowerVal : string;
  Text     : string;
  Err      : Boolean;
begin
  if not Assigned(Params) then
    Exit(RPCError(ID, -32602, 'Missing params'));
  Ref      := TJSONObject(Params.Find('ref'));
  Argument := TJSONObject(Params.Find('argument'));
  if not Assigned(Ref) or not Assigned(Argument) then
    Exit(RPCError(ID, -32602, 'ref and argument required'));
  ArgName  := Argument.Get('name', '');
  ArgValue := Argument.Get('value', '');
  RefType  := Ref.Get('type', '');

  Values := TJSONArray.Create;

  if (RefType = 'ref/tool') and
     ((ArgName = 'file') or (ArgName = 'lpk_path') or
      (ArgName = 'lpi_path') or (ArgName = 'path')) then
  begin
    Text := CallOnMain('project_list_files', nil, '', Err);
    if not Err and (Text <> '') then
    begin
      FilesData := GetJSON(Text);
      try
        FileArr := nil;
        if FilesData is TJSONObject then
          FileArr := TJSONArray(TJSONObject(FilesData).Find('files'));
        if Assigned(FileArr) then
        begin
          LowerVal := LowerCase(ArgValue);
          for I := 0 to FileArr.Count - 1 do
          begin
            FileItem := FileArr.Items[I];
            if FileItem is TJSONObject then
              FilePath := TJSONObject(FileItem).Get('file', '')
            else
              FilePath := FileItem.AsString;
            if FilePath = '' then Continue;
            if (ArgValue = '') or (Pos(LowerVal, LowerCase(FilePath)) > 0) then
              Values.Add(FilePath);
            if Values.Count >= 25 then Break;
          end;
        end;
      finally
        FilesData.Free;
      end;
    end;
  end;

  Comp := TJSONObject.Create;
  Comp.Add('values',  Values);
  Comp.Add('hasMore', Values.Count >= 25);
  Res := TJSONObject.Create;
  Res.Add('completion', Comp);
  Result := RPCResult(ID, Res);
end;

function TMcpServerThread.HandlePromptsList(ID: TJSONData): string;
var
  Prompts : TJSONArray;
  P       : TJSONObject;
  Res     : TJSONObject;
begin
  Prompts := TJSONArray.Create;

  P := TJSONObject.Create;
  P.Add('name',        'explain_compiler_errors');
  P.Add('description', 'Fetch current compiler output and ask Claude to explain errors and suggest fixes');
  Prompts.Add(P);

  P := TJSONObject.Create;
  P.Add('name',        'review_active_file');
  P.Add('description', 'Review the currently active editor file for code quality and improvements');
  Prompts.Add(P);

  Res := TJSONObject.Create;
  Res.Add('prompts', Prompts);
  Result := RPCResult(ID, Res);
end;

function TMcpServerThread.HandlePromptsGet(ID: TJSONData;
  Params: TJSONObject): string;
var
  Name     : string;
  Messages : TJSONArray;
  Msg      : TJSONObject;
  Content  : TJSONObject;
  Text     : string;
  FileData : TJSONData;
  FilePath : string;
  Res      : TJSONObject;
  Out      : string;
  Err      : Boolean;
begin
  if not Assigned(Params) then
    Exit(RPCError(ID, -32602, 'Missing params'));
  Name := Params.Get('name', '');

  if Name = 'explain_compiler_errors' then
  begin
    Out := CallOnMain('project_get_compiler_errors', nil, '', Err);
    if Err or (Out = '') then
      Text := 'No compiler output is available. Please build the project first ' +
              '(Build → Build Project), then invoke this prompt again.'
    else
      Text := 'The Lazarus IDE compiler produced the following output:' + LineEnding + LineEnding +
              Out + LineEnding + LineEnding +
              'Please explain each error or warning, identify the root cause, ' +
              'and suggest a specific code fix for each one.';
  end
  else if Name = 'review_active_file' then
  begin
    Out := CallOnMain('editor_get_active', nil, '', Err);
    FilePath := '';
    if not Err and (Out <> '') then
    begin
      FileData := GetJSON(Out);
      try
        if FileData is TJSONObject then
          FilePath := TJSONObject(FileData).Get('file', '');
      finally
        FileData.Free;
      end;
    end;
    if FilePath = '' then
      Text := 'No file is currently active in the editor. Please open a file first.'
    else
      Text := 'Please review the file "' + FilePath + '" for code quality, potential bugs, ' +
              'adherence to Pascal/FPC best practices, and improvement opportunities. ' +
              'Read its content via: file://' + FilePath;
  end
  else
    Exit(RPCError(ID, -32602, 'Unknown prompt: ' + Name));

  Content := TJSONObject.Create;
  Content.Add('type', 'text');
  Content.Add('text', Text);
  Msg := TJSONObject.Create;
  Msg.Add('role',    'user');
  Msg.Add('content', Content);
  Messages := TJSONArray.Create;
  Messages.Add(Msg);

  Res := TJSONObject.Create;
  Res.Add('messages', Messages);
  Result := RPCResult(ID, Res);
end;

function TMcpServerThread.HandleToolsCall(ID: TJSONData;
  Params: TJSONObject; const AClientId: string): string;
var
  GateMsg     : string;
  ToolName    : string;
  Args        : TJSONObject;
  Content     : TJSONArray;
  TextNode    : TJSONObject;
  Res         : TJSONObject;
  Err         : Boolean;
  Text        : string;
  ResolvedLpi : string;
  DirData     : TJSONData;
  PkgArgs     : TJSONObject;
  ProjDir     : string;
  BCtx        : TMcpToolCall;
  BHandled    : Boolean;
begin
  if not Assigned(Params) then
    Exit(RPCError(ID, -32602, 'Missing params'));

  ToolName := Params.Get('name', '');
  Args     := TJSONObject(Params.Find('arguments'));

  Err  := False;
  Text := '';

  { debug session lease and debugger lock (ADR-012) }
  if not McpGateEnter(ToolName, AClientId, Args, GateMsg) then
  begin
    Text := GateMsg;
    Err  := True;
  end
  else
  try
  if ToolName = 'package_compile' then
  begin
    if not Assigned(Args) or (Args.Get('lpk_path', '') = '') then
    begin
      Text := 'Error: lpk_path required';
      Err  := True;
    end else
      Text := McpRunLazbuild(Args.Strings['lpk_path'], Err);
  end
  else if ToolName = 'ide_run_tests' then
  begin
    { Default: the plugin's own test project (tests/ next to src/), whatever
      project is open; else tests/ in the active project.  A relative
      test_project is relative to the active project's directory. }
    ResolvedLpi := IfThen(Assigned(Args), Args.Get('test_project', ''), '');
    ProjDir := '';
    Text := CallOnMain('project_get_directory', nil, AClientId, Err);
    if not Err and (Text <> '') then
    begin
      DirData := GetJSON(Text);
      try
        if DirData is TJSONObject then
          ProjDir := TJSONObject(DirData).Get('directory', '');
      finally
        DirData.Free;
      end;
    end;
    Err := False;
    if (ResolvedLpi <> '') and not FilenameIsAbsolute(ResolvedLpi) and (ProjDir <> '') then
      ResolvedLpi := CreateAbsolutePath(ResolvedLpi, ProjDir);
    if ResolvedLpi = '' then
    begin
      PkgArgs := TJSONObject.Create(['package_name', 'LazMcpAssistant']);
      try
        Text := CallOnMain('package_get_info', PkgArgs, AClientId, Err);
      finally
        PkgArgs.Free;
      end;
      if not Err and (Text <> '') then
      begin
        DirData := GetJSON(Text);
        try
          if DirData is TJSONObject then
            ResolvedLpi := TJSONObject(DirData).Get('package_file', '');
        finally
          DirData.Free;
        end;
        if ResolvedLpi <> '' then
          ResolvedLpi := ExtractFilePath(ExcludeTrailingPathDelimiter(
                           ExtractFilePath(ResolvedLpi))) +
                         'tests' + PathDelim + 'mcpserver_tests.lpi';
      end;
      Err := False;
      if ((ResolvedLpi = '') or not FileExists(ResolvedLpi)) and (ProjDir <> '') then
        ResolvedLpi := IncludeTrailingPathDelimiter(ProjDir) +
                       'tests' + PathDelim + 'mcpserver_tests.lpi';
      if ResolvedLpi = '' then
      begin
        Text := 'No test_project given, and no default found (the plugin''s ' +
                'tests/mcpserver_tests.lpi, or tests/ in the active project)';
        Err  := True;
      end;
    end;
    if not Err then
      Text := McpRunTests(ResolvedLpi,
        IfThen(Assigned(Args), Args.Get('junit_out', ''), ''), Err);
  end
  else
  begin
    BCtx.Params := Args; BCtx.Result := ''; BCtx.Error := False;
    BCtx.ClientId := AClientId; BCtx.StopServer := @Self.StopServer;
    McpBlockingDispatch(ToolName, BCtx, BHandled);
    if BHandled then
    begin
      Text := BCtx.Result;
      Err  := BCtx.Error;
    end
    else
      // Default: IDE API — must run on main thread.
      Text := CallOnMain(ToolName, Args, AClientId, Err);
  end;
  finally
    McpGateLeave(ToolName, AClientId);
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

var
  GMcpGitHash : string = '';  { cached on first call }

function GetMcpVersion: string;
var
  IDEPkg : TIDEPackage;
begin
  Result := '?';
  IDEPkg := PackageEditingInterface.FindPackageWithName('LazMcpAssistant');
  if Assigned(IDEPkg) then
    Result := IDEPkg.Version.AsString;
end;

function GetMcpGitHash: string;
var
  IDEPkg : TIDEPackage;
  SrcDir : string;
  Proc   : TProcess;
  SL     : TStringList;
begin
  if GMcpGitHash <> '' then begin Result := GMcpGitHash; Exit; end;
  Result := 'unknown';
  IDEPkg := PackageEditingInterface.FindPackageWithName('LazMcpAssistant');
  if not Assigned(IDEPkg) then begin GMcpGitHash := Result; Exit; end;
  SrcDir := ExtractFileDir(IDEPkg.Filename);
  Proc := TProcess.Create(nil);
  SL   := TStringList.Create;
  try
    Proc.Executable      := McpGitExecutable;
    if Proc.Executable = '' then begin GMcpGitHash := Result; Exit; end;
    Proc.Parameters.Add('rev-parse');
    Proc.Parameters.Add('--short');
    Proc.Parameters.Add('HEAD');
    Proc.CurrentDirectory := SrcDir;
    Proc.Options          := [poUsePipes, poWaitOnExit, poStderrToOutPut];
    try
      Proc.Execute;
      SL.LoadFromStream(Proc.Output);
      if (SL.Count > 0) and (Trim(SL[0]) <> '') then
        Result := Trim(SL[0]);
    except
    end;
  finally
    SL.Free;
    Proc.Free;
  end;
  GMcpGitHash := Result;
end;

procedure WriteActiveConfig(APort: Word; const AVersion, AHash: string);
var
  Obj  : TJSONObject;
  SL   : TStringList;
  Path : string;
begin
  if not Assigned(LazarusIDE) then Exit;
  Path := AppendPathDelim(LazarusIDE.GetPrimaryConfigPath) + 'mcp-active.json';
  Obj := TJSONObject.Create;
  SL  := TStringList.Create;
  try
    Obj.Add('url',     Format('http://127.0.0.1:%d/mcp', [APort]));
    Obj.Add('version', AVersion);
    Obj.Add('git_hash', AHash);
    SL.Text := Obj.FormatJSON;
    try
      SL.SaveToFile(Path);
    except
      on E: Exception do
        DebugLn('[MCP Server] Could not write mcp-active.json: ' + E.Message);
    end;
  finally
    SL.Free;
    Obj.Free;
  end;
end;

procedure InitializeMcpServer;
var
  Port    : Word;
  Token   : string;
  Tries   : Integer;
  Ver     : string;
  GitHash : string;
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

  { Give the server thread up to 1 s to bind and start accepting.
    A simple liveness check replaces the fragile single-shot ping. }
  Tries := 0;
  while McpServerThread.Finished and (Tries < 10) do
  begin
    Sleep(100);
    Inc(Tries);
  end;
  if McpServerThread.Finished then
  begin
    DebugLn('[MCP Server] Server thread died immediately; tearing down.');
    FreeAndNil(McpServerThread);
    Exit;
  end;

  // Persist port so next restart reuses the same URL
  McpSettings.ServerPort := Port;
  McpSettings.SaveSettings;

  DebugLn(Format('[MCP Server] Listening on 127.0.0.1:%d.', [Port]));

  { Report to IDE messages window and write stable discovery file }
  Ver     := GetMcpVersion;
  GitHash := GetMcpGitHash;
  if Assigned(IDEMessagesWindow) then
    IDEMessagesWindow.AddCustomMessage(mluImportant,
      Format('MCP Assistant %s [%s] listening on http://127.0.0.1:%d/mcp',
             [Ver, GitHash, Port]));
  WriteActiveConfig(Port, Ver, GitHash);

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
  McpShutdownDebugGuard;
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
