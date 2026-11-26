{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpTestListener;

{ A fpcunit listener that writes one line per test as it starts, on standard output:

    ##mcp-progress 212/608 TTestSession.TestDeleteEndsSession

  ide_run_tests reads these lines while the test program runs (McpRunCapture hands the last output
  line to the progress of the call): the Messages window of the IDE gets a line every few seconds,
  and a client that asked for progress gets them in its heartbeat.  The lines are taken out of the
  output the tool answers with.  A test runner that wants this adds the listener to its result:

    Res.AddListener(TMcpTestListener.Create(ATest.CountTestCases));

  No IDE and no LCL (ADR-036). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry;

const
  MCP_PROGRESS_MARK = '##mcp-progress ';

type
  TMcpTestListener = class(TInterfacedObject, ITestListener)
  private
    FTotal : Integer;
    FCount : Integer;
  public
    constructor Create(ATotal: Integer);
    procedure AddFailure(ATest: TTest; AFailure: TTestFailure);
    procedure AddError(ATest: TTest; AError: TTestFailure);
    procedure StartTest(ATest: TTest);
    procedure EndTest(ATest: TTest);
    procedure StartTestSuite(ATestSuite: TTestSuite);
    procedure EndTestSuite(ATestSuite: TTestSuite);
  end;

implementation




constructor TMcpTestListener.Create(ATotal: Integer);
begin
  inherited Create;
  FTotal := ATotal;
end;

procedure TMcpTestListener.StartTest(ATest: TTest);
begin
  Inc(FCount);
  WriteLn(MCP_PROGRESS_MARK, FCount, '/', FTotal, ' ', ATest.TestSuiteName, '.', ATest.TestName);
  Flush(Output);
end;

{ the rest of the interface: nothing to say }
{$PUSH}{$WARN 5024 OFF}
procedure TMcpTestListener.AddFailure(ATest: TTest; AFailure: TTestFailure);
begin
end;

procedure TMcpTestListener.AddError(ATest: TTest; AError: TTestFailure);
begin
end;

procedure TMcpTestListener.EndTest(ATest: TTest);
begin
end;

procedure TMcpTestListener.StartTestSuite(ATestSuite: TTestSuite);
begin
end;

procedure TMcpTestListener.EndTestSuite(ATestSuite: TTestSuite);
begin
end;
{$POP}

end.
