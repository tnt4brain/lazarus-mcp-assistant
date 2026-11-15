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
  CheckTrue(Pos('"line" : 23', T) > 0, 'first overload: ' + T);
  CheckTrue(Pos('"line" : 27', T) > 0, 'second overload: ' + T);
  CheckTrue(Pos('Put(A: Integer)', T) > 0, 'its header: ' + T);
  CheckTrue(Pos('Halt', DiskText) = 0, 'the file is untouched');
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
  CheckTrue(Pos('"begin_line" : 28', T) > 0, 'the second overload: ' + T);
  T := Call('code_get_procedure_ast', '{"file":' + JsonStr(FUnit) + ',"proc_name":"Solo"}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"begin_line" : 32', T) > 0, T);
end;

initialization
  RegisterTest(TTestProcedures);
end.
