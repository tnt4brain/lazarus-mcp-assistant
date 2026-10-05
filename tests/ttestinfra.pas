{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TTestInfra;

{ TTestJUnitWriter — FPCUnit tests for TJUnitResultsWriter.
  Constructs synthetic suites with known pass/fail outcomes, runs them
  through the writer against a TStringStream, and asserts XML structure.
  No running server required. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TTestJUnitWriter = class(TTestCase)
  published
    procedure TestXMLDeclarationPresent;
    procedure TestTestsuitesRootElement;
    procedure TestPassingTestHasNoChildElement;
    procedure TestFailingTestHasFailureElement;
    procedure TestErrorTestHasErrorElement;
    procedure TestSuiteNameAttribute;
    procedure TestCountsReflectResults;
    procedure TestXmlEscapingInMessage;
  end;

implementation

uses
  SysUtils, Classes, TJUnitWriter;

{ ── Synthetic test cases ─────────────────────────────────────────────────── }

type
  TPassSuite = class(TTestCase)
  published
    procedure AlwaysPasses;
  end;

  TFailSuite = class(TTestCase)
  published
    procedure AlwaysFails;
    procedure AlsoFails;
  end;

  TErrorSuite = class(TTestCase)
  published
    procedure AlwaysErrors;
  end;

  TSpecialCharSuite = class(TTestCase)
  published
    procedure TestSpecialChars;
  end;

procedure TPassSuite.AlwaysPasses;
begin
  CheckTrue(True);
end;

procedure TFailSuite.AlwaysFails;
begin
  Fail('intentional failure');
end;

procedure TFailSuite.AlsoFails;
begin
  CheckEquals(1, 2, 'expected 1 got 2');
end;

procedure TErrorSuite.AlwaysErrors;
begin
  raise Exception.Create('unexpected error');
end;

procedure TSpecialCharSuite.TestSpecialChars;
begin
  Fail('msg with <tag> & "quotes"');
end;

{ ── Helpers ──────────────────────────────────────────────────────────────── }

function RunSuiteToXML(ASuiteClass: TClass): string;
var
  Inner  : TTestSuite;
  Root   : TTestSuite;
  Res    : TTestResult;
  Strm   : TStringStream;
  Writer : TJUnitResultsWriter;
begin
  // Wrap in a root so the writer sees the same depth-1=root / depth-2=leaf
  // structure as the real test registry run.
  Inner  := TTestSuite.Create(ASuiteClass);
  Root   := TTestSuite.Create('root');
  Root.AddTest(Inner);
  Strm   := TStringStream.Create('');
  Writer := TJUnitResultsWriter.Create(Strm);
  Res    := TTestResult.Create;
  try
    Res.AddListener(Writer);
    Root.Run(Res);
    Writer.FlushXML;
    Result := Strm.DataString;
  finally
    Res.Free;
    Root.Free;   // owns Inner
    Writer.Free;
    Strm.Free;
  end;
end;

{ ── Tests ────────────────────────────────────────────────────────────────── }

procedure TTestJUnitWriter.TestXMLDeclarationPresent;
var
  XML : string;
begin
  XML := RunSuiteToXML(TPassSuite);
  CheckTrue(Pos('<?xml version="1.0"', XML) > 0,
    'Output must begin with XML declaration');
end;

procedure TTestJUnitWriter.TestTestsuitesRootElement;
var
  XML : string;
begin
  XML := RunSuiteToXML(TPassSuite);
  CheckTrue(Pos('<testsuites', XML) > 0, 'Root element must be <testsuites>');
  CheckTrue(Pos('</testsuites>', XML) > 0, 'Root element must be closed');
end;

procedure TTestJUnitWriter.TestPassingTestHasNoChildElement;
var
  XML : string;
begin
  XML := RunSuiteToXML(TPassSuite);
  CheckEquals(0, Pos('<failure', XML),
    'Passing suite must not contain <failure> element');
  CheckEquals(0, Pos('<error', XML),
    'Passing suite must not contain <error> element');
  // Self-closing <testcase ... /> must be present
  CheckTrue(Pos('<testcase', XML) > 0, 'Must have at least one <testcase>');
  CheckTrue(Pos('AlwaysPasses', XML) > 0, 'Test method name must appear in output');
end;

procedure TTestJUnitWriter.TestFailingTestHasFailureElement;
var
  XML : string;
begin
  XML := RunSuiteToXML(TFailSuite);
  CheckTrue(Pos('<failure', XML) > 0,
    'Failing suite must contain <failure> element');
  CheckEquals(0, Pos('<error', XML),
    'Failing suite must not contain <error> element');
end;

procedure TTestJUnitWriter.TestErrorTestHasErrorElement;
var
  XML : string;
begin
  XML := RunSuiteToXML(TErrorSuite);
  CheckTrue(Pos('<error', XML) > 0,
    'Suite with exception must contain <error> element');
  CheckEquals(0, Pos('<failure', XML),
    'Exception-only suite must not contain <failure> element');
end;

procedure TTestJUnitWriter.TestSuiteNameAttribute;
var
  XML : string;
begin
  XML := RunSuiteToXML(TPassSuite);
  CheckTrue(Pos('name="TPassSuite"', XML) > 0,
    'Suite name attribute must match TTestCase class name');
end;

procedure TTestJUnitWriter.TestCountsReflectResults;
var
  XML : string;
begin
  XML := RunSuiteToXML(TFailSuite);
  // TFailSuite has 2 tests, 2 failures
  CheckTrue(Pos('tests="2"', XML) > 0, 'tests attribute must be 2');
  CheckTrue(Pos('failures="2"', XML) > 0, 'failures attribute must be 2');
  CheckTrue(Pos('errors="0"', XML) > 0, 'errors attribute must be 0');
end;

procedure TTestJUnitWriter.TestXmlEscapingInMessage;
var
  XML : string;
begin
  XML := RunSuiteToXML(TSpecialCharSuite);
  CheckTrue(Pos('&lt;tag&gt;', XML) > 0, '< and > must be XML-escaped');
  CheckTrue(Pos('&amp;', XML) > 0, '& must be XML-escaped');
  CheckTrue(Pos('&quot;quotes&quot;', XML) > 0, '" must be XML-escaped');
  // Raw chars must not appear inside attribute values
  CheckEquals(0, Pos('"<tag>"', XML), 'Raw < must not appear in attribute value');
end;

initialization
  RegisterTest(TTestJUnitWriter);
end.
