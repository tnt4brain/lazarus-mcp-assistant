{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpGitServe;

{ A read-only git server for one peer machine (ADR-035, the local part).

  Smart HTTP, served by git itself: GET <repo>.git/info/refs?service=git-upload-pack and
  POST <repo>.git/git-upload-pack, each answered by one `git upload-pack --stateless-rpc`
  child.  Nothing else is understood.  The listener
    - sits on the one local address that routes to the peer, on a port the OS picks (or a
      port a link has kept);
    - closes at once every connection that does not come from the peer address;
    - wants HTTP Basic with user 'mcp' and a TOTP code (RFC 6238) as the password, the code
      made from a key given at creation (a link's key, or one derived from a session token);
    - stops after its minutes, after the fetches it was told to serve, or on Stop;
    - after 5 wrong codes in a minute refuses everybody for 5 minutes.
  No IDE unit is used here, so the test project builds it. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, sockets;

{ HMAC-SHA1 (RFC 2104); raw bytes in and out. }
function McpHmacSha1(const AKey, AMsg: string): string;

{ TOTP (RFC 6238, HMAC-SHA1) of the 30-second-step (AStepS) counter holding AUnixTime. }
function McpTotp(const AKey: string; AUnixTime: Int64; ADigits: Integer = 6;
  AStepS: Integer = 30): string;

{ The key of a server started by a caller holding ABearer: HMAC-SHA1 of the token with
  the fixed message 'git-serve'.  The code never reveals the token. }
function McpServeKey(const ABearer: string): string;

{ A free TCP port on ALocal (bind to 0, read it, close); 0 when none. }
function McpPickPort(const ALocal: string): Word;

{ The local IPv4 address the system would use to reach APeer (a dotted address);
  False, with AWhy, when APeer is not one or there is no route. }
function McpLocalAddressFor(const APeer: string; out ALocal, AWhy: string): Boolean;

type
  TGitServe = class
  private
    FGitExe, FRepoDir, FPeer, FHost : string;
    FKey       : string;
    FPort      : Word;
    FListen    : TSocket;
    FEndTick   : QWord;
    FStopping  : Boolean;
    FLockUntil : QWord;
    FBadTicks  : array of QWord;
    FActive    : LongInt;
    FServed    : LongInt;
    FWrong     : LongInt;
    FFetchesLeft : LongInt;
    FFetchLimit  : LongInt;
    FLock      : TCriticalSection;
    FConns     : TList;
    FThread    : TThread;
    function  GetRunning: Boolean;
    procedure Track(ASock: TSocket; AAdd: Boolean);
    function  CheckAuth(const AHeader: string): Boolean;
    function  Locked: Boolean;
    procedure NoteWrong;
    function  Expired: Boolean;
  public
    constructor Create(const AGitExe, ARepoDir, APeer, AKey: string);
    destructor Destroy; override;
    { AMinutes: how long the listener stays up; APort 0 = the OS picks one. }
    function  Start(AMinutes: Integer; out AWhy: string; APort: Word = 0): Boolean;
    procedure Stop;
    { From a connection: close the listener now, without joining (the accept thread ends itself). }
    procedure RequestStop;
    { The code that is good now, and the seconds it has left. }
    function  Code(out ASecondsLeft: Integer): string;
    function  SecondsLeft: Integer;
    property  Running : Boolean read GetRunning;
    property  Host    : string  read FHost;
    property  Port    : Word    read FPort;
    property  Peer    : string  read FPeer;
    property  RepoDir : string  read FRepoDir;
    property  Key     : string  read FKey;
    property  Served  : LongInt read FServed;   { fetches answered }
    property  Wrong   : LongInt read FWrong;    { wrong codes seen }
    { The listener closes itself after this many answered fetches (0 = no limit); set before Start. }
    property  FetchLimit : LongInt read FFetchLimit write FFetchLimit;
  end;

var
  { Seconds since 1970 (UTC); a test can replace it. }
  GServeClock : function: Int64 = nil;

implementation

uses
  sha1, base64, Process, zstream, McpTokens;

const
  MAX_CONNS        = 2;
  MAX_HEADER       = 16384;
  MAX_BODY         = 64 * 1024 * 1024;
  REQUEST_MS       = 10 * 60 * 1000;
  WRONG_LIMIT      = 5;
  WRONG_WINDOW_MS  = 60 * 1000;
  LOCK_MS          = 5 * 60 * 1000;
  RECV_TIMEOUT_MS  = 30 * 1000;
  REPO_PATH        = '/repo.git';
  {$IFDEF WINDOWS}
  OPT_RCVTIMEO = $1006;
  OPT_SNDTIMEO = $1005;
  {$ELSE}
  OPT_RCVTIMEO = 20;
  OPT_SNDTIMEO = 21;
  {$ENDIF}

{ ── HMAC and TOTP ────────────────────────────────────────────────────────── }

function Sha1Raw(const S: string): string;
var
  D : TSHA1Digest;
begin
  D := SHA1String(S);
  SetLength(Result, 20);
  Move(D, Result[1], 20);
end;

function McpHmacSha1(const AKey, AMsg: string): string;
var
  K, Ipad, Opad : string;
  I : Integer;
begin
  K := AKey;
  if Length(K) > 64 then K := Sha1Raw(K);
  K := K + StringOfChar(#0, 64 - Length(K));
  SetLength(Ipad, 64);
  SetLength(Opad, 64);
  for I := 1 to 64 do
  begin
    Ipad[I] := Chr(Ord(K[I]) xor $36);
    Opad[I] := Chr(Ord(K[I]) xor $5C);
  end;
  Result := Sha1Raw(Opad + Sha1Raw(Ipad + AMsg));
end;

function McpTotp(const AKey: string; AUnixTime: Int64; ADigits: Integer; AStepS: Integer): string;
var
  Counter : Int64;
  Msg, H  : string;
  I, Off  : Integer;
  Bin, Modulus : QWord;
begin
  Counter := AUnixTime div AStepS;
  SetLength(Msg, 8);
  for I := 8 downto 1 do
  begin
    Msg[I]  := Chr(Counter and $FF);
    Counter := Counter shr 8;
  end;
  H   := McpHmacSha1(AKey, Msg);
  Off := Ord(H[20]) and $0F;
  Bin := (QWord(Ord(H[Off + 1]) and $7F) shl 24) or (QWord(Ord(H[Off + 2])) shl 16) or
         (QWord(Ord(H[Off + 3])) shl 8) or QWord(Ord(H[Off + 4]));
  Modulus := 1;
  for I := 1 to ADigits do Modulus := Modulus * 10;
  Result := IntToStr(Bin mod Modulus);
  while Length(Result) < ADigits do Result := '0' + Result;
end;

function McpServeKey(const ABearer: string): string;
begin
  Result := McpHmacSha1(ABearer, 'git-serve');
end;

function Now_: Int64;
begin
  if Assigned(GServeClock) then
    Result := GServeClock()
  else
    Result := McpUnixNow;
end;

{ ── Sockets ──────────────────────────────────────────────────────────────── }

procedure SetTimeouts(ASock: TSocket; AMs: Integer);
{$IFDEF WINDOWS}
var
  V : LongInt;
begin
  V := AMs;
  fpsetsockopt(ASock, SOL_SOCKET, OPT_RCVTIMEO, @V, SizeOf(V));
  fpsetsockopt(ASock, SOL_SOCKET, OPT_SNDTIMEO, @V, SizeOf(V));
end;
{$ELSE}
var
  T : TTimeVal;
begin
  T.tv_sec  := AMs div 1000;
  T.tv_usec := (AMs mod 1000) * 1000;
  fpsetsockopt(ASock, SOL_SOCKET, OPT_RCVTIMEO, @T, SizeOf(T));
  fpsetsockopt(ASock, SOL_SOCKET, OPT_SNDTIMEO, @T, SizeOf(T));
end;
{$ENDIF}

procedure CloseSock(ASock: TSocket);
begin
  fpshutdown(ASock, 2);
  CloseSocket(ASock);
end;

function ParseIPv4(const S: string; out A: TInetSockAddr): Boolean;
var
  Addr : in_addr;
  Parts : TStringList;
  I, V  : Integer;
begin
  Result := False;
  Parts := TStringList.Create;
  try
    Parts.Delimiter := '.';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := S;
    if Parts.Count <> 4 then Exit;
    for I := 0 to 3 do
    begin
      if not TryStrToInt(Parts[I], V) or (V < 0) or (V > 255) or (Parts[I] = '') or
         (Length(Parts[I]) > 3) then Exit;
    end;
  finally
    Parts.Free;
  end;
  Addr := StrToNetAddr(S);
  FillChar(A, SizeOf(A), 0);
  A.sin_family := AF_INET;
  A.sin_addr   := Addr;
  Result := True;
end;

function McpLocalAddressFor(const APeer: string; out ALocal, AWhy: string): Boolean;
var
  S    : TSocket;
  Peer, Mine : TInetSockAddr;
  Len  : TSockLen;
begin
  Result := False;
  ALocal := '';
  if not ParseIPv4(APeer, Peer) then
  begin
    AWhy := 'peer must be an IPv4 address such as 192.168.1.228, not "' + APeer + '".';
    Exit;
  end;
  Peer.sin_port := htons(9);
  S := fpsocket(AF_INET, SOCK_DGRAM, 0);
  if S = TSocket(-1) then
  begin
    AWhy := 'No socket could be made.';
    Exit;
  end;
  try
    { a UDP connect sends nothing; it only makes the system choose the route }
    if fpconnect(S, @Peer, SizeOf(Peer)) <> 0 then
    begin
      AWhy := 'There is no route from this machine to ' + APeer + '.';
      Exit;
    end;
    Len := SizeOf(Mine);
    FillChar(Mine, SizeOf(Mine), 0);
    if fpgetsockname(S, @Mine, @Len) <> 0 then
    begin
      AWhy := 'The local address for ' + APeer + ' could not be found.';
      Exit;
    end;
    ALocal := NetAddrToStr(Mine.sin_addr);
    Result := True;
  finally
    CloseSocket(S);
  end;
end;

function McpPickPort(const ALocal: string): Word;
var
  S    : TSocket;
  Addr : TInetSockAddr;
  Len  : TSockLen;
begin
  Result := 0;
  if not ParseIPv4(ALocal, Addr) then Exit;
  Addr.sin_port := 0;
  S := fpsocket(AF_INET, SOCK_STREAM, 0);
  if S = TSocket(-1) then Exit;
  try
    if fpbind(S, @Addr, SizeOf(Addr)) <> 0 then Exit;
    Len := SizeOf(Addr);
    if fpgetsockname(S, @Addr, @Len) = 0 then
      Result := ntohs(Addr.sin_port);
  finally
    CloseSocket(S);
  end;
end;

{ ── One connection ───────────────────────────────────────────────────────── }

type
  TConnThread = class(TThread)
  private
    FOwner  : TGitServe;
    FSock   : TSocket;
    FBuf    : string;
    FDeadline : QWord;
    FHeaders  : TStringList;
    function  Fill: Boolean;
    function  ReadHead(out AHead: string): Boolean;
    function  ReadLine(out ALine: string): Boolean;
    function  ReadCount(ACount: Integer; out AData: string): Boolean;
    function  ReadBody(out ABody: string): Boolean;
    function  Gunzip(const AData: string; out AOut: string): Boolean;
    procedure SendAll(const S: string);
    procedure Respond(ACode: Integer; const AReason: string; const AExtra: string = '');
    { True when the answer carried a packfile: that is a fetch, whatever the protocol version }
    function  UploadPack(AAdvertise, AV2: Boolean; const ABody: string): Boolean;
    procedure Handle;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TGitServe; ASock: TSocket);
    destructor Destroy; override;
  end;

constructor TConnThread.Create(AOwner: TGitServe; ASock: TSocket);
begin
  FOwner := AOwner;
  FSock  := ASock;
  FHeaders := TStringList.Create;
  FHeaders.NameValueSeparator := ':';
  FreeOnTerminate := True;
  inherited Create(False);
end;

destructor TConnThread.Destroy;
begin
  FHeaders.Free;
  inherited Destroy;
end;

function TConnThread.Fill: Boolean;
var
  Tmp : array[0..8191] of Byte;
  N   : LongInt;
  Chunk : string;
begin
  Result := False;
  if FOwner.FStopping or (GetTickCount64 > FDeadline) then Exit;
  N := fprecv(FSock, @Tmp, SizeOf(Tmp), 0);
  if N <= 0 then Exit;
  SetString(Chunk, PChar(@Tmp), N);
  FBuf := FBuf + Chunk;
  Result := True;
end;

function TConnThread.ReadHead(out AHead: string): Boolean;
var
  P : Integer;
begin
  Result := False;
  AHead  := '';
  repeat
    P := Pos(#13#10#13#10, FBuf);
    if P > 0 then
    begin
      AHead := Copy(FBuf, 1, P - 1);
      Delete(FBuf, 1, P + 3);
      Exit(True);
    end;
    if Length(FBuf) > MAX_HEADER then Exit;
  until not Fill;
end;

function TConnThread.ReadLine(out ALine: string): Boolean;
var
  P : Integer;
begin
  Result := False;
  ALine  := '';
  repeat
    P := Pos(#13#10, FBuf);
    if P > 0 then
    begin
      ALine := Copy(FBuf, 1, P - 1);
      Delete(FBuf, 1, P + 1);
      Exit(True);
    end;
    if Length(FBuf) > MAX_HEADER then Exit;
  until not Fill;
end;

function TConnThread.ReadCount(ACount: Integer; out AData: string): Boolean;
begin
  Result := False;
  AData  := '';
  while Length(FBuf) < ACount do
    if not Fill then Exit;
  AData := Copy(FBuf, 1, ACount);
  Delete(FBuf, 1, ACount);
  Result := True;
end;

function TConnThread.ReadBody(out ABody: string): Boolean;
var
  Len, Size : Integer;
  Line, Part, Crlf : string;
begin
  Result := False;
  ABody  := '';
  if Pos('chunked', LowerCase(FHeaders.Values['transfer-encoding'])) > 0 then
  begin
    repeat
      if not ReadLine(Line) then Exit;
      Line := Trim(Line);
      if Pos(';', Line) > 0 then Line := Copy(Line, 1, Pos(';', Line) - 1);
      Size := StrToIntDef('$' + Line, -1);
      if Size < 0 then Exit;
      if Length(ABody) + Size > MAX_BODY then Exit;
      if Size > 0 then
      begin
        if not ReadCount(Size, Part) then Exit;
        ABody := ABody + Part;
      end;
      if not ReadCount(2, Crlf) then Exit;
    until Size = 0;
    Exit(True);
  end;
  Len := StrToIntDef(Trim(FHeaders.Values['content-length']), 0);
  if (Len < 0) or (Len > MAX_BODY) then Exit;
  if Len = 0 then Exit(True);
  Result := ReadCount(Len, ABody);
end;

{ A gzip body: the 10-byte header git writes, then raw deflate. }
function TConnThread.Gunzip(const AData: string; out AOut: string): Boolean;
var
  Src : TMemoryStream;
  Dec : TDecompressionStream;
  Buf : array[0..16383] of Byte;
  N   : Integer;
  Chunk : string;
begin
  Result := False;
  AOut   := '';
  if (Length(AData) < 18) or (AData[1] <> #$1F) or (AData[2] <> #$8B) or
     (Ord(AData[4]) <> 0) then Exit;
  Src := TMemoryStream.Create;
  try
    Src.Write(AData[11], Length(AData) - 10);
    Src.Position := 0;
    Dec := TDecompressionStream.Create(Src, True);
    try
      try
        repeat
          N := Dec.Read(Buf, SizeOf(Buf));
          if N > 0 then
          begin
            SetString(Chunk, PChar(@Buf), N);
            AOut := AOut + Chunk;
            if Length(AOut) > MAX_BODY then Exit;
          end;
        until N <= 0;
        Result := True;
      except
        Result := False;
      end;
    finally
      Dec.Free;
    end;
  finally
    Src.Free;
  end;
end;

procedure TConnThread.SendAll(const S: string);
var
  Sent, N : LongInt;
begin
  Sent := 0;
  while Sent < Length(S) do
  begin
    if FOwner.FStopping then Exit;
    N := fpsend(FSock, @S[Sent + 1], Length(S) - Sent, 0);
    if N <= 0 then Exit;
    Inc(Sent, N);
  end;
end;

procedure TConnThread.Respond(ACode: Integer; const AReason: string; const AExtra: string);
begin
  SendAll('HTTP/1.1 ' + IntToStr(ACode) + ' ' + AReason + #13#10 +
    'Content-Length: 0' + #13#10 + AExtra + 'Connection: close' + #13#10#13#10);
end;

function TConnThread.UploadPack(AAdvertise, AV2: Boolean; const ABody: string): Boolean;
var
  Proc  : TProcess;
  I, N  : Integer;
  Buf   : array[0..16383] of Byte;
  Chunk, Ctype, Proto, Tail : string;
  Started : QWord;
begin
  Result := False;
  Tail := '';
  Started := GetTickCount64;
  Proc := TProcess.Create(nil);
  try
    Proc.Executable := FOwner.FGitExe;
    Proc.Parameters.Add('upload-pack');
    Proc.Parameters.Add('--stateless-rpc');
    if AAdvertise then Proc.Parameters.Add('--advertise-refs');
    Proc.Parameters.Add(FOwner.FRepoDir);
    Proc.Options := [poUsePipes, poNoConsole];
    Proc.ShowWindow := swoHide;
    for I := 1 to GetEnvironmentVariableCount do
      Proc.Environment.Add(GetEnvironmentString(I));
    Proc.Environment.Values['GIT_TERMINAL_PROMPT'] := '0';
    Proto := Trim(FHeaders.Values['git-protocol']);
    for I := 1 to Length(Proto) do
      if not (Proto[I] in ['a'..'z', '0'..'9', '=', ':', ',', '-', '_', '.']) then
      begin
        Proto := '';
        Break;
      end;
    if Proto <> '' then
      Proc.Environment.Values['GIT_PROTOCOL'] := Proto;
    Proc.Execute;
    if ABody <> '' then
      Proc.Input.Write(ABody[1], Length(ABody));
    Proc.CloseInput;

    if AAdvertise then Ctype := 'application/x-git-upload-pack-advertisement'
    else Ctype := 'application/x-git-upload-pack-result';
    SendAll('HTTP/1.1 200 OK' + #13#10 + 'Content-Type: ' + Ctype + #13#10 +
      'Cache-Control: no-cache' + #13#10 + 'Connection: close' + #13#10#13#10);
    if AAdvertise and not AV2 then
      SendAll('001e# service=git-upload-pack' + #10 + '0000');

    while True do
    begin
      if FOwner.FStopping or (GetTickCount64 - Started > REQUEST_MS) then
      begin
        Proc.Terminate(1);
        Break;
      end;
      N := Proc.Output.NumBytesAvailable;
      if N > 0 then
      begin
        if N > SizeOf(Buf) then N := SizeOf(Buf);
        N := Proc.Output.Read(Buf, N);
        if N <= 0 then Break;
        SetString(Chunk, PChar(@Buf), N);
        { "packfile" (protocol 2) or "PACK" (older): the objects went out }
        if not Result then
        begin
          Tail := Tail + Chunk;
          if (Pos('packfile', Tail) > 0) or (Pos('PACK', Tail) > 0) then
            Result := True
          else
            Tail := Copy(Tail, Length(Tail) - 7, 8);
        end;
        SendAll(Chunk);
      end
      else if not Proc.Running then
        Break
      else
        Sleep(5);
      while Proc.Stderr.NumBytesAvailable > 0 do
        if Proc.Stderr.Read(Buf, SizeOf(Buf)) <= 0 then Break;
    end;
    Proc.WaitOnExit;
  finally
    Proc.Free;
  end;
end;

procedure TConnThread.Handle;
var
  Head, Line, Method, Path, Body, Plain : string;
  Lines : TStringList;
  P : Integer;
  V2 : Boolean;
begin
  FDeadline := GetTickCount64 + REQUEST_MS;
  if not ReadHead(Head) then Exit;
  Lines := TStringList.Create;
  try
    Lines.Text := Head;
    if Lines.Count = 0 then Exit;
    Line := Lines[0];
    for P := 1 to Lines.Count - 1 do
    begin
      if Pos(':', Lines[P]) > 0 then
        FHeaders.Values[LowerCase(Trim(Copy(Lines[P], 1, Pos(':', Lines[P]) - 1)))] :=
          Trim(Copy(Lines[P], Pos(':', Lines[P]) + 1, MaxInt));
    end;
  finally
    Lines.Free;
  end;
  P := Pos(' ', Line);
  if P = 0 then Exit;
  Method := Copy(Line, 1, P - 1);
  Path   := Copy(Line, P + 1, MaxInt);
  P := Pos(' ', Path);
  if P > 0 then Path := Copy(Path, 1, P - 1);

  { git sends nothing the first time and asks its credential helper after this answer }
  if not FOwner.CheckAuth(FHeaders.Values['authorization']) then
  begin
    Respond(401, 'Unauthorized', 'WWW-Authenticate: Basic realm="git"' + #13#10);
    Exit;
  end;

  V2 := Pos('version=2', FHeaders.Values['git-protocol']) > 0;
  if (Method = 'GET') and (Path = REPO_PATH + '/info/refs?service=git-upload-pack') then
    UploadPack(True, V2, '')
  else if (Method = 'POST') and (Path = REPO_PATH + '/git-upload-pack') then
  begin
    if Pos('100-continue', LowerCase(FHeaders.Values['expect'])) > 0 then
      SendAll('HTTP/1.1 100 Continue' + #13#10#13#10);
    if not ReadBody(Body) then
    begin
      Respond(400, 'Bad Request');
      Exit;
    end;
    if Pos('gzip', LowerCase(FHeaders.Values['content-encoding'])) > 0 then
    begin
      if not Gunzip(Body, Plain) then
      begin
        Respond(400, 'Bad Request');
        Exit;
      end;
      Body := Plain;
    end;
    if UploadPack(False, V2, Body) then
    begin
      InterlockedIncrement(FOwner.FServed);
      if (FOwner.FFetchLimit > 0) and (InterlockedDecrement(FOwner.FFetchesLeft) <= 0) then
        FOwner.RequestStop;
    end;
  end
  else
    Respond(404, 'Not Found');
end;

procedure TConnThread.Execute;
begin
  try
    try
      Handle;
    except
      { a broken request ends its own connection, never the IDE }
    end;
  finally
    FOwner.Track(FSock, False);
    CloseSock(FSock);
    InterlockedDecrement(FOwner.FActive);
  end;
end;

{ ── The accepting thread ─────────────────────────────────────────────────── }

type
  TAcceptThread = class(TThread)
  private
    FOwner : TGitServe;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TGitServe);
  end;

constructor TAcceptThread.Create(AOwner: TGitServe);
begin
  FOwner := AOwner;
  inherited Create(False);
end;

procedure TAcceptThread.Execute;
var
  C    : TSocket;
  From : TInetSockAddr;
  Len  : TSockLen;
begin
  while not FOwner.FStopping do
  begin
    Len := SizeOf(From);
    C := fpaccept(FOwner.FListen, @From, @Len);
    if FOwner.FStopping then
    begin
      if C <> TSocket(-1) then CloseSock(C);
      Break;
    end;
    if C = TSocket(-1) then
    begin
      Sleep(20);
      Continue;
    end;
    if FOwner.Expired then
    begin
      CloseSock(C);
      FOwner.FStopping := True;
      Break;
    end;
    { the peer only, never while locked out, never more than MAX_CONNS at once }
    if (NetAddrToStr(From.sin_addr) <> FOwner.FPeer) or FOwner.Locked or
       (FOwner.FActive >= MAX_CONNS) then
    begin
      CloseSock(C);
      Continue;
    end;
    SetTimeouts(C, RECV_TIMEOUT_MS);
    InterlockedIncrement(FOwner.FActive);
    FOwner.Track(C, True);
    TConnThread.Create(FOwner, C);
  end;
  { the thread that owns the listener closes it, so a stop from a connection is safe }
  if FOwner.FListen <> TSocket(-1) then
  begin
    CloseSocket(FOwner.FListen);
    FOwner.FListen := TSocket(-1);
  end;
end;

{ ── TGitServe ────────────────────────────────────────────────────────────── }

constructor TGitServe.Create(const AGitExe, ARepoDir, APeer, AKey: string);
begin
  inherited Create;
  FGitExe  := AGitExe;
  FRepoDir := ARepoDir;
  FPeer    := APeer;
  FKey     := AKey;
  FListen  := TSocket(-1);
  FLock    := TCriticalSection.Create;
  FConns   := TList.Create;
end;

destructor TGitServe.Destroy;
begin
  Stop;
  FConns.Free;
  FLock.Free;
  inherited Destroy;
end;

function TGitServe.Start(AMinutes: Integer; out AWhy: string; APort: Word): Boolean;
var
  Addr : TInetSockAddr;
  Len  : TSockLen;
begin
  Result := False;
  if FThread <> nil then
  begin
    AWhy := 'Already started.';
    Exit;
  end;
  if not McpLocalAddressFor(FPeer, FHost, AWhy) then Exit;
  FListen := fpsocket(AF_INET, SOCK_STREAM, 0);
  if FListen = TSocket(-1) then
  begin
    AWhy := 'No socket could be made.';
    Exit;
  end;
  ParseIPv4(FHost, Addr);
  Addr.sin_port := htons(APort);
  if (fpbind(FListen, @Addr, SizeOf(Addr)) <> 0) or (fplisten(FListen, 4) <> 0) then
  begin
    CloseSocket(FListen);
    FListen := TSocket(-1);
    if APort <> 0 then
      AWhy := 'Port ' + IntToStr(APort) + ' on ' + FHost + ' is in use.'
    else
      AWhy := 'Could not listen on ' + FHost + '.';
    Exit;
  end;
  Len := SizeOf(Addr);
  fpgetsockname(FListen, @Addr, @Len);
  FPort     := ntohs(Addr.sin_port);
  FEndTick  := GetTickCount64 + QWord(AMinutes) * 60000;
  FStopping := False;
  FFetchesLeft := FFetchLimit;
  FThread   := TAcceptThread.Create(Self);
  Result    := True;
end;

procedure TGitServe.Stop;
var
  I : Integer;
begin
  if FThread = nil then Exit;
  RequestStop;
  FLock.Enter;
  try
    for I := 0 to FConns.Count - 1 do
      fpshutdown(TSocket(PtrInt(FConns[I])), 2);
  finally
    FLock.Leave;
  end;
  FThread.WaitFor;
  FreeAndNil(FThread);
  { let the connection threads finish their cleanup }
  I := 0;
  while (FActive > 0) and (I < 200) do
  begin
    Sleep(10);
    Inc(I);
  end;
end;

{ A blocked accept is not woken by shutting the listener down on every system: connect to
  it once; the accept thread sees FStopping first and closes that connection and the listener. }
procedure TGitServe.RequestStop;
var
  S    : TSocket;
  Addr : TInetSockAddr;
begin
  FStopping := True;
  if (FListen = TSocket(-1)) or (FHost = '') or not ParseIPv4(FHost, Addr) then Exit;
  Addr.sin_port := htons(FPort);
  S := fpsocket(AF_INET, SOCK_STREAM, 0);
  if S = TSocket(-1) then Exit;
  try
    fpconnect(S, @Addr, SizeOf(Addr));
  finally
    CloseSocket(S);
  end;
end;

function TGitServe.GetRunning: Boolean;
begin
  Result := (FThread <> nil) and not FStopping and not Expired;
end;

function TGitServe.Expired: Boolean;
begin
  Result := GetTickCount64 >= FEndTick;
end;

function TGitServe.SecondsLeft: Integer;
begin
  if not Running then Exit(0);
  Result := Integer((FEndTick - GetTickCount64) div 1000);
end;

procedure TGitServe.Track(ASock: TSocket; AAdd: Boolean);
begin
  FLock.Enter;
  try
    if AAdd then
      FConns.Add(Pointer(PtrInt(ASock)))
    else
      FConns.Remove(Pointer(PtrInt(ASock)));
  finally
    FLock.Leave;
  end;
end;

function TGitServe.Code(out ASecondsLeft: Integer): string;
var
  T : Int64;
begin
  T := Now_;
  Result := McpTotp(FKey, T);
  ASecondsLeft := 30 - Integer(T mod 30);
end;

function TGitServe.Locked: Boolean;
begin
  FLock.Enter;
  try
    Result := GetTickCount64 < FLockUntil;
  finally
    FLock.Leave;
  end;
end;

procedure TGitServe.NoteWrong;
var
  Now_t : QWord;
  I, J  : Integer;
begin
  FLock.Enter;
  try
    Inc(FWrong);
    Now_t := GetTickCount64;
    J := 0;
    for I := 0 to High(FBadTicks) do
      if Now_t - FBadTicks[I] < WRONG_WINDOW_MS then
      begin
        FBadTicks[J] := FBadTicks[I];
        Inc(J);
      end;
    SetLength(FBadTicks, J + 1);
    FBadTicks[J] := Now_t;
    if Length(FBadTicks) >= WRONG_LIMIT then
    begin
      FLockUntil := Now_t + LOCK_MS;
      SetLength(FBadTicks, 0);
    end;
  finally
    FLock.Leave;
  end;
end;

{ Basic mcp:<code>.  A missing header is only asked for (git then asks its credential
  helper); a wrong code is refused and counted. }
function TGitServe.CheckAuth(const AHeader: string): Boolean;
var
  Cred, User, Pass : string;
  P, Step : Integer;
  T : Int64;
begin
  Result := False;
  if Copy(AHeader, 1, 6) <> 'Basic ' then Exit;
  try
    Cred := DecodeStringBase64(Copy(AHeader, 7, MaxInt));
  except
    NoteWrong;
    Exit;
  end;
  P := Pos(':', Cred);
  if P = 0 then
  begin
    NoteWrong;
    Exit;
  end;
  User := Copy(Cred, 1, P - 1);
  Pass := Copy(Cred, P + 1, MaxInt);
  T := Now_;
  for Step := -1 to 1 do
    if McpConstTimeEquals(Pass, McpTotp(FKey, T + Step * 30)) and (User = 'mcp') then
      Result := True;
  if not Result then NoteWrong;
end;

initialization
  GServeClock := nil;

end.
