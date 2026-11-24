{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TDiff;

{ TTestDiff — McpDiff: line diff and three-way merge (ADR-025).  Pure; no IDE. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, McpDiff, McpReviewPaths;

type
  TTestDiff = class(TTestCase)
  private
    function L(const A: array of string): TDiffLines;
    function Same(const X, Y: TDiffLines): Boolean;
    function Show(const X: TDiffLines): string;
    function RandomLines(AMax: Integer): TDiffLines;
    function Edit(const X: TDiffLines): TDiffLines;
    function Rebuild(const C: TMergeChunks; const Mine, Theirs: TDiffLines;
      APreferMine: Boolean): TDiffLines;
    procedure CheckCoverage(const C: TMergeChunks; const Base, Mine, Theirs: TDiffLines);
    function CountKind(const C: TMergeChunks; K: TMergeKind): Integer;
  published
    procedure TestSplitJoin;
    procedure TestLinesOf;
    procedure TestIdentical;
    procedure TestInsertDeleteReplace;
    procedure TestApplyAllAndNone;
    procedure TestApplyOneHunk;
    procedure TestHugeDifferenceFallsBack;
    procedure TestMergeOneSideOnly;
    procedure TestMergeBothSidesApart;
    procedure TestMergeSameChange;
    procedure TestMergeConflict;
    procedure TestMergeAdjacentIsConflict;
    procedure TestMergeFromNothing;
    procedure TestMergeFuzz;
    procedure TestAlignRows;
    procedure TestAlignRowsFuzz;
    procedure TestMergeAuto;
    procedure TestMergeAutoFuzz;
    procedure TestMergeAutoDemo;
    procedure TestMergeAutoEx;
    procedure TestDifferingSpan;
    procedure TestDifferingSpanFuzz;
    procedure TestAlignRows3;
    procedure TestReviewPathParts;
    procedure TestReviewNotice;
    procedure TestFileStamp;
  end;

implementation

uses
  Classes, SysUtils;

function TTestDiff.L(const A: array of string): TDiffLines;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(A));
  for I := 0 to High(A) do Result[I] := A[I];
end;

function TTestDiff.Same(const X, Y: TDiffLines): Boolean;
var
  I: Integer;
begin
  Result := Length(X) = Length(Y);
  if Result then
    for I := 0 to High(X) do
      if X[I] <> Y[I] then Exit(False);
end;

function TTestDiff.Show(const X: TDiffLines): string;
var
  I: Integer;
begin
  Result := '[';
  for I := 0 to High(X) do
  begin
    if I > 0 then Result := Result + ',';
    Result := Result + X[I];
  end;
  Result := Result + ']';
end;

function TTestDiff.RandomLines(AMax: Integer): TDiffLines;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Random(AMax + 1));
  for I := 0 to High(Result) do
    Result[I] := Chr(Ord('a') + Random(6));
end;

{ a few random insertions, deletions and replacements }
function TTestDiff.Edit(const X: TDiffLines): TDiffLines;
var
  N, I, P: Integer;
  S: string;
begin
  Result := Copy(X, 0, Length(X));
  for N := 1 to Random(4) do
  begin
    case Random(3) of
      0: begin  { insert }
           P := Random(Length(Result) + 1);
           SetLength(Result, Length(Result) + 1);
           for I := High(Result) downto P + 1 do Result[I] := Result[I - 1];
           Result[P] := Chr(Ord('A') + Random(6));
         end;
      1: if Length(Result) > 0 then  { delete }
         begin
           P := Random(Length(Result));
           for I := P to High(Result) - 1 do Result[I] := Result[I + 1];
           SetLength(Result, Length(Result) - 1);
         end;
      2: if Length(Result) > 0 then  { replace }
         begin
           P := Random(Length(Result));
           S := Chr(Ord('A') + Random(6));
           Result[P] := S;
         end;
    end;
  end;
end;

{ what the merge says the text is, with the choice for conflicts }
function TTestDiff.Rebuild(const C: TMergeChunks; const Mine, Theirs: TDiffLines;
  APreferMine: Boolean): TDiffLines;
var
  I, J: Integer;
  Part: TDiffLines;
