{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpUtils;

{ Pure utility functions with no IDE dependencies.
  Used by McpIdeServer and directly by the FPCUnit test project. }

{$mode objfpc}{$H+}

interface

uses
  fpjson;

{ Byte-swap a 16-bit value (network ↔ host byte order on little-endian hosts). }
function Swap16(v: Word): Word; inline;

{ Returns a 64-character hex string derived from two GUIDs. }
function GenerateToken: string;

const
  { the address the server listens on unless the settings say otherwise }
  McpLoopback = '127.0.0.1';

{ Probe-bind AAddr:0 to let the OS pick a free port.
  Returns 0 on failure. }
function FindFreePort(const AAddr: string = McpLoopback): Word;

{ Try to bind AAddr:APort. Returns True if the port is currently free. }
function IsPortFree(APort: Word; const AAddr: string = McpLoopback): Boolean;

{ S is a dotted IPv4 address (four numbers 0..255). }
function McpValidListenAddress(const S: string): Boolean;

{ S is in 127.0.0.0/8. }
function McpIsLoopback(const S: string): Boolean;

{ The address a client on this machine connects to for a server listening on
  AListen: 0.0.0.0 ("every interface") is reached through the loopback. }
function McpClientHost(const AListen: string): string;

{ The address of this machine on the network, as other machines reach it (the one
  its default route uses); '' when it has none.  For the config of a remote client
  of a server that listens on 0.0.0.0. }
function McpPrimaryAddress: string;

{ An absolute path with native separators and no '.'/'..' segments, so
  D:/x/../y.pas and D:\y.pas compare equal.  Relative paths come back
  unchanged: tools resolve them against their own base (project or
  repository directory), not against the IDE's working directory. }
function McpNormalizePath(const S: string): string;

{ McpNormalizePath for every path argument of a tools/call (file, file_path,
  form_file, lpk_path, work_dir, ...), in place.  AArgs may be nil. }
procedure McpNormalizePathArgs(AArgs: TJSONObject);

{ Tools that named their one file argument file_path, path or filename take
  "file" since v1.0, as all other tools do; the old name is still accepted
  and renamed to "file" here, in place.  AArgs may be nil. }
procedure McpRenameLegacyFileArg(const ATool: string; AArgs: TJSONObject);

implementation

uses
  SysUtils, Sockets, LazFileUtils;

const
  { argument names that hold file or directory paths; output_dir is not one
    of them: it is stored in the .lpi as written, macros included }
  PATH_ARGS : array[0..10] of string = (
    'file', 'file_path', 'path', 'form_file', 'filename', 'directory',
    'project_dir', 'work_dir', 'lpk_path', 'test_project', 'junit_out');

function McpNormalizePath(const S: string): string;
begin
  if (S <> '') and FilenameIsAbsolute(S) then
    Result := CleanAndExpandFilename(S)
  else
    Result := S;
end;

procedure McpNormalizePathArgs(AArgs: TJSONObject);
var
  I : Integer;
  D : TJSONData;
begin
  if not Assigned(AArgs) then Exit;
  for I := Low(PATH_ARGS) to High(PATH_ARGS) do
  begin
    D := AArgs.Find(PATH_ARGS[I]);
    if Assigned(D) and (D.JSONType = jtString) then
      D.AsString := McpNormalizePath(D.AsString);
  end;
end;

procedure McpRenameLegacyFileArg(const ATool: string; AArgs: TJSONObject);
var
  Old : string;
  I   : Integer;
begin
  if not Assigned(AArgs) or (AArgs.IndexOfName('file') >= 0) then Exit;
  case ATool of
    'debug_set_breakpoint', 'debug_remove_breakpoint', 'debug_run_to_line',
    'editor_open', 'project_add_file', 'project_remove_file', 'project_open':
      Old := 'file_path';
    'editor_read_file':    Old := 'path';
    'project_create_unit': Old := 'filename';
  else
    Exit;
  end;
  I := AArgs.IndexOfName(Old);
  if I < 0 then Exit;
  AArgs.Add('file', AArgs.Items[I].Clone);
  AArgs.Delete(I);
end;

function Swap16(v: Word): Word;
begin
  Result := ((v and $00FF) shl 8) or (v shr 8);
end;

function McpValidListenAddress(const S: string): Boolean;
var
  I, P, N, Parts : Integer;
  Part : string;
  T    : string;
begin
  Result := False;
  T := S;
  Parts := 0;
  repeat
    P := Pos('.', T);
    if P = 0 then Part := T else Part := Copy(T, 1, P - 1);
    if (Part = '') or (Length(Part) > 3) then Exit;
    for I := 1 to Length(Part) do
      if not (Part[I] in ['0'..'9']) then Exit;
    N := StrToInt(Part);
    if N > 255 then Exit;
    Inc(Parts);
    if P = 0 then Break;
    Delete(T, 1, P);
  until False;
  Result := Parts = 4;
end;

function McpIsLoopback(const S: string): Boolean;
begin
  Result := McpValidListenAddress(S) and (Copy(S, 1, 4) = '127.');
end;

function McpClientHost(const AListen: string): string;
begin
  if (AListen = '') or (AListen = '0.0.0.0') or not McpValidListenAddress(AListen) then
    Result := McpLoopback
  else
    Result := AListen;
end;

function McpPrimaryAddress: string;
var
  S    : LongInt;
  Addr : TInetSockAddr;
  Len  : LongInt;
begin
  Result := '';
  S := fpSocket(AF_INET, SOCK_DGRAM, 0);
  if S < 0 then Exit;
  try
    { connecting a datagram socket sends nothing: it only makes the system pick the
      local address for the route (192.0.2.1 is reserved for documentation) }
    FillChar(Addr, SizeOf(Addr), 0);
    Addr.sin_family := AF_INET;
    Addr.sin_port   := Swap16(9);
    Addr.sin_addr   := StrToNetAddr('192.0.2.1');
    if fpConnect(S, @Addr, SizeOf(Addr)) <> 0 then Exit;
    Len := SizeOf(Addr);
    if fpGetSockName(S, @Addr, @Len) <> 0 then Exit;
    Result := NetAddrToStr(Addr.sin_addr);
    if (Result = '0.0.0.0') or McpIsLoopback(Result) then Result := '';
  finally
    CloseSocket(S);
  end;
end;

{ A socket address for the dotted address S (loopback when it is not valid) }
procedure FillAddr(var Addr: TInetSockAddr; const S: string; APort: Word);
begin
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port   := Swap16(APort);
  if McpValidListenAddress(S) then
    Addr.sin_addr := StrToNetAddr(S)
  else
    Addr.sin_addr := StrToNetAddr(McpLoopback);
end;

function FindFreePort(const AAddr: string): Word;
var
  S    : LongInt;
  Addr : TInetSockAddr;
  Len  : LongInt;
begin
  Result := 0;
  S := fpSocket(AF_INET, SOCK_STREAM, 0);
  if S < 0 then Exit;
  FillAddr(Addr, AAddr, 0);
  if fpBind(S, @Addr, SizeOf(Addr)) = 0 then
  begin
    Len := SizeOf(Addr);
    if fpGetSockName(S, @Addr, @Len) = 0 then
      Result := Swap16(Addr.sin_port);
  end;
  CloseSocket(S);
end;

function IsPortFree(APort: Word; const AAddr: string): Boolean;
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
  FillAddr(Addr, AAddr, APort);
  Result := fpBind(S, @Addr, SizeOf(Addr)) = 0;
  CloseSocket(S);
end;

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

end.
