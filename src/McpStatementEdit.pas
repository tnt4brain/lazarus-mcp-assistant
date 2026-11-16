{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpStatementEdit;

{ Edits of one statement of a routine body, found by the line and column the AST tool reported
  (ADR-008).  Pure RTL, no IDE: the caller hands over the lines of the file and the tree of
  McpStatements, and gets back ONE range to replace and its new text.  The text of the file
  around the statement is never regenerated, so its comments, directives and formatting stay.

  Ops: replace, delete, insert_before, insert_after, wrap (begin, try_finally, try_except, if,
  while, for, with).  Text the caller sends is dedented and then indented like the statement it
  is about, so it can be written with or without the indentation of the file. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, McpStatements;

type
  TStmtEdit = record
    Ok        : Boolean;
    Error     : string;
    StartLine : Integer;    { the range to replace, 1-based; the end is exclusive }
    StartCol  : Integer;
    EndLine   : Integer;
    EndCol    : Integer;
    NewText   : string;     { LF line ends }
  end;

{ The statement that starts at ALine (and ACol when it is not 0); AParent is the node that holds
  it (the body's begin block for a top-level one).  False with AError when none, or when
  several start on the line and ACol does not pick one. }
function FindStatement(ARoot: TStmtNode; ALine, ACol: Integer;
  out ANode, AParent: TStmtNode; out AError: string): Boolean;

{ ALines: the lines of the file (index 0 is line 1).  AWith: the kind of wrapper for `wrap`. }
function EditStatement(ALines: TStrings; ARoot: TStmtNode; ALine, ACol: Integer;
  const AOp, AWith, AText: string): TStmtEdit;

implementation

const
  Step = '  ';                { one level of indentation added by a wrapper }

{ ── Text helpers ─────────────────────────────────────────────────────────── }

function LineAt(ALines: TStrings; L: Integer): string;
begin
  if (L >= 1) and (L <= ALines.Count) then Result := ALines[L - 1] else Result := '';
end;

function IndentOf(const S: string): string;
var
  I : Integer;
begin
  I := 1;
  while (I <= Length(S)) and (S[I] in [' ', #9]) do Inc(I);
  Result := Copy(S, 1, I - 1);
end;

function IsBlank(const S: string): Boolean;
begin
  Result := Trim(S) = '';
end;

function CountLf(const S: string): Integer;
var
  I : Integer;
begin
  Result := 0;
  for I := 1 to Length(S) do
    if S[I] = #10 then Inc(Result);
end;

{ The text from (SL, SC) up to (EL, EC), the end exclusive, with LF between the lines. }
function TextBetween(ALines: TStrings; SL, SC, EL, EC: Integer): string;
var
  L : Integer;
begin
  if SL = EL then
    Exit(Copy(LineAt(ALines, SL), SC, EC - SC));
  Result := Copy(LineAt(ALines, SL), SC, MaxInt);
  for L := SL + 1 to EL - 1 do
    Result := Result + #10 + LineAt(ALines, L);
  Result := Result + #10 + Copy(LineAt(ALines, EL), 1, EC - 1);
end;

{ Prefix in front of every non-empty line; the first one too when AFirst. }
function IndentLines(const S, APrefix: string; AFirst: Boolean): string;
var
  SL : TStringList;
  I  : Integer;
begin
  SL := TStringList.Create;
  try
    SL.LineBreak := #10;
    SL.Text := S;
    for I := 0 to SL.Count - 1 do
      if (SL[I] <> '') and ((I > 0) or AFirst) then SL[I] := APrefix + SL[I];
    Result := SL.Text;
    if (Result <> '') and (Result[Length(Result)] = #10) and ((S = '') or (S[Length(S)] <> #10)) then
      SetLength(Result, Length(Result) - 1);
  finally
    SL.Free;
  end;
end;

{ What the caller sent: LF line ends, no leading empty lines, no trailing white space, and the
  indentation they share removed. }
function Prepare(const S: string): string;
var
  SL  : TStringList;
  I, K, Common : Integer;
begin
  Result := StringReplace(StringReplace(S, #13#10, #10, [rfReplaceAll]), #13, #10, [rfReplaceAll]);
  Result := TrimRight(Result);
  while (Result <> '') and (Result[1] = #10) do Delete(Result, 1, 1);
  if Result = '' then Exit;
  SL := TStringList.Create;
  try
    SL.LineBreak := #10;
    SL.Text := Result;
    Common := MaxInt;
    for I := 0 to SL.Count - 1 do
      if not IsBlank(SL[I]) then
      begin
        K := Length(IndentOf(SL[I]));
        if K < Common then Common := K;
      end;
    if Common = MaxInt then Common := 0;
    for I := 0 to SL.Count - 1 do
      if IsBlank(SL[I]) then SL[I] := ''
      else SL[I] := TrimRight(Copy(SL[I], Common + 1, MaxInt));
    Result := SL.Text;
    while (Result <> '') and (Result[Length(Result)] = #10) do SetLength(Result, Length(Result) - 1);
  finally
    SL.Free;
  end;
end;

function EnsureSemi(const S: string): string;
begin
  Result := S;
  if (Result <> '') and not (Result[Length(Result)] in [';', '}']) then Result := Result + ';';
end;

function IsListParent(AParent: TStmtNode): Boolean;
begin
  Result := (AParent <> nil) and
    ((AParent.Kind = 'begin') or (AParent.Kind = 'repeat') or (AParent.Kind = 'try_except') or
     (AParent.Kind = 'try_finally') or (AParent.Kind = 'case') or (AParent.Kind = 'else'));
end;

{ ── Finding the statement ────────────────────────────────────────────────── }

procedure Collect(AParent: TStmtNode; ALine, ACol: Integer; AFound, AParents: TList);
var
  I : Integer;
  N : TStmtNode;
begin
  for I := 0 to AParent.Children.Count - 1 do
  begin
    N := TStmtNode(AParent.Children[I]);
    if (N.Line = ALine) and ((ACol <= 0) or (N.Col = ACol)) then
    begin
      AFound.Add(N);
      AParents.Add(AParent);
    end;
    if (N.Line <= ALine) and (N.EndLine >= ALine) then
      Collect(N, ALine, ACol, AFound, AParents);
  end;
end;

function FindStatement(ARoot: TStmtNode; ALine, ACol: Integer;
  out ANode, AParent: TStmtNode; out AError: string): Boolean;
var
  Found, Parents : TList;
  I : Integer;
begin
  Result := False;
  ANode := nil;
  AParent := nil;
  AError := '';
  Found := TList.Create;
  Parents := TList.Create;
  try
    if ARoot <> nil then Collect(ARoot, ALine, ACol, Found, Parents);
    if Found.Count = 0 then
    begin
      AError := 'No statement starts at line ' + IntToStr(ALine);
      if ACol > 0 then AError := AError + ', column ' + IntToStr(ACol);
      AError := AError + ' (line and col are those of code_get_procedure_ast)';
      Exit;
    end;
    if Found.Count > 1 then
    begin
      AError := 'Ambiguous: ' + IntToStr(Found.Count) + ' statements start on line ' + IntToStr(ALine) + ', give col:';
      for I := 0 to Found.Count - 1 do
        AError := AError + ' ' + IntToStr(TStmtNode(Found[I]).Col) + ' (' + TStmtNode(Found[I]).Kind + ')';
      Exit;
    end;
    ANode := TStmtNode(Found[0]);
    AParent := TStmtNode(Parents[0]);
    Result := True;
  finally
    Parents.Free;
    Found.Free;
  end;
end;

{ ── The edits ────────────────────────────────────────────────────────────── }

function Fail(const AMsg: string): TStmtEdit;
begin
  Result := Default(TStmtEdit);
  Result.Error := AMsg;
end;

function Range(SL, SC, EL, EC: Integer; const AText: string): TStmtEdit;
begin
  Result := Default(TStmtEdit);
  Result.Ok := True;
  Result.StartLine := SL;
  Result.StartCol := SC;
  Result.EndLine := EL;
  Result.EndCol := EC;
  Result.NewText := AText;
end;

function EditStatement(ALines: TStrings; ARoot: TStmtNode; ALine, ACol: Integer;
  const AOp, AWith, AText: string): TStmtEdit;
var
  N, P     : TStmtNode;
  Err, Op, W, Ind, Text, S, NodeText, Open, Body, Close, Rest, TR : string;
  I, EC, Q : Integer;
  HasSemi  : Boolean;
begin
  if not FindStatement(ARoot, ALine, ACol, N, P, Err) then Exit(Fail(Err));
  Op := LowerCase(Trim(AOp));
  W := LowerCase(Trim(AWith));
  Ind := IndentOf(LineAt(ALines, N.Line));
  Text := Prepare(AText);

  if Op = 'replace' then
  begin
    if Text = '' then Exit(Fail('replace needs text'));
    if Text[Length(Text)] = ';' then SetLength(Text, Length(Text) - 1);
    Exit(Range(N.Line, N.Col, N.EndLine, N.EndCol, IndentLines(Text, Ind, False)));
  end;

  if Op = 'delete' then
  begin
    if not IsListParent(P) then
      Exit(Fail('This statement is the only one of its ' + P.Kind +
        ': delete would leave it empty (and change what follows). Use replace.'));
    EC := N.EndCol;
    S := LineAt(ALines, N.EndLine);
    Q := EC;
    while (Q <= Length(S)) and (S[Q] in [' ', #9]) do Inc(Q);
    if (Q <= Length(S)) and (S[Q] = ';') then EC := Q + 1;
    if IsBlank(Copy(LineAt(ALines, N.Line), 1, N.Col - 1)) and IsBlank(Copy(S, EC, MaxInt)) then
    begin
      if N.EndLine < ALines.Count then
        Exit(Range(N.Line, 1, N.EndLine + 1, 1, ''))
      else
        Exit(Range(N.Line, 1, N.EndLine, Length(S) + 1, ''));
    end;
    while (EC <= Length(S)) and (S[EC] in [' ', #9]) do Inc(EC);
    Q := N.Col;
    if IsBlank(Copy(S, EC, MaxInt)) and (N.Line = N.EndLine) then
      while (Q > 1) and (S[Q - 1] in [' ', #9]) do Dec(Q);   { it was the last on its line }
    Exit(Range(N.Line, Q, N.EndLine, EC, ''));
  end;

  if (Op = 'insert_before') or (Op = 'insert_after') then
  begin
    if not IsListParent(P) then
      Exit(Fail('This statement is the only one of its ' + P.Kind + ': nothing to insert next to. Use wrap with begin, or replace.'));
    if Text = '' then Exit(Fail(Op + ' needs text'));
    Text := EnsureSemi(Text);
    if Op = 'insert_before' then
    begin
      if IsBlank(Copy(LineAt(ALines, N.Line), 1, N.Col - 1)) then
        Exit(Range(N.Line, 1, N.Line, 1, IndentLines(Text, Ind, True) + #10))
      else
        Exit(Range(N.Line, N.Col, N.Line, N.Col, IndentLines(Text, Ind, False) + ' '));
    end;
    { insert_after: the statement must be closed by a ; before something follows it }
    S := LineAt(ALines, N.EndLine);
    Q := N.EndCol;
    while (Q <= Length(S)) and (S[Q] in [' ', #9]) do Inc(Q);
    HasSemi := (Q <= Length(S)) and (S[Q] = ';');
    if HasSemi then Inc(Q) else Q := N.EndCol;
    Rest := Copy(S, Q, MaxInt);
    TR := TrimLeft(Rest);
    if (TR = '') or (Copy(TR, 1, 2) = '//') then
    begin
      Result := Range(N.EndLine, N.EndCol, N.EndLine, Length(S) + 1, '');
      Result.NewText := Copy(S, N.EndCol, MaxInt);
      if not HasSemi then Result.NewText := ';' + Result.NewText;
      Result.NewText := Result.NewText + #10 + IndentLines(Text, Ind, True);
      Exit;
    end;
    if HasSemi then
      Exit(Range(N.EndLine, Q, N.EndLine, Q, ' ' + IndentLines(Text, Ind, False)))
    else
      Exit(Range(N.EndLine, N.EndCol, N.EndLine, N.EndCol, '; ' + IndentLines(Text, Ind, False)));
  end;

  if Op = 'wrap' then
  begin
    if (N.Kind = 'of') or (N.Kind = 'on') or (N.Kind = 'else') then
      Exit(Fail('A case branch or a handler cannot be wrapped; wrap the statement inside it.'));
    if W = '' then Exit(Fail('wrap needs "with": begin, try_finally, try_except, if, while, for or with'));
    if (W <> 'begin') and (Text = '') then
      Exit(Fail('wrap with ' + W + ' needs text (the cleanup, the handler, the condition, the loop header or the expression)'));
    if W = 'if' then
      for I := 0 to P.Children.Count - 1 do
        if (TStmtNode(P.Children[I]).Role = 'else') and (P.Kind = 'if') and (N.Role = 'then') then
          Exit(Fail('Wrapping this in an if would take the else of the outer if. Wrap with begin first.'));
    NodeText := TextBetween(ALines, N.Line, N.Col, N.EndLine, N.EndCol);
    Body := IndentLines(NodeText, Step, False);
    Close := '';
    if W = 'begin' then
    begin
      Open := 'begin';
      Body := Body + ';';
      Close := #10 + Ind + 'end';
    end
    else if (W = 'try_finally') or (W = 'try_except') then
    begin
      Open := 'try';
      Body := Body + ';';
      if W = 'try_finally' then S := 'finally' else S := 'except';
      Close := #10 + Ind + S + #10 + IndentLines(Text, Ind + Step, True) + #10 + Ind + 'end';
    end
    else if W = 'if' then
      Open := 'if ' + Text + ' then'
    else if (W = 'while') or (W = 'for') or (W = 'with') then
      Open := W + ' ' + Text + ' do'
    else
      Exit(Fail('Unknown wrapper "' + AWith + '": begin, try_finally, try_except, if, while, for or with'));
    Exit(Range(N.Line, N.Col, N.EndLine, N.EndCol, Open + #10 + Ind + Step + Body + Close));
  end;

  Result := Fail('Unknown op "' + AOp + '": replace, delete, insert_before, insert_after or wrap');
end;

end.
