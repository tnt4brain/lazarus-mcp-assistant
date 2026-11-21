{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TConflictFiles;

{ TTestConflictFiles — the pure part of resolving a git conflict in the review window
  (McpConflictFiles, ADR-028): what `git ls-files -u -z` says, which files are a text
  merge, the line ending written back, and the conflict block check.  No IDE needed. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TTestConflictFiles = class(TTestCase)
  published
    procedure TestParseThreeStagesAndTwo;
    procedure TestParseNothing;
    procedure TestPathWithSpacesAndTab;
    procedure TestNotTextReasons;
    procedure TestLooksBinary;
    procedure TestEol;
    procedure TestConflictBlock;
    procedure TestWithEol;
    procedure TestSpansFollowTheAutomaticMerge;
    procedure TestSpansWithoutBase;
    procedure TestClickingBackAndForthSettlesOnlyOne;
    procedure TestTakingASideMovesTheOthers;
    procedure TestTypingThirdVersionSettles;
    procedure TestTypingNextToAConflictDoesNot;
    procedure TestConflictWithNoLines;
    procedure TestConflictStartHoldsTheCommonLines;
    procedure TestWhichConflictAChangeBelongsTo;
    procedure TestDroppingBothSidesSettles;
    procedure TestDecidingAgain;
  end;

implementation

uses
  SysUtils, McpDiff, McpConflictFiles;

function Entry(const AMode, AStage, APath: string): string;
begin
  Result := AMode + ' 0123456789abcdef0123456789abcdef01234567 ' + AStage + #9 + APath + #0;
end;

procedure TTestConflictFiles.TestParseThreeStagesAndTwo;
var
  R : TConflictStagesArray;
begin
  R := ParseUnmerged(
    Entry('100644', '1', 'src/a.pas') + Entry('100644', '2', 'src/a.pas') +
    Entry('100644', '3', 'src/a.pas') +
    Entry('100644', '2', 'b.txt') + Entry('100755', '3', 'b.txt'));
  CheckEquals(2, Length(R), 'two paths');
  CheckEquals('src/a.pas', R[0].Path);
  CheckTrue(R[0].Has[1] and R[0].Has[2] and R[0].Has[3], 'all three stages');
  CheckEquals('b.txt', R[1].Path);
  CheckFalse(R[1].Has[1], 'both added: no common ancestor');
  CheckEquals('100755', R[1].Mode[3]);
  CheckEquals('', NotTextReason(R[0]), 'a text merge');
  CheckEquals('', NotTextReason(R[1]), 'also without a base');
end;

procedure TTestConflictFiles.TestParseNothing;
begin
  CheckEquals(0, Length(ParseUnmerged('')));
  CheckEquals(0, Length(ParseUnmerged(#0#0)));
  CheckEquals(0, Length(ParseUnmerged('garbage without a tab')));
end;

{ -z: a path is taken as it is, with spaces; a stage that is not 1..3 is no entry }
procedure TTestConflictFiles.TestPathWithSpacesAndTab;
var
  R : TConflictStagesArray;
begin
  R := ParseUnmerged(Entry('100644', '2', 'my dir/my file.txt') +
    Entry('100644', '3', 'my dir/my file.txt') + Entry('100644', '0', 'odd.txt'));
  CheckEquals(1, Length(R));
  CheckEquals('my dir/my file.txt', R[0].Path);
end;

procedure TTestConflictFiles.TestNotTextReasons;
var
  R : TConflictStagesArray;
begin
  R := ParseUnmerged(
    Entry('100644', '1', 'gone.txt') + Entry('100644', '3', 'gone.txt') +
    Entry('120000', '2', 'link') + Entry('120000', '3', 'link') +
    Entry('160000', '2', 'sub') + Entry('160000', '3', 'sub'));
  CheckEquals(3, Length(R));
  CheckTrue(Pos('deleted', NotTextReason(R[0])) > 0, 'modify/delete: ' + NotTextReason(R[0]));
  CheckTrue(Pos('1, 3', NotTextReason(R[0])) > 0, 'names the stages that exist');
  CheckTrue(Pos('symbolic link', NotTextReason(R[1])) > 0, NotTextReason(R[1]));
  CheckTrue(Pos('submodule', NotTextReason(R[2])) > 0, NotTextReason(R[2]));
  CheckTrue(Pos('git_resolve', NotTextReason(R[0])) > 0, 'says what to do');
end;

procedure TTestConflictFiles.TestLooksBinary;
begin
  CheckFalse(LooksBinary(''));
  CheckFalse(LooksBinary('plain text' + #13#10 + 'more'));
  CheckTrue(LooksBinary('PK' + #0 + #3));
  { git looks at the first 8000 bytes only }
  CheckFalse(LooksBinary(StringOfChar('a', 8000) + #0));
end;

procedure TTestConflictFiles.TestEol;
begin
  CheckEquals(#10, EolOf(''));
  CheckEquals(#10, EolOf('one'));
  CheckEquals(#10, EolOf('one' + #10 + 'two'));
  CheckEquals(#13#10, EolOf('one' + #13#10 + 'two'));
  CheckEquals(#10, EolOf(#10 + 'x'), 'a lone LF at the start');
  { the first line decides, as in the file the user has }
  CheckEquals(#13#10, EolOf('a' + #13#10 + 'b' + #10 + 'c'));
end;

procedure TTestConflictFiles.TestConflictBlock;
var
  Lines : TDiffLines;
begin
  Lines := nil;
  CheckFalse(HasConflictBlock(Lines), 'empty');
  SetLength(Lines, 3);
  Lines[0] := 'Title'; Lines[1] := '====='; Lines[2] := '=======';
  CheckFalse(HasConflictBlock(Lines), 'a Markdown underline is no conflict');
  SetLength(Lines, 5);
  Lines[0] := 'a'; Lines[1] := '<<<<<<< HEAD'; Lines[2] := 'x';
  Lines[3] := '=======';  Lines[4] := 'y';
  CheckFalse(HasConflictBlock(Lines), 'opened and never closed');
  SetLength(Lines, 6);
  Lines[5] := '>>>>>>> feature';
  CheckTrue(HasConflictBlock(Lines), 'a block');
  Lines[0] := '>>>>>>> feature'; Lines[5] := 'z';
  CheckFalse(HasConflictBlock(Lines), 'the closing line comes first');
end;

procedure TTestConflictFiles.TestWithEol;
begin
  CheckEquals('a' + #13#10 + 'b' + #13#10, WithEol('a' + #10 + 'b' + #10, #13#10, True));
  CheckEquals('a' + #10 + 'b', WithEol('a' + #13#10 + 'b' + #13#10, #10, False),
    'no final newline when the file had none');
  CheckEquals('a' + #13#10 + 'b', WithEol('a' + #13#10 + 'b', #13#10, False));
  CheckEquals('', WithEol('', #13#10, True));
end;

function Lines(const AItems: array of string): TDiffLines;
var
  I : Integer;
begin
  Result := nil;
  SetLength(Result, Length(AItems));
  for I := 0 to High(AItems) do
    Result[I] := AItems[I];
end;

{ Base h x m y t; both sides change x and y, differently: two conflicts. }
function TwoConflicts: TConflictSpans;
begin
  Result := InitConflictSpans(Lines(['h', 'x', 'm', 'y', 't']),
    Lines(['h', 'X1', 'm', 'Y1', 't']), Lines(['h', 'X2', 'm', 'Y2', 't']), True);
end;

procedure TTestConflictFiles.TestSpansFollowTheAutomaticMerge;
var
  S : TConflictSpans;
begin
  S := TwoConflicts;
  CheckEquals(2, Length(S));
  CheckEquals(1, S[0].Start);
  CheckEquals(1, S[0].Len);
  CheckEquals(3, S[1].Start);
  CheckEquals('X1', S[0].Ours[0]);
  CheckEquals('Y2', S[1].Theirs[0]);
  CheckEquals(2, UnsettledSpans(S), 'nothing is decided at the start');
  CheckFalse(S[0].Done[0] or S[0].Done[1] or S[1].Done[0] or S[1].Done[1],
    'and no side has been dealt with');
  CheckFalse(S[0].Took[0] or S[0].Took[1] or S[1].Took[0] or S[1].Took[1],
    'nor has any side put its lines there');

  { a change only the right made comes first and is in the result: the span moves down }
  S := InitConflictSpans(Lines(['h', 'x', 'm', 'y', 't']),
    Lines(['h', 'x', 'm', 'Y1', 't']), Lines(['h', 'n1', 'n2', 'x', 'm', 'Y2', 't']), True);
  CheckEquals(1, Length(S));
  CheckEquals(5, S[0].Start, 'h n1 n2 x m then the conflict');
end;

procedure TTestConflictFiles.TestSpansWithoutBase;
var
  S : TConflictSpans;
begin
  S := InitConflictSpans(Lines(['a', 'b']), Lines(['a', 'c', 'd']), nil, False);
  CheckEquals(1, Length(S), 'one conflict: the whole file');
  CheckEquals(0, S[0].Start);
  CheckEquals(0, S[0].Len, 'the result starts empty: both texts stand against nothing');
  CheckEquals(0, Length(ConflictStart(Lines(['a', 'b']), Lines(['a', 'c']), nil, False)));
  CheckEquals(0, Length(InitConflictSpans(nil, nil, nil, False)), 'two empty texts: none');
end;

{ The count of clicks was fooled by this; the state of each conflict is not. }
procedure TTestConflictFiles.TestClickingBackAndForthSettlesOnlyOne;
var
  S : TConflictSpans;
  I : Integer;
begin
  S := TwoConflicts;
  for I := 1 to 6 do
  begin
    MoveConflictSpans(S, S[0].Start, S[0].Len, 1, True, True);    { left, right, left ... }
    CheckEquals(1, S[0].Start);
  end;
  CheckTrue(S[0].Settled);
  CheckFalse(S[1].Settled);
  CheckEquals(1, UnsettledSpans(S), 'the other conflict is still to decide');
end;

procedure TTestConflictFiles.TestTakingASideMovesTheOthers;
var
  S : TConflictSpans;
begin
  S := TwoConflicts;
  { the right side has three lines there: the first conflict grows, the second moves }
  MoveConflictSpans(S, 1, 1, 3, True, True);
  CheckEquals(1, S[0].Start);
  CheckEquals(3, S[0].Len);
  CheckTrue(S[0].Settled);
  CheckEquals(5, S[1].Start);
  CheckEquals(1, S[1].Len);
  CheckFalse(S[1].Settled);
  { and back to one line }
  MoveConflictSpans(S, 1, 3, 1, True, True);
  CheckEquals(3, S[1].Start);
  { a change after both leaves them as they are }
  MoveConflictSpans(S, 4, 1, 2, True, True);
  CheckEquals(1, S[0].Start);
  CheckEquals(3, S[1].Start);
  CheckFalse(S[1].Settled, 'a line after the conflict is not the conflict');
end;

{ A third version, neither side's: typed over the conflict's lines in the result. }
procedure TTestConflictFiles.TestTypingThirdVersionSettles;
var
  S : TConflictSpans;
begin
  S := TwoConflicts;
  { line 1 (X1) replaced by two typed lines }
  MoveConflictSpans(S, 1, 1, 2, True, False);
  CheckTrue(S[0].Settled, 'typing over its lines settles it');
  CheckEquals(2, S[0].Len);
  CheckFalse(S[1].Settled);
  CheckEquals(4, S[1].Start, 'the second one moved down by one');
  { the lines of the second conflict deleted: also a decision }
  MoveConflictSpans(S, 4, 1, 0, True, False);
  CheckTrue(S[1].Settled);
  CheckEquals(0, UnsettledSpans(S));
  { a line typed into the middle of a three-line conflict }
  S := InitConflictSpans(Lines(['h', 'a', 'b', 'c', 't']),
    Lines(['h', 'a1', 'b1', 'c1', 't']), Lines(['h', 'a2', 'b2', 'c2', 't']), True);
  CheckEquals(3, S[0].Len);
  MoveConflictSpans(S, 2, 0, 1, True, False);
  CheckTrue(S[0].Settled);
  CheckEquals(4, S[0].Len);
end;

procedure TTestConflictFiles.TestTypingNextToAConflictDoesNot;
var
  S : TConflictSpans;
begin
  S := TwoConflicts;
  MoveConflictSpans(S, 1, 0, 1, True, False);           { a line typed just above it }
  CheckFalse(S[0].Settled, 'above');
  CheckEquals(2, S[0].Start, 'the conflict moved down');
  MoveConflictSpans(S, 3, 0, 1, True, False);           { and one just below it }
  CheckFalse(S[0].Settled, 'below');
  CheckEquals(2, S[0].Start);
  CheckEquals(1, S[0].Len);
  CheckEquals(5, S[1].Start);
  { the same changes by an arrow are part of it }
  S := TwoConflicts;
  MoveConflictSpans(S, 2, 0, 1, True, True);            { appended after its last line }
  CheckTrue(S[0].Settled);
  CheckEquals(2, S[0].Len);
  { editing elsewhere }
  S := TwoConflicts;
  MoveConflictSpans(S, 0, 1, 1, True, False);           { the first line }
  MoveConflictSpans(S, 4, 1, 1, True, False);           { the last }
  CheckEquals(2, UnsettledSpans(S));
end;

{ Ours deleted the line, theirs changed it: the conflict holds the common line, and the
  left has nothing to put there. }
procedure TTestConflictFiles.TestConflictWithNoLines;
var
  S : TConflictSpans;
begin
  S := InitConflictSpans(Lines(['h', 'x', 't']), Lines(['h', 't']),
    Lines(['h', 'X2', 't']), True);
  CheckEquals(1, Length(S));
  CheckEquals(1, S[0].Start);
  CheckEquals(1, S[0].Len, 'the common line');
  CheckEquals(0, Length(S[0].Ours), 'the left deleted it');
  CheckEquals(1, Length(S[0].Theirs));
  { taking the left's nothing removes the line: settled, and what is left is a place }
  MoveConflictSpans(S, 1, 1, 0, True, True);
  CheckTrue(S[0].Settled);
  CheckEquals(0, S[0].Len);
  { a change elsewhere does not settle it }
  S := InitConflictSpans(Lines(['h', 'x', 't']), Lines(['h', 't']),
    Lines(['h', 'X2', 't']), True);
  MoveConflictSpans(S, 2, 1, 1, True, False);
  CheckFalse(S[0].Settled);
  MoveConflictSpans(S, 0, 1, 1, True, False);
  CheckFalse(S[0].Settled);
  CheckEquals(1, S[0].Start);
end;

{ Changes only one side made are taken; a conflict holds the common line, so both sides
  stand against it. }
procedure TTestConflictFiles.TestConflictStartHoldsTheCommonLines;
var
  R : TDiffLines;
  S : TConflictSpans;
  Base, Mine, Theirs : TDiffLines;
begin
  { y and t are two lines apart: changes on neighbouring lines would be one conflict }
  Base   := Lines(['h', 'x', 'm', 'y', 'u', 't']);
  Mine   := Lines(['h', 'X1', 'm', 'Y1', 'u', 't']);
  Theirs := Lines(['h', 'X2', 'm', 'y', 'u', 'T2']);
  R := ConflictStart(Base, Mine, Theirs, True);
  CheckEquals(6, Length(R));
  CheckEquals('x', R[1], 'the conflict: the common line');
  CheckEquals('Y1', R[3], 'only the left changed it');
  CheckEquals('T2', R[5], 'only the right changed it');
  S := InitConflictSpans(Base, Mine, Theirs, True);
  CheckEquals(1, Length(S));
  CheckEquals(1, S[0].Start);
  CheckEquals(1, S[0].Len);
  CheckEquals('X1', S[0].Ours[0]);
  CheckEquals('X2', S[0].Theirs[0]);
  { a line only the right added comes first: the conflict is below it in the result too }
  R := ConflictStart(Lines(['h', 'x']), Lines(['h', 'X1']), Lines(['n', 'h', 'X2']), True);
  CheckEquals(3, Length(R));
  CheckEquals('n', R[0]);
  CheckEquals('x', R[2]);
  S := InitConflictSpans(Lines(['h', 'x']), Lines(['h', 'X1']), Lines(['n', 'h', 'X2']), True);
  CheckEquals(2, S[0].Start);
end;

procedure TTestConflictFiles.TestWhichConflictAChangeBelongsTo;
var
  S : TConflictSpans;
begin
  S := TwoConflicts;                          { lines 1 and 3 of h x m y t }
  CheckEquals(0, SpanOfHunk(S, 1, 1));
  CheckEquals(1, SpanOfHunk(S, 3, 1));
  CheckEquals(-1, SpanOfHunk(S, 2, 1), 'the line between them');
  CheckEquals(-1, SpanOfHunk(S, 0, 1));
  CheckEquals(-1, SpanOfHunk(S, 4, 1));
  CheckEquals(0, SpanOfHunk(S, 1, 0), 'a place just above a conflict');
  CheckEquals(1, SpanOfHunk(S, 4, 0), 'and just below it');
  CheckEquals(-1, SpanOfHunk(S, 5, 0));
  { a conflict with no lines is a place }
  SetLength(S, 1);
  S[0].Start := 2;
  S[0].Len := 0;
  CheckEquals(0, SpanOfHunk(S, 1, 2), 'a change that covers the place');
  CheckEquals(-1, SpanOfHunk(S, 3, 1));
end;

{ "Neither": the lines of both sides are dropped.  That is a decision, and what follows
  moves up. }
procedure TTestConflictFiles.TestDroppingBothSidesSettles;
var
  S : TConflictSpans;
begin
  S := TwoConflicts;
  MoveConflictSpans(S, S[0].Start, S[0].Len, 0, True, True);
  CheckTrue(S[0].Settled);
  CheckEquals(0, S[0].Len);
  CheckEquals(2, S[1].Start, 'the second conflict moved up by one');
  CheckFalse(S[1].Settled);
  { dropping again, where nothing is left, changes nothing but is still the same decision }
  MoveConflictSpans(S, S[0].Start, S[0].Len, 0, True, True);
  CheckTrue(S[0].Settled);
  CheckEquals(2, S[1].Start);
  CheckEquals(1, UnsettledSpans(S));
end;

{ Deciding again: the conflict's lines are the common ones, the flags are clear, and the
  conflicts after it move to fit. }
procedure TTestConflictFiles.TestDecidingAgain;
var
  S : TConflictSpans;
  R : TDiffLines;
begin
  S := TwoConflicts;
  { the result as it starts: h x m y t; the user took two lines for the first conflict }
  R := Lines(['h', 'X1', 'X2', 'm', 'y', 't']);
  S[0].Len := 2;
  S[0].Settled := True;
  S[0].Done[0] := True;
  S[0].Done[1] := True;
  S[0].Took[0] := True;
  S[0].Took[1] := True;
  S[1].Start := 4;
  ResetConflict(S, 0, R);
  CheckEquals('h x m y t', R[0] + ' ' + R[1] + ' ' + R[2] + ' ' + R[3] + ' ' + R[4]);
  CheckEquals(5, Length(R));
  CheckEquals(1, S[0].Len);
  CheckEquals(3, S[1].Start, 'the next conflict moved back up');
  CheckFalse(S[0].Settled);
  CheckFalse(S[0].Done[0] or S[0].Done[1] or S[0].Took[0] or S[0].Took[1]);
  CheckEquals(2, UnsettledSpans(S));
  { a conflict a side deleted: its lines come back too }
  S := TwoConflicts;
  R := Lines(['h', 'm', 'y', 't']);
  S[0].Len := 0;
  S[1].Start := 2;
  ResetConflict(S, 0, R);
  CheckEquals(5, Length(R));
  CheckEquals('x', R[1]);
  CheckEquals(3, S[1].Start);
  ResetConflict(S, 7, R);                  { no such conflict: nothing happens }
  CheckEquals(5, Length(R));
end;

initialization
  RegisterTest(TTestConflictFiles);

end.
