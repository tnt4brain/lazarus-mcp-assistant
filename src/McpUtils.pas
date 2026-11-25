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

{ Bytes as lower-case hex (two characters each), and back.  McpHexToStr stops at the first
  character that is not a hex pair and returns what it has read up to there. }
function McpBytesToHex(const ABuf; ALen: Integer): string;
function McpStrToHex(const S: string): string;
function McpHexToStr(const H: string): string;

const
  { the address the server listens on unless the settings say otherwise }
  McpLoopback = '127.0.0.1';

{ Probe-bind AAddr:0 to let the OS pick a free port.
  Returns 0 on failure. }
function FindFreePort(const AAddr: string = McpLoopback): Word;

{ Try to bind AAddr:APort. Returns True if the port is currently free. }
function IsPortFree(APort: Word; const AAddr: string = McpLoopback): Boolean;

{ The port to store in the settings after the server started on AActual while
  AWanted was the stored one. The stored port is the URL clients are configured
  for, so a fallback (the stored port was busy, a second IDE instance) must not
  replace it: only a first start (AWanted = 0) or the stored port itself is kept. }
function McpPortToPersist(AWanted, AActual: Word): Word;

{ S is a dotted IPv4 address (four numbers 0..255). }
function McpValidListenAddress(const S: string): Boolean;

{ S is in 127.0.0.0/8. }
function McpIsLoopback(const S: string): Boolean;

