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

{ Probe-bind 127.0.0.1:0 to let the OS pick a free port.
  Returns 0 on failure. }
function FindFreePort: Word;

{ Try to bind 127.0.0.1:APort. Returns True if the port is currently free. }
function IsPortFree(APort: Word): Boolean;

{ An absolute path with native separators and no '.'/'..' segments, so
  D:/x/../y.pas and D:\y.pas compare equal.  Relative paths come back
  unchanged: tools resolve them against their own base (project or
  repository directory), not against the IDE's working directory. }
function McpNormalizePath(const S: string): string;

{ McpNormalizePath for every path argument of a tools/call (file, file_path,
  form_file, lpk_path, work_dir, ...), in place.  AArgs may be nil. }
procedure McpNormalizePathArgs(AArgs: TJSONObject);

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

function Swap16(v: Word): Word;
begin
  Result := ((v and $00FF) shl 8) or (v shr 8);
end;

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
  Addr.sin_port            := 0;
  Addr.sin_addr.s_bytes[1] := 127;
  Addr.sin_addr.s_bytes[2] := 0;
  Addr.sin_addr.s_bytes[3] := 0;
  Addr.sin_addr.s_bytes[4] := 1;
  if fpBind(S, @Addr, SizeOf(Addr)) = 0 then
  begin
    Len := SizeOf(Addr);
    if fpGetSockName(S, @Addr, @Len) = 0 then
      Result := Swap16(Addr.sin_port);
  end;
  CloseSocket(S);
end;

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
