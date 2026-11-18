{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TSelfTest;

{ McpSelfTest (ADR-032), the connection test of the Options page.
  TTestSelfTest needs a running MCP server; TTestSelfTestOffline does not. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, McpSelfTest, THttpHelper;

type
  TTestSelfTest = class(TTestCase)
  published
    procedure TestEverythingPasses;
    procedure TestWrongTokenIsReportedAndSkipsTheRest;
  end;

  TTestSelfTestOffline = class(TTestCase)
  published
    procedure TestClosedPortFailsTheFirstCheckOnly;
    procedure TestTextSaysWhichCheckFailed;
  end;

implementation

uses
  SysUtils, McpUtils;

procedure TTestSelfTest.TestEverythingPasses;
var
  C : TMcpSelfTestChecks;
  I : Integer;
begin
  C := McpRunSelfTest('127.0.0.1', GServerPort, GServerToken);
  CheckEquals(5, Length(C), 'five checks');
  for I := 0 to High(C) do
    CheckTrue(C[I].State = csOk, C[I].Name + ': ' + C[I].Detail);
  CheckTrue(McpSelfTestPassed(C));
  CheckTrue(Pos('tools', C[2].Detail) > 0, 'says how many tools: ' + C[2].Detail);
  CheckTrue(Pos('Everything a client needs works', McpSelfTestText(C)) > 0);
  CheckEquals(0, Pos(GServerToken, McpSelfTestText(C)), 'the token is not in the text');
end;

procedure TTestSelfTest.TestWrongTokenIsReportedAndSkipsTheRest;
var
  C : TMcpSelfTestChecks;
begin
  C := McpRunSelfTest('127.0.0.1', GServerPort, 'lmcp_wrong');
  CheckEquals(5, Length(C));
  CheckTrue(C[0].State = csOk, 'the server is there: ' + C[0].Detail);
  CheckTrue(C[1].State = csFailed, 'the token is not accepted');
  CheckTrue(Pos('401', C[1].Detail) > 0, C[1].Detail);
  CheckTrue(C[2].State = csSkipped, 'tools/list is not tried');
  CheckTrue(C[3].State = csOk, 'but a wrong token is refused, which is the point: ' + C[3].Detail);
  CheckTrue(C[4].State = csSkipped, 'ide_ping is not tried');
  CheckFalse(McpSelfTestPassed(C));
end;

procedure TTestSelfTestOffline.TestClosedPortFailsTheFirstCheckOnly;
var
  C : TMcpSelfTestChecks;
  I : Integer;
  P : Word;
begin
  P := FindFreePort;
  CheckTrue(P > 0);
  C := McpRunSelfTest('127.0.0.1', P, 'whatever');
  CheckEquals(5, Length(C));
  CheckTrue(C[0].State = csFailed, 'no server: ' + C[0].Detail);
  for I := 1 to High(C) do
    CheckTrue(C[I].State = csSkipped, 'nothing after it is tried: ' + C[I].Name);
  CheckFalse(McpSelfTestPassed(C));
  CheckFalse(McpSelfTestPassed(nil), 'no checks is not a pass');
end;

procedure TTestSelfTestOffline.TestTextSaysWhichCheckFailed;
var
  T : string;
begin
  T := McpSelfTestText(McpRunSelfTest('127.0.0.1', FindFreePort, 'x'));
  CheckTrue(Pos('FAILED', T) > 0, T);
  CheckTrue(Pos('skipped', T) > 0, T);
  CheckTrue(Pos('see the first FAILED line', T) > 0, T);
end;

initialization
  RegisterTest(TTestSelfTestOffline);
end.
