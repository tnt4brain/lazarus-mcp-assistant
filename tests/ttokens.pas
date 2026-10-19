{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TTokens;

{ TTestTokens — McpTokens (ADR-021) and the settings file's token list.
  No IDE or running server required. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, McpTokens, McpSettingsFile;

type
  TTestTokens = class(TTestCase)
  published
    procedure TestHashIsTagged;
    procedure TestMatches;
    procedure TestNewTokensLookRight;
    procedure TestConstTimeEquals;
    procedure TestStoreAddFindRevoke;
    procedure TestStoreRefusals;
    procedure TestAuthorize;
    procedure TestSettingsKeepOnlyHashes;
  end;

implementation

function Base64UrlOnly(const S: string): Boolean;
var
  I : Integer;
begin
  Result := True;
  for I := 1 to Length(S) do
    if not (S[I] in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_']) then
      Exit(False);
end;

{ SHA-1 of '' and 'abc' (FIPS 180 examples): FPC's sha1 unit is what we rely on }
procedure TTestTokens.TestHashIsTagged;
begin
  CheckEquals('sha1:da39a3ee5e6b4b0d3255bfef95601890afd80709', McpHashToken(''));
  CheckEquals('sha1:a9993e364706816aba3e25717850c26c9cd0d89d', McpHashToken('abc'));
end;

procedure TTestTokens.TestMatches;
var
  H : string;
begin
  H := McpHashToken('secret');
  CheckTrue(McpTokenMatches('secret', H));
  CheckFalse(McpTokenMatches('Secret', H), 'case');
  CheckFalse(McpTokenMatches('secret ', H), 'a space');
  CheckFalse(McpTokenMatches('secret', ''), 'no hash');
  CheckFalse(McpTokenMatches('secret', 'md5:5ebe2294ecd0e0f08eab7690d2a6ee69'), 'a tag we do not know');
  CheckFalse(McpTokenMatches('secret', Copy(H, 6, MaxInt)), 'the tag is part of the hash');
end;

procedure TTestTokens.TestNewTokensLookRight;
var
  A, B : string;
  I    : Integer;
begin
  A := McpNewClientToken;
  CheckEquals(MCP_TOKEN_PREFIX, Copy(A, 1, 5), 'prefix');
  CheckEquals(48, Length(A), 'lmcp_ and 43 characters');
  CheckTrue(Base64UrlOnly(Copy(A, 6, MaxInt)), 'base64url: ' + A);
  B := McpNewClientToken;
  CheckNotEquals(A, B, 'two tokens differ');

  A := McpNewPrimaryToken;
  CheckEquals(64, Length(A));
  for I := 1 to Length(A) do
    CheckTrue(A[I] in ['0'..'9', 'a'..'f'], 'hex at ' + IntToStr(I));
  CheckNotEquals(A, McpNewPrimaryToken);
end;

procedure TTestTokens.TestConstTimeEquals;
begin
  CheckTrue(McpConstTimeEquals('abc', 'abc'));
  CheckTrue(McpConstTimeEquals('', ''));
  CheckFalse(McpConstTimeEquals('abc', 'abd'));
  CheckFalse(McpConstTimeEquals('abc', 'ab'));
  CheckFalse(McpConstTimeEquals('ab', 'abc'));
end;

procedure TTestTokens.TestStoreAddFindRevoke;
var
  S      : TMcpTokenStore;
  Tok, E : string;
  Entry  : TMcpClientToken;
  Items  : TMcpClientTokens;
begin
  S := TMcpTokenStore.Create;
  try
    CheckTrue(S.Add('laptop', Tok, E), E);
    CheckEquals(1, S.Count);
    Items := S.Items;
    CheckEquals('laptop', Items[0].Name);
    CheckEquals(8, Length(Items[0].Id), 'id');
    CheckEquals(Copy(Tok, Length(Tok) - 3, 4), Items[0].Hint, 'hint: the last 4 characters');
    CheckEquals(McpHashToken(Tok), Items[0].Hash, 'only the hash is kept');
    CheckEquals(0, Pos(Tok, Items[0].Hash), 'not the token');
    CheckEquals(0, Items[0].LastUsed, 'never used');

    CheckTrue(S.Find(Tok, Entry), 'found');
    CheckEquals(Items[0].Id, Entry.Id);
    CheckEquals('laptop', Entry.Name);
    CheckTrue(S.Items[0].LastUsed > 0, 'last used is set');
    CheckFalse(S.Find(Tok + 'x', Entry), 'wrong token');
    CheckFalse(S.Find('', Entry), 'empty');

    CheckTrue(S.Revoke(Items[0].Id), 'revoked');
    CheckFalse(S.Find(Tok, Entry), 'a revoked token is refused');
    CheckEquals(0, S.Count);
    CheckFalse(S.Revoke(Items[0].Id), 'twice');
  finally
    S.Free;
  end;
end;

procedure TTestTokens.TestStoreRefusals;
var
  S      : TMcpTokenStore;
  Tok, E : string;
  I      : Integer;
begin
  S := TMcpTokenStore.Create;
  try
    CheckFalse(S.Add('', Tok, E), 'no name');
    CheckTrue(E <> '');
    CheckFalse(S.Add('   ', Tok, E), 'blank name');
    CheckFalse(S.Add(StringOfChar('x', 41), Tok, E), 'long name');
    CheckFalse(S.Add('a'#9'b', Tok, E), 'control character');
    CheckEquals('', Tok, 'no token was made');
    CheckTrue(S.Add('Linux box', Tok, E), E);
    CheckFalse(S.Add('linux BOX', Tok, E), 'same name, other case');
    CheckTrue(Pos('already', E) > 0, E);
    for I := 2 to MCP_MAX_TOKENS do
      CheckTrue(S.Add('c' + IntToStr(I), Tok, E), E);
    CheckEquals(MCP_MAX_TOKENS, S.Count);
    CheckFalse(S.Add('one too many', Tok, E), 'limit');
    CheckTrue(Pos('At most', E) > 0, E);
  finally
    S.Free;
  end;
end;

procedure TTestTokens.TestAuthorize;
var
  S        : TMcpTokenStore;
  Tok, E   : string;
  Id, Name : string;
  Prim     : string;
begin
  Prim := McpNewPrimaryToken;
  S := TMcpTokenStore.Create;
  try
    CheckTrue(S.Add('laptop', Tok, E), E);
    CheckTrue(McpAuthorize('Bearer ' + Prim, Prim, S, Id, Name), 'primary');
    CheckEquals(MCP_PRIMARY_ID, Id);
    CheckEquals('', Name);
    CheckTrue(McpAuthorize('Bearer ' + Tok, Prim, S, Id, Name), 'named');
    CheckEquals('laptop', Name);
    CheckEquals(8, Length(Id));
    CheckFalse(McpAuthorize('Bearer ' + Tok + 'x', Prim, S, Id, Name), 'wrong');
    CheckEquals('', Id, 'nothing is set for a refusal');
    CheckFalse(McpAuthorize(Tok, Prim, S, Id, Name), 'no Bearer');
    CheckFalse(McpAuthorize('bearer ' + Tok, Prim, S, Id, Name), 'the scheme is case-sensitive, as before');
    CheckFalse(McpAuthorize('Bearer ', Prim, S, Id, Name), 'empty token');
    CheckFalse(McpAuthorize('', Prim, S, Id, Name), 'no header');
    { an empty primary token never matches an empty bearer }
    CheckFalse(McpAuthorize('Bearer ', '', S, Id, Name));
    CheckTrue(McpAuthorize('Bearer ' + Prim, Prim, nil, Id, Name), 'no store: primary still works');
    CheckFalse(McpAuthorize('Bearer ' + Tok, Prim, nil, Id, Name), 'no store: named refused');
    S.Revoke(S.Items[0].Id);
    CheckFalse(McpAuthorize('Bearer ' + Tok, Prim, S, Id, Name), 'revoked');
  finally
    S.Free;
  end;
end;

{ The token is shown once: the settings file holds the hash, and brings the list back }
procedure TTestTokens.TestSettingsKeepOnlyHashes;
var
  F       : string;
  A, B    : TMcpIdeSettings;
  Tok, E  : string;
  SL      : TStringList;
  Items   : TMcpClientTokens;
  Entry   : TMcpClientToken;
begin
  F := GetTempDir(False) + 'mcptokens_test.xml';
  DeleteFile(F);
  A := TMcpIdeSettings.Create;
  B := TMcpIdeSettings.Create;
  SL := TStringList.Create;
  try
    A.LoadSettings(F);
    CheckTrue(A.ClientTokens.Add('laptop', Tok, E), E);
    CheckTrue(A.ClientTokens.Find(Tok, Entry), 'used once');
    A.SaveSettings;

    SL.LoadFromFile(F);
    CheckEquals(0, Pos(Tok, SL.Text), 'the file does not hold the token');
    CheckTrue(Pos('sha1:', SL.Text) > 0, 'it holds the tagged hash');

    B.LoadSettings(F);
    Items := B.ClientTokens.Items;
    CheckEquals(1, Length(Items), 'one token read back');
    CheckEquals('laptop', Items[0].Name);
    CheckEquals(McpHashToken(Tok), Items[0].Hash);
    CheckTrue(Items[0].LastUsed > 0, 'last used kept');
    CheckTrue(Items[0].Created > 0, 'created kept');
    CheckTrue(B.ClientTokens.Find(Tok, Entry), 'the token still works after a restart');

    { revoked: gone from the file too }
    A.ClientTokens.Revoke(A.ClientTokens.Items[0].Id);
    A.SaveSettings;
    SL.LoadFromFile(F);
    CheckEquals(0, Pos('sha1:', SL.Text), 'nothing left');
  finally
    SL.Free;
    B.Free;
    A.Free;
    DeleteFile(F);
  end;
end;

initialization
  RegisterTest(TTestTokens);
end.
