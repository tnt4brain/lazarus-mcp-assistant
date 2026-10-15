{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TToolSmoke;

{ TTestToolSmoke — one read-only call per tool group against the running IDE:
  editor, CodeTools, forms, git, project, packages, debugger.  The code and form tools
  read tests/fixtures/fixtureform.pas (never modified); form_list_components
  opens it in the designer, and the test closes it again.
  Requires a running MCP server. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, THttpHelper;

type
  TTestToolSmoke = class(TTestCase)
  published
    procedure TestEditorListOpen;
    procedure TestCodeGetOutline;
    procedure TestCodeGetUnitInterface;
    procedure TestCodeNewFileInKnownFolder;
    procedure TestProjectCreateRefusesUnsavedEditor;
    procedure TestFormListComponentsForwardSlashes;
    procedure TestPathSpellingsNameOneFile;
    procedure TestGitStatus;
    procedure TestGitBlameActiveEditor;
    procedure TestEditorReplaceRange;
    procedure TestEditorFileDeletedAndCreatedAgain;
    procedure TestProjectGetSettings;
    procedure TestProjectOpenAlreadyOpen;
    procedure TestPackageGetInfo;
    procedure TestPackageFindUnit;
    procedure TestProjectListPackages;
    procedure TestDebugGetState;
  end;

implementation

uses
  Classes, SysUtils, fpjson, jsonparser;

function TestsDir: string;
begin
  Result := ExtractFilePath(ExpandFileName(ParamStr(0)));
end;

function FixtureUnit: string;
begin
  Result := TestsDir + 'fixtures' + PathDelim + 'fixtureform.pas';
end;

function Call(const ATool, AArgs: string): string;
begin
  Result := CallToolText(ATool, AArgs, []);
end;

procedure CheckNoError(ACase: TTestCase; const ATool, AText: string);
begin
  ACase.CheckFalse((Pos('TOOL ERROR', AText) = 1) or (Pos('RPC ERROR', AText) = 1) or
    (Pos('HTTP ', AText) = 1), ATool + ' failed: ' + AText);
end;

procedure TTestToolSmoke.TestEditorListOpen;
var
  T : string;
  D : TJSONData;
begin
  T := Call('editor_list_open', '{}');
  CheckNoError(Self, 'editor_list_open', T);
  D := GetJSON(T);
  try
    CheckTrue(D is TJSONArray, 'editor_list_open returns an array: ' + T);
  finally
    D.Free;
  end;
end;

procedure TTestToolSmoke.TestCodeGetOutline;
var
  T : string;
begin
  T := Call('code_get_outline', '{"file":' + JsonStr(FixtureUnit) + '}');
  CheckNoError(Self, 'code_get_outline', T);
  CheckTrue(Pos('"TFixtureForm"', T) > 0, 'outline lists the class: ' + T);
  CheckTrue(Pos('"FixtureFormInst"', T) > 0, 'outline lists the variable: ' + T);
end;

procedure TTestToolSmoke.TestCodeGetUnitInterface;
var
  T : string;
begin
  T := Call('code_get_unit_interface', '{"file":' + JsonStr(FixtureUnit) + '}');
  CheckNoError(Self, 'code_get_unit_interface', T);
  CheckTrue(Pos('function Twice(AValue: Integer): Integer;', T) > 0,
    'interface section returned: ' + T);
  CheckEquals(0, Pos('Result := AValue * 2', T), 'implementation is left out');
end;

procedure TTestToolSmoke.TestCodeNewFileInKnownFolder;
{ Regression: a unit written into a folder the IDE had already looked at was
  "Could not load" for CodeTools, its file caches still saying it was not
  there. }
var
  Dir, First, Second, T : string;

  procedure WriteUnit(const AFile, AName: string);
  var
    SL : TStringList;
  begin
    SL := TStringList.Create;
    try
      SL.Text := 'unit ' + AName + ';' + LineEnding + 'interface' + LineEnding +
                 'procedure P' + AName + ';' + LineEnding + 'implementation' + LineEnding +
                 'procedure P' + AName + ';' + LineEnding + 'begin' + LineEnding +
                 'end;' + LineEnding + 'end.' + LineEnding;
      SL.SaveToFile(AFile);
    finally
      SL.Free;
    end;
  end;

begin
  Dir    := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'mcpnewfile' +
            IntToStr(GetTickCount64) + PathDelim;
  First  := Dir + 'mcpfirst.pas';
  Second := Dir + 'mcpsecond.pas';
  ForceDirectories(Dir);
  try
    WriteUnit(First, 'McpFirst');
    T := Call('code_get_outline', '{"file":' + JsonStr(First) + '}');
    CheckNoError(Self, 'code_get_outline', T);
    WriteUnit(Second, 'McpSecond');
    T := Call('code_get_outline', '{"file":' + JsonStr(Second) + '}');
    CheckNoError(Self, 'code_get_outline on the new file', T);
    CheckTrue(Pos('"name" : "PMcpSecond"', T) > 0, 'procedures by name: ' + T);
  finally
    DeleteFile(First);
    DeleteFile(Second);
    RemoveDir(Dir);
  end;
end;

procedure TTestToolSmoke.TestProjectCreateRefusesUnsavedEditor;
{ Regression: project_create closed the current project without the checks
  project_open makes, so the IDE asked "Save changes?" in a dialog and the
  call waited for it.  Never creates a project: it must refuse. }
var
  Dir, F, T, Before : string;
  SL : TStringList;
begin
  Dir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'mcpprojcreate' +
         IntToStr(GetTickCount64) + PathDelim;
  F   := Dir + 'mcpunsaved.pas';
  ForceDirectories(Dir);
  SL := TStringList.Create;
  try
    SL.Text := 'unit McpUnsaved;' + LineEnding + 'interface' + LineEnding +
               'implementation' + LineEnding + 'end.' + LineEnding;
    SL.SaveToFile(F);
  finally
    SL.Free;
  end;
  Before := Call('project_get_settings', '{}');
  try
    T := Call('editor_open', '{"file_path":' + JsonStr(F) + '}');
    CheckNoError(Self, 'editor_open', T);
    T := Call('editor_edit_text', '{"file":' + JsonStr(F) +
              ',"old_string":"interface","new_string":"interface\n// changed"}');
    CheckNoError(Self, 'editor_edit_text', T);
    T := Call('project_create', '{"project_dir":' + JsonStr(Dir + 'p') +
              ',"project_name":"mcpnever"}');
    CheckTrue(Pos('TOOL ERROR', T) = 1, 'refused: ' + T);
    CheckTrue((Pos('Unsaved changes', T) > 0) or (Pos('unsaved changes', T) > 0) or
              (Pos('busy', T) > 0), 'says why: ' + T);
    CheckEquals(Before, Call('project_get_settings', '{}'), 'project unchanged');
  finally
    Call('editor_revert', '{"file":' + JsonStr(F) + '}');
    Call('editor_close', '{"file":' + JsonStr(F) + '}');
    DeleteFile(F);
    RemoveDir(Dir);
  end;
end;

procedure TTestToolSmoke.TestFormListComponentsForwardSlashes;
{ Regression: with D:/... paths the open editor (D:\...) wasn't recognised
  and every form_* tool failed with "Could not open the form unit". }
var
  Fx : string;
  T  : string;
begin
  Fx := StringReplace(FixtureUnit, '\', '/', [rfReplaceAll]);
  try
    T := Call('form_list_components', '{"form_file":' + JsonStr(Fx) + '}');
    CheckNoError(Self, 'form_list_components', T);
    CheckTrue(Pos('"btnOK"', T) > 0, 'the fixture''s button is listed: ' + T);
    CheckTrue(Pos('"TButton"', T) > 0, 'with its class: ' + T);
  finally
    Call('editor_close', '{"file":' + JsonStr(FixtureUnit) + '}');
  end;
end;

procedure TTestToolSmoke.TestPathSpellingsNameOneFile;
{ The server normalises path arguments: opened with forward slashes, found
  again through a '..' detour, closed with the native spelling. }
var
  Slashes, Detour, T : string;
begin
  Slashes := StringReplace(FixtureUnit, '\', '/', [rfReplaceAll]);
  Detour  := StringReplace(TestsDir + 'fixtures/../fixtures/fixtureform.pas',
                           '\', '/', [rfReplaceAll]);
  try
    T := Call('editor_open', '{"file_path":' + JsonStr(Slashes) + '}');
    CheckNoError(Self, 'editor_open', T);
    T := Call('editor_open', '{"file_path":' + JsonStr(Detour) + '}');
    CheckTrue(Pos('"already_open" : true', T) > 0, 'same file through ..: ' + T);
    T := Call('editor_list_open', '{}');
    CheckTrue(Pos(JsonStr(FixtureUnit), T) > 0, 'listed with the native path: ' + T);
  finally
    T := Call('editor_close', '{"file":' + JsonStr(FixtureUnit) + '}');
  end;
  CheckTrue(Pos('"closed" : true', T) > 0, 'closed by its native path: ' + T);
end;

procedure TTestToolSmoke.TestGitStatus;
var
  Repo : string;
  T    : string;
begin
  Repo := ExpandFileName(TestsDir + '..');
  if not DirectoryExists(IncludeTrailingPathDelimiter(Repo) + '.git') then
    Ignore('not a git checkout: ' + Repo);
  T := Call('git_status', '{"work_dir":' + JsonStr(Repo) + '}');
  if Pos('TOOL ERROR', T) = 1 then
    Ignore('git not usable here: ' + T);
  CheckTrue(Pos('"output"', T) > 0, 'git_status returns its output: ' + T);
end;

procedure TTestToolSmoke.TestGitBlameActiveEditor;
{ Blame defaults to the active editor's cursor line; an unsaved line is
  "uncommitted" and the committed line below it keeps its commit (the buffer
  is written with the file's own line endings). The fixture is reverted. }
var
  T : string;
begin
  if not DirectoryExists(ExpandFileName(TestsDir + '..') + PathDelim + '.git') then
    Ignore('not a git checkout');
  try
    T := Call('editor_open', '{"file_path":' + JsonStr(FixtureUnit) + '}');
    CheckNoError(Self, 'editor_open', T);
    Call('editor_set_cursor', '{"line":1,"col":1}');
    T := Call('git_blame', '{}');
    if Pos('TOOL ERROR', T) = 1 then
      Ignore('git not usable here: ' + T);
    CheckTrue(Pos('"line" : 1, "commit" : "', T) > 0, 'cursor line blamed: ' + T);
    CheckEquals(0, Pos('uncommitted', T), 'saved fixture is committed: ' + T);
    Call('editor_replace_range',
      '{"start_line":1,"start_col":1,"new_text":"// scratch\n"}');
    T := Call('git_blame', '{"start_line":1,"end_line":2}');
    CheckTrue(Pos('"editor_modified" : true', T) > 0, 'buffer blamed: ' + T);
    CheckTrue(Pos('"line" : 1, "commit" : "uncommitted"', T) > 0, 'new line: ' + T);
    CheckEquals(0, Pos('"line" : 2, "commit" : "uncommitted"', T),
      'old line keeps its commit: ' + T);
    T := Call('git_diff', '{"active_file":true}');
    CheckTrue(Pos('"editor_modified" : true', T) > 0, 'diff warns about unsaved edits: ' + T);
  finally
    Call('editor_revert', '{"file":' + JsonStr(FixtureUnit) + '}');
    Call('editor_close', '{"file":' + JsonStr(FixtureUnit) + '}');
  end;
end;

{ editor_replace_range: the end as a position, as a length (the old
  editor_edit_at_position), or neither for an insert. }
procedure TTestToolSmoke.TestEditorReplaceRange;
var
  F, T : string;
  SL   : TStringList;
  J    : TJSONData;

  function Buffer: string;
  begin
    J := GetJSON(Call('editor_read_file', '{"file":' + JsonStr(F) + '}'));
    try
      Result := AdjustLineBreaks(TJSONObject(J).Get('content', ''), tlbsLF);
    finally
      J.Free;
    end;
  end;

begin
  F  := GetTempDir(False) + 'mcpreplacerange.pas';
  SL := TStringList.Create;
  try
    SL.Text := 'abc' + LineEnding + 'def' + LineEnding + 'ghi';
    SL.SaveToFile(F);
  finally
    SL.Free;
  end;
  try
    { "bc", the line break and "de" }
    T := Call('editor_replace_range', '{"file":' + JsonStr(F) +
      ',"start_line":1,"start_col":2,"delete_len":5,"new_text":"X"}');
    CheckNoError(Self, 'editor_replace_range', T);
    CheckEquals('aXf'#10'ghi'#10, Buffer, 'delete_len');
    T := Call('editor_replace_range', '{"file":' + JsonStr(F) +
      ',"start_line":2,"start_col":1,"end_line":2,"end_col":4,"new_text":"Y"}');
    CheckNoError(Self, 'editor_replace_range', T);
    CheckEquals('aXf'#10'Y'#10, Buffer, 'end_line/end_col');
    T := Call('editor_replace_range', '{"file":' + JsonStr(F) +
      ',"start_line":1,"start_col":1,"new_text":"Z"}');
    CheckNoError(Self, 'editor_replace_range', T);
    CheckEquals('ZaXf'#10'Y'#10, Buffer, 'insert');
    T := Call('editor_replace_range', '{"file":' + JsonStr(F) +
      ',"start_line":1,"start_col":1,"end_line":1,"end_col":2,"delete_len":1,"new_text":""}');
    CheckTrue(Pos('not both', T) > 0, 'both ends refused: ' + T);
    CheckEquals('ZaXf'#10'Y'#10, Buffer, 'unchanged after the refusal');
  finally
    Call('editor_revert', '{"file":' + JsonStr(F) + '}');
    Call('editor_close', '{"file":' + JsonStr(F) + '}');
    DeleteFile(F);
  end;
end;

{ A file the IDE saw missing and the shell created again (the rerun of
  TestEditorReplaceRange): the IDE's file cache still said missing, and
  opening it showed the modal "File not found".  A missing file is an error
  of the tool, without the dialog. }
procedure TTestToolSmoke.TestEditorFileDeletedAndCreatedAgain;
var
  F, T : string;
  SL   : TStringList;

  procedure Write;
  begin
    SL := TStringList.Create;
    try
      SL.Text := 'unit mcprecreated;' + LineEnding + 'interface' + LineEnding +
                 'implementation' + LineEnding + 'end.';
      SL.SaveToFile(F);
    finally
      SL.Free;
    end;
  end;

begin
  F := GetTempDir(False) + 'mcprecreated.pas';
  Write;
  try
    CheckNoError(Self, 'editor_open', Call('editor_open', '{"file":' + JsonStr(F) + '}'));
    Call('editor_close', '{"file":' + JsonStr(F) + '}');
    DeleteFile(F);
    Call('code_get_outline', '{"file":' + JsonStr(F) + '}');   { the IDE looks for it }
    T := Call('editor_replace_range', '{"file":' + JsonStr(F) +
      ',"start_line":1,"start_col":1,"new_text":"// x\n"}');
    CheckTrue(Pos('File not found', T) > 0, 'missing: ' + T);
    T := Call('editor_open', '{"file":' + JsonStr(F) + '}');
    CheckTrue(Pos('File not found', T) > 0, 'editor_open, missing: ' + T);
    Write;
    T := Call('editor_replace_range', '{"file":' + JsonStr(F) +
      ',"start_line":1,"start_col":1,"new_text":"// x\n"}');
    CheckNoError(Self, 'editor_replace_range on the new file', T);
  finally
    Call('editor_revert', '{"file":' + JsonStr(F) + '}');
    Call('editor_close', '{"file":' + JsonStr(F) + '}');
    DeleteFile(F);
  end;
end;

procedure TTestToolSmoke.TestProjectGetSettings;
var
  T : string;
begin
  T := Call('project_get_settings', '{}');
  if (Pos('TOOL ERROR', T) = 1) and (Pos('project', LowerCase(T)) > 0) then
    Ignore('no project open: ' + T);
  CheckNoError(Self, 'project_get_settings', T);
  CheckTrue(Pos('"project_file"', T) > 0, 'settings name the project: ' + T);
end;

procedure TTestToolSmoke.TestProjectOpenAlreadyOpen;
{ Opening the active project again changes nothing and says so. }
var
  T, Prj : string;
  D      : TJSONData;
begin
  T := Call('project_get_settings', '{}');
  if Pos('TOOL ERROR', T) = 1 then
    Ignore('no project open: ' + T);
  D := GetJSON(T);
  try
    Prj := TJSONObject(D).Get('project_file', '');
  finally
    D.Free;
  end;
  if Prj = '' then
    Ignore('the open project has no file yet');
  T := Call('project_open', '{"file_path":' + JsonStr(Prj) + '}');
  CheckNoError(Self, 'project_open', T);
  D := GetJSON(T);
  try
    CheckTrue(TJSONObject(D).Get('already_open', False), 'already_open: ' + T);
    CheckTrue(SameFileName(Prj, TJSONObject(D).Get('project_file', '')), T);
  finally
    D.Free;
  end;
end;

procedure TTestToolSmoke.TestPackageGetInfo;
{ The plugin's own package: resolved requirements, its files, and the IDE as user. }
var
  T : string;
begin
  T := Call('package_get_info', '{"package_name":"LazMcpAssistant","files":true}');
  CheckNoError(Self, 'package_get_info', T);
  CheckTrue(Pos('"name" : "IDEIntf", "status" : "ok"', T) > 0, 'IDEIntf resolved: ' + T);
  CheckTrue(Pos('"unit" : "McpToolsPackages"', T) > 0, 'files listed: ' + T);
  CheckTrue(Pos('"required_by" : ["IDE"]', T) > 0, 'installed in the IDE: ' + T);
end;

procedure TTestToolSmoke.TestPackageFindUnit;
var
  T : string;
begin
  T := Call('package_find_unit', '{"unit_name":"synedit"}');
  CheckNoError(Self, 'package_find_unit', T);
  CheckTrue(Pos('"package" : "SynEdit"', T) > 0, 'SynEdit unit is in package SynEdit: ' + T);
  T := Call('package_find_unit', '{"unit_name":"NoSuchUnitXyz"}');
  CheckTrue(Pos('"packages" : []', T) > 0, 'unknown unit: no packages: ' + T);
end;

procedure TTestToolSmoke.TestProjectListPackages;
var
  T : string;
begin
  T := Call('project_list_packages', '{"recursive":true}');
  if (Pos('TOOL ERROR', T) = 1) and (Pos('project', LowerCase(T)) > 0) then
    Ignore('no project open: ' + T);
  CheckNoError(Self, 'project_list_packages', T);
  CheckTrue(Pos('"requires"', T) > 0, 'direct requirements: ' + T);
  CheckTrue(Pos('"compile_order"', T) > 0, 'recursive graph: ' + T);
end;

procedure TTestToolSmoke.TestDebugGetState;
var
  T : string;
begin
  T := Call('debug_get_state', '{}');
  CheckNoError(Self, 'debug_get_state', T);
  CheckTrue(Pos('"state"', T) > 0, 'debugger state reported: ' + T);
end;

end.
