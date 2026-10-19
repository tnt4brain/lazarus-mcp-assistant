{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpTokens;

{ Bearer tokens (ADR-021): the primary token every local client uses, and the named
  tokens given to other clients, kept only as tagged hashes ('sha1:<hex>').  Plain
  code with no IDE units, so the test program can use it.  The hash is FPC's own
  sha1 unit; the tag lets another algorithm follow when the compiler ships one. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs;

const
  MCP_PRIMARY_ID    = 'primary';   { the id of the primary token in logs and sessions }
  MCP_MAX_TOKENS    = 16;
  MCP_TOKEN_PREFIX  = 'lmcp_';

type
  TMcpClientToken = record
    Id       : string;   { 8 hex characters, for logs and for revoking }
    Name     : string;   { what the client is called }
    Hash     : string;   { 'sha1:<hex>' }
    Hint     : string;   { the last 4 characters of the token }
    Created  : Int64;    { Unix seconds, UTC }
    LastUsed : Int64;    { 0: never }
  end;
  TMcpClientTokens = array of TMcpClientToken;

  { The named tokens.  Safe to use from the server threads and the main thread. }
  TMcpTokenStore = class
  private
    FLock  : TCriticalSection;
    FItems : TMcpClientTokens;
  public
    constructor Create;
    destructor Destroy; override;
    { Makes a token; AToken is its only plain-text appearance.  False, with
      AErr, if the name is not usable or the limit is reached. }
    function Add(const AName: string; out AToken, AErr: string): Boolean;
    function Revoke(const AId: string): Boolean;
    { The entry whose token this is; its last-used time is set. }
    function Find(const AToken: string; out AEntry: TMcpClientToken): Boolean;
    function Items: TMcpClientTokens;
    procedure SetItems(const AItems: TMcpClientTokens);
    function Count: Integer;
  end;

{ Random bytes from the operating system (BCryptGenRandom, /dev/urandom);
  raises if there are none: a weak token is worse than no token. }
procedure McpRandomBytes(var ABuf; ALen: Integer);

{ 64 hex characters (the primary token). }
function McpNewPrimaryToken: string;

{ 'lmcp_' + 43 base64url characters (32 random bytes): a token for one client. }
function McpNewClientToken: string;

{ 'sha1:<hex>' }
function McpHashToken(const AToken: string): string;

{ Does AToken match the stored AHash?  By the algorithm the hash names; an
  unknown one never matches. }
function McpTokenMatches(const AToken, AHash: string): Boolean;

{ Equal strings, without stopping at the first difference. }
function McpConstTimeEquals(const A, B: string): Boolean;

{ The Authorization header of a request ('Bearer <token>'): the primary token
  (AId = MCP_PRIMARY_ID, AName = ''), or a named one in AStore.  AStore may be nil. }
function McpAuthorize(const AHeader, APrimary: string; AStore: TMcpTokenStore;
  out AId, AName: string): Boolean;

{ '' if AName can name a token, else why not. }
function McpTokenNameError(const AName: string): string;

function McpUnixNow: Int64;

implementation

uses
  {$IFDEF WINDOWS} Windows, {$ENDIF}
  Math, base64, sha1, DateUtils;

{ ── Random ───────────────────────────────────────────────────────────────── }

{$IFDEF WINDOWS}
function BCryptGenRandom(hAlgorithm: Pointer; pbBuffer: PByte; cbBuffer: ULONG;
  dwFlags: ULONG): LongInt; stdcall; external 'bcrypt.dll';

procedure McpRandomBytes(var ABuf; ALen: Integer);
const
  BCRYPT_USE_SYSTEM_PREFERRED_RNG = 2;
begin
  if ALen <= 0 then Exit;
  if BCryptGenRandom(nil, @ABuf, ALen, BCRYPT_USE_SYSTEM_PREFERRED_RNG) <> 0 then
    raise Exception.Create('The system random number generator failed');
end;
{$ELSE}
procedure McpRandomBytes(var ABuf; ALen: Integer);
var
  F    : THandle;
  Got  : Integer;
  Done : Integer;
  P    : PByte;
begin
  if ALen <= 0 then Exit;
  F := FileOpen('/dev/urandom', fmOpenRead or fmShareDenyNone);
  if F = THandle(-1) then
    raise Exception.Create('Cannot open /dev/urandom');
  try
    P := @ABuf;
    Done := 0;
    while Done < ALen do
    begin
      Got := FileRead(F, (P + Done)^, ALen - Done);
      if Got <= 0 then
        raise Exception.Create('Cannot read /dev/urandom');
      Inc(Done, Got);
    end;
  finally
    FileClose(F);
  end;
end;
{$ENDIF}

function HexOf(const ABytes: array of Byte): string;
const
  Digits = '0123456789abcdef';
var
  I : Integer;
begin
  SetLength(Result, Length(ABytes) * 2);
  for I := 0 to High(ABytes) do
  begin
    Result[I * 2 + 1] := Digits[(ABytes[I] shr 4) + 1];
    Result[I * 2 + 2] := Digits[(ABytes[I] and 15) + 1];
  end;
end;

function McpNewPrimaryToken: string;
var
  B : array[0..31] of Byte;
begin
  McpRandomBytes(B, SizeOf(B));
  Result := HexOf(B);
end;

function McpNewClientToken: string;
var
  B : array[0..31] of Byte;
  S : string;
begin
  McpRandomBytes(B, SizeOf(B));
  SetString(S, PChar(@B[0]), SizeOf(B));
  Result := EncodeStringBase64(S);
  Result := StringReplace(Result, '+', '-', [rfReplaceAll]);
  Result := StringReplace(Result, '/', '_', [rfReplaceAll]);
  Result := StringReplace(Result, '=', '', [rfReplaceAll]);
  Result := MCP_TOKEN_PREFIX + Result;
end;

{ ── Hashes ───────────────────────────────────────────────────────────────── }

function McpConstTimeEquals(const A, B: string): Boolean;
var
  I    : Integer;
  Diff : Byte;
begin
  Diff := 0;
  if Length(A) <> Length(B) then Diff := 1;
  for I := 1 to Min(Length(A), Length(B)) do
    Diff := Diff or (Ord(A[I]) xor Ord(B[I]));
  Result := Diff = 0;
end;

function McpHashToken(const AToken: string): string;
begin
  Result := 'sha1:' + SHA1Print(SHA1String(AToken));
end;

function McpTokenMatches(const AToken, AHash: string): Boolean;
begin
  if Copy(AHash, 1, 5) = 'sha1:' then
    Result := McpConstTimeEquals(McpHashToken(AToken), AHash)
  else
    Result := False;
end;

{ ── Store ────────────────────────────────────────────────────────────────── }

function McpUnixNow: Int64;
begin
  Result := DateTimeToUnix(Now, False);
end;

function McpTokenNameError(const AName: string): string;
var
  I : Integer;
begin
  Result := '';
  if Trim(AName) = '' then Exit('The token needs a name');
  if Length(AName) > 40 then Exit('The name is longer than 40 characters');
  for I := 1 to Length(AName) do
    if AName[I] < ' ' then Exit('The name has a control character');
end;

constructor TMcpTokenStore.Create;
begin
  inherited Create;
  FLock := SyncObjs.TCriticalSection.Create;   { not the Windows unit's }
end;

destructor TMcpTokenStore.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TMcpTokenStore.Add(const AName: string; out AToken, AErr: string): Boolean;
var
  T   : TMcpClientToken;
  Id  : array[0..3] of Byte;
  I   : Integer;
begin
  Result := False;
  AToken := '';
  AErr   := McpTokenNameError(AName);
  if AErr <> '' then Exit;
  FLock.Enter;
  try
    if Length(FItems) >= MCP_MAX_TOKENS then
    begin
      AErr := 'At most ' + IntToStr(MCP_MAX_TOKENS) + ' tokens: revoke one first';
      Exit;
    end;
    for I := 0 to High(FItems) do
      if SameText(FItems[I].Name, Trim(AName)) then
      begin
        AErr := 'There is a token named "' + Trim(AName) + '" already';
        Exit;
      end;
    AToken := McpNewClientToken;
    McpRandomBytes(Id, SizeOf(Id));
    T.Id       := HexOf(Id);
    T.Name     := Trim(AName);
    T.Hash     := McpHashToken(AToken);
    T.Hint     := Copy(AToken, Length(AToken) - 3, 4);
    T.Created  := McpUnixNow;
    T.LastUsed := 0;
    SetLength(FItems, Length(FItems) + 1);
    FItems[High(FItems)] := T;
    Result := True;
  finally
    FLock.Leave;
  end;
end;

function TMcpTokenStore.Revoke(const AId: string): Boolean;
var
  I : Integer;
begin
  Result := False;
  FLock.Enter;
  try
    for I := 0 to High(FItems) do
      if FItems[I].Id = AId then
      begin
        Delete(FItems, I, 1);
        Exit(True);
      end;
  finally
    FLock.Leave;
  end;
end;

function TMcpTokenStore.Find(const AToken: string; out AEntry: TMcpClientToken): Boolean;
var
  I, Hit : Integer;
  H      : string;
begin
  Result := False;
  if AToken = '' then Exit;
  H := McpHashToken(AToken);
  FLock.Enter;
  try
    Hit := -1;
    { every entry is compared, so the time does not tell which one matched }
    for I := 0 to High(FItems) do
      if McpConstTimeEquals(H, FItems[I].Hash) then Hit := I;
    if Hit >= 0 then
    begin
      FItems[Hit].LastUsed := McpUnixNow;
      AEntry := FItems[Hit];
      Result := True;
    end;
  finally
    FLock.Leave;
  end;
end;

function TMcpTokenStore.Items: TMcpClientTokens;
begin
  FLock.Enter;
  try
    Result := Copy(FItems, 0, Length(FItems));
  finally
    FLock.Leave;
  end;
end;

procedure TMcpTokenStore.SetItems(const AItems: TMcpClientTokens);
begin
  FLock.Enter;
  try
    FItems := Copy(AItems, 0, Length(AItems));
  finally
    FLock.Leave;
  end;
end;

function TMcpTokenStore.Count: Integer;
begin
  FLock.Enter;
  try
    Result := Length(FItems);
  finally
    FLock.Leave;
  end;
end;

{ ── Request check ────────────────────────────────────────────────────────── }

function McpAuthorize(const AHeader, APrimary: string; AStore: TMcpTokenStore;
  out AId, AName: string): Boolean;
var
  Tok   : string;
  Entry : TMcpClientToken;
begin
  Result := False;
  AId    := '';
  AName  := '';
  if Copy(AHeader, 1, 7) <> 'Bearer ' then Exit;
  Tok := Copy(AHeader, 8, MaxInt);
  if Tok = '' then Exit;
  if (APrimary <> '') and McpConstTimeEquals(Tok, APrimary) then
  begin
    AId := MCP_PRIMARY_ID;
    Exit(True);
  end;
  if Assigned(AStore) and AStore.Find(Tok, Entry) then
  begin
    AId   := Entry.Id;
    AName := Entry.Name;
    Result := True;
  end;
end;

end.
