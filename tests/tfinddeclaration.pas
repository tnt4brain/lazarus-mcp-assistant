{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TFindDeclaration;

{ TTestFindDeclaration — code_find_declaration follows the uses clauses: a type from a
  sibling unit, one from the RTL, and from a program (.lpr).  Each test works on a
  few files in a temp folder of its own, deleted afterwards.
  Requires a running MCP server. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, THttpHelper;

type
  TTestFindDeclaration = class(TTestCase)
  private
    FDir : string;
    function Find(const AFile, ASymbol: string; const AExtra: string = ''): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestOwnInterface;
    procedure TestSiblingUnit;
    procedure TestRtlUnit;
    procedure TestProgram;
    procedure TestGivenPosition;
    procedure TestCommentsAndStringsSkipped;
    procedure TestNotUsedInFile;
    procedure TestReferencesOutsideProject;
    procedure TestAlsoSameFolder;
    procedure TestSearchDirAndLimit;
    procedure TestAlsoUnknownScope;
    procedure TestAddToClassIndent;
  end;

implementation

uses
  Classes, SysUtils, FileUtil, fpjson, jsonparser;

const
  HelperUnit =
    'unit helperu;' + LineEnding +
    '{$mode objfpc}{$H+}' + LineEnding +
    'interface' + LineEnding +
    'type' + LineEnding +
    '  THelper = class' + LineEnding +
    '  end;' + LineEnding +
    'function Shout(const S: string): string;' + LineEnding +
    'implementation' + LineEnding +
    'function Shout(const S: string): string;' + LineEnding +
    'begin' + LineEnding +
    '  Result := UpperCase(S);' + LineEnding +
    'end;' + LineEnding +
    'end.' + LineEnding;

  UserUnit =
    'unit user;' + LineEnding +                          { 1 }
    '{$mode objfpc}{$H+}' + LineEnding +                 { 2 }
    'interface' + LineEnding +                           { 3 }
    'uses Classes, helperu;' + LineEnding +              { 4 }
    'procedure Run;' + LineEnding +                      { 5 }
    'implementation' + LineEnding +                      { 6 }
    '// THelper in a comment, TList too' + LineEnding +  { 7 }
    'procedure Run;' + LineEnding +                      { 8 }
    'var' + LineEnding +                                 { 9 }
    '  L: TList;' + LineEnding +                         { 10 }
    '  H: THelper;' + LineEnding +                       { 11 }
    '  S: string;' + LineEnding +                        { 12 }
    'begin' + LineEnding +                               { 13 }
    '  S := ''THelper'' + Shout(''x'');' + LineEnding +  { 14 }
    'end;' + LineEnding +                                { 15 }
    'end.' + LineEnding;

  ProgramSrc =
    'program prog;' + LineEnding +
    '{$mode objfpc}{$H+}' + LineEnding +
    'uses helperu;' + LineEnding +
    'var H: THelper;' + LineEnding +
    'begin' + LineEnding +
    '  WriteLn(Shout(''hi''));' + LineEnding +
    'end.' + LineEnding;

function IsError(const T: string): Boolean;
begin
  Result := (Pos('TOOL ERROR', T) = 1) or (Pos('RPC ERROR', T) = 1) or (Pos('HTTP ', T) = 1);
end;

function JStr(const T, AName: string): string;
var
  D : TJSONData;
begin
  Result := '';
  if IsError(T) then Exit;
  D := GetJSON(T);
  try
    Result := TJSONObject(D).Get(AName, '');
  finally
    D.Free;
  end;
end;

procedure Save(const AFile, AText: string);
var
  SL : TStringList;
begin
  SL := TStringList.Create;
  try
    SL.Text := AText;
    SL.SaveToFile(AFile);
  finally
    SL.Free;
  end;
end;

procedure TTestFindDeclaration.SetUp;
begin
  { a folder per test: the IDE caches files by name }
  FDir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'mcpfinddecl' + PathDelim +
          TestName + PathDelim;
  ForceDirectories(FDir);
  Save(FDir + 'helperu.pas', HelperUnit);
  Save(FDir + 'user.pas', UserUnit);
  Save(FDir + 'prog.lpr', ProgramSrc);
end;

procedure TTestFindDeclaration.TearDown;
begin
  DeleteDirectory(FDir, False);
  RemoveDir(ExcludeTrailingPathDelimiter(ExtractFileDir(ExcludeTrailingPathDelimiter(FDir))));
end;

function TTestFindDeclaration.Find(const AFile, ASymbol: string; const AExtra: string): string;
begin
  Result := CallToolText('code_find_declaration', '{"file":' + JsonStr(FDir + AFile) +
    ',"symbol":' + JsonStr(ASymbol) + AExtra + '}', []);
end;

procedure TTestFindDeclaration.TestOwnInterface;
var
  T : string;
begin
  T := Find('helperu.pas', 'THelper');
  CheckFalse(IsError(T), T);
  CheckEquals('helperu.pas', ExtractFileName(JStr(T, 'declaration_file')), T);
end;

{ not in the file's own interface: found through its uses clause }
procedure TTestFindDeclaration.TestSiblingUnit;
var
  T : string;
begin
  T := Find('user.pas', 'THelper');
  CheckFalse(IsError(T), T);
  CheckEquals('helperu.pas', ExtractFileName(JStr(T, 'declaration_file')), T);
  CheckTrue(Pos('THelper', JStr(T, 'context')) > 0, T);
  T := Find('user.pas', 'Shout');
  CheckFalse(IsError(T), T);
  CheckEquals('helperu.pas', ExtractFileName(JStr(T, 'declaration_file')), T);
end;

procedure TTestFindDeclaration.TestRtlUnit;
var
  T : string;
begin
  T := Find('user.pas', 'TList');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('classes', LowerCase(JStr(T, 'declaration_file'))) > 0, T);
end;

{ a program has no interface section }
procedure TTestFindDeclaration.TestProgram;
var
  T : string;
begin
  T := Find('prog.lpr', 'Shout');
  CheckFalse(IsError(T), T);
  CheckEquals('helperu.pas', ExtractFileName(JStr(T, 'declaration_file')), T);
end;

procedure TTestFindDeclaration.TestGivenPosition;
var
  T : string;
begin
  { the THelper in 'H: THelper;' on line 11, column 6 }
  T := Find('user.pas', 'THelper', ',"line":11,"col":6');
  CheckFalse(IsError(T), T);
  CheckEquals('helperu.pas', ExtractFileName(JStr(T, 'declaration_file')), T);
end;

{ the only uses before line 10 are in a comment and in a string }
procedure TTestFindDeclaration.TestCommentsAndStringsSkipped;
var
  T : string;
begin
  T := Find('user.pas', 'THelper');
  CheckFalse(IsError(T), T);
  CheckEquals('helperu.pas', ExtractFileName(JStr(T, 'declaration_file')), T);
end;

procedure TTestFindDeclaration.TestNotUsedInFile;
var
  T : string;
begin
  T := Find('user.pas', 'NoSuchThing');
  CheckTrue(IsError(T), T);
  CheckTrue(Pos('not used in this file', T) > 0, T);
end;

{ code_find_references on a file that is not in the project searches that file too }
procedure TTestFindDeclaration.TestReferencesOutsideProject;
var
  T : string;
  D : TJSONData;
begin
  { Shout, declared on line 7 of helperu.pas, used by its own implementation }
  T := CallToolText('code_find_references', '{"file":' + JsonStr(FDir + 'helperu.pas') +
    ',"line":7,"col":10}', []);
  CheckFalse(IsError(T), T);
  D := GetJSON(T);
  try
    CheckTrue(TJSONArray(D).Count >= 2, 'declaration and implementation: ' + T);
  finally
    D.Free;
  end;
end;

function FilesOf(const T: string): string;
var
  D : TJSONData;
  A : TJSONArray;
  I : Integer;
begin
  Result := '';
  D := GetJSON(T);
  try
    if D is TJSONObject then A := TJSONObject(D).Arrays['references'] else A := TJSONArray(D);
    for I := 0 to A.Count - 1 do
      Result := Result + '|' + ExtractFileName(TJSONObject(A[I]).Get('file', ''));
  finally
    D.Free;
  end;
end;

{ THelper is declared on line 5 of helperu.pas and used in user.pas and prog.lpr }
procedure TTestFindDeclaration.TestAlsoSameFolder;
var
  T, Base : string;
begin
  Base := '{"file":' + JsonStr(FDir + 'helperu.pas') + ',"line":5,"col":3';
  T := CallToolText('code_find_references', Base + '}', []);
  CheckFalse(IsError(T), T);
  CheckEquals(0, Pos('user.pas', FilesOf(T)), 'the project does not have it: ' + T);
  T := CallToolText('code_find_references', Base + ',"also":["same_folder"]}', []);
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('user.pas', FilesOf(T)) > 0, 'user.pas: ' + T);
  CheckTrue(Pos('prog.lpr', FilesOf(T)) > 0, 'prog.lpr: ' + T);
  CheckTrue(Pos('"extra_files_searched" : 2', T) > 0, T);
end;

procedure TTestFindDeclaration.TestSearchDirAndLimit;
var
  T, Base, Dir : string;
begin
  Base := '{"file":' + JsonStr(FDir + 'helperu.pas') + ',"line":5,"col":3';
  Dir  := JsonStr(ExcludeTrailingPathDelimiter(FDir));
  T := CallToolText('code_find_references', Base + ',"search_dir":' + Dir + '}', []);
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('user.pas', FilesOf(T)) > 0, T);
  T := CallToolText('code_find_references',
    Base + ',"search_dir":' + Dir + ',"max_files":1}', []);
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"extra_files_searched" : 1', T) > 0, T);
  CheckTrue(Pos('"truncated"', T) > 0, 'more files than the limit: ' + T);
