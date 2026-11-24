{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TProcedures;

{ TTestProcedures — code_insert_in_procedure, code_replace_procedure_body and
  code_get_procedure_ast on a unit with overloaded routines and a method name that two classes
  share: an ambiguous name is refused with the candidates, never resolved to the first match
  (ADR-008).  Requires a running MCP server. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, THttpHelper;

type
  TTestProcedures = class(TTestCase)
  private
    FDir  : string;
    FUnit : string;
    function Call(const ATool, AArgs: string): string;
    function DiskText: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestOverloadRefused;
    procedure TestOverloadPickedByLine;
    procedure TestInsertPickedByLine;
    procedure TestSameMethodInTwoClassesRefused;
    procedure TestClassNamePicksTheMethod;
    procedure TestUniqueNameStillWorks;
    procedure TestNotFoundIsNotAmbiguous;
    procedure TestAstRefusedAndPicked;
    procedure TestAstStatementsAndLocalTypes;
    procedure TestConditionalCodeIsTheCompilers;
    procedure TestEditStatement;
  end;

implementation

uses
  Classes, SysUtils, FileUtil;

const
  Src =
    'unit ovlu;' + LineEnding +                                  {  1 }
    '{$mode objfpc}{$H+}' + LineEnding +                         {  2 }
    'interface' + LineEnding +                                   {  3 }
    'type' + LineEnding +                                        {  4 }
    '  TA = class' + LineEnding +                                {  5 }
    '    procedure Run;' + LineEnding +                          {  6 }
    '  end;' + LineEnding +                                      {  7 }
    '  TB = class' + LineEnding +                                {  8 }
    '    procedure Run;' + LineEnding +                          {  9 }
    '  end;' + LineEnding +                                      { 10 }
    'procedure Put(A: Integer); overload;' + LineEnding +        { 11 }
    'procedure Put(const S: string); overload;' + LineEnding +   { 12 }
    'procedure Solo;' + LineEnding +                             { 13 }
    'implementation' + LineEnding +                              { 14 }
    'procedure TA.Run;' + LineEnding +                           { 15 }
    'begin' + LineEnding +                                       { 16 }
    '  WriteLn(''a'');' + LineEnding +                           { 17 }
    'end;' + LineEnding +                                        { 18 }
    'procedure TB.Run;' + LineEnding +                           { 19 }
    'begin' + LineEnding +                                       { 20 }
    '  WriteLn(''b'');' + LineEnding +                           { 21 }
    'end;' + LineEnding +                                        { 22 }
    'procedure Put(A: Integer);' + LineEnding +                  { 23 }
    'begin' + LineEnding +                                       { 24 }
    '  WriteLn(A);' + LineEnding +                               { 25 }
    'end;' + LineEnding +                                        { 26 }
    'procedure Put(const S: string);' + LineEnding +             { 27 }
    'begin' + LineEnding +                                       { 28 }
    '  WriteLn(S);' + LineEnding +                               { 29 }
    'end;' + LineEnding +                                        { 30 }
    'procedure Solo;' + LineEnding +                             { 31 }
    'begin' + LineEnding +                                       { 32 }
    '  WriteLn(''solo'');' + LineEnding +                        { 33 }
    'end;' + LineEnding +                                        { 34 }
    'procedure Mix(N: Integer);' + LineEnding +                  { 35 }
    'var' + LineEnding +                                         { 36 }
    '  I, J: Integer;' + LineEnding +                            { 37 }
    '  S: string;' + LineEnding +                                { 38 }
    'begin' + LineEnding +                                       { 39 }
    '  for I := 1 to N do' + LineEnding +                        { 40 }
    '    if Odd(I) then' + LineEnding +                          { 41 }
    '      WriteLn(I)' + LineEnding +                            { 42 }
    '    else' + LineEnding +                                    { 43 }
    '      Inc(J);' + LineEnding +                               { 44 }
    '  try' + LineEnding +                                       { 45 }
    '    S := ''x'';' + LineEnding +                             { 46 }
    '  finally' + LineEnding +                                   { 47 }
    '    Write(S);' + LineEnding +                               { 48 }
    '  end;' + LineEnding +                                      { 49 }
    'end;' + LineEnding +                                        { 50 }
    'end.' + LineEnding;

function IsError(const T: string): Boolean;
begin
  Result := (Pos('TOOL ERROR', T) = 1) or (Pos('RPC ERROR', T) = 1) or (Pos('HTTP ', T) = 1);
end;

procedure TTestProcedures.SetUp;
var
  SL : TStringList;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'mcpprocs' + PathDelim +
          TestName + PathDelim;
  ForceDirectories(FDir);
  FUnit := FDir + 'ovlu.pas';
  SL := TStringList.Create;
  try
    SL.Text := Src;
    SL.SaveToFile(FUnit);
  finally
    SL.Free;
  end;
end;

procedure TTestProcedures.TearDown;
begin
  CallToolText('editor_close', '{"file":' + JsonStr(FUnit) + '}', []);
  DeleteDirectory(FDir, False);
  RemoveDir(ExcludeTrailingPathDelimiter(ExtractFileDir(ExcludeTrailingPathDelimiter(FDir))));
end;

function TTestProcedures.Call(const ATool, AArgs: string): string;
begin
  Result := CallToolText(ATool, AArgs, []);
end;

function TTestProcedures.DiskText: string;
var
  SL : TStringList;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(FUnit);
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

{ Two overloads: the tool says so, lists both with their lines, and changes nothing. }
procedure TTestProcedures.TestOverloadRefused;
var
  T : string;
begin
  T := Call('code_replace_procedure_body', '{"file":' + JsonStr(FUnit) +
    ',"proc_name":"Put","new_body":"  Halt;","auto_save":true}');
  CheckTrue(IsError(T), 'refused: ' + T);
  CheckTrue(Pos('Ambiguous', T) > 0, T);
  CheckTrue(Pos('"line":23', T) > 0, 'first overload: ' + T);
  CheckTrue(Pos('"line":27', T) > 0, 'second overload: ' + T);
  CheckTrue(Pos('Put(A: Integer)', T) > 0, 'its header: ' + T);
  CheckTrue(Pos('Halt', DiskText) = 0, 'the file is untouched');
end;

{ Code the compiler skips is not part of the tree, and the lines after it are still right. }
procedure TTestProcedures.TestConditionalCodeIsTheCompilers;
var
  SL : TStringList;
  T  : string;
begin
  SL := TStringList.Create;
  try
    SL.Add('unit ovlu;');
    SL.Add('{$mode objfpc}{$H+}');
    SL.Add('interface');
    SL.Add('implementation');
    SL.Add('{$IFDEF NOPE_NEVER_DEFINED}');
    SL.Add('procedure Hidden;');
    SL.Add('begin');
    SL.Add('  WriteLn(''hidden'');');
    SL.Add('end;');
    SL.Add('{$ENDIF}');
    SL.Add('procedure Shown;');
    SL.Add('begin');
    SL.Add('  WriteLn(1);');
    SL.Add('  {$IFDEF NOPE_NEVER_DEFINED}');
    SL.Add('  WriteLn(''skipped'');');
    SL.Add('  {$ENDIF}');
    SL.Add('  WriteLn(2);');
    SL.Add('end;');
    SL.Add('end.');
    SL.SaveToFile(FUnit);
  finally
    SL.Free;
  end;
  T := Call('code_get_procedure_ast', '{"file":' + JsonStr(FUnit) + ',"proc_name":"Shown"}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"begin_line":12', T) > 0, 'begin: ' + T);
  CheckTrue(Pos('"end_line":18', T) > 0, 'end: ' + T);
  CheckTrue(Pos('skipped', T) = 0, 'the skipped branch is not read: ' + T);
  CheckTrue(Pos('"line":13', T) > 0, 'first statement: ' + T);
  CheckTrue(Pos('"line":17', T) > 0, 'second statement, after the skipped code: ' + T);
end;

{ code_edit_statement: wrap, delete, insert and replace by the position the AST gave; the
  lines around stay as they were; a lone statement of an if is refused. }
procedure TTestProcedures.TestEditStatement;
var
  SL : TStringList;
  T, D : string;
begin
  SL := TStringList.Create;
  try
    SL.Add('unit ovlu;');
    SL.Add('{$mode objfpc}{$H+}');
    SL.Add('interface');
    SL.Add('implementation');
    SL.Add('procedure Work(X: Integer);');
    SL.Add('begin');
    SL.Add('  Prep; // first');
    SL.Add('  if X > 0 then');
    SL.Add('    Go');
    SL.Add('  else');
    SL.Add('    Stop;');
    SL.Add('  Last');
    SL.Add('end;');
    SL.Add('end.');
    SL.SaveToFile(FUnit);
  finally
    SL.Free;
  end;
  T := Call('code_get_procedure_ast', '{"file":' + JsonStr(FUnit) + ',"proc_name":"Work"}');
  CheckTrue(Pos('"line":12', T) > 0, 'the AST lists Last: ' + T);

  T := Call('code_edit_statement', '{"file":' + JsonStr(FUnit) +
    ',"line":12,"action":"wrap","with":"try_finally","text":"Cleanup;","auto_save":true}');
  CheckFalse(IsError(T), T);
  D := DiskText;
  CheckTrue(Pos('  try' + LineEnding + '    Last;' + LineEnding + '  finally' + LineEnding +
                '    Cleanup;' + LineEnding + '  end' + LineEnding + 'end;', D) > 0, 'wrapped: ' + D);
  CheckTrue(Pos('Prep; // first', D) > 0, 'the comment is still there');

  T := Call('code_edit_statement', '{"file":' + JsonStr(FUnit) +
    ',"line":9,"action":"delete","auto_save":true}');
  CheckTrue(IsError(T), 'the only statement of a branch: ' + T);
  CheckTrue(Pos('Go', DiskText) > 0, 'untouched after a refusal');

  T := Call('code_edit_statement', '{"file":' + JsonStr(FUnit) +
    ',"line":7,"action":"insert_after","text":"Mid(1)","auto_save":true}');
  CheckFalse(IsError(T), T);
  D := DiskText;
  CheckTrue(Pos('  Prep; // first' + LineEnding + '  Mid(1);' + LineEnding + '  if X > 0 then', D) > 0,
    'inserted after, the comment kept: ' + D);

  T := Call('code_edit_statement', '{"file":' + JsonStr(FUnit) +
    ',"line":7,"action":"delete","auto_save":true}');
  CheckFalse(IsError(T), T);
  D := DiskText;
  CheckTrue(Pos('Prep', D) = 0, 'deleted');
  CheckTrue(Pos('begin' + LineEnding + '  // first' + LineEnding + '  Mid(1);', D) > 0,
    'its comment stays: ' + D);

  T := Call('code_edit_statement', '{"file":' + JsonStr(FUnit) +
    ',"line":10,"action":"replace","text":"Go(1, 2)","auto_save":true}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('    Go(1, 2)' + LineEnding + '  else', DiskText) > 0, 'replaced in its branch');

  T := Call('code_edit_statement', '{"file":' + JsonStr(FUnit) + ',"line":99,"action":"delete"}');
  CheckTrue(IsError(T), 'no routine there: ' + T);
end;

procedure TTestProcedures.TestOverloadPickedByLine;
var
  T, D : string;
begin
  T := Call('code_replace_procedure_body', '{"file":' + JsonStr(FUnit) +
    ',"proc_name":"Put","line":27,"new_body":"  WriteLn(''changed'');","auto_save":true}');
  CheckFalse(IsError(T), T);
  D := DiskText;
  CheckTrue(Pos('WriteLn(''changed'')', D) > 0, 'the second overload changed');
  CheckTrue(Pos('WriteLn(A);', D) > 0, 'the first one did not');
  CheckTrue(Pos('WriteLn(S);', D) = 0, 'the old body of the second is gone');
end;

procedure TTestProcedures.TestInsertPickedByLine;
var
  T, D   : string;
  P1, P2 : Integer;
begin
  T := Call('code_insert_in_procedure', '{"file":' + JsonStr(FUnit) +
    ',"proc_name":"Put","line":23,"text":"  WriteLn(''first'');","auto_save":true}');
  CheckFalse(IsError(T), T);
  D := DiskText;
  P1 := Pos('WriteLn(''first'')', D);
  P2 := Pos('procedure Put(const S: string);' + LineEnding + 'begin', D);
  CheckTrue(P1 > 0, 'inserted');
  CheckTrue(P1 < P2, 'into the first overload, before the second begins');
end;

procedure TTestProcedures.TestSameMethodInTwoClassesRefused;
var
  T : string;
begin
  T := Call('code_insert_in_procedure', '{"file":' + JsonStr(FUnit) +
    ',"proc_name":"Run","text":"  Halt;","auto_save":true}');
  CheckTrue(IsError(T), 'refused: ' + T);
  CheckTrue(Pos('Ambiguous', T) > 0, T);
  CheckTrue(Pos('TA.Run', T) > 0, 'lists TA.Run: ' + T);
  CheckTrue(Pos('TB.Run', T) > 0, 'lists TB.Run: ' + T);
  CheckTrue(Pos('Halt', DiskText) = 0, 'the file is untouched');
end;

procedure TTestProcedures.TestClassNamePicksTheMethod;
var
  T, D : string;
begin
  T := Call('code_replace_procedure_body', '{"file":' + JsonStr(FUnit) +
    ',"proc_name":"Run","class_name":"TB","new_body":"  WriteLn(''B2'');","auto_save":true}');
  CheckFalse(IsError(T), T);
  D := DiskText;
  CheckTrue(Pos('WriteLn(''B2'')', D) > 0, 'TB.Run changed');
  CheckTrue(Pos('WriteLn(''a'')', D) > 0, 'TA.Run did not');
  CheckTrue(Pos('WriteLn(''b'')', D) = 0, 'the old body of TB.Run is gone');
end;

procedure TTestProcedures.TestUniqueNameStillWorks;
var
  T : string;
begin
  T := Call('code_replace_procedure_body', '{"file":' + JsonStr(FUnit) +
    ',"proc_name":"Solo","new_body":"  WriteLn(''alone'');","auto_save":true}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('WriteLn(''alone'')', DiskText) > 0);
end;

procedure TTestProcedures.TestNotFoundIsNotAmbiguous;
var
  T : string;
begin
  T := Call('code_replace_procedure_body', '{"file":' + JsonStr(FUnit) +
    ',"proc_name":"Nope","new_body":"  Halt;"}');
  CheckTrue(IsError(T), T);
  CheckTrue(Pos('not found', T) > 0, T);
  CheckTrue(Pos('Ambiguous', T) = 0, T);
  { a line that is inside no overload of the name: not found, not a guess }
  T := Call('code_replace_procedure_body', '{"file":' + JsonStr(FUnit) +
    ',"proc_name":"Put","line":33,"new_body":"  Halt;"}');
  CheckTrue(IsError(T), T);
  CheckTrue(Pos('not found', T) > 0, T);
end;

procedure TTestProcedures.TestAstRefusedAndPicked;
var
  T : string;
begin
  T := Call('code_get_procedure_ast', '{"file":' + JsonStr(FUnit) + ',"proc_name":"Put"}');
  CheckTrue(IsError(T), T);
  CheckTrue(Pos('Ambiguous', T) > 0, T);
  T := Call('code_get_procedure_ast', '{"file":' + JsonStr(FUnit) +
    ',"proc_name":"Put","line":27}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"begin_line":28', T) > 0, 'the second overload: ' + T);
  T := Call('code_get_procedure_ast', '{"file":' + JsonStr(FUnit) + ',"proc_name":"Solo"}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"begin_line":32', T) > 0, T);
end;

{ The statements of a body (McpStatements): kind, lines, the else and handler lines; the
  levels below depth are counted, not listed; locals carry their type. }
procedure TTestProcedures.TestAstStatementsAndLocalTypes;
var
  T : string;
begin
  T := Call('code_get_procedure_ast', '{"file":' + JsonStr(FUnit) + ',"proc_name":"Mix"}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"name":"S","type":"string"', T) > 0, 'a local with its type: ' + T);
  CheckTrue(Pos('"type":"Integer"', T) > 0, 'Integer locals: ' + T);
  CheckTrue(Pos('{"kind":"for","line":40,"col":3,"end_line":44,"nested":1}', T) > 0,
    'the loop, its body only counted: ' + T);
  CheckTrue(Pos('{"kind":"try_finally","line":45,"col":3,"end_line":49,"handler_line":47,"nested":2}', T) > 0,
    'the try with its finally line: ' + T);
  { one more level: the if is listed, its branches are only counted }
  T := Call('code_get_procedure_ast', '{"file":' + JsonStr(FUnit) + ',"proc_name":"Mix","depth":2}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"kind":"if","line":41,"col":5,"end_line":44,"else_line":43,"nested":2', T) > 0,
    'the if with its else line: ' + T);
  CheckTrue(Pos('"name":"Inc"', T) = 0, 'Inc is below the listed levels: ' + T);
  { and one more: the branches }
  T := Call('code_get_procedure_ast', '{"file":' + JsonStr(FUnit) + ',"proc_name":"Mix","depth":3}');
  CheckTrue(Pos('{"kind":"call","name":"Inc","line":44,"col":7,"role":"else"}', T) > 0,
    'the else branch of the if: ' + T);
  CheckTrue(Pos('{"kind":"call","name":"WriteLn","line":42,"col":7,"role":"then"}', T) > 0,
    'the then branch: ' + T);
end;

initialization
  RegisterTest(TTestProcedures);
end.
