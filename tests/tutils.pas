{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TUtils;

{ TTestUtils — standalone FPCUnit tests for McpUtils functions.
  No IDE or running server required. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, McpUtils;

type
  TTestUtils = class(TTestCase)
  published
    procedure TestGenerateTokenIs64Chars;
    procedure TestGenerateTokenAllHex;
    procedure TestGenerateTokenIsUnique;
    procedure TestFindFreePortNonZero;
    procedure TestFindFreePortIsUsable;
    procedure TestIsPortFreeForBoundPort;
    procedure TestListenAddresses;
    procedure TestPortToPersist;
    procedure TestSwap16RoundTrip;
    procedure TestNormalizePathAbsolute;
    procedure TestNormalizePathRelativeUnchanged;
    procedure TestNormalizePathArgs;
    procedure TestPathIsUnder;
    procedure TestPathHasSegment;
    procedure TestRepoRoot;
  end;

implementation

uses
  SysUtils, Sockets, fpjson, jsonparser;

procedure TTestUtils.TestPathIsUnder;
var
  Root, Sep, DiskRoot : string;
begin
  Sep := PathDelim;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'mcproot';
  AssertTrue('a file', McpPathIsUnder(Root + Sep + 'a.pas', Root));
  AssertTrue('a file below a folder', McpPathIsUnder(Root + Sep + 'sub' + Sep + 'a.pas', Root));
  AssertTrue('the root written with a trailing separator', McpPathIsUnder(Root + Sep + 'a.pas', Root + Sep));
  AssertFalse('the root itself', McpPathIsUnder(Root, Root));
  AssertFalse('a sibling with the same start', McpPathIsUnder(Root + '2' + Sep + 'a.pas', Root));
  AssertFalse('.. leaves the root', McpPathIsUnder(Root + Sep + '..' + Sep + 'a.pas', Root));
  AssertTrue('.. that stays inside', McpPathIsUnder(Root + Sep + 'x' + Sep + '..' + Sep + 'a.pas', Root));
  AssertFalse('a relative path', McpPathIsUnder('a.pas', Root));
  AssertFalse('a relative root', McpPathIsUnder(Root + Sep + 'a.pas', 'mcproot'));
  DiskRoot := IncludeTrailingPathDelimiter(ExtractFileDrive(Root));
  AssertFalse('a disk root contains nothing', McpPathIsUnder(Root + Sep + 'a.pas', DiskRoot));
  {$IFDEF WINDOWS}
  AssertTrue('Windows does not care about case', McpPathIsUnder(UpperCase(Root) + Sep + 'A.PAS', Root));
  {$ENDIF}
end;

procedure TTestUtils.TestRepoRoot;
var
  Base, Deep : string;
  F : TextFile;
begin
  Base := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'mcprepo' + PathDelim;
  Deep := Base + 'a' + PathDelim + 'b' + PathDelim;
  ForceDirectories(Deep);
  ForceDirectories(Base + '.git');
  try
    AssertEquals('the folder with .git', Base, McpRepoRoot(Deep));
    AssertEquals('the folder itself', Base, McpRepoRoot(Base));
    AssertEquals('a relative path has none', '', McpRepoRoot('a' + PathDelim + 'b'));
    { a worktree has a .git file, not a folder }
    RemoveDir(Base + '.git');
    AssignFile(F, Base + '.git');
    Rewrite(F);
    WriteLn(F, 'gitdir: elsewhere');
    CloseFile(F);
    AssertEquals('.git as a file', Base, McpRepoRoot(Deep));
  finally
    DeleteFile(Base + '.git');
    RemoveDir(Deep);
    RemoveDir(Base + 'a' + PathDelim);
    RemoveDir(Base);
  end;
end;

procedure TTestUtils.TestPathHasSegment;
begin
  AssertTrue(McpPathHasSegment('/a/.git/hooks/pre-push', '.git'));
  AssertTrue(McpPathHasSegment('C:\a\.GIT\config', '.git'));
  AssertFalse(McpPathHasSegment('/a/.github/x', '.git'));
  AssertFalse(McpPathHasSegment('/a/b.git/x', '.git'));
  AssertTrue(McpPathHasSegment('/a/b/.git', '.git'));
end;

procedure TTestUtils.TestGenerateTokenIs64Chars;
begin
  CheckEquals(64, Length(GenerateToken),
    'GenerateToken must return exactly 64 characters');
end;

procedure TTestUtils.TestGenerateTokenAllHex;
var
  T : string;
  I : Integer;
begin
  T := GenerateToken;
  for I := 1 to Length(T) do
    CheckTrue(T[I] in ['0'..'9', 'A'..'F', 'a'..'f'],
      'GenerateToken char ' + IntToStr(I) + ' is not hex: ' + T[I]);
end;

procedure TTestUtils.TestGenerateTokenIsUnique;
begin
  CheckNotEquals(GenerateToken, GenerateToken,
    'Two consecutive GenerateToken calls must return different values');
end;

{ Where the server may listen: IPv4 addresses only, the loopback is the default }
procedure TTestUtils.TestListenAddresses;
var
  P : Word;
begin
  CheckTrue(McpValidListenAddress('127.0.0.1'));
  CheckTrue(McpValidListenAddress('0.0.0.0'));
  CheckTrue(McpValidListenAddress('192.0.2.10'));
  CheckFalse(McpValidListenAddress(''), 'empty');
  CheckFalse(McpValidListenAddress('localhost'), 'a name');
  CheckFalse(McpValidListenAddress('1.2.3'), 'three numbers');
  CheckFalse(McpValidListenAddress('1.2.3.4.5'), 'five numbers');
  CheckFalse(McpValidListenAddress('256.1.1.1'), 'out of range');
  CheckFalse(McpValidListenAddress('1.2.3.-4'), 'a sign');
  CheckFalse(McpValidListenAddress('1..3.4'), 'an empty part');
  CheckFalse(McpValidListenAddress('::1'), 'IPv6');

  CheckTrue(McpIsLoopback('127.0.0.1'));
  CheckTrue(McpIsLoopback('127.1.2.3'));
  CheckFalse(McpIsLoopback('0.0.0.0'), 'every interface is not the loopback');
  CheckFalse(McpIsLoopback('10.0.0.1'));
  CheckFalse(McpIsLoopback('127.x'));

  CheckEquals('127.0.0.1', McpClientHost('0.0.0.0'), 'reached through the loopback');
  CheckEquals('127.0.0.1', McpClientHost(''));
  CheckEquals('127.0.0.1', McpClientHost('nonsense'));
  CheckEquals('192.0.2.10', McpClientHost('192.0.2.10'));

  { '' without a network; otherwise an address of this machine, never 0.0.0.0 or the loopback }
  CheckFalse(McpIsLoopback(McpPrimaryAddress) or (McpPrimaryAddress = '0.0.0.0'));
  CheckTrue((McpPrimaryAddress = '') or McpValidListenAddress(McpPrimaryAddress));

  P := FindFreePort('0.0.0.0');
  CheckTrue(P > 0, 'a port on every interface');
  CheckTrue(IsPortFree(P, '0.0.0.0'));
  CheckEquals(0, FindFreePort('203.0.113.77'), 'an address this machine does not have');
end;

procedure TTestUtils.TestFindFreePortNonZero;
begin
  CheckTrue(FindFreePort > 0, 'FindFreePort must return a non-zero port');
end;

procedure TTestUtils.TestFindFreePortIsUsable;
var
  P : Word;
begin
  P := FindFreePort;
  CheckTrue(P > 0, 'FindFreePort returned 0');
  CheckTrue(IsPortFree(P),
    'Port returned by FindFreePort should pass IsPortFree immediately after');
end;

procedure TTestUtils.TestIsPortFreeForBoundPort;
var
  P      : Word;
  S      : LongInt;
  Addr   : TInetSockAddr;
  Enable : LongInt;
begin
  // A port held by a listening socket is not free, even when that socket set SO_REUSEADDR (on
  // Windows a bind with the option would succeed against it: ADR-032); once the socket is
  // closed the port is free again.
  P := FindFreePort;
  CheckTrue(P > 0, 'FindFreePort returned 0');

  S := fpSocket(AF_INET, SOCK_STREAM, 0);
  CheckTrue(S >= 0, 'Could not create socket');
  Enable := 1;
  fpSetSockOpt(S, SOL_SOCKET, SO_REUSEADDR, @Enable, SizeOf(Enable));
  Addr := Default(TInetSockAddr);
  Addr.sin_family          := AF_INET;
  Addr.sin_port            := Swap16(P);
  Addr.sin_addr.s_bytes[1] := 127;
  Addr.sin_addr.s_bytes[2] := 0;
  Addr.sin_addr.s_bytes[3] := 0;
  Addr.sin_addr.s_bytes[4] := 1;
  CheckEquals(0, fpBind(S, @Addr, SizeOf(Addr)), 'Could not bind test socket');
  CheckEquals(0, fpListen(S, 1), 'Could not listen on test socket');
  CheckFalse(IsPortFree(P), 'A port a socket listens on is not free');
  CloseSocket(S);
  CheckTrue(IsPortFree(P), 'Port must register as free immediately after the listening socket is closed');
end;

procedure TTestUtils.TestPortToPersist;
begin
  CheckEquals(38765, McpPortToPersist(0, 38765), 'first start keeps the port it got');
  CheckEquals(38765, McpPortToPersist(38765, 38765), 'the stored port stays');
  CheckEquals(38765, McpPortToPersist(38765, 64099),
    'a fallback port must not replace the stored one');
end;

procedure TTestUtils.TestSwap16RoundTrip;
begin
  CheckEquals(Word($1234), Swap16(Swap16($1234)), 'Swap16 round-trip failed');
  CheckEquals(Word($AB00), Swap16(Word($00AB)), 'Swap16 byte swap failed');
end;

procedure TTestUtils.TestNormalizePathAbsolute;
begin
  {$IFDEF WINDOWS}
  CheckEquals('D:\a\c\f.pas', McpNormalizePath('D:/a/b/../c/./f.pas'));
  CheckEquals('D:\a\f.pas', McpNormalizePath('D:\a\f.pas'), 'already normal');
  {$ELSE}
  CheckEquals('/a/c/f.pas', McpNormalizePath('/a/b/../c/./f.pas'));
  CheckEquals('/a/f.pas', McpNormalizePath('/a/f.pas'), 'already normal');
  {$ENDIF}
end;

procedure TTestUtils.TestNormalizePathRelativeUnchanged;
begin
  { tools resolve these against their own base directory }
  CheckEquals('tests/x.lpi', McpNormalizePath('tests/x.lpi'));
  CheckEquals('../src', McpNormalizePath('../src'));
  CheckEquals('', McpNormalizePath(''));
end;

procedure TTestUtils.TestNormalizePathArgs;
var
  Args : TJSONObject;
  Abs  : string;
begin
  {$IFDEF WINDOWS}Abs := 'C:/p/./u.pas';{$ELSE}Abs := '/p/./u.pas';{$ENDIF}
  Args := TJSONObject(GetJSON('{"file":"' + Abs + '","form_file":"' + Abs + '",' +
    '"output_dir":"' + Abs + '","query":"' + Abs + '","line":3,"test_project":"t/x.lpi"}'));
  try
    McpNormalizePathArgs(Args);
    CheckEquals(McpNormalizePath(Abs), Args.Get('file', ''));
    CheckEquals(McpNormalizePath(Abs), Args.Get('form_file', ''));
    CheckNotEquals(Abs, Args.Get('file', ''), 'the path argument was changed');
    CheckEquals(Abs, Args.Get('output_dir', ''), 'output_dir is stored as written');
    CheckEquals(Abs, Args.Get('query', ''), 'not a path argument');
    CheckEquals(3, Args.Get('line', 0));
    CheckEquals('t/x.lpi', Args.Get('test_project', ''), 'relative stays relative');
  finally
    Args.Free;
  end;
  McpNormalizePathArgs(nil);   { no arguments at all }
end;

initialization
  RegisterTest(TTestUtils);
end.