begin
  Result := nil;
  for I := 0 to High(C) do
  begin
    case C[I].Kind of
      mkTheirs:   Part := Slice(Theirs, C[I].TheirStart, C[I].TheirLen);
      mkConflict: if APreferMine then Part := Slice(Mine, C[I].MineStart, C[I].MineLen)
                  else Part := Slice(Theirs, C[I].TheirStart, C[I].TheirLen);
    else
      Part := Slice(Mine, C[I].MineStart, C[I].MineLen);
    end;
    SetLength(Result, Length(Result) + Length(Part));
    for J := 0 to High(Part) do
      Result[Length(Result) - Length(Part) + J] := Part[J];
  end;
end;

{ the chunks follow each other in every version and use each text up }
procedure TTestDiff.CheckCoverage(const C: TMergeChunks; const Base, Mine, Theirs: TDiffLines);
var
  I, B, M, T: Integer;
begin
  B := 0; M := 0; T := 0;
  for I := 0 to High(C) do
  begin
    CheckEquals(B, C[I].BaseStart, 'base start of chunk ' + IntToStr(I));
    CheckEquals(M, C[I].MineStart, 'mine start of chunk ' + IntToStr(I));
    CheckEquals(T, C[I].TheirStart, 'theirs start of chunk ' + IntToStr(I));
    Inc(B, C[I].BaseLen);
    Inc(M, C[I].MineLen);
    Inc(T, C[I].TheirLen);
    if C[I].Kind = mkStable then
    begin
      CheckTrue(Same(Slice(Base, C[I].BaseStart, C[I].BaseLen),
                     Slice(Mine, C[I].MineStart, C[I].MineLen)), 'stable: mine = base');
      CheckTrue(Same(Slice(Base, C[I].BaseStart, C[I].BaseLen),
                     Slice(Theirs, C[I].TheirStart, C[I].TheirLen)), 'stable: theirs = base');
    end;
  end;
  CheckEquals(Length(Base), B, 'base used up');
  CheckEquals(Length(Mine), M, 'mine used up');
  CheckEquals(Length(Theirs), T, 'theirs used up');
end;

function TTestDiff.CountKind(const C: TMergeChunks; K: TMergeKind): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(C) do
    if C[I].Kind = K then Inc(Result);
end;

procedure TTestDiff.TestSplitJoin;
var
  Final: Boolean;
  X: TDiffLines;
