{ git credential helper for a git_serve link (ADR-035), as an instantfpc script:
    git config credential.helper "!instantfpc ~/.git-credential-mcp.pas <key as hex>"
  git runs it as  <script> <key> get  and writes what it knows to stdin.  It answers with the
  user "mcp" and the TOTP code (RFC 6238, HMAC-SHA1, 6 digits, 30 s) of the link's key.
  The same text is in the answer of git_serve link (McpToolsGitServe.pas); keep the two equal.
  scripts/git-credential-mcp is the fallback for a box without FPC. }
{$mode objfpc}{$H+}
uses SysUtils, DateUtils, sha1;

function Raw(const D: TSHA1Digest): string;
begin
  SetLength(Result, 20);
  Move(D, Result[1], 20);
end;

function Hmac(const AKey, AMsg: string): string;
var
  K, Ip, Op : string;
  I : Integer;
begin
  K := AKey + StringOfChar(#0, 64 - Length(AKey));
  SetLength(Ip, 64);
  SetLength(Op, 64);
  for I := 1 to 64 do
  begin
    Ip[I] := Chr(Ord(K[I]) xor $36);
    Op[I] := Chr(Ord(K[I]) xor $5C);
  end;
  Result := Raw(SHA1String(Op + Raw(SHA1String(Ip + AMsg))));
end;

var
  Key, Msg, H, Line : string;
  I, Off : Integer;
  T : Int64;
  Bin : LongWord;
begin
  if (ParamCount < 2) or (ParamStr(2) <> 'get') then Halt(0);
  while not EOF(Input) do ReadLn(Input, Line);
  Key := '';
  for I := 0 to (Length(ParamStr(1)) div 2) - 1 do
    Key := Key + Chr(StrToIntDef('$' + Copy(ParamStr(1), I * 2 + 1, 2), 0));
  T := DateTimeToUnix(Now, False) div 30;
  SetLength(Msg, 8);
  for I := 8 downto 1 do
  begin
    Msg[I] := Chr(T and $FF);
    T := T shr 8;
  end;
  H := Hmac(Key, Msg);
  Off := Ord(H[20]) and $0F;
  Bin := ((LongWord(Ord(H[Off + 1])) and $7F) shl 24) or (LongWord(Ord(H[Off + 2])) shl 16) or
         (LongWord(Ord(H[Off + 3])) shl 8) or LongWord(Ord(H[Off + 4]));
  Write('username=mcp'#10, 'password=', Format('%.6d', [Bin mod 1000000]), #10);
end.
