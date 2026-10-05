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
    procedure TestSwap16RoundTrip;
  end;

implementation

uses
  SysUtils, Sockets;

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

initialization
  RegisterTest(TTestUtils);
end.
