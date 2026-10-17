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
    procedure TestSwap16RoundTrip;
    procedure TestNormalizePathAbsolute;
    procedure TestNormalizePathRelativeUnchanged;
    procedure TestNormalizePathArgs;
    procedure TestRenameLegacyFileArg;
  end;

implementation

uses
  SysUtils, Sockets, fpjson, jsonparser;

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
  // Confirm that a port released from a listening socket registers as free.
  // Note: on Windows, SO_REUSEADDR allows rebinding an already-bound port, so
  // we only test the "freed" direction (free after close), not the "occupied"
  // direction (which would require SO_EXCLUSIVEADDRUSE on Windows).
  P := FindFreePort;
  CheckTrue(P > 0, 'FindFreePort returned 0');

  S := fpSocket(AF_INET, SOCK_STREAM, 0);
  CheckTrue(S >= 0, 'Could not create socket');
  Enable := 1;
  fpSetSockOpt(S, SOL_SOCKET, SO_REUSEADDR, @Enable, SizeOf(Enable));
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family          := AF_INET;
  Addr.sin_port            := Swap16(P);
  Addr.sin_addr.s_bytes[1] := 127;
  Addr.sin_addr.s_bytes[2] := 0;
  Addr.sin_addr.s_bytes[3] := 0;
  Addr.sin_addr.s_bytes[4] := 1;
  CheckEquals(0, fpBind(S, @Addr, SizeOf(Addr)), 'Could not bind test socket');
  CheckEquals(0, fpListen(S, 1), 'Could not listen on test socket');
  CloseSocket(S);
  CheckTrue(IsPortFree(P), 'Port must register as free immediately after the listening socket is closed');
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

procedure TTestUtils.TestRenameLegacyFileArg;
var
  Args : TJSONObject;
begin
  Args := TJSONObject(GetJSON('{"path":"a.pas"}'));
  try
    McpRenameLegacyFileArg('editor_read_file', Args);
    CheckEquals('a.pas', Args.Get('file', ''), 'path is file');
    CheckEquals(-1, Args.IndexOfName('path'), 'old name gone');
  finally
    Args.Free;
  end;
  Args := TJSONObject(GetJSON('{"file_path":"a.pas","line":3}'));
  try
    McpRenameLegacyFileArg('debug_set_breakpoint', Args);
    CheckEquals('a.pas', Args.Get('file', ''), 'file_path is file');
    CheckEquals(3, Args.Get('line', 0));
  finally
    Args.Free;
  end;
  Args := TJSONObject(GetJSON('{"file":"new.pas","filename":"old.pas"}'));
  try
    McpRenameLegacyFileArg('project_create_unit', Args);
    CheckEquals('new.pas', Args.Get('file', ''), 'file wins');
  finally
    Args.Free;
  end;
  { git_diff's path may be a directory: not renamed }
  Args := TJSONObject(GetJSON('{"path":"src"}'));
  try
    McpRenameLegacyFileArg('git_diff', Args);
    CheckEquals('src', Args.Get('path', ''));
    CheckEquals(-1, Args.IndexOfName('file'));
  finally
    Args.Free;
  end;
  McpRenameLegacyFileArg('editor_open', nil);
end;

initialization
  RegisterTest(TTestUtils);
end.