{ A pointer kept in an integer slot (a list item, a window message's parameter) and back.  FPC
  hints at every cast between the two ("not portable"), whatever the types; PtrInt is as wide as
  a pointer, so these two are portable, and the hint is switched off in their bodies only. }
function McpIntToPtr(AValue: PtrInt): Pointer;
function McpPtrToInt(APtr: Pointer): PtrInt;

{ The address a client on this machine connects to for a server listening on
  AListen: 0.0.0.0 ("every interface") is reached through the loopback. }
function McpClientHost(const AListen: string): string;

{ The address of this machine on the network, as other machines reach it (the one
  its default route uses); '' when it has none.  For the config of a remote client
  of a server that listens on 0.0.0.0. }
function McpPrimaryAddress: string;

{ Delete ADir and everything in it; a link (symbolic, or a junction on Windows) is removed itself,
  never followed.  True when ADir is gone.  The same on Lazarus 4.x and 5.x: FileUtil's DeleteDirectory
  has a different signature in 5.0 and the old one is deprecated there. }
function McpDeleteTree(const ADir: string): Boolean;

{ An absolute path with native separators and no '.'/'..' segments, so
  D:/x/../y.pas and D:\y.pas compare equal.  Relative paths come back
  unchanged: tools resolve them against their own base (project or
  repository directory), not against the IDE's working directory. }
function McpNormalizePath(const S: string): string;

{ APath lies inside ARoot (both absolute; '.' and '..' are resolved first, and the comparison is
  the file system's: case-insensitive on Windows).  A drive or file system root as ARoot contains
  nothing: a project there must not open the whole disk. }
function McpPathIsUnder(const APath, ARoot: string): Boolean;

{ Where APath really is: the deepest part of it that exists, with every symbolic link, junction
  and short (8.3) name resolved, and the rest (which may not exist yet) appended.  A path that
  cannot be resolved at all comes back normalised.  ADR-034. }
function McpRealPath(const APath: string): string;

{ McpPathIsUnder for where both really are: a link inside ARoot that points out of it does not
  make what is behind it part of ARoot. }
function McpPathIsUnderReal(const APath, ARoot: string): Boolean;

{ Some segment of APath is AName, whatever the case (.git, say). }
function McpPathHasSegment(const APath, AName: string): Boolean;

{ The working tree that holds ADir: the nearest folder above it (or itself) with a .git entry,
  with a trailing separator; '' when there is none. }
function McpRepoRoot(const ADir: string): string;

{ McpNormalizePath for every path argument of a tools/call (file, file_path,
  form_file, lpk_path, work_dir, ...), in place.  AArgs may be nil. }
procedure McpNormalizePathArgs(AArgs: TJSONObject);

implementation

uses
  SysUtils, Sockets, LazFileUtils
  {$IFDEF WINDOWS}, Windows{$ENDIF};

{$IFDEF WINDOWS}
function GetFinalPathNameByHandleW(hFile: THandle; lpszFilePath: PWideChar;
  cchFilePath, dwFlags: DWORD): DWORD; stdcall; external 'kernel32' name 'GetFinalPathNameByHandleW';
{$ENDIF}

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

function McpPathIsUnder(const APath, ARoot: string): Boolean;
var
  P, R, Bare : string;
begin
  Result := False;
  if not (FilenameIsAbsolute(APath) and FilenameIsAbsolute(ARoot)) then Exit;
  P := McpNormalizePath(APath);
  Bare := ExcludeTrailingPathDelimiter(McpNormalizePath(ARoot));
  if (ExtractFilePath(Bare) = '') or (ExtractFilePath(Bare) = Bare) then Exit;   { a root }
  R := Bare + PathDelim;
  Result := (Length(P) > Length(R)) and (CompareFilenames(Copy(P, 1, Length(R)), R) = 0);
end;

{ The real name of a path that exists, or '' }
function RealOfExisting(const AExisting: string): string;
{$IFDEF WINDOWS}
var
  H   : THandle;
  Buf : array[0..32767] of WideChar;
  N   : DWORD;
  S   : string;
begin
  Result := '';
  H := CreateFileW(PWideChar(UTF8Decode(AExisting)), 0,
         FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil, OPEN_EXISTING,
         FILE_FLAG_BACKUP_SEMANTICS, 0);
  if H = INVALID_HANDLE_VALUE then Exit;
  try
    N := GetFinalPathNameByHandleW(H, @Buf[0], Length(Buf), 0);
    if (N = 0) or (N >= Length(Buf)) then Exit;
    S := UTF8Encode(WideString(PWideChar(@Buf[0])));
  finally
    CloseHandle(H);
  end;
  if Copy(S, 1, 8) = '\\?\UNC\' then S := '\\' + Copy(S, 9, MaxInt)
  else if Copy(S, 1, 4) = '\\?\' then S := Copy(S, 5, MaxInt);
  Result := S;
end;
{$ELSE}
begin
  Result := GetPhysicalFilename(AExisting, pfeEmpty);
end;
{$ENDIF}

function McpRealPath(const APath: string): string;
var
  P, Existing, Tail, Real, Up : string;
begin
  P := McpNormalizePath(APath);
  if not FilenameIsAbsolute(P) then Exit(P);
  Existing := ExcludeTrailingPathDelimiter(P);
  Tail := '';
  while Existing <> '' do
  begin
    Real := RealOfExisting(Existing);
    if Real <> '' then
    begin
      Result := ExcludeTrailingPathDelimiter(Real);
      if Tail <> '' then Result := Result + PathDelim + Tail;
      Exit;
    end;
    Up := ExtractFileDir(Existing);
    if (Up = '') or (Up = Existing) then Break;
    if Tail = '' then Tail := ExtractFileName(Existing)
    else Tail := ExtractFileName(Existing) + PathDelim + Tail;
    Existing := Up;
  end;
  Result := P;
end;

function McpPathIsUnderReal(const APath, ARoot: string): Boolean;
begin
  Result := McpPathIsUnder(McpRealPath(APath), McpRealPath(ARoot));
end;

function McpPathHasSegment(const APath, AName: string): Boolean;
var
  I, Start : Integer;
begin
  Result := False;
  Start := 1;
  for I := 1 to Length(APath) + 1 do
    if (I > Length(APath)) or (APath[I] in ['/', '\']) then
    begin
      if SameText(Copy(APath, Start, I - Start), AName) then Exit(True);
      Start := I + 1;
    end;
end;

function McpRepoRoot(const ADir: string): string;
var
  D, Up : string;
begin
  Result := '';
  if not FilenameIsAbsolute(ADir) then Exit;
  D := ExcludeTrailingPathDelimiter(McpNormalizePath(ADir));
  while D <> '' do
  begin
    if DirectoryExists(D + PathDelim + '.git') or FileExists(D + PathDelim + '.git') then
      Exit(D + PathDelim);
    Up := ExtractFileDir(D);
    if (Up = '') or (Up = D) then Break;
    D := Up;
  end;
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

{$PUSH}{$HINTS OFF}
function McpIntToPtr(AValue: PtrInt): Pointer;
begin
  Result := Pointer(AValue);
end;

function McpPtrToInt(APtr: Pointer): PtrInt;
begin
  Result := PtrInt(APtr);
end;
{$POP}

function McpClientHost(const AListen: string): string;
begin
  if (AListen = '') or (AListen = '0.0.0.0') or not McpValidListenAddress(AListen) then
    Result := McpLoopback
  else
    Result := AListen;
end;

function McpDeleteTree(const ADir: string): Boolean;
{$WARN 5044 OFF}   { faSymLink: the same bit means a link on Unix and a junction on Windows }
var
  SR   : TSearchRec;
  Dir  : string;
  Path : string;
begin
  Dir := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(Dir + '*', faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      Path := Dir + SR.Name;
      if ((SR.Attr and faDirectory) <> 0) and ((SR.Attr and faSymLink) = 0) then
        McpDeleteTree(Path)
      else
      begin
        FileSetAttr(Path, 0);   { a read-only file is deleted too }
        if not SysUtils.DeleteFile(Path) then RemoveDir(Path);   { a directory link goes with RemoveDir }
      end;
    until FindNext(SR) <> 0;
  finally
    SysUtils.FindClose(SR);
  end;
  RemoveDir(ChompPathDelim(Dir));
  Result := not DirectoryExists(ChompPathDelim(Dir));
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
    Addr := Default(TInetSockAddr);
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
procedure FillAddr(out Addr: TInetSockAddr; const S: string; APort: Word);
begin
  Addr := Default(TInetSockAddr);
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
  {$IFNDEF MSWINDOWS}
  Enable : LongInt;
  {$ENDIF}
begin
  Result := False;
  S := fpSocket(AF_INET, SOCK_STREAM, 0);
  if S < 0 then Exit;
  { Unix: a port in TIME_WAIT counts as free, a listening one still blocks the bind.  Windows:
    the option lets this bind succeed on a port another program listens on (when that one set
    it too), so a busy port would look free (ADR-032). }
  {$IFNDEF MSWINDOWS}
  Enable := 1;
  fpSetSockOpt(S, SOL_SOCKET, SO_REUSEADDR, @Enable, SizeOf(Enable));
  {$ENDIF}
  FillAddr(Addr, AAddr, APort);
  Result := fpBind(S, @Addr, SizeOf(Addr)) = 0;
  CloseSocket(S);
end;

function McpPortToPersist(AWanted, AActual: Word): Word;
begin
  if AWanted = 0 then
    Result := AActual
  else
    Result := AWanted;
end;

function McpBytesToHex(const ABuf; ALen: Integer): string;
const
  Digits = '0123456789abcdef';
var
  I : Integer;
  P : PByte;
begin
  Result := '';
  if ALen <= 0 then Exit;
  SetLength(Result, ALen * 2);
  P := @ABuf;
  for I := 0 to ALen - 1 do
  begin
    Result[I * 2 + 1] := Digits[(P[I] shr 4) + 1];
    Result[I * 2 + 2] := Digits[(P[I] and 15) + 1];
  end;
end;

function McpStrToHex(const S: string): string;
begin
  if S = '' then Exit('');
  Result := McpBytesToHex(S[1], Length(S));
end;

function McpHexToStr(const H: string): string;
var
  I, Hi, Lo : Integer;

  function Nibble(C: Char): Integer;
  begin
    case C of
      '0'..'9': Result := Ord(C) - Ord('0');
      'a'..'f': Result := Ord(C) - Ord('a') + 10;
      'A'..'F': Result := Ord(C) - Ord('A') + 10;
    else
      Result := -1;
    end;
  end;

begin
  Result := '';
  I := 1;
  while I < Length(H) do
  begin
    Hi := Nibble(H[I]);
    Lo := Nibble(H[I + 1]);
    if (Hi < 0) or (Lo < 0) then Break;
    Result := Result + Chr(Hi * 16 + Lo);
    Inc(I, 2);
  end;
end;

end.
