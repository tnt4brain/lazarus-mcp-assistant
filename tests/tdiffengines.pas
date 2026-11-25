{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TDiffEngines;

{ McpDiff.DiffLines serves the review window and code_format / code_complete (through
  McpLineDiff), so it is held to rules that do not depend on the case: ordered hunks, the
  texts rebuilt from them, and the smallest set of changed lines.  Pure; no IDE. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, McpDiff;

type
  TTestDiffEngines = class(TTestCase)
  private
    function Lcs(const A, B: TDiffLines): Integer;
    function Edits(const H: TDiffHunks): Integer;
    function RandomText(AMax, AAlphabet: Integer): TDiffLines;
    function Mutate(const X: TDiffLines; AAlphabet: Integer): TDiffLines;
    procedure CheckHunks(const AName: string; const A, B: TDiffLines; const H: TDiffHunks);
  published
    procedure TestFuzz;
    procedure TestEmptyAndEqual;
    procedure TestLargeEditsStillRebuildTheText;
    procedure TestInsertedDuplicateSlidesDown;
    procedure TestEditsFarApartAreSeparateHunks;
    procedure TestMostlyRepeatedLinesStaySmall;
    procedure TestTooManyEditsInRepeatedLinesStillRebuildTheText;
  end;

implementation

function TTestDiffEngines.Lcs(const A, B: TDiffLines): Integer;
var
  L    : array of array of Integer = nil;
  I, J : Integer;
begin
  SetLength(L, Length(A) + 1, Length(B) + 1);
  for I := 0 to Length(A) do
    for J := 0 to Length(B) do
      L[I][J] := 0;
  for I := Length(A) - 1 downto 0 do
    for J := Length(B) - 1 downto 0 do
      if A[I] = B[J] then
        L[I][J] := L[I + 1][J + 1] + 1
      else if L[I + 1][J] >= L[I][J + 1] then
        L[I][J] := L[I + 1][J]
      else
        L[I][J] := L[I][J + 1];
  Result := L[0][0];
end;

function TTestDiffEngines.Edits(const H: TDiffHunks): Integer;
var
  K : Integer;
begin
  Result := 0;
  for K := 0 to High(H) do
    Inc(Result, H[K].ALen + H[K].BLen);
end;

function TTestDiffEngines.RandomText(AMax, AAlphabet: Integer): TDiffLines;
var
  I : Integer;
begin
  Result := nil;
  SetLength(Result, Random(AMax + 1));
  for I := 0 to High(Result) do
    Result[I] := Chr(Ord('a') + Random(AAlphabet));
end;

{ X with a few lines changed, added or removed. }
function TTestDiffEngines.Mutate(const X: TDiffLines; AAlphabet: Integer): TDiffLines;
var
  I, K, N : Integer;
begin
  Result := Copy(X);
  for K := 1 to 1 + Random(4) do
  begin
    N := Length(Result);
    case Random(3) of
      0: if N > 0 then Result[Random(N)] := Chr(Ord('a') + Random(AAlphabet));
      1: begin
           I := Random(N + 1);
           Insert(Chr(Ord('a') + Random(AAlphabet)), Result, I);
         end;
      2: if N > 0 then
           Delete(Result, Random(N), 1);
    end;
  end;
end;

procedure TTestDiffEngines.CheckHunks(const AName: string; const A, B: TDiffLines;
  const H: TDiffHunks);
var
  K, PA, PB : Integer;
  Take      : array of Boolean = nil;
  X, Y      : TDiffLines;
  I         : Integer;
begin
  PA := 0;
  PB := 0;
  for K := 0 to High(H) do
  begin
    CheckTrue((H[K].ALen > 0) or (H[K].BLen > 0), AName + ': empty hunk');
    CheckTrue((H[K].AStart >= PA) and (H[K].BStart >= PB),
      AName + ': hunks overlap or are out of order');
    { the lines between two hunks are the same in both texts }
    CheckEquals(H[K].AStart - PA, H[K].BStart - PB, AName + ': unequal gap before hunk');
    for I := 0 to H[K].AStart - PA - 1 do
      CheckTrue(A[PA + I] = B[PB + I], AName + ': the gap differs');
    PA := H[K].AStart + H[K].ALen;
    PB := H[K].BStart + H[K].BLen;
    CheckTrue((PA <= Length(A)) and (PB <= Length(B)), AName + ': hunk past the end');
  end;
  CheckEquals(Length(A) - PA, Length(B) - PB, AName + ': unequal tail');
  for I := 0 to Length(A) - PA - 1 do
    CheckTrue(A[PA + I] = B[PB + I], AName + ': the tail differs');
  SetLength(Take, Length(H));
  for K := 0 to High(Take) do Take[K] := True;
  X := ApplyHunks(A, B, H, Take);
  CheckEquals(Length(B), Length(X), AName + ': taking every hunk gives B (length)');
  for I := 0 to High(X) do
    CheckTrue(X[I] = B[I], AName + ': taking every hunk gives B');
  for K := 0 to High(Take) do Take[K] := False;
  Y := ApplyHunks(A, B, H, Take);
  CheckEquals(Length(A), Length(Y), AName + ': taking none gives A (length)');
  for I := 0 to High(Y) do
    CheckTrue(Y[I] = A[I], AName + ': taking none gives A');
end;

procedure TTestDiffEngines.TestFuzz;
var
  N    : Integer;
  A, B : TDiffLines;
  H    : TDiffHunks;
begin
  RandSeed := 20261124;
  for N := 1 to 600 do
  begin
    A := RandomText(30, 4);
    if Random(2) = 0 then B := RandomText(30, 4) else B := Mutate(A, 4);
    H := DiffLines(A, B);
    CheckHunks('fuzz', A, B, H);
    { as small as possible: every line outside the common subsequence is in a hunk }
    CheckEquals(Length(A) + Length(B) - 2 * Lcs(A, B), Edits(H),
      'not a smallest set of changes, case ' + IntToStr(N));
  end;
end;

procedure TTestDiffEngines.TestEmptyAndEqual;
var
  E, X : TDiffLines;
begin
  E := nil;
  X := nil;
  SetLength(X, 2);
  X[0] := 'a';
  X[1] := 'b';
  CheckEquals(0, Length(DiffLines(E, E)), 'nothing against nothing');
  CheckEquals(0, Length(DiffLines(X, X)), 'equal texts');
  CheckEquals(1, Length(DiffLines(E, X)), 'all added');
  CheckEquals(1, Length(DiffLines(X, E)), 'all removed');
end;

{ A text of thousands of lines with a change every few lines: more than the table holds,
  so the anchors are used; the hunks must still rebuild the text. }
{ 20000 lines of six distinct values and three edited lines: no line is unique, the table is too big,
  so the anchors have nothing to hold on to.  Myers finds the three edits (before it was one hunk of
  most of the file). }
procedure TTestDiffEngines.TestMostlyRepeatedLinesStaySmall;
var
  A, B : TDiffLines;
  H    : TDiffHunks;
  I    : Integer;
begin
  A := nil;
  B := nil;
  SetLength(A, 20000);
  SetLength(B, 20000);
  for I := 0 to 19999 do
  begin
    A[I] := 'value ' + IntToStr(I mod 6);
    B[I] := A[I];
  end;
  B[3000] := 'edited a';
  B[9001] := 'edited b';
  B[15002] := 'edited c';
  H := DiffLines(A, B);
  CheckHunks('repeated', A, B, H);
  CheckTrue(Length(H) <= 6, 'a few hunks, not one for the file: ' + IntToStr(Length(H)));
  CheckTrue(Edits(H) <= 12, 'only the edited lines changed: ' + IntToStr(Edits(H)));
end;

{ more differences than Myers looks for, in lines that repeat: one big hunk is allowed, the texts
  must still be rebuilt from it }
procedure TTestDiffEngines.TestTooManyEditsInRepeatedLinesStillRebuildTheText;
var
  A, B : TDiffLines;
  I    : Integer;
begin
  A := nil;
  B := nil;
  SetLength(A, 20000);
  SetLength(B, 20000);
  for I := 0 to 19999 do
  begin
    A[I] := 'value ' + IntToStr(I mod 6);
    if I mod 5 = 2 then B[I] := 'other ' + IntToStr(I mod 4) else B[I] := A[I];
  end;
  CheckHunks('many', A, B, DiffLines(A, B));
end;

procedure TTestDiffEngines.TestLargeEditsStillRebuildTheText;
var
  A, B : TDiffLines;
  I    : Integer;
begin
  A := nil;
  B := nil;
  SetLength(A, 3000);
  SetLength(B, 3000);
  for I := 0 to 2999 do
  begin
    A[I] := 'line ' + IntToStr(I);
    if I mod 7 = 3 then B[I] := 'changed ' + IntToStr(I) else B[I] := A[I];
  end;
  CheckHunks('large', A, B, DiffLines(A, B));
end;

{ Inserting a line equal to its neighbour is one hunk, put after the run (as git does), so
  that an inserted method ends with its own "end;" and not the one before it. }
procedure TTestDiffEngines.TestInsertedDuplicateSlidesDown;
var
  A, B : TDiffLines;
  H    : TDiffHunks;
begin
  A := nil;
  B := nil;
  SetLength(A, 3);
  A[0] := 'x'; A[1] := 'end;'; A[2] := 'y';
  SetLength(B, 4);
  B[0] := 'x'; B[1] := 'end;'; B[2] := 'end;'; B[3] := 'y';
  H := DiffLines(A, B);
  CheckEquals(1, Length(H));
  CheckEquals(0, H[0].ALen, 'only added');
  CheckEquals(2, H[0].BStart, 'after the line it equals');
  CheckEquals(1, H[0].BLen);
end;

{ Two edits with a thousand unchanged lines between them are two hunks, not one that
  spans the lot. }
procedure TTestDiffEngines.TestEditsFarApartAreSeparateHunks;
var
  A, B : TDiffLines;
  I    : Integer;
  H    : TDiffHunks;
begin
  A := nil;
  B := nil;
  SetLength(A, 1200);
  SetLength(B, 1200);
  for I := 0 to 1199 do
  begin
    A[I] := 'line ' + IntToStr(I);
    B[I] := A[I];
  end;
  B[10]   := 'first change';
  B[1190] := 'second change';
  H := DiffLines(A, B);
  CheckEquals(2, Length(H), 'two hunks');
  CheckEquals(1, H[0].ALen);
  CheckEquals(1, H[1].ALen);
end;

initialization
  RegisterTest(TTestDiffEngines);
end.