begin
  X := SplitLines('a'#13#10'b'#10, Final);
  CheckTrue(Same(X, L(['a', 'b'])), Show(X));
  CheckTrue(Final, 'final newline');
  X := SplitLines('a'#10'b', Final);
  CheckTrue(Same(X, L(['a', 'b'])), Show(X));
  CheckFalse(Final, 'no final newline');
  X := SplitLines('', Final);
  CheckEquals(0, Length(X), 'empty text has no lines');
  X := SplitLines(#10, Final);
  CheckTrue(Same(X, L([''])), 'one empty line');
  CheckEquals(#10, JoinLines(X, #10, Final));
  CheckEquals('a|b|', JoinLines(L(['a', 'b']), '|', True));
  CheckEquals('a|b', JoinLines(L(['a', 'b']), '|', False));
end;

procedure TTestDiff.TestLinesOf;
begin
  CheckEquals(2, Length(LinesOf('a'#13#10'b'#10)), 'a closing line end adds no line');
  CheckEquals(2, Length(LinesOf('a'#10'b')));
  CheckEquals(0, Length(LinesOf('')));
end;

procedure TTestDiff.TestIdentical;
begin
  CheckEquals(0, Length(DiffLines(L(['a', 'b']), L(['a', 'b']))));
  CheckEquals(0, Length(DiffLines(L([]), L([]))));
end;

procedure TTestDiff.TestInsertDeleteReplace;
var
  H: TDiffHunks;
begin
  H := DiffLines(L(['a', 'c']), L(['a', 'b', 'c']));
  CheckEquals(1, Length(H));
  CheckEquals(1, H[0].AStart); CheckEquals(0, H[0].ALen);
  CheckEquals(1, H[0].BStart); CheckEquals(1, H[0].BLen);
  H := DiffLines(L(['a', 'b', 'c']), L(['a', 'c']));
  CheckEquals(1, Length(H));
  CheckEquals(1, H[0].AStart); CheckEquals(1, H[0].ALen);
  CheckEquals(0, H[0].BLen);
  H := DiffLines(L(['a', 'b', 'c']), L(['a', 'X', 'c']));
  CheckEquals(1, Length(H));
  CheckEquals(1, H[0].ALen); CheckEquals(1, H[0].BLen);
  H := DiffLines(L(['a', 'b', 'c', 'd', 'e']), L(['X', 'b', 'c', 'd', 'Y']));
  CheckEquals(2, Length(H), 'two separate changes');
  H := DiffLines(L([]), L(['a', 'b']));
  CheckEquals(1, Length(H));
  CheckEquals(2, H[0].BLen);
end;

procedure TTestDiff.TestApplyAllAndNone;
var
  I, J: Integer;
  A, B, R: TDiffLines;
  H: TDiffHunks;
  All  : array of Boolean = nil;
  None : array of Boolean = nil;
begin
  RandSeed := 20261114;
  for I := 1 to 400 do
  begin
    A := RandomLines(12);
    if Random(4) = 0 then B := RandomLines(12) else B := Edit(A);
    H := DiffLines(A, B);
    SetLength(All, Length(H));
    SetLength(None, Length(H));
    for J := 0 to High(H) do
    begin
      All[J] := True;
      None[J] := False;
    end;
    R := ApplyHunks(A, B, H, All);
    CheckTrue(Same(R, B), 'all: ' + Show(A) + ' -> ' + Show(B) + ' gave ' + Show(R));
    R := ApplyHunks(A, B, H, None);
    CheckTrue(Same(R, A), 'none: ' + Show(A) + ' -> ' + Show(B) + ' gave ' + Show(R));
  end;
end;

procedure TTestDiff.TestApplyOneHunk;
var
  A, B, R: TDiffLines;
  H: TDiffHunks;
begin
  A := L(['a', 'b', 'c', 'd', 'e']);
  B := L(['X', 'b', 'c', 'd', 'Y']);
  H := DiffLines(A, B);
  R := ApplyHunks(A, B, H, [True, False]);
  CheckTrue(Same(R, L(['X', 'b', 'c', 'd', 'e'])), Show(R));
  R := ApplyHunks(A, B, H, [False, True]);
  CheckTrue(Same(R, L(['a', 'b', 'c', 'd', 'Y'])), Show(R));
end;

procedure TTestDiff.TestHugeDifferenceFallsBack;
var
  A: TDiffLines = nil;
  B: TDiffLines = nil;
  R: TDiffLines;
  H: TDiffHunks;
  I: Integer;
begin
  SetLength(A, 2500);
  SetLength(B, 2500);
  for I := 0 to 2499 do
  begin
    A[I] := 'a' + IntToStr(I);
    B[I] := 'b' + IntToStr(I);
  end;
  H := DiffLines(A, B);
  CheckEquals(1, Length(H), 'one hunk for everything');
  R := ApplyHunks(A, B, H, [True]);
  CheckTrue(Same(R, B), 'still applies');
end;

procedure TTestDiff.TestMergeOneSideOnly;
var
  Base, C: TMergeChunks;
  B, M, T: TDiffLines;
begin
  B := L(['a', 'b', 'c']);
  M := L(['a', 'B', 'c']);
  Base := Merge3(B, M, B);
  CheckEquals(1, CountKind(Base, mkMine));
  CheckEquals(0, CountKind(Base, mkConflict));
  CheckCoverage(Base, B, M, B);
  T := L(['a', 'b', 'c', 'd']);
  C := Merge3(B, B, T);
  CheckEquals(1, CountKind(C, mkTheirs));
  CheckTrue(Same(Rebuild(C, B, T, True), T), 'theirs only gives theirs');
end;

procedure TTestDiff.TestMergeBothSidesApart;
var
  C: TMergeChunks;
  B, M, T: TDiffLines;
begin
  B := L(['a', 'b', 'c', 'd', 'e']);
  M := L(['A', 'b', 'c', 'd', 'e']);   { mine changes the first }
  T := L(['a', 'b', 'c', 'd', 'E']);   { theirs the last }
  C := Merge3(B, M, T);
  CheckEquals(1, CountKind(C, mkMine));
  CheckEquals(1, CountKind(C, mkTheirs));
  CheckEquals(0, CountKind(C, mkConflict));
  CheckCoverage(C, B, M, T);
  CheckTrue(Same(Rebuild(C, M, T, True), L(['A', 'b', 'c', 'd', 'E'])),
    Show(Rebuild(C, M, T, True)));
end;

procedure TTestDiff.TestMergeSameChange;
var
  C: TMergeChunks;
  B, M: TDiffLines;
begin
  B := L(['a', 'b', 'c']);
  M := L(['a', 'X', 'c']);
  C := Merge3(B, M, M);
  CheckEquals(1, CountKind(C, mkBoth));
  CheckEquals(0, CountKind(C, mkConflict));
end;

procedure TTestDiff.TestMergeConflict;
var
  C: TMergeChunks;
  B, M, T: TDiffLines;
begin
  B := L(['a', 'b', 'c']);
  M := L(['a', 'mine', 'c']);
  T := L(['a', 'theirs', 'c']);
  C := Merge3(B, M, T);
  CheckEquals(1, CountKind(C, mkConflict));
  CheckCoverage(C, B, M, T);
  CheckTrue(Same(Rebuild(C, M, T, True), M), 'mine chosen');
  CheckTrue(Same(Rebuild(C, M, T, False), T), 'theirs chosen');
end;

{ as in git: changes on neighbouring lines from both sides are a conflict }
procedure TTestDiff.TestMergeAdjacentIsConflict;
var
  C: TMergeChunks;
  B, M, T: TDiffLines;
begin
  B := L(['a', 'b', 'c', 'd']);
  M := L(['a', 'B', 'c', 'd']);
  T := L(['a', 'b', 'C', 'd']);
  C := Merge3(B, M, T);
  CheckEquals(1, CountKind(C, mkConflict));
  CheckCoverage(C, B, M, T);
end;

procedure TTestDiff.TestMergeFromNothing;
var
  C: TMergeChunks;
  B, M, T: TDiffLines;
begin
  B := nil;
  M := L(['x']);
  T := L(['y']);
  C := Merge3(B, M, T);
  CheckEquals(1, CountKind(C, mkConflict));
  CheckCoverage(C, B, M, T);
  C := Merge3(B, nil, nil);
  CheckEquals(0, Length(C));
end;

procedure TTestDiff.TestMergeFuzz;
var
  I: Integer;
  B, M, T: TDiffLines;
  C: TMergeChunks;
begin
  RandSeed := 14112026;
  for I := 1 to 600 do
  begin
    B := RandomLines(14);
    M := Edit(B);
    T := Edit(B);
    C := Merge3(B, M, T);
    CheckCoverage(C, B, M, T);
    { theirs untouched: the merge is mine, with no conflict }
    C := Merge3(B, M, B);
    CheckEquals(0, CountKind(C, mkConflict), 'no conflict without theirs');
    CheckTrue(Same(Rebuild(C, M, B, True), M), 'mine only: ' + Show(B) + ' ' + Show(M));
    { mine untouched: the merge is theirs }
    C := Merge3(B, B, T);
    CheckEquals(0, CountKind(C, mkConflict), 'no conflict without mine');
    CheckTrue(Same(Rebuild(C, B, T, True), T), 'theirs only: ' + Show(B) + ' ' + Show(T));
    { the same change on both sides is no conflict }
    C := Merge3(B, M, M);
    CheckEquals(0, CountKind(C, mkConflict), 'same change, no conflict');
    CheckTrue(Same(Rebuild(C, M, M, True), M), 'same change gives that change');
  end;
end;

procedure TTestDiff.TestAlignRows;
var
  R: TAlignedRows;
begin
  { one line replaced, one deleted, one added }
  R := AlignRows(L(['a', 'b', 'c', 'd']), L(['a', 'X', 'c', 'd', 'e']));
  CheckEquals(5, Length(R.Left), 'rows');
  CheckEquals(5, Length(R.Right));
  CheckTrue(R.LeftKind[1] = rkChanged, 'replaced, left');
  CheckTrue(R.RightKind[1] = rkChanged, 'replaced, right');
  CheckTrue(R.LeftKind[4] = rkFiller, 'filler where theirs has an extra line');
  CheckTrue(R.RightKind[4] = rkAdded);
  CheckEquals(1, Length(R.HunkRow) - 1, 'two changes');
  CheckEquals(1, R.HunkRow[0]);
  CheckEquals(4, R.HunkRow[1]);
  R := AlignRows(L(['a', 'b']), L(['a']));
  CheckTrue(R.LeftKind[1] = rkRemoved);
  CheckTrue(R.RightKind[1] = rkFiller);
  CheckEquals(0, Length(AlignRows(nil, nil).Left));
end;

{ without its fillers each side is its own text; kinds agree on filler rows }
procedure TTestDiff.TestAlignRowsFuzz;
var
  I, J: Integer;
  A, B, X, Y: TDiffLines;
  R: TAlignedRows;
begin
  RandSeed := 77112014;
  for I := 1 to 500 do
  begin
    A := RandomLines(12);
    if Random(4) = 0 then B := RandomLines(12) else B := Edit(A);
    R := AlignRows(A, B);
    CheckEquals(Length(R.Left), Length(R.Right), 'same row count');
    CheckEquals(Length(R.Left), Length(R.LeftKind));
    CheckEquals(Length(R.Left), Length(R.RightKind));
    X := nil;
    Y := nil;
    for J := 0 to High(R.Left) do
    begin
      if R.LeftKind[J] <> rkFiller then
      begin
        SetLength(X, Length(X) + 1);
        X[High(X)] := R.Left[J];
      end;
      if R.RightKind[J] <> rkFiller then
      begin
        SetLength(Y, Length(Y) + 1);
        Y[High(Y)] := R.Right[J];
      end;
      CheckFalse((R.LeftKind[J] = rkFiller) and (R.RightKind[J] = rkFiller), 'a row of two fillers');
    end;
    CheckTrue(Same(X, A), 'left without fillers: ' + Show(A) + ' vs ' + Show(X));
    CheckTrue(Same(Y, B), 'right without fillers: ' + Show(B) + ' vs ' + Show(Y));
  end;
end;

procedure TTestDiff.TestMergeAuto;
var
  B, M, T, R: TDiffLines;
  Applied, Conflicts: Integer;
begin
  B := L(['a', 'b', 'c', 'd', 'e']);
  M := L(['A', 'b', 'c', 'd', 'e']);      { my change }
  T := L(['a', 'b', 'c', 'd', 'E']);      { the agent's change }
  R := MergeAuto(B, M, T, Applied, Conflicts);
  CheckTrue(Same(R, L(['A', 'b', 'c', 'd', 'E'])), Show(R));
  CheckEquals(1, Applied);
  CheckEquals(0, Conflicts);
  { a conflict keeps my lines and is counted }
  T := L(['theirs', 'b', 'c', 'd', 'e']);
  R := MergeAuto(B, M, T, Applied, Conflicts);
  CheckTrue(Same(R, M), Show(R));
  CheckEquals(0, Applied);
  CheckEquals(1, Conflicts);
end;

{ I changed nothing: the merge is the disk.  The agent changed nothing: it is mine. }
procedure TTestDiff.TestMergeAutoFuzz;
var
  I, Applied, Conflicts: Integer;
  B, M, T, R: TDiffLines;
begin
  RandSeed := 30112014;
  for I := 1 to 500 do
  begin
    B := RandomLines(14);
    M := Edit(B);
    T := Edit(B);
    R := MergeAuto(B, B, T, Applied, Conflicts);
    CheckTrue(Same(R, T), 'unchanged mine gives theirs: ' + Show(B) + ' ' + Show(T));
    CheckEquals(0, Conflicts);
    R := MergeAuto(B, M, B, Applied, Conflicts);
    CheckTrue(Same(R, M), 'unchanged theirs gives mine');
    CheckEquals(0, Applied);
    R := MergeAuto(B, M, T, Applied, Conflicts);
    if Conflicts = 0 then
      { with no conflict, the changes of both sides are in }
      CheckTrue(Same(R, Rebuild(Merge3(B, M, T), M, T, True)), 'same as the chunk rebuild');
  end;
end;

procedure TTestDiff.TestMergeAutoDemo;
const
  Base =
    'unit Sample;'#10'procedure Greet;'#10'begin'#10'  WriteLn(''Hi, '');'#10 +
    '  Count := Count + 2;'#10'end;'#10'procedure Farewell;'#10'begin'#10 +
    '  WriteLn(''Bye, '');'#10'end;'#10'end.'#10;
  Mine =
    'unit Sample;'#10'procedure Greet;'#10'begin'#10'  WriteLn(''Hello there, '');'#10 +
    '  Count := Count + 2;'#10'end;'#10'procedure Farewell;'#10'begin'#10 +
    '  WriteLn(''Bye, '');'#10'end;'#10'end.'#10;
  Theirs =
    'unit Sample;'#10'procedure Greet;'#10'begin'#10'  WriteLn(''Howdy, '');'#10 +
    '  Count := Count + 5;'#10'end;'#10'procedure Farewell;'#10'begin'#10 +
    '  WriteLn(''Goodbye, '');'#10'end;'#10'end.'#10;
var
  B, M, T, R: TDiffLines;
  F: Boolean;
  Applied, Conflicts: Integer;
begin
  B := SplitLines(Base, F);
  M := SplitLines(Mine, F);
  T := SplitLines(Theirs, F);
  R := MergeAuto(B, M, T, Applied, Conflicts);
  CheckEquals(Length(T), Length(R), 'no line was added or lost');
  CheckEquals('end.', R[High(R)], 'the last line is the last line');
  CheckEquals('  WriteLn(''Goodbye, '');', R[8], 'the change only the disk made is in');
end;

procedure TTestDiff.TestMergeAutoEx;
var
  B, M, T, R: TDiffLines;
  Flags: TLineFlags;
  Applied, Conflicts, Removed, I, J, Taken, Flagged: Integer;
  C: TMergeChunks;
begin
  { the disk added a line and changed another, the user changed a third: both disk
    changes are taken, and the taken lines are flagged by their place in Theirs }
  B := L(['a', 'b', 'c', 'd', 'e', 'f', 'g']);
  M := L(['a', 'b', 'c', 'd', 'e', 'F mine', 'g']);
  T := L(['a', 'b2', 'c', 'd', 'new', 'e', 'f', 'g']);
  R := MergeAutoEx(B, M, T, Applied, Conflicts, Flags, Removed);
  CheckEquals(0, Conflicts);
  CheckEquals(2, Applied);
  CheckEquals(Length(T), Length(Flags));
  CheckFalse(Flags[0]);
  CheckTrue(Flags[1], 'b2');
  CheckFalse(Flags[2]);
  CheckFalse(Flags[3]);
  CheckTrue(Flags[4], 'the added line');
  CheckFalse(Flags[5]);
  CheckFalse(Flags[6]);
  CheckFalse(Flags[7]);
  CheckEquals(1, Removed, 'the line b was replaced');
  CheckEquals('F mine', R[6]);
  { fuzz: the flags count the lines of the taken chunks }
  RandSeed := 14112026;
  for I := 1 to 300 do
  begin
    B := RandomLines(14);
    M := Edit(B);
    T := Edit(B);
    R := MergeAutoEx(B, M, T, Applied, Conflicts, Flags, Removed);
    CheckEquals(Length(T), Length(Flags));
    C := Merge3(B, M, T);
    Taken := 0;
    for J := 0 to High(C) do
      if C[J].Kind = mkTheirs then Inc(Taken, C[J].TheirLen);
    Flagged := 0;
    for J := 0 to High(Flags) do
      if Flags[J] then Inc(Flagged);
    CheckEquals(Taken, Flagged, 'flagged lines = lines of the taken chunks');
  end;
end;

procedure TTestDiff.TestDifferingSpan;
  procedure Span(const A, B: string; AF, AT, BF, BT: Integer);
  var
    F1, T1, F2, T2: Integer;
  begin
    DifferingSpan(A, B, F1, T1, F2, T2);
    CheckEquals(AF, F1, A + '|' + B + ' A from');
    CheckEquals(AT, T1, A + '|' + B + ' A to');
    CheckEquals(BF, F2, A + '|' + B + ' B from');
    CheckEquals(BT, T2, A + '|' + B + ' B to');
  end;
begin
  Span('Hello world', 'Hallo world', 1, 6, 1, 6);         { the whole word, not one letter }
  Span('x := 1;', 'x := 22;', 6, 7, 6, 8);                { a changed number }
  Span('abc', 'abcd', 4, 4, 4, 5);                        { only added at the end }
  Span('abcd', 'abc', 4, 5, 4, 4);
  Span('', 'text', 1, 1, 1, 5);
  Span('same', 'same', 5, 5, 5, 5);                       { nothing differs }
  Span('a b', 'a c', 3, 4, 3, 4);
end;

procedure TTestDiff.TestDifferingSpanFuzz;
const
  Alphabet = 'ab _;';
var
  I, F1, T1, F2, T2: Integer;
  A, B: string;
  function Rnd: string;
  var
    K: Integer;
  begin
    Result := '';
    SetLength(Result, Random(9));
    for K := 1 to Length(Result) do Result[K] := Alphabet[1 + Random(Length(Alphabet))];
  end;
begin
  RandSeed := 17112026;
  for I := 1 to 3000 do
  begin
    A := Rnd;
    B := Rnd;
    DifferingSpan(A, B, F1, T1, F2, T2);
    Check((F1 >= 1) and (F1 <= T1) and (T1 <= Length(A) + 1), 'A range ' + A + '|' + B);
    Check((F2 >= 1) and (F2 <= T2) and (T2 <= Length(B) + 1), 'B range ' + A + '|' + B);
    CheckEquals(F1, F2, 'same start');
    CheckEquals(Copy(A, 1, F1 - 1), Copy(B, 1, F2 - 1), 'common start ' + A + '|' + B);
    CheckEquals(Copy(A, T1, Length(A)), Copy(B, T2, Length(B)), 'common end ' + A + '|' + B);
  end;
end;

procedure TTestDiff.TestAlignRows3;
var
  A: TAligned3;
  I, K, N: Integer;
  Ed, Mid, Dk: TDiffLines;
  function Lines(const S: string): TDiffLines;
  var
    X: Integer;
  begin
    Result := nil;
    SetLength(Result, Length(S));
    for X := 1 to Length(S) do Result[X - 1] := S[X];
  end;
  function Column(const ALines: TDiffLines; const AKinds: TDiffRowKinds): string;
  var
    X: Integer;
  begin
    Result := '';
    for X := 0 to High(AKinds) do
      if AKinds[X] <> rkFiller then Result := Result + ALines[X];
  end;
  function RandText: string;
  var
    X: Integer;
  begin
    Result := '';
    SetLength(Result, Random(8));
    for X := 1 to Length(Result) do Result[X] := Chr(Ord('a') + Random(4));
  end;
begin
  { the editor has "x" and the disk "y", both missing in the result: one row for both }
  A := AlignRows3(Lines('abxd'), Lines('abd'), Lines('abyd'));
  CheckEquals(4, Length(A.M));
  CheckEquals('abxd', Column(A.L, A.LK), 'editor column');
  CheckEquals('abd', Column(A.M, A.MK), 'result column');
  CheckEquals('abyd', Column(A.R, A.RK), 'disk column');
  CheckEquals(1, Length(A.RightHunks), 'one difference result-disk');
  CheckEquals(2, A.RightHunkRow[0], 'the disk-only line has its own row');
  CheckTrue(A.MK[2] = rkFiller, 'no result line there');
  CheckTrue(A.RK[2] = rkAdded, 'the disk has a line there');
  CheckTrue(A.LK[2] = rkAdded, 'the editor has one too (x), in the same row');

  { identical: no extra rows, no differences }
  A := AlignRows3(Lines('abc'), Lines('abc'), Lines('abc'));
  CheckEquals(3, Length(A.M));
  CheckEquals(0, Length(A.LeftHunks) + Length(A.RightHunks));

  { a merged deletion: the editor still has the line the result lacks }
  A := AlignRows3(Lines('abc'), Lines('ac'), Lines('ac'));
  CheckEquals(3, Length(A.M));
  CheckTrue(A.MK[1] = rkFiller);
  CheckTrue(A.LK[1] = rkAdded, 'the editor line is shown');
  CheckTrue(A.RK[1] = rkFiller);
  CheckEquals(1, A.LeftHunkRow[0]);

  RandSeed := 14112026;
  for I := 1 to 1500 do
  begin
    Ed := Lines(RandText);
    Mid := Lines(RandText);
    Dk := Lines(RandText);
    A := AlignRows3(Ed, Mid, Dk);
    N := Length(A.M);
    CheckEquals(N, Length(A.L));
    CheckEquals(N, Length(A.R));
    CheckEquals(JoinLines(Ed, '', False), Column(A.L, A.LK), 'editor kept');
    CheckEquals(JoinLines(Mid, '', False), Column(A.M, A.MK), 'result kept');
    CheckEquals(JoinLines(Dk, '', False), Column(A.R, A.RK), 'disk kept');
    for K := 0 to N - 1 do
    begin
      if A.MK[K] = rkFiller then
        Check((A.LK[K] <> rkFiller) or (A.RK[K] <> rkFiller), 'an empty row');
      if (A.MK[K] <> rkFiller) and (A.LK[K] = rkEqual) then CheckEquals(A.M[K], A.L[K]);
      if (A.MK[K] <> rkFiller) and (A.RK[K] = rkEqual) then CheckEquals(A.M[K], A.R[K]);
    end;
    for K := 0 to High(A.RightHunkRow) do
      Check((A.RightHunkRow[K] >= 0) and (A.RightHunkRow[K] < N), 'hunk row');
    for K := 0 to High(A.LeftHunkRow) do
      Check((A.LeftHunkRow[K] >= 0) and (A.LeftHunkRow[K] < N), 'hunk row');
  end;
end;

procedure TTestDiff.TestReviewPathParts;
var
  P: TPathParts;
  Out_: Boolean;
begin
  P := ReviewPathParts('D:\Proj\src\units\a.pas', 'D:\Proj', Out_);
  CheckFalse(Out_);
  CheckEquals(3, Length(P));
  CheckEquals('src', P[0]);
  CheckEquals('units', P[1]);
  CheckEquals('a.pas', P[2]);
  P := ReviewPathParts('D:/Proj/a.pas', 'D:/Proj/', Out_);   { either slash, a final one }
  CheckFalse(Out_);
  CheckEquals(1, Length(P));
  CheckEquals('a.pas', P[0]);
  P := ReviewPathParts('D:\Other\a.pas', 'D:\Proj', Out_);
  CheckTrue(Out_, 'another folder is outside');
  CheckEquals(1, Length(P));
  CheckEquals('D:\Other\a.pas', P[0], 'the whole path, as given');
  P := ReviewPathParts('D:\ProjX\a.pas', 'D:\Proj', Out_);
  CheckTrue(Out_, 'a folder that only starts with the root name is outside');
  P := ReviewPathParts('D:\Proj\a.pas', '', Out_);
  CheckTrue(Out_, 'no root: outside');
  P := ReviewPathParts('D:\Proj', 'D:\Proj', Out_);
  CheckTrue(Out_, 'the root itself is no file');
  {$IFDEF WINDOWS}
  P := ReviewPathParts('d:\proj\SRC\a.pas', 'D:\Proj', Out_);
  CheckFalse(Out_, 'the case is ignored on Windows');
  CheckEquals('SRC', P[0]);
  {$ENDIF}
end;

procedure TTestDiff.TestFileStamp;
var
  F, A, B: string;
  SL: TStringList;
begin
  F := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'mcpstamp-test.txt';
  CheckEquals('', McpFileStamp(F + '.absent'), 'no file, no stamp');
  SL := TStringList.Create;
  try
    SL.Text := 'one';
    SL.SaveToFile(F);
    A := McpFileStamp(F);
    CheckTrue(A <> '', 'a file has a stamp');
    CheckEquals(A, McpFileStamp(F), 'unchanged: the same stamp');
    SL.Text := 'one and more';          { another size, whatever the clock says }
    SL.SaveToFile(F);
    B := McpFileStamp(F);
    CheckTrue(A <> B, 'a different file state: a different stamp');
  finally
    SL.Free;
    DeleteFile(F);
  end;
end;

procedure TTestDiff.TestReviewNotice;
var
  A, K, T: TStringList;
  S: string;
begin
  A := TStringList.Create;
  K := TStringList.Create;
  T := TStringList.Create;
  try
    CheckEquals('', ReviewNoticeText(A, K, T), 'no file: no notice');
    CheckEquals('', ReviewNoticeText(nil, nil, nil), 'nil lists are empty');
    A.Add('a.pas');
    A.Add('b.pas');
    S := ReviewNoticeText(A, K, T);
    CheckTrue(Pos('a.pas, b.pas changed on disk', S) = 1, 'every waiting file is named: ' + S);
    CheckTrue(Pos('asked to review', S) > 0, S);
    CheckTrue(Pos('.agent', S) = 0, 'nothing was kept: ' + S);
    CheckTrue(Pos('editor_* tools', S) > 0, 'ends with the advice: ' + S);
    K.Add('c.pas');
    T.Add('d.pas');
    S := ReviewNoticeText(A, K, T);
    CheckTrue(Pos('c.pas changed on disk', S) > 0, S);
    CheckTrue(Pos('.agent', S) > 0, 'the kept file says where the disk version went: ' + S);
    CheckTrue(Pos('d.pas changed on disk', S) > 0, S);
    CheckTrue(Pos('Ctrl+Z', S) > 0, 'the taken file says it can be undone: ' + S);
  finally
    T.Free;
    K.Free;
    A.Free;
  end;
end;

initialization
  RegisterTest(TTestDiff);
end.
