{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TStatementEdit;

{ TTestStatementEdit — McpStatementEdit: replace, delete, insert and wrap of one statement,
  against the text of a small body (ADR-008).  Pure RTL, no server needed. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, Classes, McpStatements, McpStatementEdit;

type
  TTestStatementEdit = class(TTestCase)
  private
    function Run(const ASrc, AOp, AWith, AText: string; ALine, ACol: Integer): string;
  published
    procedure TestReplace;
    procedure TestReplaceKeepsTheSemicolonOnce;
    procedure TestDeleteWholeLine;
    procedure TestDeleteOneOfTwoOnALine;
    procedure TestDeleteLastWithoutSemicolon;
    procedure TestDeleteOnlyStatementOfASlotRefused;
    procedure TestInsertBefore;
    procedure TestInsertAfterLastWithoutSemicolon;
    procedure TestInsertAfterOnASharedLine;
    procedure TestInsertAfterKeepsTheComment;
    procedure TestInsertTextIsDedented;
    procedure TestWrapBeginInASlot;
    procedure TestWrapTryFinally;
    procedure TestWrapTryExcept;
    procedure TestWrapMultiLineStatement;
    procedure TestWrapIfNeedsCondition;
    procedure TestWrapIfCannotTakeTheElse;
    procedure TestWrapWhileAndFor;
    procedure TestAmbiguousLineNeedsCol;
    procedure TestNoStatementThere;
    procedure TestRefusals;
    procedure TestSurroundingTextIsKept;
  end;

implementation

uses
  SysUtils, TStatements;

const
  Src =
    'procedure P;' + #10 +             { 1 }
    'begin' + #10 +                    { 2 }
    '  A;' + #10 +                     { 3 }
    '  if X then' + #10 +              { 4 }
    '    B' + #10 +                    { 5 }
    '  else' + #10 +                   { 6 }
    '    C;' + #10 +                   { 7 }
    '  D; E;' + #10 +                  { 8 }
    '  Last' + #10 +                   { 9 }
    'end;' + #10;                      { 10 }

{ Lines joined with LF, a final LF. }
function Lns(const A: array of string): string;
var
  I : Integer;
begin
  Result := '';
  for I := Low(A) to High(A) do
    Result := Result + A[I] + #10;
end;

function OffsetOf(const S: string; ALine, ACol: Integer): Integer;
var
  L, I : Integer;
begin
  I := 1;
  L := 1;
  while (L < ALine) and (I <= Length(S)) do
  begin
    if S[I] = #10 then Inc(L);
    Inc(I);
  end;
  Result := I + ACol - 1;
  if Result > Length(S) + 1 then Result := Length(S) + 1;
end;

{ The edit done, or "ERR: " and its error. }
function TTestStatementEdit.Run(const ASrc, AOp, AWith, AText: string; ALine, ACol: Integer): string;
var
  Root  : TStmtNode;
  Lines : TStringList;
  E     : TStmtEdit;
  O1, O2 : Integer;
begin
  Root := ParseBodyStatements(ASrc, 1);
  Lines := TStringList.Create;
  try
    Lines.LineBreak := #10;
    Lines.Text := ASrc;
    E := EditStatement(Lines, Root, ALine, ACol, AOp, AWith, AText);
  finally
    Lines.Free;
    Root.Free;
  end;
  if not E.Ok then Exit('ERR: ' + E.Error);
  O1 := OffsetOf(ASrc, E.StartLine, E.StartCol);
  O2 := OffsetOf(ASrc, E.EndLine, E.EndCol);
  Result := Copy(ASrc, 1, O1 - 1) + E.NewText + Copy(ASrc, O2, MaxInt);
end;

procedure TTestStatementEdit.TestReplace;
begin
  AssertEquals(Lns(['procedure P;', 'begin', '  Foo(1, 2);', '  if X then', '    B', '  else',
    '    C;', '  D; E;', '  Last', 'end;']),
    Run(Src, 'replace', '', 'Foo(1, 2)', 3, 0));
  { the branch of an if: its place in the if stays }
  AssertEquals(Lns(['procedure P;', 'begin', '  A;', '  if X then', '    Y := 1', '  else',
    '    C;', '  D; E;', '  Last', 'end;']),
    Run(Src, 'replace', '', 'Y := 1', 5, 0));
end;

procedure TTestStatementEdit.TestReplaceKeepsTheSemicolonOnce;
begin
  { a ; at the end of the new text is dropped: the old one is still there }
  AssertEquals(Lns(['procedure P;', 'begin', '  Foo;', '  if X then', '    B', '  else',
    '    C;', '  D; E;', '  Last', 'end;']),
    Run(Src, 'replace', '', 'Foo;', 3, 0));
end;

procedure TTestStatementEdit.TestDeleteWholeLine;
begin
  AssertEquals(Lns(['procedure P;', 'begin', '  if X then', '    B', '  else', '    C;',
    '  D; E;', '  Last', 'end;']),
    Run(Src, 'delete', '', '', 3, 0));
end;

procedure TTestStatementEdit.TestDeleteOneOfTwoOnALine;
begin
  AssertEquals(Lns(['procedure P;', 'begin', '  A;', '  if X then', '    B', '  else', '    C;',
    '  D;', '  Last', 'end;']),
    Run(Src, 'delete', '', '', 8, 6));
  AssertEquals(Lns(['procedure P;', 'begin', '  A;', '  if X then', '    B', '  else', '    C;',
    '  E;', '  Last', 'end;']),
    Run(Src, 'delete', '', '', 8, 3));
end;

procedure TTestStatementEdit.TestDeleteLastWithoutSemicolon;
begin
  AssertEquals(Lns(['procedure P;', 'begin', '  A;', '  if X then', '    B', '  else', '    C;',
    '  D; E;', 'end;']),
    Run(Src, 'delete', '', '', 9, 0));
end;

procedure TTestStatementEdit.TestDeleteOnlyStatementOfASlotRefused;
var
  R : string;
begin
  R := Run(Src, 'delete', '', '', 5, 0);
  AssertTrue(R, Pos('ERR: ', R) = 1);
  AssertTrue(R, Pos('replace', R) > 0);
end;

procedure TTestStatementEdit.TestInsertBefore;
begin
  AssertEquals(Lns(['procedure P;', 'begin', '  A;', '  Log(1);', '  if X then', '    B', '  else',
    '    C;', '  D; E;', '  Last', 'end;']),
    Run(Src, 'insert_before', '', 'Log(1)', 4, 0));
  { two statements, a semicolon after each }
  AssertEquals(Lns(['procedure P;', 'begin', '  X1;', '  X2;', '  A;', '  if X then', '    B',
    '  else', '    C;', '  D; E;', '  Last', 'end;']),
    Run(Src, 'insert_before', '', 'X1;' + #10 + 'X2', 3, 0));
end;

procedure TTestStatementEdit.TestInsertAfterLastWithoutSemicolon;
begin
  AssertEquals(Lns(['procedure P;', 'begin', '  A;', '  if X then', '    B', '  else', '    C;',
    '  D; E;', '  Last;', '  Done;', 'end;']),
    Run(Src, 'insert_after', '', 'Done', 9, 0));
end;

procedure TTestStatementEdit.TestInsertAfterOnASharedLine;
begin
  AssertEquals(Lns(['procedure P;', 'begin', '  A;', '  if X then', '    B', '  else', '    C;',
    '  D; Z; E;', '  Last', 'end;']),
    Run(Src, 'insert_after', '', 'Z', 8, 3));
end;

procedure TTestStatementEdit.TestInsertAfterKeepsTheComment;
const
  S2 =
    'begin' + #10 +
    '  A; // note' + #10 +
    '  B;' + #10 +
    'end;' + #10;
begin
  AssertEquals(Lns(['begin', '  A; // note', '  Z;', '  B;', 'end;']),
    Run(S2, 'insert_after', '', 'Z', 2, 0));
end;

procedure TTestStatementEdit.TestInsertTextIsDedented;
begin
  AssertEquals(Lns(['procedure P;', 'begin', '  A;', '  X := 1;', '  Y := 2;', '  if X then',
    '    B', '  else', '    C;', '  D; E;', '  Last', 'end;']),
    Run(Src, 'insert_after', '', '    X := 1;' + #10 + '    Y := 2', 3, 0));
end;

procedure TTestStatementEdit.TestWrapBeginInASlot;
begin
  AssertEquals(Lns(['procedure P;', 'begin', '  A;', '  if X then', '    begin', '      B;',
    '    end', '  else', '    C;', '  D; E;', '  Last', 'end;']),
    Run(Src, 'wrap', 'begin', '', 5, 0));
end;

procedure TTestStatementEdit.TestWrapTryFinally;
begin
  AssertEquals(Lns(['procedure P;', 'begin', '  A;', '  if X then', '    B', '  else', '    C;',
    '  D; E;', '  try', '    Last;', '  finally', '    Free;', '  end', 'end;']),
    Run(Src, 'wrap', 'try_finally', 'Free;', 9, 0));
end;

procedure TTestStatementEdit.TestWrapTryExcept;
begin
  AssertEquals(Lns(['procedure P;', 'begin', '  try', '    A;', '  except', '    on E: Exception do Log(E);',
    '  end;', '  if X then', '    B', '  else', '    C;', '  D; E;', '  Last', 'end;']),
    Run(Src, 'wrap', 'try_except', 'on E: Exception do Log(E);', 3, 0));
end;

procedure TTestStatementEdit.TestWrapMultiLineStatement;
begin
  { the lines after the first move with it }
  AssertEquals(Lns(['procedure P;', 'begin', '  A;', '  begin', '    if X then', '      B', '    else',
    '      C;', '  end;', '  D; E;', '  Last', 'end;']),
    Run(Src, 'wrap', 'begin', '', 4, 0));
end;

procedure TTestStatementEdit.TestWrapIfNeedsCondition;
var
  R : string;
begin
  R := Run(Src, 'wrap', 'if', '', 3, 0);
  AssertTrue(R, Pos('ERR: ', R) = 1);
  AssertEquals(Lns(['procedure P;', 'begin', '  if Ready then', '    A;', '  if X then', '    B',
    '  else', '    C;', '  D; E;', '  Last', 'end;']),
    Run(Src, 'wrap', 'if', 'Ready', 3, 0));
end;

{ `if Y then B else C` : B in an if would take the else. }
procedure TTestStatementEdit.TestWrapIfCannotTakeTheElse;
var
  R : string;
begin
  R := Run(Src, 'wrap', 'if', 'Y', 5, 0);
  AssertTrue(R, Pos('ERR: ', R) = 1);
  AssertTrue(R, Pos('else', R) > 0);
  { the else branch itself has nothing after it to take }
  AssertTrue(Run(Src, 'wrap', 'if', 'Y', 7, 0), Pos('ERR: ', Run(Src, 'wrap', 'if', 'Y', 7, 0)) = 0);
end;

procedure TTestStatementEdit.TestWrapWhileAndFor;
begin
  AssertEquals(Lns(['procedure P;', 'begin', '  while Busy do', '    A;', '  if X then', '    B',
    '  else', '    C;', '  D; E;', '  Last', 'end;']),
    Run(Src, 'wrap', 'while', 'Busy', 3, 0));
  AssertEquals(Lns(['procedure P;', 'begin', '  for I := 0 to 9 do', '    A;', '  if X then', '    B',
    '  else', '    C;', '  D; E;', '  Last', 'end;']),
    Run(Src, 'wrap', 'for', 'I := 0 to 9', 3, 0));
end;

procedure TTestStatementEdit.TestAmbiguousLineNeedsCol;
var
  R : string;
begin
  R := Run(Src, 'delete', '', '', 8, 0);
  AssertTrue(R, Pos('Ambiguous', R) > 0);
  AssertTrue(R, Pos('3 (', R) > 0);
  AssertTrue(R, Pos('6 (', R) > 0);
end;

procedure TTestStatementEdit.TestNoStatementThere;
var
  R : string;
begin
  R := Run(Src, 'delete', '', '', 1, 0);
  AssertTrue(R, Pos('No statement starts at line 1', R) > 0);
  R := Run(Src, 'delete', '', '', 3, 9);
  AssertTrue(R, Pos('column 9', R) > 0);
end;

procedure TTestStatementEdit.TestRefusals;
begin
  AssertTrue(Pos('Unknown action', Run(Src, 'frobnicate', '', '', 3, 0)) > 0);
  AssertTrue(Pos('needs text', Run(Src, 'replace', '', '', 3, 0)) > 0);
  AssertTrue(Pos('needs text', Run(Src, 'insert_before', '', '', 3, 0)) > 0);
  AssertTrue(Pos('needs "with"', Run(Src, 'wrap', '', '', 3, 0)) > 0);
  AssertTrue(Pos('Unknown wrapper', Run(Src, 'wrap', 'repeat', 'x', 3, 0)) > 0);
  AssertTrue(Pos('is the only one', Run(Src, 'insert_before', '', 'Z', 5, 0)) > 0);
end;

{ Comments, a directive and odd spacing around the edited statement come out as they were. }
procedure TTestStatementEdit.TestSurroundingTextIsKept;
const
  S2 =
    'begin' + #10 +
    '  { first }  A;   // trailing' + #10 +
    '  {$IFDEF X}' + #10 +
    '  B;' + #10 +
    '  {$ENDIF}' + #10 +
    '  (* c *) C ( 1 ,2 ) ;' + #10 +
    'end;' + #10;
begin
  AssertEquals(Lns(['begin', '  { first }  A;   // trailing', '  {$IFDEF X}', '  B;', '  {$ENDIF}',
    '  (* c *) Foo ;', 'end;']),
    Run(S2, 'replace', '', 'Foo', 6, 0));
end;

initialization
  RegisterTest(TTestStatementEdit);

end.
