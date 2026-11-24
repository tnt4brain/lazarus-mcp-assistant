{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TStatements;

{ TTestStatements — McpStatements: the statements of a routine body as a tree (ADR-008).
  Pure RTL, no server needed. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, McpStatements;

type
  TTestStatements = class(TTestCase)
  published
    procedure TestEveryConstruct;
    procedure TestCommentsStringsDirectives;
    procedure TestElseIfChain;
    procedure TestFirstLineOffset;
    procedure TestNoBeginAndEmptyBody;
    procedure TestHeaderOnTheBeginLine;
    procedure TestSimpleKinds;
    procedure TestAsmIsOneNode;
    procedure TestTruncatedTextNeverFails;
    procedure TestDeepNestingNeverFails;
  end;

{ The statements of a text, tokenized by the test's own scanner (lines count from FirstLine). }
function ParseBodyStatements(const Text: string; FirstLine: Integer): TStmtNode;

implementation

uses
  SysUtils;

{ ── A token source of the test's own ──────────────────────────────────────── }

{ The plugin feeds the walker with the atoms of CodeTools (McpToolsCodeTools, BodyStatements);
  the walker has no scanner.  This one lets it be tested without the IDE: comments, strings and
  compiler directives are skipped, nothing is evaluated.  The live tests (tprocedures.pas) check
  the real source, including conditional code. }

function IsIdentStart(C: Char): Boolean;
begin
  Result := (C in ['A'..'Z', 'a'..'z', '_', '&']) or (C >= #128);
end;

function IsIdentChar(C: Char): Boolean;
begin
  Result := (C in ['A'..'Z', 'a'..'z', '0'..'9', '_']) or (C >= #128);
end;

procedure Tokenize(const S: string; FirstLine: Integer; out T: TStmtTokens; out N: Integer);
var
  I, L, Col, Len, StartLine, StartCol, StartI : Integer;
  C, D : Char;

  procedure Push(AKind: Byte; AStart, AEnd: Integer);
  begin
    if N = Length(T) then SetLength(T, N * 2 + 64);
    T[N].Txt  := Copy(S, AStart, AEnd - AStart);
    T[N].Up   := UpperCase(T[N].Txt);
    T[N].Kind := AKind;
    T[N].Line := StartLine;
    T[N].Col  := StartCol;
    T[N].EndLine := L;
    T[N].EndCol  := Col;
    Inc(N);
  end;

  procedure Adv;
  begin
    if S[I] = #10 then
    begin
      Inc(L);
      Col := 1;
    end
    else if S[I] <> #13 then
      Inc(Col);
    Inc(I);
  end;

begin
  N := 0;
  SetLength(T, 0);
  I := 1;
  L := FirstLine;
  Col := 1;
  Len := Length(S);
  while I <= Len do
  begin
    C := S[I];
    if I < Len then D := S[I + 1] else D := #0;
    if C <= ' ' then
      Adv
    else if C = '{' then
    begin
      while (I <= Len) and (S[I] <> '}') do Adv;
      if I <= Len then Adv;
    end
    else if (C = '(') and (D = '*') then
    begin
      Adv; Adv;
      while (I <= Len) and not ((S[I] = '*') and (I < Len) and (S[I + 1] = ')')) do Adv;
      if I <= Len then begin Adv; Adv; end;
    end
    else if (C = '/') and (D = '/') then
    begin
      while (I <= Len) and (S[I] <> #10) do Adv;
    end
    else if C = '''' then
    begin
      StartLine := L; StartCol := Col; StartI := I;
      Adv;
      while I <= Len do
      begin
        if S[I] = '''' then
        begin
          Adv;
          if (I <= Len) and (S[I] = '''') then Adv else Break;
        end
        else if S[I] = #10 then
          Break                           { an unterminated string ends at the line }
        else
          Adv;
      end;
      Push(2, StartI, I);
    end
    else if IsIdentStart(C) then
    begin
      StartLine := L; StartCol := Col; StartI := I;
      Adv;
      while (I <= Len) and IsIdentChar(S[I]) do Adv;
      Push(0, StartI, I);
    end
    else if (C in ['0'..'9']) or ((C in ['$', '%', '#']) and (D <> #0) and IsIdentChar(D)) then
    begin
      StartLine := L; StartCol := Col; StartI := I;
      Adv;
      while (I <= Len) and IsIdentChar(S[I]) do Adv;
      if (I < Len) and (S[I] = '.') and (S[I + 1] in ['0'..'9']) then
      begin
        Adv;
        while (I <= Len) and IsIdentChar(S[I]) do Adv;
      end;
      Push(2, StartI, I);
    end
    else
    begin
      StartLine := L; StartCol := Col; StartI := I;
      Adv;
      if (I <= Len) and
         (((C = ':') and (S[I] = '=')) or ((C = '.') and (S[I] = '.')) or
          ((C = '<') and (S[I] in ['>', '='])) or ((C = '>') and (S[I] in ['=', '<'])) or
          ((C in ['+', '-', '*', '/']) and (S[I] = '=')) or ((C = '*') and (S[I] = '*'))) then
        Adv;
      Push(1, StartI, I);
    end;
  end;
end;

function ParseBodyStatements(const Text: string; FirstLine: Integer): TStmtNode;
var
  T : TStmtTokens;
  N : Integer;
begin
  Tokenize(Text, FirstLine, T, N);
  Result := ParseStatementTokens(T, N);
end;

const
  Sample =
    'begin' + LineEnding +                                   {  1 }
    '  I := 1;' + LineEnding +                               {  2 }
    '  if I > 0 then' + LineEnding +                         {  3 }
    '    WriteLn(I)' + LineEnding +                          {  4 }
    '  else' + LineEnding +                                  {  5 }
    '    Inc(I);' + LineEnding +                             {  6 }
    '  for I := 0 to 9 do' + LineEnding +                    {  7 }
    '  begin' + LineEnding +                                 {  8 }
    '    Foo.Bar(I);' + LineEnding +                         {  9 }
    '  end;' + LineEnding +                                  { 10 }
    '  try' + LineEnding +                                   { 11 }
    '    DoIt;' + LineEnding +                               { 12 }
    '  except' + LineEnding +                                { 13 }
    '    on E: Exception do Log(E.Message);' + LineEnding +  { 14 }
    '  end;' + LineEnding +                                  { 15 }
    '  try' + LineEnding +                                   { 16 }
    '    Go;' + LineEnding +                                 { 17 }
    '  finally' + LineEnding +                               { 18 }
    '    Done;' + LineEnding +                               { 19 }
    '  end;' + LineEnding +                                  { 20 }
    '  case I of' + LineEnding +                             { 21 }
    '    1, 2: Inc(I);' + LineEnding +                       { 22 }
    '    3: begin Dec(I); end;' + LineEnding +               { 23 }
    '  else' + LineEnding +                                  { 24 }
    '    Halt;' + LineEnding +                               { 25 }
    '  end;' + LineEnding +                                  { 26 }
    '  repeat' + LineEnding +                                { 27 }
    '    Inc(I);' + LineEnding +                             { 28 }
    '  until I > 5;' + LineEnding +                          { 29 }
    '  while True do Break;' + LineEnding +                  { 30 }
    '  FreeAndNil(X);' + LineEnding +                        { 31 }
    'end;' + LineEnding;                                     { 32 }

{ kind[:name]@line[-endline][~else][^handler][/role], then the children in braces }
function Dump(N: TStmtNode): string;
var
  I : Integer;
begin
  Result := N.Kind;
  if N.Name <> '' then Result := Result + ':' + N.Name;
  Result := Result + '@' + IntToStr(N.Line);
  if N.EndLine > N.Line then Result := Result + '-' + IntToStr(N.EndLine);
  if N.ElseLine > 0 then Result := Result + '~' + IntToStr(N.ElseLine);
  if N.HandlerLine > 0 then Result := Result + '^' + IntToStr(N.HandlerLine);
  if N.Role <> '' then Result := Result + '/' + N.Role;
  if N.Children.Count > 0 then
  begin
    Result := Result + '{';
    for I := 0 to N.Children.Count - 1 do
    begin
      if I > 0 then Result := Result + ',';
      Result := Result + Dump(TStmtNode(N.Children[I]));
    end;
    Result := Result + '}';
  end;
end;

function DumpBody(const AText: string; AFirst: Integer = 1): string;
var
  N : TStmtNode;
begin
  N := ParseBodyStatements(AText, AFirst);
  try
    Result := Dump(N);
  finally
    N.Free;
  end;
end;

procedure TTestStatements.TestEveryConstruct;
begin
  CheckEquals(
    'begin@1-32{' +
    'assign:I@2,' +
    'if@3-6~5{call:WriteLn@4/then,call:Inc@6/else},' +
    'for@7-10{begin@8-10{call:Foo.Bar@9}},' +
    'try_except@11-15^13{call:DoIt@12/try,on:E:Exception@14/except{call:Log@14}},' +
    'try_finally@16-20^18{call:Go@17/try,call:Done@19/finally},' +
    'case@21-26{of:1,2@22{call:Inc@22},of:3@23{begin@23{call:Dec@23}},else@24-25{call:Halt@25}},' +
    'repeat@27-29{call:Inc@28},' +
    'while@30{break@30},' +
    'call:FreeAndNil@31}',
    DumpBody(Sample));
end;

{ A keyword in a string, a comment or a directive is not a statement. }
procedure TTestStatements.TestCommentsStringsDirectives;
begin
  CheckEquals('begin@1-5{assign:X@2,assign:Y@4}',
    DumpBody(
      'begin' + LineEnding +
      '  X := ''end; begin if'';' + LineEnding +
      '  { end } // end' + LineEnding +
      '  (* if x then *) Y := 2 {$IFDEF Z} + 1 {$ENDIF};' + LineEnding +
      'end;'));
end;

procedure TTestStatements.TestElseIfChain;
begin
  CheckEquals('begin@1{if@1~1{call:b@1/then,if@1~1/else{call:d@1/then,call:e@1/else}}}',
    DumpBody('begin if a then b else if c then d else e; end;'));
end;

procedure TTestStatements.TestFirstLineOffset;
begin
  CheckEquals('begin@101-102{call:A@101,call:B@102}',
    DumpBody('begin A;' + LineEnding + 'B; end;', 101));
end;

procedure TTestStatements.TestNoBeginAndEmptyBody;
var
  N : TStmtNode;
begin
  N := ParseBodyStatements('', 1);
  try
    CheckEquals(0, N.Children.Count, 'empty text');
  finally
    N.Free;
  end;
  N := ParseBodyStatements('var X: Integer;', 1);
  try
    CheckEquals(0, N.Children.Count, 'no begin');
  finally
    N.Free;
  end;
  CheckEquals('begin@1', DumpBody('begin end;'));
end;

{ The routine's own line holds the header: the body starts at its begin. }
procedure TTestStatements.TestHeaderOnTheBeginLine;
begin
  CheckEquals('begin@5{call:Helper@5}',
    DumpBody('procedure TWorker.Work; begin Helper; end;', 5));
end;

procedure TTestStatements.TestSimpleKinds;
begin
  CheckEquals(
    'begin@1-8{inherited:Create@2,raise@3,exit@4,continue@5,goto@6,call:A.B.C@7}',
    DumpBody(
      'begin' + LineEnding +
      '  inherited Create(AOwner);' + LineEnding +
      '  raise Exception.Create(''x'');' + LineEnding +
      '  exit;' + LineEnding +
      '  continue;' + LineEnding +
      '  goto Done;' + LineEnding +
      '  A.B.C(1, [2, 3], (4));' + LineEnding +
      'end;'));
  { a statement without a closing semicolon before end }
  CheckEquals('begin@1{call:X@1}', DumpBody('begin X end;'));
  { an empty then and an empty else }
  CheckEquals('begin@1{if@1~1{call:Z@1/else}}', DumpBody('begin if a then else Z; end;'));
  { a with and a label }
  CheckEquals('begin@1-2{with@1{call:Run@1},call:Y@2}',
    DumpBody('begin with Form do Run;' + LineEnding + 'Done: Y; end;'));
end;

procedure TTestStatements.TestAsmIsOneNode;
begin
  CheckEquals('begin@1-4{asm@2,call:X@3}',
    DumpBody(
      'begin' + LineEnding +
      '  asm mov eax, 1 end;' + LineEnding +
      '  X;' + LineEnding +
      'end;'));
end;

{ A body cut anywhere (a half-typed routine) gives a tree, never an exception, and the
  lines of a node stay inside its parent's. }
procedure CheckTree(ATest: TTestCase; N: TStmtNode; const AWhat: string);
var
  I : Integer;
  C : TStmtNode;
begin
  ATest.CheckTrue(N.EndLine >= N.Line, AWhat + ': end before start in ' + N.Kind);
  for I := 0 to N.Children.Count - 1 do
  begin
    C := TStmtNode(N.Children[I]);
    ATest.CheckTrue(C.Line >= N.Line, AWhat + ': child before parent, ' + C.Kind);
    ATest.CheckTrue(C.EndLine <= N.EndLine, AWhat + ': child after parent, ' + C.Kind);
    CheckTree(ATest, C, AWhat);
  end;
end;

procedure TTestStatements.TestTruncatedTextNeverFails;
var
  Len : Integer;
  N   : TStmtNode;
  T   : string;
begin
  Len := 1;
  while Len <= Length(Sample) do
  begin
    T := Copy(Sample, 1, Len);
    N := ParseBodyStatements(T, 1);
    try
      CheckTree(Self, N, 'cut at ' + IntToStr(Len));
    finally
      N.Free;
    end;
    Inc(Len, 3);
  end;
  { and with pieces removed from the middle }
  Len := 1;
  while Len < Length(Sample) - 40 do
  begin
    T := Copy(Sample, 1, Len) + Copy(Sample, Len + 37, MaxInt);
    N := ParseBodyStatements(T, 1);
    try
      CheckTree(Self, N, 'hole at ' + IntToStr(Len));
    finally
      N.Free;
    end;
    Inc(Len, 11);
  end;
end;

procedure TTestStatements.TestDeepNestingNeverFails;
var
  I : Integer;
  T : string;
  N : TStmtNode;
begin
  T := 'begin ';
  for I := 1 to 400 do T := T + 'if a then ';
  T := T + 'X; end;';
  N := ParseBodyStatements(T, 1);
  try
    CheckTrue(N.Children.Count >= 1, 'a tree came back');
  finally
    N.Free;
  end;
  T := 'begin ';
  for I := 1 to 400 do T := T + 'begin ';
  for I := 1 to 400 do T := T + 'end; ';
  N := ParseBodyStatements(T + 'end;', 1);
  N.Free;
end;

initialization
  RegisterTest(TTestStatements);
end.
