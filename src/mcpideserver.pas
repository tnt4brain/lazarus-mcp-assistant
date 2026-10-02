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
    function  DoSearchInProject(const FileListJSON, Query: string): string;
    function  GetUnitInterface(const FilePath: string; out IsError: Boolean): string;
    function  RunLazbuild(const LpkPath: string; out IsError: Boolean): string;
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
  SrcEditorIntf, ProjectIntf, LazFileUtils, FileUtil, Sockets, fphttpclient,
  Controls, CompOptsIntf, CodeToolManager, CodeCache, CodeTree, AVL_Tree,
  PackageIntf, Process, Contnrs;

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

{ Try to bind 127.0.0.1:APort; returns True if the port is usable.
  Uses SO_REUSEADDR so TIME_WAIT sockets don't cause false negatives,
  matching TInetServer's own bind behaviour. }
function IsPortFree(APort: Word): Boolean;
var
  S      : LongInt;
  Addr   : TInetSockAddr;
  Enable : LongInt;
begin
  Result := False;
  S := fpSocket(AF_INET, SOCK_STREAM, 0);
  if S < 0 then Exit;
  Enable := 1;
  fpSetSockOpt(S, SOL_SOCKET, SO_REUSEADDR, @Enable, SizeOf(Enable));
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family          := AF_INET;
  Addr.sin_port            := Swap16(APort);
  Addr.sin_addr.s_bytes[1] := 127;
  Addr.sin_addr.s_bytes[2] := 0;
  Addr.sin_addr.s_bytes[3] := 0;
  Addr.sin_addr.s_bytes[4] := 1;
  Result := fpBind(S, @Addr, SizeOf(Addr)) = 0;
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
  SrvInfo.Add('version', '0.5.0');

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
  Prop1    : TJSONObject;
  Prop2    : TJSONObject;
  SProps   : TJSONObject;
  SReq2    : TJSONArray;
  PA, PB, PC : TJSONObject;
  SC         : TJSONObject;
  SR3        : TJSONArray;
  P3, P4     : TJSONObject;
  S4         : TJSONObject;
  R4         : TJSONArray;
  CUProps, CUPfn, CUPct : TJSONObject;
  CUReq                  : TJSONArray;
  AUProps, AUPf, AUPu, AUPi : TJSONObject;
  AUReq                      : TJSONArray;
  CPProps, CPLpk             : TJSONObject;
  CPReq                      : TJSONArray;
  SCPProps, SCPFile, SCPLine, SCPCol : TJSONObject;
  SCPReq                             : TJSONArray;
  RTProps, RTFile, RTSLine, RTSCol, RTELine, RTECol, RTText : TJSONObject;
  RTReq                                                      : TJSONArray;
  RIProps, RILpk             : TJSONObject;
  RIReq                      : TJSONArray;
  GPProps, GPName            : TJSONObject;
  GPReq                      : TJSONArray;
  SFProps, SFFile            : TJSONObject;
  GDProps, GDSym, GDFile     : TJSONObject;
  GDReq                      : TJSONArray;
  CFProps, CFFile            : TJSONObject;
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

  // build_project — no args
  Tools.Add(MakeTool('build_project',
    'Trigger an incremental build of the active project and return ' +
    'success/failure with any compiler errors.',
    TJSONObject.Create, TJSONArray.Create));

  // get_open_editors — no args
  Tools.Add(MakeTool('get_open_editors',
    'Return the list of all currently open editor tabs (file names).',
    TJSONObject.Create, TJSONArray.Create));

  // search_in_project — requires query
  PathDef := TJSONObject.Create;
  PathDef.Add('type',        'string');
  PathDef.Add('description', 'Text or substring to search for (case-insensitive)');
  SPath := TJSONObject.Create;
  SPath.Add('query', PathDef);
  SPReq := TJSONArray.Create;
  SPReq.Add('query');
  Tools.Add(MakeTool('search_in_project',
    'Search for a text substring across all project source files. ' +
    'Returns matching file, line number, and line content.',
    SPath, SPReq));

  // get_symbol_declaration — requires symbol + file
  Prop1 := TJSONObject.Create;
    Prop1.Add('type', 'string');
    Prop1.Add('description', 'Identifier name to look up');
    Prop2 := TJSONObject.Create;
    Prop2.Add('type', 'string');
    Prop2.Add('description', 'Absolute path of the file containing the identifier');
    SProps := TJSONObject.Create;
    SProps.Add('symbol', Prop1);
    SProps.Add('file',   Prop2);
    SReq2 := TJSONArray.Create;
    SReq2.Add('symbol');
    SReq2.Add('file');
    Tools.Add(MakeTool('get_symbol_declaration',
      'Find where an identifier is declared using Codetools. ' +
      'Returns declaration file, line, column and a short context snippet.',
      SProps, SReq2));

  // get_unit_interface — requires file
  PathDef := TJSONObject.Create;
  PathDef.Add('type',        'string');
  PathDef.Add('description', 'Absolute path to the .pas file');
  SPath := TJSONObject.Create;
  SPath.Add('file', PathDef);
  SPReq := TJSONArray.Create;
  SPReq.Add('file');
  Tools.Add(MakeTool('get_unit_interface',
    'Return only the interface section of a Pascal unit ' +
    '(everything above the implementation keyword).',
    SPath, SPReq));

  // run_project — no args
  Tools.Add(MakeTool('run_project',
    'Build (if needed) and run the active project without the debugger.',
    TJSONObject.Create, TJSONArray.Create));

  // get_identifier_context — requires file, line, col
  PA := TJSONObject.Create;  PA.Add('type', 'string');  PA.Add('description', 'Absolute path to the file');
  PB := TJSONObject.Create;  PB.Add('type', 'integer'); PB.Add('description', 'Line number (1-based)');
  PC := TJSONObject.Create;  PC.Add('type', 'integer'); PC.Add('description', 'Column number (1-based)');
  SC := TJSONObject.Create;
  SC.Add('file', PA);
  SC.Add('line', PB);
  SC.Add('col',  PC);
  SR3 := TJSONArray.Create;
  SR3.Add('file'); SR3.Add('line'); SR3.Add('col');
  Tools.Add(MakeTool('get_identifier_context',
    'Return type, declaration location, and hint text for the identifier ' +
    'at a given file/line/col using Codetools FindSmartHint.',
    SC, SR3));

  // get_project_settings — no args
  Tools.Add(MakeTool('get_project_settings',
    'Return active project compiler options: target OS/CPU, output directory, ' +
    'custom options, and project file path.',
    TJSONObject.Create, TJSONArray.Create));

  // get_code_outline — requires file
  PathDef := TJSONObject.Create;
  PathDef.Add('type', 'string');
  PathDef.Add('description', 'Absolute path to the .pas file');
  SPath := TJSONObject.Create;
  SPath.Add('file', PathDef);
  SPReq := TJSONArray.Create;
  SPReq.Add('file');
  Tools.Add(MakeTool('get_code_outline',
    'Return the structural outline of a Pascal unit: uses clauses, type ' +
    'names, class members, and top-level routines with their line numbers. ' +
    'Does not include method bodies.',
    SPath, SPReq));

  // find_all_references — requires symbol + file + line + col
  PA := TJSONObject.Create; PA.Add('type', 'string');  PA.Add('description', 'Absolute path to the file containing the declaration');
  PB := TJSONObject.Create; PB.Add('type', 'integer'); PB.Add('description', 'Line of the declaration (1-based)');
  PC := TJSONObject.Create; PC.Add('type', 'integer'); PC.Add('description', 'Column of the declaration (1-based)');
  SC := TJSONObject.Create;
  SC.Add('file', PA); SC.Add('line', PB); SC.Add('col', PC);
  SR3 := TJSONArray.Create;
  SR3.Add('file'); SR3.Add('line'); SR3.Add('col');
  Tools.Add(MakeTool('find_all_references',
    'Find every reference to the identifier at the given declaration position ' +
    'across all project files.',
    SC, SR3));

  // rename_identifier — requires file + line + col + new_name
  Prop1 := TJSONObject.Create; Prop1.Add('type', 'string');  Prop1.Add('description', 'Absolute path to the file containing the declaration');
  Prop2 := TJSONObject.Create; Prop2.Add('type', 'integer'); Prop2.Add('description', 'Line of the declaration (1-based)');
  P3    := TJSONObject.Create; P3.Add('type', 'integer');    P3.Add('description', 'Column of the declaration (1-based)');
  P4    := TJSONObject.Create; P4.Add('type', 'string');     P4.Add('description', 'New identifier name');
  S4    := TJSONObject.Create;
  S4.Add('file', Prop1); S4.Add('line', Prop2); S4.Add('col', P3); S4.Add('new_name', P4);
  R4 := TJSONArray.Create;
  R4.Add('file'); R4.Add('line'); R4.Add('col'); R4.Add('new_name');
  Tools.Add(MakeTool('rename_identifier',
    'Rename an identifier at the given declaration position across all ' +
    'project files. WARNING: this operation writes directly to disk and ' +
    'bypasses the IDE undo stack — it CANNOT be undone with Ctrl+Z. ' +
    'Use git to revert if needed. Only call this after confirming the ' +
    'new name with the user.',
    S4, R4));

  // get_cursor_position — no required params
  Tools.Add(MakeTool('get_cursor_position',
    'Return the active editor''s current cursor position: file path, ' +
    'line and column (both 1-based).',
    TJSONObject.Create, TJSONArray.Create));

  // get_selected_text — no required params
  Tools.Add(MakeTool('get_selected_text',
    'Return the text currently selected in the active editor, together ' +
    'with the selection start/end positions. Returns an empty string if ' +
    'nothing is selected.',
    TJSONObject.Create, TJSONArray.Create));

  // set_cursor_position — file optional, line+col required
  SCPProps := TJSONObject.Create;
  SCPFile  := TJSONObject.Create; SCPFile.Add('type', 'string');  SCPFile.Add('description', 'Absolute path to the file to open and navigate to; omit to move the cursor in the active editor');
  SCPLine  := TJSONObject.Create; SCPLine.Add('type', 'integer'); SCPLine.Add('description', 'Line number (1-based)');
  SCPCol   := TJSONObject.Create; SCPCol.Add('type',  'integer'); SCPCol.Add('description', 'Column number (1-based)');
  SCPProps.Add('file', SCPFile);
  SCPProps.Add('line', SCPLine);
  SCPProps.Add('col',  SCPCol);
  SCPReq := TJSONArray.Create;
  SCPReq.Add('line');
  SCPReq.Add('col');
  Tools.Add(MakeTool('set_cursor_position',
    'Move the cursor to a specific line and column in the editor. ' +
    'Opens the file first if it is not already open. ' +
    'Omit file to move the cursor in the currently active editor.',
    SCPProps, SCPReq));

  // replace_text — file optional, range + new_text required
  RTProps  := TJSONObject.Create;
  RTFile   := TJSONObject.Create; RTFile.Add('type',   'string');  RTFile.Add('description', 'Absolute path to the file; omit to edit the active editor');
  RTSLine  := TJSONObject.Create; RTSLine.Add('type',  'integer'); RTSLine.Add('description', 'Start line (1-based, inclusive)');
  RTSCol   := TJSONObject.Create; RTSCol.Add('type',   'integer'); RTSCol.Add('description', 'Start column (1-based, inclusive)');
  RTELine  := TJSONObject.Create; RTELine.Add('type',  'integer'); RTELine.Add('description', 'End line (1-based, exclusive — the character at this position is NOT replaced)');
  RTECol   := TJSONObject.Create; RTECol.Add('type',   'integer'); RTECol.Add('description', 'End column (1-based, exclusive)');
  RTText   := TJSONObject.Create; RTText.Add('type',   'string');  RTText.Add('description', 'Replacement text; empty string to delete the range');
  RTProps.Add('file',       RTFile);
  RTProps.Add('start_line', RTSLine);
  RTProps.Add('start_col',  RTSCol);
  RTProps.Add('end_line',   RTELine);
  RTProps.Add('end_col',    RTECol);
  RTProps.Add('new_text',   RTText);
  RTReq := TJSONArray.Create;
  RTReq.Add('start_line');
  RTReq.Add('start_col');
  RTReq.Add('end_line');
  RTReq.Add('end_col');
  RTReq.Add('new_text');
  Tools.Add(MakeTool('replace_text',
    'Replace a range of text in the editor buffer. ' +
    'The edit is recorded in the editor''s undo history (Ctrl+Z works). ' +
    'Use an empty range (start = end) to insert text. ' +
    'Use empty new_text to delete the range. ' +
    'Opens the file first if it is not already open.',
    RTProps, RTReq));

  // create_unit — filename required, content optional
  CUProps := TJSONObject.Create;
  CUPfn   := TJSONObject.Create; CUPfn.Add('type', 'string'); CUPfn.Add('description', 'Absolute path for the new .pas file');
  CUPct   := TJSONObject.Create; CUPct.Add('type', 'string'); CUPct.Add('description', 'Full source content; omit for a blank unit skeleton');
  CUProps.Add('filename', CUPfn);
  CUProps.Add('content',  CUPct);
  CUReq := TJSONArray.Create;
  CUReq.Add('filename');
  Tools.Add(MakeTool('create_unit',
    'Create a new Pascal unit file on disk, add it to the active project, ' +
    'and open it in the editor. Provide content or receive a blank ' +
    'unit skeleton.',
    CUProps, CUReq));

  // add_unit_to_uses — file + unit_name required, in_interface optional
  AUProps := TJSONObject.Create;
  AUPf    := TJSONObject.Create; AUPf.Add('type',  'string');  AUPf.Add('description', 'Absolute path to the Pascal file to modify');
  AUPu    := TJSONObject.Create; AUPu.Add('type',  'string');  AUPu.Add('description', 'Unit name to add to the uses clause');
  AUPi    := TJSONObject.Create; AUPi.Add('type',  'boolean'); AUPi.Add('description', 'Add to interface uses (true, default) or implementation uses (false)');
  AUProps.Add('file',         AUPf);
  AUProps.Add('unit_name',    AUPu);
  AUProps.Add('in_interface', AUPi);
  AUReq := TJSONArray.Create;
  AUReq.Add('file');
  AUReq.Add('unit_name');
  Tools.Add(MakeTool('add_unit_to_uses',
    'Add a unit to the uses clause of a Pascal file using Codetools. ' +
    'Writes directly to disk (not undoable via Ctrl+Z; use git to revert). ' +
    'Set in_interface=false to target the implementation uses clause.',
    AUProps, AUReq));

  // compile_plugin — lpk_path required
  CPProps := TJSONObject.Create;
  CPLpk   := TJSONObject.Create; CPLpk.Add('type', 'string'); CPLpk.Add('description', 'Absolute path to the .lpk package file to compile');
  CPProps.Add('lpk_path', CPLpk);
  CPReq := TJSONArray.Create; CPReq.Add('lpk_path');
  Tools.Add(MakeTool('compile_plugin',
    'Compile a Lazarus package (.lpk) using lazbuild and return the full ' +
    'compiler output. Use this as a smoke-test before calling rebuild_ide. ' +
    'Does not restart the IDE.',
    CPProps, CPReq));

  // rebuild_ide — lpk_path optional
  RIProps := TJSONObject.Create;
  RILpk   := TJSONObject.Create;
  RILpk.Add('type', 'string');
  RILpk.Add('description', 'Absolute path to the .lpk package file to install and ' +
                            'rebuild with. Omit to rebuild with currently installed packages ' +
                            '(e.g. after compile_plugin).');
  RIProps.Add('lpk_path', RILpk);
  Tools.Add(MakeTool('rebuild_ide',
    'Rebuild and restart the Lazarus IDE. Pass lpk_path to install a package ' +
    'before rebuilding; omit it to rebuild with currently installed packages. ' +
    'The IDE exits immediately after this call; the MCP server will be ' +
    'unavailable for ~60 s. Call compile_plugin first to catch errors early.',
    RIProps, TJSONArray.Create));

  // get_package_info — package_name required
  GPProps := TJSONObject.Create;
  GPName  := TJSONObject.Create; GPName.Add('type', 'string'); GPName.Add('description', 'Package name as registered in the IDE (e.g. LazMcpAssistant)');
  GPProps.Add('package_name', GPName);
  GPReq := TJSONArray.Create; GPReq.Add('package_name');
  Tools.Add(MakeTool('get_package_info',
    'Query a package''s load and install status in the running IDE.',
    GPProps, GPReq));

  // save_file — file optional
  SFProps := TJSONObject.Create;
  SFFile  := TJSONObject.Create; SFFile.Add('type', 'string'); SFFile.Add('description', 'Absolute path of the file to save; omit to save the active editor');
  SFProps.Add('file', SFFile);
  Tools.Add(MakeTool('save_file',
    'Save the editor buffer to disk. Omit file to save the active editor.',
    SFProps, TJSONArray.Create));

  // goto_declaration — symbol + file required
  GDProps := TJSONObject.Create;
  GDSym   := TJSONObject.Create; GDSym.Add('type', 'string'); GDSym.Add('description', 'Identifier name to look up');
  GDFile  := TJSONObject.Create; GDFile.Add('type', 'string'); GDFile.Add('description', 'Absolute path of the file that contains (or imports) the identifier');
  GDProps.Add('symbol', GDSym);
  GDProps.Add('file',   GDFile);
  GDReq := TJSONArray.Create; GDReq.Add('symbol'); GDReq.Add('file');
  Tools.Add(MakeTool('goto_declaration',
    'Find where an identifier is declared and jump the editor cursor there. ' +
    'Opens the declaration file if needed.',
    GDProps, GDReq));

  // close_file — file optional
  CFProps := TJSONObject.Create;
  CFFile  := TJSONObject.Create; CFFile.Add('type', 'string'); CFFile.Add('description', 'Absolute path of the file to close; omit to close the active editor');
  CFProps.Add('file', CFFile);
  Tools.Add(MakeTool('close_file',
    'Close an editor tab. Omit file to close the active editor. ' +
    'Unsaved changes are discarded quietly.',
    CFProps, TJSONArray.Create));

  // ping — no params
  Tools.Add(MakeTool('ping',
    'Returns {"status":"ok","version":"x.y"} immediately. Use this to poll for the MCP server ' +
    'coming back after rebuild_ide — retry until it succeeds.',
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
  else if ToolName = 'get_unit_interface' then
  begin
    if not Assigned(Args) or (Args.Get('file', '') = '') then
    begin
      Text := 'Error: file argument required';
      Err  := True;
    end else
      Text := GetUnitInterface(Args.Strings['file'], Err);
  end
  else if ToolName = 'ping' then
  begin
    FSyncToolName := 'ping';
    FSyncParams   := nil;
    FSyncResult   := '';
    FSyncError    := False;
    FSyncConnectionClose := False;
    TThread.Synchronize(Self, @SyncCallTool);
    Text := FSyncResult;
    Err  := FSyncError;
  end
  else if ToolName = 'compile_plugin' then
  begin
    if not Assigned(Args) or (Args.Get('lpk_path', '') = '') then
    begin
      Text := 'Error: lpk_path required';
      Err  := True;
    end else
      Text := RunLazbuild(Args.Strings['lpk_path'], Err);
  end
  else if (ToolName = 'get_active_file') or
          (ToolName = 'get_project_files') or
          (ToolName = 'get_compiler_errors') or
          (ToolName = 'build_project') or
          (ToolName = 'get_open_editors') or
          (ToolName = 'get_symbol_declaration') or
          (ToolName = 'run_project') or
          (ToolName = 'get_identifier_context') or
          (ToolName = 'get_project_settings') or
          (ToolName = 'get_code_outline') or
          (ToolName = 'get_cursor_position') or
          (ToolName = 'get_selected_text') or
          (ToolName = 'set_cursor_position') or
          (ToolName = 'replace_text') or
          (ToolName = 'create_unit') or
          (ToolName = 'add_unit_to_uses') or
          (ToolName = 'rebuild_ide') or
          (ToolName = 'get_package_info') or
          (ToolName = 'save_file') or
          (ToolName = 'goto_declaration') or
          (ToolName = 'close_file') then
  begin
    // IDE APIs — must run on main thread
    FSyncToolName        := ToolName;
    FSyncParams          := Args;
    FSyncResult          := '';
    FSyncError           := False;
    FSyncConnectionClose := False;
    TThread.Synchronize(Self, @SyncCallTool);
    Text := FSyncResult;
    Err  := FSyncError;
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
        Text := DoSearchInProject(FSyncResult, Args.Get('query', ''))
      else
        Text := DoSearchInProject(FSyncResult, '');
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

{ ── Project-wide text search (runs in server thread) ─────────────────────── }

function TMcpServerThread.DoSearchInProject(const FileListJSON,
  Query: string): string;
var
  FileList : TJSONArray;
  Results  : TJSONArray;
  Match    : TJSONObject;
  Lines    : TStringList;
  FilePath : string;
  Q        : string;
  I, J     : Integer;
begin
  if Query = '' then
    Exit('{"error":"query argument required"}');

  Q       := LowerCase(Query);
  Results := TJSONArray.Create;
  Lines   := TStringList.Create;
  try
    FileList := TJSONArray(GetJSON(FileListJSON));
    try
      for I := 0 to FileList.Count - 1 do
      begin
        FilePath := FileList.Strings[I];
        if not FileExists(FilePath) then Continue;
        try
          Lines.LoadFromFile(FilePath);
          for J := 0 to Lines.Count - 1 do
            if Pos(Q, LowerCase(Lines[J])) > 0 then
            begin
              Match := TJSONObject.Create;
              Match.Add('file', FilePath);
              Match.Add('line', J + 1);
              Match.Add('text', Trim(Lines[J]));
              Results.Add(Match);
            end;
        except
          // skip unreadable files
        end;
      end;
    finally
      FileList.Free;
    end;
    Result := Results.AsJSON;
  finally
    Lines.Free;
    Results.Free;
  end;
end;

{ ── lazbuild output filter ───────────────────────────────────────────────── }

{ On success: keep only Error/Warning/Hint lines + the "N lines compiled" summary.
  On failure: return everything so the full error context is visible. }
function FilterLazbuildOutput(const Raw: string; IsError: Boolean): string;
var
  Lines : TStringList;
  I     : Integer;
  Line  : string;
begin
  if Raw = '' then begin Result := '(no output)'; Exit; end;
  if IsError then begin Result := Raw; Exit; end;
  Lines := TStringList.Create;
  try
    Lines.Text := Raw;
    Result := '';
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      if (Pos(') Error:',   Line) > 0) or
         (Pos(') Warning:', Line) > 0) or
         (Pos(') Hint:',    Line) > 0) or
         (Pos('lines compiled', Line) > 0) then
        Result := Result + Line + LineEnding;
    end;
    if Result = '' then Result := '(compiled clean, no diagnostics)';
  finally
    Lines.Free;
  end;
end;

{ ── lazbuild runner (server thread) ─────────────────────────────────────── }

function TMcpServerThread.RunLazbuild(const LpkPath: string;
  out IsError: Boolean): string;
var
  LazbuildExe : string;
  Proc        : TProcess;
  Chunk       : string = '';
  BytesRead   : LongInt;
const
  BufSize = 4096;
begin
  IsError := False;
  LazbuildExe := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
                 'lazbuild' + GetExeExt;
  if not FileExists(LazbuildExe) then
  begin
    IsError := True;
    Result  := 'lazbuild not found at: ' + LazbuildExe;
    Exit;
  end;

  Result := '';
  Proc   := TProcess.Create(nil);
  try
    Proc.Executable := LazbuildExe;
    Proc.Parameters.Add(LpkPath);
    Proc.Options    := [poUsePipes, poStdErrToOutput];
    Proc.Execute;
    repeat
      SetLength(Chunk, BufSize);
      BytesRead := Proc.Output.Read(Chunk[1], BufSize);
      if BytesRead > 0 then
      begin
        SetLength(Chunk, BytesRead);
        Result := Result + Chunk;
      end;
    until (BytesRead = 0) and not Proc.Running;
    Proc.WaitOnExit;
    IsError := Proc.ExitCode <> 0;
    Result  := FilterLazbuildOutput(Result, IsError);
  finally
    Proc.Free;
  end;
end;

{ ── Unit interface extractor (server thread) ─────────────────────────────── }

function TMcpServerThread.GetUnitInterface(const FilePath: string;
  out IsError: Boolean): string;
var
  Lines   : TStringList;
  I       : Integer;
  ULine   : string;
begin
  IsError := False;
  if not FileExists(FilePath) then
  begin
    IsError := True;
    Result  := 'Error: file not found: ' + FilePath;
    Exit;
  end;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(FilePath);
      for I := 0 to Lines.Count - 1 do
      begin
        ULine := Trim(LowerCase(Lines[I]));
        if (ULine = 'implementation') or
           (Copy(ULine, 1, 15) = 'implementation ') or
           (Copy(ULine, 1, 15) = 'implementation{') then
        begin
          while Lines.Count > I do
            Lines.Delete(Lines.Count - 1);
          Result := Lines.Text;
          Exit;
        end;
      end;
      Result := Lines.Text; // no implementation keyword — return everything
    except
      on E: Exception do
      begin
        IsError := True;
        Result  := 'Error reading file: ' + E.Message;
      end;
    end;
  finally
    Lines.Free;
  end;
end;

{ ── Main-thread tool dispatcher ──────────────────────────────────────────── }

procedure TMcpServerThread.SyncCallTool;
var
  Ed           : TSourceEditorInterface;
  Obj          : TJSONObject;
  Files        : TJSONArray;
  Proj         : TLazProject;
  Errors       : TJSONArray;
  PasName      : string;
  BuildRes     : Integer;
  SyncSymbol     : string;
  SyncFilePath   : string;
  SyncCodeBuf    : TCodeBuffer;
  SyncNewCode    : TCodeBuffer;
  SyncNewX       : Integer;
  SyncNewY       : Integer;
  SyncNewTopLine : Integer;
  SyncSnippet    : string;
  SyncNewName    : string;
  SyncDeclPt     : TPoint;
  SyncFileNames  : TStringList;
  SyncRefTree    : TAVLTree;
  SyncRefNode    : TAVLTreeNode;
  SyncRefPos     : PCodeXYPosition;
  SyncRefArr     : TJSONArray;
  SyncRefObj     : TJSONObject;
  SyncFileListJ  : TJSONArray;
  SyncTool       : TCodeTool;
  SyncTreeNode   : TCodeTreeNode;
  SyncOutline    : TJSONArray;
  SyncEntry      : TJSONObject;
  SyncPkgList    : TObjectList;
  SyncIDEPkg     : TIDEPackage;
  SyncIDEPkg2    : TIDEPackage;
  SyncPkgID      : TLazPackageID;
  SyncPollExe    : string;
  SyncPasFile    : string;
  J              : Integer;
  I              : Integer;
begin
  FSyncError := False;
  try
    if FSyncToolName = 'ping' then
    begin
      Obj := TJSONObject.Create;
      try
        Obj.Add('status', 'ok');
        SyncIDEPkg := PackageEditingInterface.FindPackageWithName('LazMcpAssistant');
        if Assigned(SyncIDEPkg) then
          Obj.Add('version', SyncIDEPkg.Version.AsString);
        FSyncResult := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    end

    else if FSyncToolName = 'get_active_file' then
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
    end

    else if FSyncToolName = 'build_project' then
    begin
      if not Assigned(LazarusIDE) then
      begin
        FSyncError  := True;
        FSyncResult := 'No IDE available';
        Exit;
      end;
      BuildRes := LazarusIDE.DoBuildProject(crCompile, []);
      Obj := TJSONObject.Create;
      try
        Obj.Add('success', BuildRes = mrOK);
        if Assigned(McpHookManager) then
          Errors := McpHookManager.CurrentCompilerErrors
        else
          Errors := nil;
        if Assigned(Errors) then
          Obj.Add('errors', Errors.Clone as TJSONArray)
        else
          Obj.Add('errors', TJSONArray.Create);
        FSyncResult := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    end

    else if FSyncToolName = 'get_open_editors' then
    begin
      Files := TJSONArray.Create;
      try
        for I := 0 to SourceEditorManagerIntf.SourceEditorCount - 1 do
          Files.Add(SourceEditorManagerIntf.SourceEditors[I].FileName);
        FSyncResult := Files.AsJSON;
      finally
        Files.Free;
      end;
    end

    else if FSyncToolName = 'get_symbol_declaration' then
    begin
      if not Assigned(FSyncParams) then
      begin
        FSyncError := True; FSyncResult := 'Missing params'; Exit;
      end;
      SyncSymbol   := FSyncParams.Get('symbol', '');
      SyncFilePath := FSyncParams.Get('file',   '');
      if (SyncSymbol = '') or (SyncFilePath = '') then
      begin
        FSyncError := True; FSyncResult := 'symbol and file arguments required'; Exit;
      end;
      SyncCodeBuf := CodeToolBoss.LoadFile(SyncFilePath, False, False);
      if not Assigned(SyncCodeBuf) then
      begin
        FSyncError := True; FSyncResult := 'Could not load file: ' + SyncFilePath; Exit;
      end;
      if CodeToolBoss.FindDeclarationInInterface(SyncCodeBuf, SyncSymbol,
           SyncNewCode, SyncNewX, SyncNewY, SyncNewTopLine) then
      begin
        Obj := TJSONObject.Create;
        try
          Obj.Add('declaration_file', SyncNewCode.Filename);
          Obj.Add('line',  SyncNewY);
          Obj.Add('col',   SyncNewX);
          if SyncNewY >= 1 then
          begin
            SyncSnippet := SyncNewCode.GetLine(SyncNewY - 1, False);
            Obj.Add('context', Trim(SyncSnippet));
          end;
          FSyncResult := Obj.AsJSON;
        finally
          Obj.Free;
        end;
      end else
      begin
        FSyncError  := True;
        FSyncResult := 'Declaration not found for: ' + SyncSymbol +
                       ' (' + CodeToolBoss.ErrorMessage + ')';
      end;
    end

    else if FSyncToolName = 'get_identifier_context' then
    begin
      if not Assigned(FSyncParams) then
      begin
        FSyncError := True; FSyncResult := 'Missing params'; Exit;
      end;
      SyncFilePath := FSyncParams.Get('file', '');
      SyncNewX     := FSyncParams.Get('col',  0);
      SyncNewY     := FSyncParams.Get('line', 0);
      if SyncFilePath = '' then
      begin
        FSyncError := True; FSyncResult := 'file argument required'; Exit;
      end;
      SyncCodeBuf := CodeToolBoss.LoadFile(SyncFilePath, False, False);
      if not Assigned(SyncCodeBuf) then
      begin
        FSyncError := True; FSyncResult := 'Could not load file: ' + SyncFilePath; Exit;
      end;
      SyncSnippet := CodeToolBoss.FindSmartHint(SyncCodeBuf, SyncNewX, SyncNewY);
      FSyncResult := '{"hint":' + TJSONString.Create(SyncSnippet).AsJSON + '}';
    end

    else if FSyncToolName = 'run_project' then
    begin
      if not Assigned(LazarusIDE) then
      begin
        FSyncError := True; FSyncResult := 'No IDE available'; Exit;
      end;
      BuildRes := LazarusIDE.DoRunProjectWithoutDebug;
      Obj := TJSONObject.Create;
      try
        Obj.Add('success', BuildRes = mrOK);
        FSyncResult := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    end

    else if FSyncToolName = 'get_cursor_position' then
    begin
      Ed := SourceEditorManagerIntf.ActiveEditor;
      if not Assigned(Ed) then
      begin
        FSyncError := True; FSyncResult := 'No active editor'; Exit;
      end;
      Obj := TJSONObject.Create;
      try
        Obj.Add('file', Ed.FileName);
        Obj.Add('line', Ed.CursorTextXY.Y);
        Obj.Add('col',  Ed.CursorTextXY.X);
        FSyncResult := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    end

    else if FSyncToolName = 'get_selected_text' then
    begin
      Ed := SourceEditorManagerIntf.ActiveEditor;
      if not Assigned(Ed) then
      begin
        FSyncError := True; FSyncResult := 'No active editor'; Exit;
      end;
      Obj := TJSONObject.Create;
      try
        Obj.Add('file', Ed.FileName);
        if Ed.SelectionAvailable then
        begin
          Obj.Add('text',       Ed.Selection);
          Obj.Add('start_line', Ed.BlockBegin.Y);
          Obj.Add('start_col',  Ed.BlockBegin.X);
          Obj.Add('end_line',   Ed.BlockEnd.Y);
          Obj.Add('end_col',    Ed.BlockEnd.X);
        end
        else
        begin
          Obj.Add('text', '');
          Obj.Add('note', 'No text selected');
        end;
        FSyncResult := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    end

    else if FSyncToolName = 'create_unit' then
    begin
      if not Assigned(FSyncParams) or (FSyncParams.Get('filename', '') = '') then
      begin
        FSyncError := True; FSyncResult := 'filename required'; Exit;
      end;
      SyncFilePath := FSyncParams.Get('filename', '');
      // Expand relative paths against the project directory
      if not FilenameIsAbsolute(SyncFilePath) then
      begin
        if McpProject.IsProjectOpen then
          SyncFilePath := AppendPathDelim(McpProject.GetProjectDirectory) + SyncFilePath
        else begin
          FSyncError := True; FSyncResult := 'No active project to resolve relative path'; Exit;
        end;
      end;
      if FileExists(SyncFilePath) then
      begin
        FSyncError := True; FSyncResult := 'File already exists: ' + SyncFilePath; Exit;
      end;
      // Build content: use provided content or generate a blank unit skeleton
      SyncNewName := FSyncParams.Get('content', '');
      if SyncNewName = '' then
      begin
        PasName := ChangeFileExt(ExtractFileName(SyncFilePath), '');
        SyncNewName :=
          'unit ' + PasName + ';' + LineEnding +
          LineEnding +
          '{$mode objfpc}{$H+}' + LineEnding +
          LineEnding +
          'interface' + LineEnding +
          LineEnding +
          'implementation' + LineEnding +
          LineEnding +
          'end.' + LineEnding;
      end;
      SyncCodeBuf := CodeToolBoss.CreateFile(SyncFilePath);
      if not Assigned(SyncCodeBuf) then
      begin
        FSyncError := True; FSyncResult := 'Could not create buffer for: ' + SyncFilePath; Exit;
      end;
      SyncCodeBuf.Source := SyncNewName;
      if not SyncCodeBuf.Save then
      begin
        FSyncError := True; FSyncResult := 'Could not save: ' + SyncFilePath; Exit;
      end;
      // Add to project
      Proj := LazarusIDE.ActiveProject;
      if Assigned(Proj) then
        Proj.AddFile(Proj.CreateProjectFile(SyncFilePath), False);
      // Open in editor
      LazarusIDE.DoOpenEditorFile(SyncFilePath, -1, -1, [ofRegularFile]);
      Obj := TJSONObject.Create;
      try
        Obj.Add('filename', SyncFilePath);
        Obj.Add('created',  True);
        FSyncResult := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    end

    else if FSyncToolName = 'add_unit_to_uses' then
    begin
      if not Assigned(FSyncParams) then
      begin
        FSyncError := True; FSyncResult := 'Missing params'; Exit;
      end;
      SyncFilePath := FSyncParams.Get('file',      '');
      SyncSymbol   := FSyncParams.Get('unit_name', '');
      if (SyncFilePath = '') or (SyncSymbol = '') then
      begin
        FSyncError := True; FSyncResult := 'file and unit_name required'; Exit;
      end;
      SyncCodeBuf := CodeToolBoss.LoadFile(SyncFilePath, False, False);
      if not Assigned(SyncCodeBuf) then
      begin
        FSyncError := True; FSyncResult := 'Could not load: ' + SyncFilePath; Exit;
      end;
      if FSyncParams.Get('in_interface', True) then
      begin
        if not CodeToolBoss.AddUnitToMainUsesSection(SyncCodeBuf, SyncSymbol, '') then
        begin
          FSyncError := True; FSyncResult := 'AddUnitToMainUsesSection failed: ' + CodeToolBoss.ErrorMessage; Exit;
        end;
      end
      else
      begin
        if not CodeToolBoss.AddUnitToImplementationUsesSection(SyncCodeBuf, SyncSymbol, '') then
        begin
          FSyncError := True; FSyncResult := 'AddUnitToImplementationUsesSection failed: ' + CodeToolBoss.ErrorMessage; Exit;
        end;
      end;
      if not CodeToolBoss.ApplyChanges then
      begin
        FSyncError := True; FSyncResult := 'ApplyChanges failed'; Exit;
      end;
      SyncCodeBuf.Save;
      LazarusIDE.DoRevertEditorFile(SyncFilePath);
      Obj := TJSONObject.Create;
      try
        Obj.Add('file',          SyncFilePath);
        Obj.Add('unit_added',    SyncSymbol);
        Obj.Add('in_interface',  FSyncParams.Get('in_interface', True));
        FSyncResult := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    end

    else if FSyncToolName = 'get_code_outline' then
    begin
      if not Assigned(FSyncParams) or (FSyncParams.Get('file', '') = '') then
      begin
        FSyncError := True; FSyncResult := 'file argument required'; Exit;
      end;
      SyncFilePath := FSyncParams.Get('file', '');
      SyncCodeBuf  := CodeToolBoss.LoadFile(SyncFilePath, False, False);
      if not Assigned(SyncCodeBuf) then
      begin
        FSyncError := True; FSyncResult := 'Could not load: ' + SyncFilePath; Exit;
      end;
      if not CodeToolBoss.Explore(SyncCodeBuf, SyncTool, False, True) then
      begin
        FSyncError := True; FSyncResult := 'Parse error: ' + CodeToolBoss.ErrorMessage; Exit;
      end;
      SyncOutline := TJSONArray.Create;
      try
        SyncTreeNode := SyncTool.Tree.Root;
        while Assigned(SyncTreeNode) do
        begin
          // Emit interesting structural nodes
          if SyncTreeNode.Desc in [ctnTypeDefinition, ctnVarDefinition,
                                   ctnProcedure, ctnUseUnit] then
          begin
            SyncCodeBuf.AbsoluteToLineCol(SyncTreeNode.StartPos, SyncNewY, SyncNewX);
            SyncEntry := TJSONObject.Create;
            SyncEntry.Add('kind', NodeDescriptionAsString(SyncTreeNode.Desc));
            SyncEntry.Add('line', SyncNewY);
            SyncEntry.Add('name', SyncTool.ExtractIdentifier(SyncTreeNode.StartPos));
            SyncOutline.Add(SyncEntry);
          end;
          // Descend into structural containers; skip procedure bodies and leaves
          if Assigned(SyncTreeNode.FirstChild) and
             (SyncTreeNode.Desc in [ctnUnit, ctnInterface, ctnImplementation,
                                    ctnTypeSection, ctnVarSection, ctnConstSection,
                                    ctnUsesSection, ctnTypeDefinition,
                                    ctnClass, ctnRecordType, ctnObject]) then
            SyncTreeNode := SyncTreeNode.FirstChild
          else if Assigned(SyncTreeNode.NextBrother) then
            SyncTreeNode := SyncTreeNode.NextBrother
          else
          begin
            // Pop up until a node with a next sibling
            SyncTreeNode := SyncTreeNode.Parent;
            while Assigned(SyncTreeNode) and not Assigned(SyncTreeNode.NextBrother) do
              SyncTreeNode := SyncTreeNode.Parent;
            if Assigned(SyncTreeNode) then
              SyncTreeNode := SyncTreeNode.NextBrother;
          end;
        end;
        FSyncResult := SyncOutline.AsJSON;
      finally
        SyncOutline.Free;
      end;
    end

    else if FSyncToolName = 'find_all_references' then
    begin
      if not Assigned(FSyncParams) then
      begin
        FSyncError := True; FSyncResult := 'Missing params'; Exit;
      end;
      SyncFilePath := FSyncParams.Get('file', '');
      SyncNewX     := FSyncParams.Get('col',  0);
      SyncNewY     := FSyncParams.Get('line', 0);
      if SyncFilePath = '' then
      begin
        FSyncError := True; FSyncResult := 'file argument required'; Exit;
      end;
      SyncCodeBuf := CodeToolBoss.LoadFile(SyncFilePath, False, False);
      if not Assigned(SyncCodeBuf) then
      begin
        FSyncError := True; FSyncResult := 'Could not load: ' + SyncFilePath; Exit;
      end;
      SyncFileListJ := TJSONArray(GetJSON(FSyncFileList));
      SyncFileNames := TStringList.Create;
      SyncRefTree   := nil;
      try
        for J := 0 to SyncFileListJ.Count - 1 do
          SyncFileNames.Add(SyncFileListJ.Strings[J]);
        SyncDeclPt := Point(SyncNewX, SyncNewY);
        if not CodeToolBoss.FindReferencesInFiles(SyncFileNames, SyncCodeBuf,
               SyncDeclPt, False, SyncRefTree) then
        begin
          FSyncError := True;
          FSyncResult := 'FindReferences failed: ' + CodeToolBoss.ErrorMessage;
          Exit;
        end;
        SyncRefArr := TJSONArray.Create;
        try
          if Assigned(SyncRefTree) then
          begin
            SyncRefNode := SyncRefTree.FindLowest;
            while Assigned(SyncRefNode) do
            begin
              SyncRefPos := PCodeXYPosition(SyncRefNode.Data);
              SyncRefObj := TJSONObject.Create;
              SyncRefObj.Add('file', SyncRefPos^.Code.Filename);
              SyncRefObj.Add('line', SyncRefPos^.Y);
              SyncRefObj.Add('col',  SyncRefPos^.X);
              SyncRefArr.Add(SyncRefObj);
              SyncRefNode := SyncRefNode.Successor;
            end;
          end;
          FSyncResult := SyncRefArr.AsJSON;
        finally
          SyncRefArr.Free;
        end;
      finally
        SyncFileNames.Free;
        SyncFileListJ.Free;
        if Assigned(SyncRefTree) then
          CodeToolBoss.FreeTreeOfPCodeXYPosition(SyncRefTree);
      end;
    end

    else if FSyncToolName = 'rename_identifier' then
    begin
      if not Assigned(FSyncParams) then
      begin
        FSyncError := True; FSyncResult := 'Missing params'; Exit;
      end;
      SyncFilePath := FSyncParams.Get('file',     '');
      SyncNewX     := FSyncParams.Get('col',       0);
      SyncNewY     := FSyncParams.Get('line',      0);
      SyncNewName  := FSyncParams.Get('new_name', '');
      if (SyncFilePath = '') or (SyncNewName = '') then
      begin
        FSyncError := True; FSyncResult := 'file and new_name required'; Exit;
      end;
      SyncCodeBuf := CodeToolBoss.LoadFile(SyncFilePath, False, False);
      if not Assigned(SyncCodeBuf) then
      begin
        FSyncError := True; FSyncResult := 'Could not load: ' + SyncFilePath; Exit;
      end;
      // Extract old identifier name directly from source line
      SyncSnippet := SyncCodeBuf.GetLine(SyncNewY - 1, False);
      I := SyncNewX;
      while (I > 1) and (SyncSnippet[I - 1] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
        Dec(I);
      SyncSymbol := '';
      while (I <= Length(SyncSnippet)) and (SyncSnippet[I] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
      begin
        SyncSymbol := SyncSymbol + SyncSnippet[I];
        Inc(I);
      end;
      if SyncSymbol = '' then
      begin
        FSyncError := True; FSyncResult := 'No identifier at line ' + IntToStr(SyncNewY) + ' col ' + IntToStr(SyncNewX); Exit;
      end;
      SyncFileListJ := TJSONArray(GetJSON(FSyncFileList));
      SyncFileNames := TStringList.Create;
      SyncRefTree   := nil;
      try
        for J := 0 to SyncFileListJ.Count - 1 do
          SyncFileNames.Add(SyncFileListJ.Strings[J]);
        SyncDeclPt := Point(SyncNewX, SyncNewY);
        if not CodeToolBoss.FindReferencesInFiles(SyncFileNames, SyncCodeBuf,
               SyncDeclPt, False, SyncRefTree) then
        begin
          FSyncError := True;
          FSyncResult := 'FindReferences failed: ' + CodeToolBoss.ErrorMessage;
          Exit;
        end;
        if not CodeToolBoss.RenameIdentifier(SyncRefTree, SyncSymbol, SyncNewName,
               SyncCodeBuf, @SyncDeclPt, False) then
        begin
          FSyncError := True;
          FSyncResult := 'RenameIdentifier failed: ' + CodeToolBoss.ErrorMessage;
          Exit;
        end;
        if not CodeToolBoss.ApplyChanges then
        begin
          FSyncError := True; FSyncResult := 'ApplyChanges failed'; Exit;
        end;
        // Save modified buffers and reload any open editors
        SyncRefArr := TJSONArray.Create;
        try
          for J := 0 to SyncFileNames.Count - 1 do
          begin
            SyncNewCode := CodeToolBoss.SourceCache.FindFile(SyncFileNames[J]);
            if Assigned(SyncNewCode) and SyncNewCode.Modified then
            begin
              SyncNewCode.Save;
              LazarusIDE.DoRevertEditorFile(SyncNewCode.Filename);
              SyncRefArr.Add(SyncNewCode.Filename);
            end;
          end;
          Obj := TJSONObject.Create;
          try
            Obj.Add('renamed_to',    SyncNewName);
            Obj.Add('files_changed', SyncRefArr.Count);
            Obj.Add('files',         SyncRefArr.Clone as TJSONArray);
            FSyncResult := Obj.AsJSON;
          finally
            Obj.Free;
          end;
        finally
          SyncRefArr.Free;
        end;
      finally
        SyncFileNames.Free;
        SyncFileListJ.Free;
        if Assigned(SyncRefTree) then
          CodeToolBoss.FreeTreeOfPCodeXYPosition(SyncRefTree);
      end;
    end

    else if FSyncToolName = 'get_project_settings' then
    begin
      Obj := TJSONObject.Create;
      try
        if Assigned(LazarusIDE) and Assigned(LazarusIDE.ActiveProject) then
        begin
          Proj := LazarusIDE.ActiveProject;
          Obj.Add('project_file',    Proj.ProjectInfoFile);
          Obj.Add('target_os_cpu',   LazarusIDE.GetFPCFrontEndOptions);
          if Assigned(Proj.LazCompilerOptions) then
          begin
            Obj.Add('custom_options',
              Proj.LazCompilerOptions.CustomOptions);
            Obj.Add('output_dir',
              Proj.LazCompilerOptions.UnitOutputDirectory);
            Obj.Add('target_os',
              Proj.LazCompilerOptions.TargetOS);
          end;
        end else
          Obj.Add('error', 'No active project');
        FSyncResult := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    end

    else if FSyncToolName = 'rebuild_ide' then
    begin
      SyncFilePath := '';
      if Assigned(FSyncParams) then
        SyncFilePath := FSyncParams.Get('lpk_path', '');
      // Build response before InstallPackages — IDE may exit immediately after.
      Obj := TJSONObject.Create;
      try
        Obj.Add('status',  'rebuilding');
        Obj.Add('message', 'IDE is rebuilding and will restart. Poll with the ' +
                           'command in poll_command until it succeeds.');
        SyncPollExe := ExtractFilePath(LazarusIDE.GetFPCompilerFilename) +
                       'instantfpc' + GetExeExt;
        if SyncFilePath <> '' then
          SyncPasFile := ExtractFilePath(ExcludeTrailingPathDelimiter(
                           ExtractFilePath(SyncFilePath))) + 'wait_for_restart.pas'
        else
        begin
          // No lpk_path — find wait_for_restart.pas via the installed package.
          SyncIDEPkg := PackageEditingInterface.FindPackageWithName('LazMcpAssistant');
          if Assigned(SyncIDEPkg) then
            SyncPasFile := ExtractFilePath(ExcludeTrailingPathDelimiter(
                             ExtractFilePath(SyncIDEPkg.Filename))) + 'wait_for_restart.pas'
          else
            SyncPasFile := '';
        end;
        if SyncPasFile <> '' then
        begin
          {$IFDEF WINDOWS}
          Obj.Add('poll_command',
            'cmd /c "SET PATH=' +
            ExcludeTrailingPathDelimiter(ExtractFilePath(LazarusIDE.GetFPCompilerFilename)) +
            ';%PATH% && "' + SyncPollExe + '" "' + SyncPasFile + '""');
          {$ELSE}
          Obj.Add('poll_command',
            'sh -c ''PATH="' +
            ExcludeTrailingPathDelimiter(ExtractFilePath(LazarusIDE.GetFPCompilerFilename)) +
            ':$PATH" "' + SyncPollExe + '" "' + SyncPasFile + '"''');
          {$ENDIF}
        end;
        FSyncResult          := Obj.AsJSON;
        FSyncConnectionClose := True;
      finally
        Obj.Free;
      end;
      // Close all open source editors — prevents blocking dialog during rebuild.
      while SourceEditorManagerIntf.UniqueSourceEditorCount > 0 do
        LazarusIDE.DoCloseEditorFile(
          SourceEditorManagerIntf.UniqueSourceEditors[0], [cfQuiet]);
      // Release the listening socket now so the new IDE can bind the same port.
      // The server thread is blocked in Synchronize and won't call Accept again
      // until after this block returns; Active := False closes the OS socket
      // cleanly before InstallPackages exits the process.
      StopServer;
      // Build the install list and trigger rebuild.
      SyncPkgList := TObjectList.Create(True);
      try
        if SyncFilePath <> '' then
        begin
          PackageEditingInterface.DoOpenPackageFile(SyncFilePath, [pofDoNotOpenEditor], False);
          SyncIDEPkg := PackageEditingInterface.FindPackageWithName(
                          ExtractFileNameOnly(SyncFilePath));
          if Assigned(SyncIDEPkg) then
          begin
            SyncPkgID := TLazPackageID.Create;
            SyncPkgID.AssignID(SyncIDEPkg);
            SyncPkgList.Add(SyncPkgID);
          end;
        end;
        // Empty list = rebuild with currently installed packages.
        PackageEditingInterface.InstallPackages(SyncPkgList, [piiifRebuildIDE, piiifSkipChecks, piiifQuiet]);
      finally
        SyncPkgList.Free;
      end;
    end

    else if FSyncToolName = 'set_cursor_position' then
    begin
      if not Assigned(FSyncParams) then
      begin
        FSyncError := True; FSyncResult := 'line and col required'; Exit;
      end;
      SyncNewY := FSyncParams.Get('line', 0);
      SyncNewX := FSyncParams.Get('col',  0);
      if (SyncNewY < 1) or (SyncNewX < 1) then
      begin
        FSyncError := True; FSyncResult := 'line and col must be >= 1'; Exit;
      end;
      SyncFilePath := FSyncParams.Get('file', '');
      if SyncFilePath <> '' then
      begin
        SyncDeclPt := Point(SyncNewX, SyncNewY);
        if LazarusIDE.DoOpenFileAndJumpToPos(SyncFilePath, SyncDeclPt,
             SyncNewY, -1, -1, [ofOnlyIfExists, ofRegularFile]) <> mrOK then
        begin
          FSyncError := True; FSyncResult := 'Could not open: ' + SyncFilePath; Exit;
        end;
        Ed := SourceEditorManagerIntf.ActiveEditor;
      end
      else
      begin
        Ed := SourceEditorManagerIntf.ActiveEditor;
        if not Assigned(Ed) then
        begin
          FSyncError := True; FSyncResult := 'No active editor'; Exit;
        end;
        Ed.CursorTextXY := Point(SyncNewX, SyncNewY);
      end;
      Obj := TJSONObject.Create;
      try
        Obj.Add('file', Ed.FileName);
        Obj.Add('line', SyncNewY);
        Obj.Add('col',  SyncNewX);
        FSyncResult := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    end

    else if FSyncToolName = 'replace_text' then
    begin
      if not Assigned(FSyncParams) then
      begin
        FSyncError := True; FSyncResult := 'start_line, start_col, end_line, end_col, new_text required'; Exit;
      end;
      SyncNewY   := FSyncParams.Get('start_line', 0);
      SyncNewX   := FSyncParams.Get('start_col',  0);
      SyncNewTopLine := FSyncParams.Get('end_line', 0);
      J              := FSyncParams.Get('end_col',  0);
      if (SyncNewY < 1) or (SyncNewX < 1) or (SyncNewTopLine < 1) or (J < 1) then
      begin
        FSyncError := True; FSyncResult := 'start_line, start_col, end_line, end_col must be >= 1'; Exit;
      end;
      SyncFilePath := FSyncParams.Get('file', '');
      if SyncFilePath <> '' then
      begin
        Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(SyncFilePath);
        if not Assigned(Ed) then
        begin
          if LazarusIDE.DoOpenEditorFile(SyncFilePath, -1, -1,
               [ofOnlyIfExists, ofRegularFile]) <> mrOK then
          begin
            FSyncError := True; FSyncResult := 'Could not open: ' + SyncFilePath; Exit;
          end;
          Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(SyncFilePath);
        end;
      end
      else
        Ed := SourceEditorManagerIntf.ActiveEditor;
      if not Assigned(Ed) then
      begin
        FSyncError := True; FSyncResult := 'No active editor'; Exit;
      end;
      SyncNewName  := FSyncParams.Get('new_text', '');
      SyncDeclPt   := Point(SyncNewX, SyncNewY);
      Ed.ReplaceText(SyncDeclPt, Point(J, SyncNewTopLine), SyncNewName);
      Obj := TJSONObject.Create;
      try
        Obj.Add('file', Ed.FileName);
        Obj.Add('replaced', True);
        FSyncResult := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    end

    else if FSyncToolName = 'get_package_info' then
    begin
      if not Assigned(FSyncParams) or (FSyncParams.Get('package_name', '') = '') then
      begin
        FSyncError := True; FSyncResult := 'package_name required'; Exit;
      end;
      SyncSymbol := FSyncParams.Get('package_name', '');
      SyncIDEPkg := PackageEditingInterface.IsPackageInstalled(SyncSymbol);
      Obj := TJSONObject.Create;
      try
        Obj.Add('package_name', SyncSymbol);
        Obj.Add('is_installed', Assigned(SyncIDEPkg));
        if Assigned(SyncIDEPkg) then
          Obj.Add('package_file', SyncIDEPkg.Filename);
        SyncIDEPkg2 := PackageEditingInterface.FindPackageWithName(SyncSymbol);
        Obj.Add('is_loaded', Assigned(SyncIDEPkg2));
        if Assigned(SyncIDEPkg2) then
          Obj.Add('loaded_file', SyncIDEPkg2.Filename);
        FSyncResult := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    end

    else if FSyncToolName = 'save_file' then
    begin
      SyncFilePath := '';
      if Assigned(FSyncParams) then
        SyncFilePath := FSyncParams.Get('file', '');
      if SyncFilePath <> '' then
      begin
        if LazarusIDE.DoSaveEditorFile(SyncFilePath, []) <> mrOK then
        begin
          FSyncError := True; FSyncResult := 'Save failed: ' + SyncFilePath; Exit;
        end;
      end
      else
      begin
        Ed := SourceEditorManagerIntf.ActiveEditor;
        if not Assigned(Ed) then
        begin
          FSyncError := True; FSyncResult := 'No active editor'; Exit;
        end;
        if LazarusIDE.DoSaveEditorFile(Ed, []) <> mrOK then
        begin
          FSyncError := True; FSyncResult := 'Save failed'; Exit;
        end;
        SyncFilePath := Ed.FileName;
      end;
      Obj := TJSONObject.Create;
      try
        Obj.Add('file',  SyncFilePath);
        Obj.Add('saved', True);
        FSyncResult := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    end

    else if FSyncToolName = 'goto_declaration' then
    begin
      if not Assigned(FSyncParams) then
      begin
        FSyncError := True; FSyncResult := 'symbol and file required'; Exit;
      end;
      SyncSymbol   := FSyncParams.Get('symbol', '');
      SyncFilePath := FSyncParams.Get('file',   '');
      if (SyncSymbol = '') or (SyncFilePath = '') then
      begin
        FSyncError := True; FSyncResult := 'symbol and file required'; Exit;
      end;
      SyncCodeBuf := CodeToolBoss.LoadFile(SyncFilePath, False, False);
      if not Assigned(SyncCodeBuf) then
      begin
        FSyncError := True; FSyncResult := 'Could not load file: ' + SyncFilePath; Exit;
      end;
      if not CodeToolBoss.FindDeclarationInInterface(SyncCodeBuf, SyncSymbol,
               SyncNewCode, SyncNewX, SyncNewY, SyncNewTopLine) then
      begin
        FSyncError  := True;
        FSyncResult := 'Declaration not found for: ' + SyncSymbol +
                       ' (' + CodeToolBoss.ErrorMessage + ')';
        Exit;
      end;
      SyncDeclPt := Point(SyncNewX, SyncNewY);
      if LazarusIDE.DoOpenFileAndJumpToPos(SyncNewCode.Filename, SyncDeclPt,
           SyncNewTopLine, -1, -1, [ofOnlyIfExists, ofRegularFile]) <> mrOK then
      begin
        FSyncError := True; FSyncResult := 'Could not open: ' + SyncNewCode.Filename; Exit;
      end;
      Obj := TJSONObject.Create;
      try
        Obj.Add('declaration_file', SyncNewCode.Filename);
        Obj.Add('line', SyncNewY);
        Obj.Add('col',  SyncNewX);
        if SyncNewY >= 1 then
          Obj.Add('context', Trim(SyncNewCode.GetLine(SyncNewY - 1, False)));
        FSyncResult := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    end

    else if FSyncToolName = 'close_file' then
    begin
      SyncFilePath := '';
      if Assigned(FSyncParams) then
        SyncFilePath := FSyncParams.Get('file', '');
      if SyncFilePath <> '' then
      begin
        if LazarusIDE.DoCloseEditorFile(SyncFilePath, [cfQuiet]) <> mrOK then
        begin
          FSyncError := True; FSyncResult := 'Close failed: ' + SyncFilePath; Exit;
        end;
      end
      else
      begin
        Ed := SourceEditorManagerIntf.ActiveEditor;
        if not Assigned(Ed) then
        begin
          FSyncError := True; FSyncResult := 'No active editor'; Exit;
        end;
        SyncFilePath := Ed.FileName;
        if LazarusIDE.DoCloseEditorFile(Ed, [cfQuiet]) <> mrOK then
        begin
          FSyncError := True; FSyncResult := 'Close failed'; Exit;
        end;
      end;
      Obj := TJSONObject.Create;
      try
        Obj.Add('file',   SyncFilePath);
        Obj.Add('closed', True);
        FSyncResult := Obj.AsJSON;
      finally
        Obj.Free;
      end;
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
