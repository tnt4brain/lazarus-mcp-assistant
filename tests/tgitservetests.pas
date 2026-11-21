{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TGitServeTests;

{ TTestGitServe — the git server of ADR-035 (McpGitServe): HMAC and TOTP against the RFC
  vectors, and a real `git fetch` against a server on the loopback address in a throwaway
  folder.  The server unit uses no IDE, so these need neither the IDE nor its consent dialog.
  Needs git. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TTestGitServe = class(TTestCase)
  private
    FBase : string;
    FRepo : string;
    FGit  : string;
    function GitRun(const ADir: string; const AArgs: array of string; out AOut: string): Boolean;
    function FetchWith(const ACode: string; AServerUrl: string): Boolean;
    function Fetch(const AServerUrl, ACode: string): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestHmacSha1Rfc2202;
    procedure TestTotpRfc6238;
    procedure TestServeKeyIsNotTheToken;
    procedure TestLocalAddressForLoopback;
    procedure TestBadPeerIsRefused;
    procedure TestFetchWithRightCode;
    procedure TestFetchWithWrongCodeFails;
    procedure TestFiveWrongCodesLockOut;
    procedure TestStopClosesTheListener;
    procedure TestPickPortAndFixedPort;
    procedure TestFetchLimitClosesTheListener;
    procedure TestCredentialHelperAnswersTheServer;
    procedure TestInstantFpcHelperAnswersTheServer;
  end;

implementation

uses
  {$IFDEF WINDOWS} Windows, {$ENDIF}
  Classes, SysUtils, FileUtil, Process, base64, McpGitServe;

function Hex(const S: string): string;
var
  I : Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    Result := Result + LowerCase(IntToHex(Ord(S[I]), 2));
end;

procedure TTestGitServe.SetUp;
var
  Out_ : string;
begin
  FGit  := FindDefaultExecutablePath('git');
  FBase := IncludeTrailingPathDelimiter(GetTempDir) + 'mcpserve_' + IntToStr(GetTickCount64);
  FRepo := FBase + PathDelim + 'src';
  ForceDirectories(FRepo);
  if FGit = '' then Exit;
  GitRun(FRepo, ['init', '-q'], Out_);
  GitRun(FRepo, ['config', 'user.email', 't@example.com'], Out_);
  GitRun(FRepo, ['config', 'user.name', 'T'], Out_);
  with TStringList.Create do
  try
    Add('hello');
    SaveToFile(FRepo + PathDelim + 'a.txt');
  finally
    Free;
  end;
  GitRun(FRepo, ['add', 'a.txt'], Out_);
  GitRun(FRepo, ['commit', '-q', '-m', 'one'], Out_);
end;

procedure TTestGitServe.TearDown;
begin
  if DirectoryExists(FBase) then
    DeleteDirectory(FBase, False);
end;

function TTestGitServe.GitRun(const ADir: string; const AArgs: array of string;
  out AOut: string): Boolean;
var
  Status : Integer;
begin
  Result := RunCommandInDir(ADir, FGit, AArgs, AOut, Status) = 0;
  Result := Result and (Status = 0);
end;

{ git fetch of the server's HEAD into a fresh repository; True when it worked. }
function TTestGitServe.Fetch(const AServerUrl, ACode: string): Boolean;
var
  Dst, Out_ : string;
begin
  Dst := FBase + PathDelim + 'dst' + IntToStr(GetTickCount64);
  ForceDirectories(Dst);
  GitRun(Dst, ['init', '-q'], Out_);
  { 'credential.helper=' first: no helper of the system (Git Credential Manager opens a window
    when the server answers 401) may be asked }
  Result := GitRun(Dst, ['-c', 'credential.helper=', '-c', 'http.extraHeader=Authorization: Basic ' +
    EncodeStringBase64('mcp:' + ACode), 'fetch', '-q', AServerUrl, '+HEAD:refs/mcp/snapshot'],
    Out_);
end;

function TTestGitServe.FetchWith(const ACode: string; AServerUrl: string): Boolean;
begin
  Result := Fetch(AServerUrl, ACode);
end;

procedure TTestGitServe.TestHmacSha1Rfc2202;
begin
  { RFC 2202, case 1 }
  CheckEquals('b617318655057264e28bc0b6fb378c8ef146be00',
    Hex(McpHmacSha1(StringOfChar(#$0B, 20), 'Hi There')), 'case 1');
  { case 2 }
  CheckEquals('effcdf6ae5eb2fa2d27416d5f184df9c259a7c79',
    Hex(McpHmacSha1('Jefe', 'what do ya want for nothing?')), 'case 2');
  { a key longer than the block (case 6) }
  CheckEquals('aa4ae5e15272d00e95705637ce8a3b55ed402112',
    Hex(McpHmacSha1(StringOfChar(#$AA, 80),
      'Test Using Larger Than Block-Size Key - Hash Key First')), 'case 6');
end;

procedure TTestGitServe.TestTotpRfc6238;
const
  KEY = '12345678901234567890';
begin
  CheckEquals('94287082', McpTotp(KEY, 59, 8), 't=59');
  CheckEquals('07081804', McpTotp(KEY, 1111111109, 8), 't=1111111109');
  CheckEquals('14050471', McpTotp(KEY, 1111111111, 8), 't=1111111111');
  CheckEquals('89005924', McpTotp(KEY, 1234567890, 8), 't=1234567890');
  CheckEquals('69279037', McpTotp(KEY, 2000000000, 8), 't=2000000000');
  CheckEquals('287082', McpTotp(KEY, 59), 'six digits are the last six');
end;

procedure TTestGitServe.TestServeKeyIsNotTheToken;
begin
  CheckEquals(20, Length(McpServeKey('token-a')), 'a SHA-1 sized key');
  CheckTrue(McpServeKey('token-a') <> 'token-a', 'not the token');
  CheckTrue(McpServeKey('token-a') <> McpServeKey('token-b'), 'one key per token');
  CheckTrue(McpTotp(McpServeKey('token-a'), 1000) <> McpTotp(McpServeKey('token-b'), 1000),
    'one code per token');
end;

procedure TTestGitServe.TestLocalAddressForLoopback;
var
  Local, Why : string;
begin
  CheckTrue(McpLocalAddressFor('127.0.0.1', Local, Why), Why);
  CheckEquals('127.0.0.1', Local);
end;

procedure TTestGitServe.TestBadPeerIsRefused;
var
  Local, Why : string;
begin
  CheckFalse(McpLocalAddressFor('not-an-address', Local, Why), 'a name');
  CheckTrue(Why <> '', 'says why');
  CheckFalse(McpLocalAddressFor('1.2.3', Local, Why), 'three parts');
  CheckFalse(McpLocalAddressFor('1.2.3.400', Local, Why), 'out of range');
end;

procedure TTestGitServe.TestFetchWithRightCode;
var
  Srv  : TGitServe;
  Why, Code : string;
  Left : Integer;
begin
  if FGit = '' then Ignore('no git');
  Srv := TGitServe.Create(FGit, FRepo, '127.0.0.1', McpServeKey('tok'));
  try
    CheckTrue(Srv.Start(1, Why), Why);
    CheckTrue(Srv.Port > 0, 'the OS chose a port');
    Code := Srv.Code(Left);
    CheckTrue(Fetch('http://127.0.0.1:' + IntToStr(Srv.Port) + '/repo.git', Code),
      'a fetch with the current code works');
    CheckTrue(Srv.Served > 0, 'it served a request');
  finally
    Srv.Free;
  end;
end;

procedure TTestGitServe.TestFetchWithWrongCodeFails;
var
  Srv : TGitServe;
  Why : string;
begin
  if FGit = '' then Ignore('no git');
  Srv := TGitServe.Create(FGit, FRepo, '127.0.0.1', McpServeKey('tok'));
  try
    CheckTrue(Srv.Start(1, Why), Why);
    CheckFalse(Fetch('http://127.0.0.1:' + IntToStr(Srv.Port) + '/repo.git', '000000'),
      'a wrong code');
    CheckFalse(Fetch('http://127.0.0.1:' + IntToStr(Srv.Port) + '/repo.git',
      McpTotp(McpServeKey('other'), 0)), 'a code of another token');
    CheckTrue(Srv.Wrong >= 1, 'wrong codes are counted');
  finally
    Srv.Free;
  end;
end;

procedure TTestGitServe.TestFiveWrongCodesLockOut;
var
  Srv  : TGitServe;
  Why, Code : string;
  Left, I : Integer;
begin
  if FGit = '' then Ignore('no git');
  Srv := TGitServe.Create(FGit, FRepo, '127.0.0.1', McpServeKey('tok'));
  try
    CheckTrue(Srv.Start(1, Why), Why);
    for I := 1 to 6 do
      Fetch('http://127.0.0.1:' + IntToStr(Srv.Port) + '/repo.git', '111111');
    Code := Srv.Code(Left);
    CheckFalse(Fetch('http://127.0.0.1:' + IntToStr(Srv.Port) + '/repo.git', Code),
      'even the right code is refused during the lockout');
  finally
    Srv.Free;
  end;
end;

procedure TTestGitServe.TestStopClosesTheListener;
var
  Srv  : TGitServe;
  Why, Code : string;
  Left : Integer;
  Port : Word;
begin
  if FGit = '' then Ignore('no git');
  Srv := TGitServe.Create(FGit, FRepo, '127.0.0.1', McpServeKey('tok'));
  try
    CheckTrue(Srv.Start(1, Why), Why);
    Port := Srv.Port;
    Code := Srv.Code(Left);
    Srv.Stop;
    CheckFalse(Srv.Running, 'not running');
    CheckFalse(Fetch('http://127.0.0.1:' + IntToStr(Port) + '/repo.git', Code),
      'nothing answers after stop');
  finally
    Srv.Free;
  end;
end;

procedure TTestGitServe.TestPickPortAndFixedPort;
var
  Srv  : TGitServe;
  Why  : string;
  Port : Word;
begin
  if FGit = '' then Ignore('no git');
  Port := McpPickPort('127.0.0.1');
  CheckTrue(Port > 0, 'a free port');
  Srv := TGitServe.Create(FGit, FRepo, '127.0.0.1', McpServeKey('tok'));
  try
    CheckTrue(Srv.Start(1, Why, Port), Why);
    CheckEquals(Port, Srv.Port, 'the kept port');
  finally
    Srv.Free;
  end;
end;

procedure TTestGitServe.TestFetchLimitClosesTheListener;
var
  Srv  : TGitServe;
  Why, Code : string;
  Left, I : Integer;
begin
  if FGit = '' then Ignore('no git');
  Srv := TGitServe.Create(FGit, FRepo, '127.0.0.1', McpServeKey('tok'));
  try
    Srv.FetchLimit := 1;
    CheckTrue(Srv.Start(1, Why), Why);
    Code := Srv.Code(Left);
    CheckTrue(Fetch('http://127.0.0.1:' + IntToStr(Srv.Port) + '/repo.git', Code), 'the fetch');
    for I := 1 to 100 do
      if Srv.Running then Sleep(20);
    CheckFalse(Srv.Running, 'closed itself after the fetch');
    Code := Srv.Code(Left);
    CheckFalse(Fetch('http://127.0.0.1:' + IntToStr(Srv.Port) + '/repo.git', Code),
      'a second fetch finds nobody');
  finally
    Srv.Free;
  end;
end;

{ The helper script of git_serve link, run by git itself: it must make the code the server wants. }
procedure TTestGitServe.TestCredentialHelperAnswersTheServer;
var
  Srv    : TGitServe;
  Why, Script, Key, Dst, Out_ : string;
  I      : Integer;
begin
  if FGit = '' then Ignore('no git');
  Script := StringReplace(ExpandFileName(ExtractFilePath(ParamStr(0)) +
    '..' + PathDelim + 'scripts' + PathDelim + 'git-credential-mcp'), '\', '/', [rfReplaceAll]);
  if not FileExists(Script) then Ignore('no ' + Script);
  Key := '';
  for I := 1 to 20 do Key := Key + Chr(I * 7);
  Srv := TGitServe.Create(FGit, FRepo, '127.0.0.1', Key);
  try
    CheckTrue(Srv.Start(1, Why), Why);
    Dst := FBase + PathDelim + 'viahelper';
    ForceDirectories(Dst);
    GitRun(Dst, ['init', '-q'], Out_);
    if not GitRun(Dst, ['-c', 'credential.helper=', '-c', 'credential.helper=!sh ' + Script + ' ' + Hex(Key),
         'fetch', '-q', 'http://127.0.0.1:' + IntToStr(Srv.Port) + '/repo.git',
         '+HEAD:refs/mcp/snapshot'], Out_) then
      Ignore('the helper could not run here (needs sh and openssl): ' + Out_);
    CheckTrue(Srv.Served > 0, 'git got its credentials from the helper');
  finally
    Srv.Free;
  end;
end;

{ The same, with the instantfpc script (scripts/git-credential-mcp.pas).  instantfpc and fpc must
  be on PATH, or MCP_FPC_DIR names the folder that holds them. }
procedure TTestGitServe.TestInstantFpcHelperAnswersTheServer;
var
  Srv    : TGitServe;
  Why, Script, Key, Dst, Out_, Dir : string;
  I      : Integer;
begin
  if FGit = '' then Ignore('no git');
  Dir := GetEnvironmentVariable('MCP_FPC_DIR');
  {$IFDEF WINDOWS}
  if Dir <> '' then
    Windows.SetEnvironmentVariable('PATH', PChar(Dir + PathSeparator + GetEnvironmentVariable('PATH')));
  {$ENDIF}
  if (FindDefaultExecutablePath('instantfpc') = '') or (FindDefaultExecutablePath('fpc') = '') then
    Ignore('instantfpc and fpc are not on PATH (set MCP_FPC_DIR)');
  Script := StringReplace(ExpandFileName(ExtractFilePath(ParamStr(0)) +
    '..' + PathDelim + 'scripts' + PathDelim + 'git-credential-mcp.pas'), '\', '/', [rfReplaceAll]);
  if not FileExists(Script) then Ignore('no ' + Script);
  Key := '';
  for I := 1 to 20 do Key := Key + Chr(I * 11);
  Srv := TGitServe.Create(FGit, FRepo, '127.0.0.1', Key);
  try
    CheckTrue(Srv.Start(1, Why), Why);
    Dst := FBase + PathDelim + 'viapas';
    ForceDirectories(Dst);
    GitRun(Dst, ['init', '-q'], Out_);
    CheckTrue(GitRun(Dst, ['-c', 'credential.helper=', '-c', 'credential.helper=!instantfpc ' + Script + ' ' + Hex(Key),
      'fetch', '-q', 'http://127.0.0.1:' + IntToStr(Srv.Port) + '/repo.git',
      '+HEAD:refs/mcp/snapshot'], Out_), 'the fetch through the script: ' + Out_);
    CheckTrue(Srv.Served > 0, 'git got its credentials from the script');
  finally
    Srv.Free;
  end;
end;

initialization
  RegisterTest(TTestGitServe);

end.
