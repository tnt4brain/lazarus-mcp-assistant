{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TToolSmoke;

{ TTestToolSmoke — one read-only call per tool group against the running IDE:
  editor, CodeTools, forms, git, project, debugger.  The code and form tools
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
    procedure TestFormListComponentsForwardSlashes;
    procedure TestPathSpellingsNameOneFile;
    procedure TestGitStatus;
    procedure TestProjectGetSettings;
    procedure TestProjectOpenAlreadyOpen;
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

procedure TTestToolSmoke.TestDebugGetState;
var
  T : string;
begin
  T := Call('debug_get_state', '{}');
  CheckNoError(Self, 'debug_get_state', T);
  CheckTrue(Pos('"state"', T) > 0, 'debugger state reported: ' + T);
end;

end.
