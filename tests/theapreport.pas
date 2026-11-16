{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit THeapReport;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, fpjson, McpHeapReport;

type
  TTestHeapReport = class(TTestCase)
  published
    procedure TestRealOutput;
    procedure TestNotAReport;
    procedure TestCleanRun;
    procedure TestLeaks;
    procedure TestMaxLeaks;
    procedure TestTruncatedReport;
    procedure TestReportAmongOtherOutput;
  end;

implementation

const
  CLEAN =
    'Heap dump by heaptrc unit of C:\work\clean.exe' + LineEnding +
    '12 memory blocks allocated : 480/512' + LineEnding +
    '12 memory blocks freed     : 480/512' + LineEnding +
    '0 unfreed memory blocks : 0' + LineEnding +
    'True heap size : 163840' + LineEnding +
    'True free heap : 163840' + LineEnding;

  LEAKY =
    'Heap dump by heaptrc unit of C:\work\leak.exe' + LineEnding +
    '3 memory blocks allocated : 120/128' + LineEnding +
    '1 memory blocks freed     : 40/48' + LineEnding +
    '2 unfreed memory blocks : 80' + LineEnding +
    'True heap size : 163840' + LineEnding +
    'True free heap : 162112' + LineEnding +
    'Should be : 162144' + LineEnding +
    'Call trace for block $0000000000A4C3C0 size 40' + LineEnding +
    '  $0000000000401234  main,  line 12 of leak.pas' + LineEnding +
    '  $0000000000401456' + LineEnding +
    'Call trace for block $0000000000A4C400 size 40' + LineEnding +
    '  $0000000000401234' + LineEnding;

procedure TTestHeapReport.TestRealOutput;
{ Verbatim from fpc 3.2.2 (-gh -gl), a program that leaks a list and a 40-byte block. }
const
  REAL =
    'Heap dump by heaptrc unit of C:\tmp\leak2.exe' + LineEnding +
    '120 memory blocks allocated : 4573/4888' + LineEnding +
    '117 memory blocks freed     : 4325/4640' + LineEnding +
    '3 unfreed memory blocks : 248' + LineEnding +
    'True heap size : 229376 (192 used in System startup)' + LineEnding +
    'True free heap : 228288' + LineEnding +
    'Should be : 228360' + LineEnding +
    'Call trace for block $000000000010C960 size 40' + LineEnding +
    '  $000000010000A872' + LineEnding +
    '  $000000010000178C  main,  line 7 of leak2.pas' + LineEnding +
    '  $00000001000017A6' + LineEnding +
    'Call trace for block $00000000001135F0 size 64' + LineEnding +
    '  $000000010000A872' + LineEnding +
    '  $0000000100001779  main,  line 6 of leak2.pas' + LineEnding;
var
  R : TJSONObject;
begin
  AssertTrue(ParseHeapReport(REAL, R));
  try
    AssertEquals(120, R.Integers['allocated_blocks']);
    AssertEquals(4573, R.Integers['allocated_bytes']);
    AssertEquals(117, R.Integers['freed_blocks']);
    AssertEquals(3, R.Integers['unfreed_blocks']);
    AssertEquals(248, R.Integers['unfreed_bytes']);
    AssertEquals(2, R.Arrays['leaks'].Count);
    AssertEquals(40, R.Arrays['leaks'].Objects[0].Integers['size']);
    AssertEquals(3, R.Arrays['leaks'].Objects[0].Arrays['stack'].Count);
  finally
    R.Free;
  end;
end;

procedure TTestHeapReport.TestNotAReport;
var
  R : TJSONObject;
begin
  AssertFalse('plain output', ParseHeapReport('hello' + LineEnding + 'world', R));
  AssertTrue('no object', R = nil);
  AssertFalse('empty', ParseHeapReport('', R));
  AssertFalse('a leak count without the marker',
    ParseHeapReport('2 unfreed memory blocks : 80', R));
end;

procedure TTestHeapReport.TestCleanRun;
var
  R : TJSONObject;
begin
  AssertTrue(ParseHeapReport(CLEAN, R));
  try
    AssertEquals(12,  R.Integers['allocated_blocks']);
    AssertEquals(480, R.Integers['allocated_bytes']);
    AssertEquals(12,  R.Integers['freed_blocks']);
    AssertEquals(0,   R.Integers['unfreed_blocks']);
    AssertEquals(0,   R.Integers['unfreed_bytes']);
    AssertFalse('not leaked', R.Booleans['leaked']);
    AssertEquals(0, R.Arrays['leaks'].Count);
  finally
    R.Free;
  end;
end;

procedure TTestHeapReport.TestLeaks;
var
  R : TJSONObject;
  L : TJSONObject;
begin
  AssertTrue(ParseHeapReport(LEAKY, R));
  try
    AssertEquals(3,  R.Integers['allocated_blocks']);
    AssertEquals(120, R.Integers['allocated_bytes']);
    AssertEquals(1,  R.Integers['freed_blocks']);
    AssertEquals(40, R.Integers['freed_bytes']);
    AssertEquals(2,  R.Integers['unfreed_blocks']);
    AssertEquals(80, R.Integers['unfreed_bytes']);
    AssertTrue('leaked', R.Booleans['leaked']);
    AssertEquals(2, R.Arrays['leaks'].Count);
    L := R.Arrays['leaks'].Objects[0];
    AssertEquals('$0000000000A4C3C0', L.Strings['address']);
    AssertEquals(40, L.Integers['size']);
    AssertEquals(2, L.Arrays['stack'].Count);
    AssertEquals('$0000000000401234  main,  line 12 of leak.pas',
      L.Arrays['stack'].Strings[0]);
    AssertEquals(1, R.Arrays['leaks'].Objects[1].Arrays['stack'].Count);
  finally
    R.Free;
  end;
end;

procedure TTestHeapReport.TestMaxLeaks;
var
  R : TJSONObject;
begin
  AssertTrue(ParseHeapReport(LEAKY, R, 1));
  try
    AssertEquals('the count is the program''s, the list is capped', 2, R.Integers['unfreed_blocks']);
    AssertEquals(1, R.Arrays['leaks'].Count);
    AssertEquals('the second block''s stack is not added to the first', 2,
      R.Arrays['leaks'].Objects[0].Arrays['stack'].Count);
  finally
    R.Free;
  end;
end;

procedure TTestHeapReport.TestTruncatedReport;
var
  R : TJSONObject;
begin
  { the program was killed while the report was written: take what is there }
  AssertTrue(ParseHeapReport('Heap dump by heaptrc unit of x.exe' + LineEnding +
    '3 memory blocks allocated : 12', R));
  try
    AssertEquals(3, R.Integers['allocated_blocks']);
    AssertEquals(0, R.Integers['unfreed_blocks']);
  finally
    R.Free;
  end;
  AssertTrue(ParseHeapReport('Heap dump by heaptrc unit of x.exe', R));
  R.Free;
end;

procedure TTestHeapReport.TestReportAmongOtherOutput;
var
  R : TJSONObject;
begin
  AssertTrue(ParseHeapReport('program said hi' + LineEnding + 'Runtime warning' + LineEnding +
    LEAKY + 'after' + LineEnding, R));
  try
    AssertEquals(2, R.Integers['unfreed_blocks']);
    AssertEquals(2, R.Arrays['leaks'].Count);
  finally
    R.Free;
  end;
end;

initialization
  RegisterTest(TTestHeapReport);
end.
