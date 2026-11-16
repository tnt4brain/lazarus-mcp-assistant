{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpStatements;

{ The statements of a routine body as a tree: kind, position, and for the structured ones
  (begin, if, for, while, with, repeat, try, case, on) the statements inside.

  CodeTools' tree ends at the `begin` block: it knows no statements.  This unit walks the
  tokens of the body with a tolerant recursive descent: it never raises, a malformed body gives
  a shorter tree.  It has NO scanner of its own, so it cannot disagree with CodeTools about
  comments, directives, conditional code or includes: the caller delivers the atoms CodeTools
  reads (McpToolsCodeTools, BodyStatements).  Pure RTL, no IDE; tested in tests/tstatements.pas
  with a token source of the test's own (ADR-008).

  Limit, said in the tool description: an `asm` block is one node. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, contnrs;

type
  TStmtNode = class
  public
    Kind        : string;      { begin if for while with repeat try_except try_finally case of
                                 else on asm assign call inherited raise exit break continue goto }
    Name        : string;      { call/assign: the leading name (Obj.Method); of: the labels; on: the handler }
    Role        : string;      { in an if: then, else; in a try: try, except, finally }
    Line, Col   : Integer;     { 1-based, of the first token }
    EndLine     : Integer;     { line of the last token }
    EndCol      : Integer;     { column after the last token on EndLine (the `;` is not part of it) }
    ElseLine    : Integer;     { if: the line of its `else`, else 0 }
    HandlerLine : Integer;     { try: the line of `except` or `finally` }
    Children    : TObjectList; { of TStmtNode, owned }
    constructor Create(const AKind: string; ALine, ACol: Integer);
    destructor Destroy; override;
  end;

  { One token of the body, as the caller's scanner delivers it. }
  TStmtToken = record
    Txt  : string;      { as written }
    Up   : string;      { upper case, to compare keywords }
    Kind : Byte;        { 0 identifier or keyword, 1 symbol, 2 literal (string, number) }
    Line : Integer;     { in the file }
    Col  : Integer;
    EndLine, EndCol : Integer;  { where the token ends: the column after its last character }
  end;
  TStmtTokens = array of TStmtToken;

{ The tokens of a routine body from its `begin` on (more is read up to its matching `end`;
  tokens after it are left alone).  The result is the `begin` block; its Children are the
  statements.  Never nil.  The unit has no scanner of its own: the plugin feeds it the atoms
  of CodeTools, so conditional compilation and includes are those of the compiler. }
function ParseStatementTokens(const AToks: TStmtTokens; ACount: Integer): TStmtNode;

implementation

{ ── Node ─────────────────────────────────────────────────────────────────── }

constructor TStmtNode.Create(const AKind: string; ALine, ACol: Integer);
begin
  inherited Create;
  Kind := AKind;
  Line := ALine;
  Col := ACol;
  EndLine := ALine;
  EndCol := ACol;
  Children := TObjectList.Create(True);
end;

destructor TStmtNode.Destroy;
begin
  Children.Free;
  inherited Destroy;
end;

{ ── The walk ─────────────────────────────────────────────────────────────── }

type
  TParser = class
  private
    FT        : TStmtTokens;
    FN, FP    : Integer;
    FLast     : Integer;     { line of the last token consumed }
    FLastCol  : Integer;     { and the column after it }
    FDepth    : Integer;
    function CurIs(const AKeyword: string): Boolean;
    function CurSym(const ASym: string): Boolean;
    function AtStop: Boolean;
    procedure Take;
    function SkipTo(const AKeyword: string): Boolean;
    function NameAt(AIndex: Integer): string;
    function ParseSimple(const AKind: string): TStmtNode;
    function ParseStatement: TStmtNode;
    procedure ParseList(AParent: TStmtNode; const ARole: string);
    procedure Finish(ANode: TStmtNode);
  public
    constructor Create(const AToks: TStmtTokens; ACount: Integer);
    function Run: TStmtNode;
  end;

constructor TParser.Create(const AToks: TStmtTokens; ACount: Integer);
begin
  inherited Create;
  FT := AToks;
  FN := ACount;
end;

function TParser.CurIs(const AKeyword: string): Boolean;
begin
  Result := (FP < FN) and (FT[FP].Kind = 0) and (FT[FP].Up = AKeyword);
end;

function TParser.CurSym(const ASym: string): Boolean;
begin
  Result := (FP < FN) and (FT[FP].Kind = 1) and (FT[FP].Txt = ASym);
end;

{ The words that end a statement list or a simple statement without being part of it. }
function TParser.AtStop: Boolean;
begin
  Result := (FP >= FN) or
    ((FT[FP].Kind = 0) and ((FT[FP].Up = 'END') or (FT[FP].Up = 'UNTIL') or
      (FT[FP].Up = 'EXCEPT') or (FT[FP].Up = 'FINALLY')));
end;

procedure TParser.Take;
begin
  if FP < FN then
  begin
    FLast := FT[FP].EndLine;
    FLastCol := FT[FP].EndCol;
    Inc(FP);
  end;
end;

procedure TParser.Finish(ANode: TStmtNode);
begin
  if (FLast > ANode.EndLine) or ((FLast = ANode.EndLine) and (FLastCol > ANode.EndCol)) then
  begin
    ANode.EndLine := FLast;
    ANode.EndCol := FLastCol;
  end;
end;

{ Reads on to AKeyword outside brackets and takes it; False when a `;` or the end comes first. }
function TParser.SkipTo(const AKeyword: string): Boolean;
var
  D : Integer;
begin
  Result := False;
  D := 0;
  while FP < FN do
  begin
    if (D = 0) and CurIs(AKeyword) then
    begin
      Take;
      Exit(True);
    end;
    if (FT[FP].Kind = 1) then
    begin
      if (FT[FP].Txt = '(') or (FT[FP].Txt = '[') then Inc(D)
      else if ((FT[FP].Txt = ')') or (FT[FP].Txt = ']')) and (D > 0) then Dec(D)
      else if (D = 0) and (FT[FP].Txt = ';') then Exit;
    end;
    Take;
  end;
end;

{ The dotted name that starts at AIndex: Obj.Method. }
function TParser.NameAt(AIndex: Integer): string;
begin
  Result := '';
  while (AIndex < FN) and (FT[AIndex].Kind = 0) do
  begin
    Result := Result + FT[AIndex].Txt;
    if (AIndex + 2 < FN) and (FT[AIndex + 1].Kind = 1) and (FT[AIndex + 1].Txt = '.') and
       (FT[AIndex + 2].Kind = 0) then
    begin
      Result := Result + '.';
      Inc(AIndex, 2);
    end
    else
      Break;
  end;
end;

{ An assignment or a call, and raise/exit/break/continue/goto/inherited: up to the `;` or the
  word that ends the list around it, neither taken. }
function TParser.ParseSimple(const AKind: string): TStmtNode;
var
  D : Integer;
  Assign : Boolean;
  First  : Boolean;
begin
  Result := TStmtNode.Create(AKind, FT[FP].Line, FT[FP].Col);
  if AKind = 'call' then Result.Name := NameAt(FP)
  else if AKind = 'inherited' then Result.Name := NameAt(FP + 1);
  D := 0;
  Assign := False;
  First := True;
  while FP < FN do
  begin
    if FT[FP].Kind = 1 then
    begin
      if (FT[FP].Txt = '(') or (FT[FP].Txt = '[') then Inc(D)
      else if ((FT[FP].Txt = ')') or (FT[FP].Txt = ']')) and (D > 0) then Dec(D)
      else if (D = 0) and (FT[FP].Txt = ';') then Break
      else if (D = 0) and (FT[FP].Txt = ':=') then Assign := True;
    end
    else if (D = 0) and (FT[FP].Kind = 0) and not First then
    begin
      if AtStop or (FT[FP].Up = 'ELSE') or (FT[FP].Up = 'BEGIN') or (FT[FP].Up = 'IF') or
         (FT[FP].Up = 'FOR') or (FT[FP].Up = 'WHILE') or (FT[FP].Up = 'REPEAT') or
         (FT[FP].Up = 'TRY') or (FT[FP].Up = 'CASE') then Break;
    end;
    Take;
    First := False;
  end;
  if (AKind = 'call') and Assign then
  begin
    Result.Kind := 'assign';
  end;
  Finish(Result);
end;

function TParser.ParseStatement: TStmtNode;
var
  Kw   : string;
  Node, Sub, Body : TStmtNode;
  D, From : Integer;
  Labels : string;
begin
  Result := nil;
  if (FP >= FN) or CurSym(';') then Exit;
  if FDepth > 150 then
    Exit(ParseSimple('call'));              { too deep: taken flat }
  Inc(FDepth);
  try
    Kw := '';
    if FT[FP].Kind = 0 then Kw := FT[FP].Up;

    { a handler of an except part: on E: Exception do ... }
    if (Kw = 'ON') and (FP + 2 < FN) and (FT[FP + 1].Kind = 0) and
       (((FT[FP + 2].Kind = 1) and ((FT[FP + 2].Txt = ':') or (FT[FP + 2].Txt = '.'))) or
        ((FT[FP + 2].Kind = 0) and (FT[FP + 2].Up = 'DO'))) then
    begin
      Node := TStmtNode.Create('on', FT[FP].Line, FT[FP].Col);
      Take;
      From := FP;
      if SkipTo('DO') then
      begin
        Labels := '';
        for D := From to FP - 2 do Labels := Labels + FT[D].Txt;
        Node.Name := Labels;
        Sub := ParseStatement();
        if Sub <> nil then Node.Children.Add(Sub);
      end;
      Finish(Node);
      Exit(Node);
    end;

    { a label:  Name: statement }
    if (FT[FP].Kind = 0) and (FP + 1 < FN) and (FT[FP + 1].Kind = 1) and (FT[FP + 1].Txt = ':') and
       (Kw <> 'ELSE') then
    begin
      Take; Take;
      Exit(ParseStatement());
    end;

    if Kw = 'BEGIN' then
    begin
      Node := TStmtNode.Create('begin', FT[FP].Line, FT[FP].Col);
      Take;
      ParseList(Node, '');
      if CurIs('END') then Take;
      Finish(Node);
      Exit(Node);
    end
    else if Kw = 'IF' then
    begin
      Node := TStmtNode.Create('if', FT[FP].Line, FT[FP].Col);
      Take;
      if SkipTo('THEN') then
      begin
        if not (AtStop or CurIs('ELSE')) then
        begin
          Sub := ParseStatement();
          if Sub <> nil then begin Sub.Role := 'then'; Node.Children.Add(Sub); end;
        end;
        if CurIs('ELSE') then
        begin
          Node.ElseLine := FT[FP].Line;
          Take;
          Sub := ParseStatement();
          if Sub <> nil then begin Sub.Role := 'else'; Node.Children.Add(Sub); end;
        end;
      end;
      Finish(Node);
      Exit(Node);
    end
    else if (Kw = 'FOR') or (Kw = 'WHILE') or (Kw = 'WITH') then
    begin
      Node := TStmtNode.Create(LowerCase(Kw), FT[FP].Line, FT[FP].Col);
      Take;
      if SkipTo('DO') then
      begin
        Sub := ParseStatement();
        if Sub <> nil then Node.Children.Add(Sub);
      end;
      Finish(Node);
      Exit(Node);
    end
    else if Kw = 'REPEAT' then
    begin
      Node := TStmtNode.Create('repeat', FT[FP].Line, FT[FP].Col);
      Take;
      ParseList(Node, '');
      if CurIs('UNTIL') then
      begin
        Take;
        if FP < FN then
          ParseSimple('call').Free;         { the condition, up to the ; }
      end;
      Finish(Node);
      Exit(Node);
    end
    else if Kw = 'TRY' then
    begin
      Node := TStmtNode.Create('try_finally', FT[FP].Line, FT[FP].Col);
      Take;
      ParseList(Node, 'try');
      if CurIs('EXCEPT') or CurIs('FINALLY') then
      begin
        if CurIs('EXCEPT') then Node.Kind := 'try_except';
        Node.HandlerLine := FT[FP].Line;
        Labels := LowerCase(FT[FP].Up);
        Take;
        ParseList(Node, Labels);
      end;
      if CurIs('END') then Take;
      Finish(Node);
      Exit(Node);
    end
    else if Kw = 'CASE' then
    begin
      Node := TStmtNode.Create('case', FT[FP].Line, FT[FP].Col);
      Take;
      if SkipTo('OF') then
        while FP < FN do
        begin
          while CurSym(';') do Take;
          if (FP >= FN) or CurIs('END') then Break;
          if CurIs('ELSE') then
          begin
            Sub := TStmtNode.Create('else', FT[FP].Line, FT[FP].Col);
            Take;
            ParseList(Sub, '');
            Finish(Sub);
            Node.Children.Add(Sub);
            Break;
          end;
          { labels up to the colon }
          Sub := TStmtNode.Create('of', FT[FP].Line, FT[FP].Col);
          Labels := '';
          D := 0;
          while FP < FN do
          begin
            if FT[FP].Kind = 1 then
            begin
              if (FT[FP].Txt = '(') or (FT[FP].Txt = '[') then Inc(D)
              else if ((FT[FP].Txt = ')') or (FT[FP].Txt = ']')) and (D > 0) then Dec(D)
              else if (D = 0) and (FT[FP].Txt = ':') then Break
              else if (D = 0) and (FT[FP].Txt = ';') then Break;
            end;
            if Length(Labels) < 60 then Labels := Labels + FT[FP].Txt;
            Take;
          end;
          Sub.Name := Labels;
          if CurSym(':') then
          begin
            Take;
            Body := ParseStatement();
            if Body <> nil then Sub.Children.Add(Body);
          end;
          Finish(Sub);
          Node.Children.Add(Sub);
        end;
      if CurIs('END') then Take;
      Finish(Node);
      Exit(Node);
    end
    else if Kw = 'ELSE' then
    begin
      { the else part of an except block }
      Node := TStmtNode.Create('else', FT[FP].Line, FT[FP].Col);
      Take;
      ParseList(Node, '');
      Finish(Node);
      Exit(Node);
    end
    else if Kw = 'ASM' then
    begin
      Node := TStmtNode.Create('asm', FT[FP].Line, FT[FP].Col);
      Take;
      while (FP < FN) and not CurIs('END') do Take;
      if CurIs('END') then Take;
      Finish(Node);
      Exit(Node);
    end
    else if (Kw = 'RAISE') or (Kw = 'EXIT') or (Kw = 'BREAK') or (Kw = 'CONTINUE') or
            (Kw = 'GOTO') or (Kw = 'INHERITED') then
      Exit(ParseSimple(LowerCase(Kw)))
    else
      Exit(ParseSimple('call'));
  finally
    Dec(FDepth);
  end;
end;

{ Statements until END, UNTIL, EXCEPT or FINALLY (none of them taken); ARole is put on each. }
procedure TParser.ParseList(AParent: TStmtNode; const ARole: string);
var
  S    : TStmtNode;
  Before : Integer;
begin
  while FP < FN do
  begin
    while CurSym(';') do Take;
    if AtStop then Break;
    Before := FP;
    S := ParseStatement();
    if S <> nil then
    begin
      S.Role := ARole;
      AParent.Children.Add(S);
    end;
    if FP = Before then Take;               { never stand still }
  end;
end;

function TParser.Run: TStmtNode;
var
  I : Integer;
begin
  I := 0;
  while (I < FN) and not ((FT[I].Kind = 0) and (FT[I].Up = 'BEGIN')) do Inc(I);
  if I >= FN then
    Exit(TStmtNode.Create('begin', 0, 0));
  Result := TStmtNode.Create('begin', FT[I].Line, FT[I].Col);
  FP := I + 1;
  FLast := FT[I].EndLine;
  FLastCol := FT[I].EndCol;
  ParseList(Result, '');
  if FN > 0 then
  begin
    Result.EndLine := FT[FN - 1].EndLine;
    Result.EndCol := FT[FN - 1].EndCol;
  end;
  if CurIs('END') then
  begin
    Result.EndLine := FT[FP].EndLine;
    Result.EndCol := FT[FP].EndCol;
  end;
end;

function ParseStatementTokens(const AToks: TStmtTokens; ACount: Integer): TStmtNode;
var
  P : TParser;
begin
  P := TParser.Create(AToks, ACount);
  try
    Result := P.Run;
  finally
    P.Free;
  end;
end;

end.
