{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TJUnitWriter;

{ TJUnitResultsWriter — ITestListener that emits JUnit-compatible XML.

  Attach to a TTestResult before running a suite:

    Writer := TJUnitResultsWriter.Create(Stream);
    try
      TestResult.AddListener(Writer);
      Suite.Run(TestResult);
    finally
      Writer.Free;
    end;

  The XML is flushed to the stream on destruction (or call FlushXML manually).
  One <testsuite> per TTestCase subclass; <testcase> per test method. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testutils;

type
  TJUnitTestCase = record
    Name      : string;
    ClassName : string;
    TimeMs    : Int64;    // elapsed milliseconds
    Failure   : string;   // empty = passed
    IsError   : Boolean;  // True = unexpected exception (not assertion)
  end;

  TJUnitSuite = record
    Name     : string;
    Cases    : array of TJUnitTestCase;
    Count    : Integer;
    Failures : Integer;
    Errors   : Integer;
    TimeMs   : Int64;
  end;

  TJUnitResultsWriter = class(TNoRefCountObject, ITestListener)
  private
    FStream      : TStream;
    FSuites      : array of TJUnitSuite;
    FSuiteCount  : Integer;
    FDepth       : Integer;   // suite nesting depth
    FCurSuite    : Integer;   // index into FSuites for the active leaf suite
    FCurCase     : Integer;   // index into FCurSuite.Cases for the active test
    FTestStart   : TDateTime;
    FSuiteStart  : TDateTime;
    FFailed      : Boolean;
    FFailMsg     : string;
    FIsError     : Boolean;
    FFlushed     : Boolean;
    procedure EnsureSuiteCapacity;
    procedure EnsureCaseCapacity(ASuiteIdx: Integer);
    procedure WriteXMLToStream;
    function XmlEscape(const S: string): string;
    function MsToSec(AMs: Int64): string;
  public
    constructor Create(AStream: TStream);
    destructor Destroy; override;
    procedure FlushXML;
    { ITestListener }
    procedure AddFailure(ATest: TTest; AFailure: TTestFailure);
    procedure AddError(ATest: TTest; AError: TTestFailure);
    procedure StartTest(ATest: TTest);
    procedure EndTest(ATest: TTest);
    procedure StartTestSuite(ATestSuite: TTestSuite);
    procedure EndTestSuite(ATestSuite: TTestSuite);
  end;

implementation

const
  MS_PER_DAY = 86400000;

{ ── Helpers ─────────────────────────────────────────────────────────────── }

function TJUnitResultsWriter.XmlEscape(const S: string): string;
var
  I : Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    case S[I] of
      '&': Result := Result + '&amp;';
      '<': Result := Result + '&lt;';
      '>': Result := Result + '&gt;';
      '"': Result := Result + '&quot;';
    else
      Result := Result + S[I];
    end;
end;

function TJUnitResultsWriter.MsToSec(AMs: Int64): string;
begin
  Result := Format('%.3f', [AMs / 1000.0]);
end;

procedure TJUnitResultsWriter.EnsureSuiteCapacity;
begin
  if FSuiteCount >= Length(FSuites) then
    SetLength(FSuites, FSuiteCount + 8);
end;

procedure TJUnitResultsWriter.EnsureCaseCapacity(ASuiteIdx: Integer);
begin
  with FSuites[ASuiteIdx] do
    if Count >= Length(Cases) then
      SetLength(Cases, Count + 16);
end;

{ ── Lifecycle ───────────────────────────────────────────────────────────── }

constructor TJUnitResultsWriter.Create(AStream: TStream);
begin
  inherited Create;
  FStream     := AStream;
  FSuiteCount := 0;
  FDepth      := 0;
  FCurSuite   := -1;
  FCurCase    := -1;
  FFlushed    := False;
end;

destructor TJUnitResultsWriter.Destroy;
begin
  FlushXML;
  inherited;
end;

{ ── ITestListener ───────────────────────────────────────────────────────── }

procedure TJUnitResultsWriter.StartTestSuite(ATestSuite: TTestSuite);
begin
  Inc(FDepth);
  if FDepth = 1 then
    Exit;  // root registry suite — no <testsuite> element

  // Leaf suite: one <testsuite> per TTestCase class.
  EnsureSuiteCapacity;
  with FSuites[FSuiteCount] do
  begin
    Name     := ATestSuite.TestName;
    Count    := 0;
    Failures := 0;
    Errors   := 0;
    TimeMs   := 0;
    SetLength(Cases, 0);
  end;
  FCurSuite  := FSuiteCount;
  FSuiteStart := Now;
end;

procedure TJUnitResultsWriter.EndTestSuite(ATestSuite: TTestSuite);
begin
  if FDepth > 1 then
  begin
    FSuites[FCurSuite].TimeMs := Round((Now - FSuiteStart) * MS_PER_DAY);
    Inc(FSuiteCount);
  end;
  Dec(FDepth);
end;

procedure TJUnitResultsWriter.StartTest(ATest: TTest);
begin
  if FCurSuite < 0 then Exit;
  EnsureCaseCapacity(FCurSuite);
  FCurCase := FSuites[FCurSuite].Count;
  with FSuites[FCurSuite].Cases[FCurCase] do
  begin
    Name      := ATest.TestName;
    ClassName := FSuites[FCurSuite].Name;
    TimeMs    := 0;
    Failure   := '';
    IsError   := False;
  end;
  FFailed   := False;
  FFailMsg  := '';
  FIsError  := False;
  FTestStart := Now;
end;

procedure TJUnitResultsWriter.EndTest(ATest: TTest);
var
  ElapsedMs : Int64;
begin
  if (FCurSuite < 0) or (FCurCase < 0) then Exit;
  ElapsedMs := Round((Now - FTestStart) * MS_PER_DAY);
  with FSuites[FCurSuite].Cases[FCurCase] do
  begin
    TimeMs  := ElapsedMs;
    Failure := FFailMsg;
    IsError := FIsError;
  end;
  if FFailed then
  begin
    if FIsError then
      Inc(FSuites[FCurSuite].Errors)
    else
      Inc(FSuites[FCurSuite].Failures);
  end;
  Inc(FSuites[FCurSuite].Count);
  FCurCase := -1;
end;

procedure TJUnitResultsWriter.AddFailure(ATest: TTest; AFailure: TTestFailure);
begin
  FFailed  := True;
  FIsError := False;
  FFailMsg := AFailure.ExceptionMessage;
end;

procedure TJUnitResultsWriter.AddError(ATest: TTest; AError: TTestFailure);
begin
  FFailed  := True;
  FIsError := True;
  FFailMsg := AError.ExceptionMessage;
end;

{ ── XML output ──────────────────────────────────────────────────────────── }

procedure TJUnitResultsWriter.FlushXML;
begin
  if FFlushed then Exit;
  FFlushed := True;
  WriteXMLToStream;
end;

procedure TJUnitResultsWriter.WriteXMLToStream;
var
  SB         : TStringList;
  XML        : string;
  I, J       : Integer;
  TotalTests : Integer;
  TotalFail  : Integer;
  TotalErr   : Integer;
  TotalMs    : Int64;

  procedure Emit(const S: string);
  begin
    SB.Add(S);
  end;

begin
  SB := TStringList.Create;
  try
    TotalTests := 0;
    TotalFail  := 0;
    TotalErr   := 0;
    TotalMs    := 0;
    for I := 0 to FSuiteCount - 1 do
    begin
      Inc(TotalTests, FSuites[I].Count);
      Inc(TotalFail,  FSuites[I].Failures);
      Inc(TotalErr,   FSuites[I].Errors);
      Inc(TotalMs,    FSuites[I].TimeMs);
    end;

    Emit('<?xml version="1.0" encoding="UTF-8"?>');
    Emit(Format('<testsuites tests="%d" errors="%d" failures="%d" time="%s">',
      [TotalTests, TotalErr, TotalFail, MsToSec(TotalMs)]));

    for I := 0 to FSuiteCount - 1 do
    begin
      Emit(Format('  <testsuite name="%s" tests="%d" errors="%d" failures="%d" time="%s">',
        [XmlEscape(FSuites[I].Name),
         FSuites[I].Count,
         FSuites[I].Errors,
         FSuites[I].Failures,
         MsToSec(FSuites[I].TimeMs)]));

      for J := 0 to FSuites[I].Count - 1 do
        with FSuites[I].Cases[J] do
        begin
          if Failure = '' then
            Emit(Format('    <testcase name="%s" classname="%s" time="%s"/>',
              [XmlEscape(Name), XmlEscape(ClassName), MsToSec(TimeMs)]))
          else
          begin
            Emit(Format('    <testcase name="%s" classname="%s" time="%s">',
              [XmlEscape(Name), XmlEscape(ClassName), MsToSec(TimeMs)]));
            if IsError then
              Emit(Format('      <error message="%s"/>', [XmlEscape(Failure)]))
            else
              Emit(Format('      <failure message="%s"/>', [XmlEscape(Failure)]));
            Emit('    </testcase>');
          end;
        end;

      Emit('  </testsuite>');
    end;

    Emit('</testsuites>');
    XML := SB.Text;
  finally
    SB.Free;
  end;
  if Length(XML) > 0 then
    FStream.WriteBuffer(XML[1], Length(XML));
end;

end.