end;

procedure TTestFindDeclaration.TestAlsoUnknownScope;
var
  T : string;
begin
  T := CallToolText('code_find_references', '{"file":' + JsonStr(FDir + 'helperu.pas') +
    ',"line":5,"col":3,"also":["moon"]}', []);
  CheckTrue(IsError(T) and (Pos('Unknown "also" scope moon', T) > 0), T);
end;
{ code_add_to_class indents the new member like the ones around it. }
procedure TTestFindDeclaration.TestAddToClassIndent;
var
  T, Src, Text : string;
  SL           : TStringList;
begin
  Src := FDir + 'cls.pas';
  Save(Src,
    'unit cls;' + LineEnding +
    '{$mode objfpc}{$H+}' + LineEnding +
    'interface' + LineEnding +
    'type' + LineEnding +
    '  TFoo = class' + LineEnding +
    '  private' + LineEnding +
    '    FA: Integer;' + LineEnding +
    '  public' + LineEnding +
    '    procedure Existing;' + LineEnding +
    '  end;' + LineEnding +
    'implementation' + LineEnding +
    'procedure TFoo.Existing;' + LineEnding +
    'begin' + LineEnding +
    'end;' + LineEnding +
    'end.' + LineEnding);
  try
    T := CallToolText('code_add_to_class', '{"file":' + JsonStr(Src) +
      ',"class_name":"TFoo","section":"public","text":"procedure Added;","auto_save":true}', []);
    CheckFalse(IsError(T), T);
    T := CallToolText('code_add_to_class', '{"file":' + JsonStr(Src) +
      ',"class_name":"TFoo","section":"private","text":"FB: string;\nFC: Integer;","auto_save":true}', []);
    CheckFalse(IsError(T), T);
    SL := TStringList.Create;
    try
      SL.LoadFromFile(Src);
      Text := StringReplace(SL.Text, #13#10, #10, [rfReplaceAll]);
    finally
      SL.Free;
    end;
    CheckTrue(Pos('    procedure Existing;'#10'    procedure Added;'#10, Text) > 0, 'public: ' + Text);
    CheckTrue(Pos('    FA: Integer;'#10'    FB: string;'#10'    FC: Integer;'#10, Text) > 0, 'private: ' + Text);
  finally
    CallToolText('editor_revert', '{"file":' + JsonStr(Src) + '}', []);
    CallToolText('editor_close', '{"file":' + JsonStr(Src) + '}', []);
  end;
end;


end.
