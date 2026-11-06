{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TReport;

{ The report bundle's text handling (ADR-022, Amendment 1): tails, the home
  directory, the size cap, the files.  Standalone, no IDE. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, fpcunit, testregistry, McpReport;

type
  TTestReport = class(TTestCase)
  private
    FDir : string;
    function Numbered(ACount: Integer): string;
    function CountOf(const ASub, AText: string): Integer;
    function ReportFiles: Integer;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestTailKeepsTheLastLines;
    procedure TestTailOfShortTextIsAll;
    procedure TestTailIgnoresCrAndClosingBreak;
    procedure TestReadTailOfAbsentFileSaysSo;
    procedure TestReadTailOfBigFileDropsThePartialLine;
    procedure TestHomeBecomesTildeInEveryForm;
    procedure TestShortHomeIsLeftAlone;
    procedure TestPartsComeInOrderAndFencedOnes;
    procedure TestSizeCapCutsEarlyLinesOfShrinkableParts;
    procedure TestSizeCapNeverCutsTheOtherParts;
    procedure TestFileNamesSortByTime;
    procedure TestWriteNeverOverwritesAndKeepsThree;
  end;

implementation

procedure TTestReport.SetUp;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'mcpreport-' +
          IntToStr(GetTickCount64) + '-' + IntToStr(Random(100000));
  ForceDirectories(FDir);
end;

procedure TTestReport.TearDown;
var
  SR : TSearchRec;
begin
  if FindFirst(IncludeTrailingPathDelimiter(FDir) + '*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') then
        DeleteFile(IncludeTrailingPathDelimiter(FDir) + SR.Name);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  RemoveDir(FDir);
end;

function TTestReport.Numbered(ACount: Integer): string;
var
  I : Integer;
begin
  Result := '';
  for I := 1 to ACount do
    Result := Result + 'line ' + IntToStr(I) + LineEnding;
end;

function TTestReport.CountOf(const ASub, AText: string): Integer;
var
  P : Integer;
begin
  Result := 0;
  P := Pos(ASub, AText);
  while P > 0 do
  begin
    Inc(Result);
    P := PosEx(ASub, AText, P + Length(ASub));
  end;
end;

function TTestReport.ReportFiles: Integer;
var
  SR : TSearchRec;
begin
  Result := 0;
  if FindFirst(IncludeTrailingPathDelimiter(FDir) + 'mcp-report-*.md', faAnyFile, SR) = 0 then
  begin
    repeat
      Inc(Result);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
end;

procedure TTestReport.TestTailKeepsTheLastLines;
begin
  AssertEquals('line 4' + LineEnding + 'line 5' + LineEnding, McpTailLines(Numbered(5), 2));
end;

procedure TTestReport.TestTailOfShortTextIsAll;
begin
  AssertEquals(Numbered(3), McpTailLines(Numbered(3), 200));
  AssertEquals('', McpTailLines('', 5));
  AssertEquals('', McpTailLines(Numbered(3), 0));
end;

procedure TTestReport.TestTailIgnoresCrAndClosingBreak;
begin
  AssertEquals('b' + LineEnding + 'c' + LineEnding, McpTailLines('a'#13#10'b'#13#10'c'#13#10, 2));
  AssertEquals('c' + LineEnding, McpTailLines('a'#10'b'#10'c', 1));
end;

procedure TTestReport.TestReadTailOfAbsentFileSaysSo;
var
  Note : string;
begin
  AssertEquals('', McpReadTail(FDir + PathDelim + 'nope.log', 10, Note));
  AssertEquals('not present', Note);
end;

procedure TTestReport.TestReadTailOfBigFileDropsThePartialLine;
var
  F    : TStringList;
  I    : Integer;
  Note, Tail : string;
begin
  F := TStringList.Create;
  try
    for I := 1 to 40000 do F.Add('entry number ' + IntToStr(I) + ' with some padding text');
    F.SaveToFile(FDir + PathDelim + 'big.log');
  finally
    F.Free;
  end;
  Tail := McpReadTail(FDir + PathDelim + 'big.log', 3, Note);
  AssertEquals('', Note);
  AssertEquals('entry number 39998 with some padding text' + LineEnding +
               'entry number 39999 with some padding text' + LineEnding +
               'entry number 40000 with some padding text' + LineEnding, Tail);
end;

procedure TTestReport.TestHomeBecomesTildeInEveryForm;
var
  S : string;
begin
  S := McpRedactHome('C:\Users\Admin\a.pas and c:/users/admin/b.pas and "C:\\Users\\Admin\\c.pas"',
                     'C:\Users\Admin\');
  AssertEquals('~\a.pas and ~/b.pas and "~\\c.pas"', S);
  AssertEquals('"~\\\\d.pas"', McpRedactHome('"C:\\\\Users\\\\Admin\\\\d.pas"', 'C:\Users\Admin'));
end;

procedure TTestReport.TestShortHomeIsLeftAlone;
begin
  AssertEquals('/x/y', McpRedactHome('/x/y', '/'));
  AssertEquals('C:\x', McpRedactHome('C:\x', 'C:'));
  AssertEquals('abc', McpRedactHome('abc', ''));
end;

procedure TTestReport.TestPartsComeInOrderAndFencedOnes;
var
  P : TMcpReportParts;
  R : string;
begin
  SetLength(P, 2);
  P[0] := McpReportPart('Versions', '- plugin 1.1.1', False, False);
  P[1] := McpReportPart('Log', 'a ```` b', True, True);
  R := McpComposeReport(P, 'at 2026-11-06T10:00:00Z', MCP_REPORT_MAX_BYTES);
  AssertTrue('heading', Pos('# MCP Assistant report', R) = 1);
  AssertTrue('order', Pos('## Versions', R) < Pos('## Log', R));
  AssertTrue('plain part unfenced', Pos('- plugin 1.1.1', R) > 0);
  AssertEquals('fence open and close', 2, CountOf('````' + LineEnding, R));
  AssertTrue('stamp', Pos('at 2026-11-06T10:00:00Z', R) > 0);
end;

procedure TTestReport.TestSizeCapCutsEarlyLinesOfShrinkableParts;
var
  P : TMcpReportParts;
  R : string;
begin
  SetLength(P, 1);
  P[0] := McpReportPart('Log', Numbered(2000), True, True);
  R := McpComposeReport(P, 's', 4000);
  AssertTrue('within the cap', Length(R) <= 4000);
  AssertTrue('newest line kept', Pos('line 2000', R) > 0);
  AssertTrue('oldest line gone', Pos('line 1' + LineEnding, R) = 0);
  AssertTrue('cut counted', Pos('earlier lines cut to fit', R) > 0);
end;

procedure TTestReport.TestSizeCapNeverCutsTheOtherParts;
var
  P : TMcpReportParts;
  R : string;
begin
  SetLength(P, 2);
  P[0] := McpReportPart('Settings', Numbered(50), False, False);
  P[1] := McpReportPart('Log', Numbered(2000), True, True);
  R := McpComposeReport(P, 's', 5000);
  AssertTrue('first line of the fixed part', Pos('line 1' + LineEnding + 'line 2' + LineEnding, R) > 0);
  AssertTrue('last line of the fixed part', Pos('line 50' + LineEnding, R) > 0);
  AssertTrue('within the cap', Length(R) <= 5000);
end;

procedure TTestReport.TestFileNamesSortByTime;
var
  A, B : string;
begin
  A := McpReportFileName(EncodeDate(2026, 11, 6) + EncodeTime(9, 59, 59, 999));
  B := McpReportFileName(EncodeDate(2026, 11, 6) + EncodeTime(10, 0, 0, 0));
  AssertEquals('mcp-report-20261106T095959999Z.md', A);
  AssertTrue(A < B);
end;

procedure TTestReport.TestWriteNeverOverwritesAndKeepsThree;
var
  I           : Integer;
  P1, P2, Err : string;
  T           : TDateTime;
  SL          : TStringList;
begin
  T := EncodeDate(2026, 11, 6) + EncodeTime(10, 0, 0, 0);
  AssertTrue(McpWriteReportFile(FDir, 'one', T, P1, Err));
  AssertTrue(McpWriteReportFile(FDir, 'two', T, P2, Err));  { the same instant }
  AssertTrue('not the same file', P1 <> P2);
  SL := TStringList.Create;
  try
    SL.LoadFromFile(P1);
    AssertEquals('one', Trim(SL.Text));
  finally
    SL.Free;
  end;
  for I := 1 to 4 do
    AssertTrue(McpWriteReportFile(FDir, 'more', T + I / 24, P2, Err));
  AssertTrue('oldest gone', not FileExists(P1));
  AssertTrue('newest kept', FileExists(P2));
  AssertEquals('three kept', 3, ReportFiles);
end;

initialization
  RegisterTest(TTestReport);
end.
