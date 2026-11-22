{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TCreateFile;

{ TTestCreateFile — editor_create_file: a new file on the machine the IDE runs on, only inside the
  project, a package or the temp folder, never in .git, no overwrite unless asked.
  Requires a running MCP server. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, THttpHelper;

type
  TTestCreateFile = class(TTestCase)
  private
    FRoot : string;
    function Call(const AArgs: string): string;
    function Path(const ARel: string): string;
    function ReadAll(const AFile: string): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestCreatesInNewFolders;
    procedure TestEmptyFile;
    procedure TestExistingFileRefusedUnlessOverwrite;
    procedure TestOverwriteRefusedWhileOpen;
    procedure TestOutsideTheAllowedFoldersRefused;
    procedure TestDotDotCannotEscape;
    procedure TestGitFolderRefused;
    procedure TestDirectoryRefused;
    procedure TestEditTextOutsideRefused;
    procedure TestReplaceRangeOutsideRefused;
    procedure TestCreateUnitOutsideRefused;
    procedure TestEditInTheRepositoryIsAllowed;
    procedure TestCodeToolsRefuseOutside;
    procedure TestFormToolsRefuseOutside;
    procedure TestRenameDryRunIsNotRefused;
    procedure TestActiveEditorOutsideRefused;
    procedure TestLazarusOwnPackageRefused;
    procedure TestPackageToolsRefuseStockPackage;
  end;

implementation

uses
  Classes, SysUtils, FileUtil, fpjson, jsonparser;

function IsError(const T: string): Boolean;
begin
  Result := (Pos('TOOL ERROR', T) = 1) or (Pos('RPC ERROR', T) = 1) or (Pos('HTTP ', T) = 1);
end;

procedure TTestCreateFile.SetUp;
begin
  FRoot := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'mcpcreate' + PathDelim +
           TestName + PathDelim;
end;

procedure TTestCreateFile.TearDown;
begin
  DeleteDirectory(ExcludeTrailingPathDelimiter(FRoot), False);
  RemoveDir(ExcludeTrailingPathDelimiter(FRoot));
  RemoveDir(ExcludeTrailingPathDelimiter(ExtractFileDir(ExcludeTrailingPathDelimiter(FRoot))));
end;

function TTestCreateFile.Call(const AArgs: string): string;
begin
  Result := CallToolText('editor_create_file', AArgs, []);
end;

function TTestCreateFile.Path(const ARel: string): string;
begin
  Result := FRoot + ARel;
end;

function TTestCreateFile.ReadAll(const AFile: string): string;
var
  SL : TStringList;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(AFile);
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

procedure TTestCreateFile.TestCreatesInNewFolders;
var
  T, F : string;
begin
  F := Path('sub' + PathDelim + 'deeper' + PathDelim + 'a.txt');
  T := Call('{"file":' + JsonStr(F) + ',"text":"one\ntwo\r\nthree"}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"created":true', T) > 0, T);
  CheckTrue(Pos('"opened":true', T) > 0, 'opened in the editor: ' + T);
  CheckEquals('one' + LineEnding + 'two' + LineEnding + 'three' + LineEnding, ReadAll(F));
  CallToolText('editor_close', '{"file":' + JsonStr(F) + '}', []);
end;

procedure TTestCreateFile.TestEmptyFile;
var
  T, F : string;
begin
  F := Path('empty.txt');
  T := Call('{"file":' + JsonStr(F) + ',"open":false}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"bytes":0', T) > 0, T);
  CheckTrue(Pos('"opened":false', T) > 0, T);
  CheckTrue(FileExists(F));
end;

procedure TTestCreateFile.TestExistingFileRefusedUnlessOverwrite;
var
  T, F : string;
begin
  F := Path('a.txt');
  CheckFalse(IsError(Call('{"file":' + JsonStr(F) + ',"text":"first","open":false}')));
  T := Call('{"file":' + JsonStr(F) + ',"text":"second","open":false}');
  CheckTrue(IsError(T), T);
  CheckTrue(Pos('already exists', T) > 0, T);
  CheckEquals('first' + LineEnding, ReadAll(F), 'untouched after the refusal');
  T := Call('{"file":' + JsonStr(F) + ',"text":"second","overwrite":true,"open":false}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"replaced":true', T) > 0, T);
  CheckEquals('second' + LineEnding, ReadAll(F));
end;

procedure TTestCreateFile.TestOverwriteRefusedWhileOpen;
var
  T, F : string;
begin
  F := Path('open.txt');
  CheckFalse(IsError(Call('{"file":' + JsonStr(F) + ',"text":"first"}')));
  T := Call('{"file":' + JsonStr(F) + ',"text":"second","overwrite":true}');
  CheckTrue(IsError(T), T);
  CheckTrue(Pos('open in an editor', T) > 0, T);
  CheckEquals('first' + LineEnding, ReadAll(F));
  CallToolText('editor_close', '{"file":' + JsonStr(F) + '}', []);
end;

procedure TTestCreateFile.TestOutsideTheAllowedFoldersRefused;
var
  T, F : string;
begin
  F := IncludeTrailingPathDelimiter(GetUserDir) + 'mcp_must_not_exist.txt';
  T := Call('{"file":' + JsonStr(F) + ',"text":"x","open":false}');
  CheckTrue(IsError(T), T);
  CheckTrue(Pos('Refused', T) > 0, T);
  CheckFalse(FileExists(F), 'nothing was written');
end;

procedure TTestCreateFile.TestDotDotCannotEscape;
var
  T, F : string;
begin
  F := FRoot + '..' + PathDelim + '..' + PathDelim + '..' + PathDelim + 'mcp_escape.txt';
  T := Call('{"file":' + JsonStr(F) + ',"text":"x","open":false}');
  CheckTrue(IsError(T), T);
  CheckTrue(Pos('Refused', T) > 0, T);
  CheckFalse(FileExists(ExpandFileName(F)), 'nothing was written');
end;

procedure TTestCreateFile.TestGitFolderRefused;
var
  T, F : string;
begin
  F := Path('repo' + PathDelim + '.git' + PathDelim + 'hooks' + PathDelim + 'pre-push');
  T := Call('{"file":' + JsonStr(F) + ',"text":"#!/bin/sh","open":false}');
  CheckTrue(IsError(T), T);
  CheckTrue(Pos('.git', T) > 0, T);
  CheckFalse(FileExists(F), 'nothing was written');
  CheckFalse(DirectoryExists(Path('repo')), 'not even the folder');
end;

procedure TTestCreateFile.TestDirectoryRefused;
var
  T : string;
begin
  ForceDirectories(FRoot + 'adir');
  T := Call('{"file":' + JsonStr(FRoot + 'adir') + ',"text":"x","open":false}');
  CheckTrue(IsError(T), T);
  CheckTrue(Pos('directory', T) > 0, T);
end;

{ A file that exists and is surely outside the project, the packages and the temp folder. }
function SystemFile: string;
begin
  {$IFDEF WINDOWS}
  Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('SystemRoot')) + 'win.ini';
  {$ELSE}
  Result := '/etc/hostname';
  {$ENDIF}
end;

{ The checkout this test was built in: the folder above tests/ that holds src/McpToolHelpers.pas. }
function RepoRoot: string;
var
  D, Up : string;
begin
  D := ExcludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  while D <> '' do
  begin
    if FileExists(D + PathDelim + 'src' + PathDelim + 'McpToolHelpers.pas') then
      Exit(D + PathDelim);
    Up := ExtractFileDir(D);
    if (Up = '') or (Up = D) then Break;
    D := Up;
  end;
  Result := '';
end;

procedure TTestCreateFile.TestEditTextOutsideRefused;
var
  T : string;
begin
  if not FileExists(SystemFile) then Ignore('no ' + SystemFile);
  T := CallToolText('editor_edit_text', '{"file":' + JsonStr(SystemFile) +
    ',"old_text":"zzz_never_there","new_text":"x"}', []);
  CheckTrue(IsError(T), T);
  CheckTrue(Pos('Refused', T) > 0, T);
end;

procedure TTestCreateFile.TestReplaceRangeOutsideRefused;
var
  T : string;
begin
  if not FileExists(SystemFile) then Ignore('no ' + SystemFile);
  T := CallToolText('editor_replace_range', '{"file":' + JsonStr(SystemFile) +
    ',"start_line":1,"start_col":1,"new_text":""}', []);
  CheckTrue(IsError(T), T);
  CheckTrue(Pos('Refused', T) > 0, T);
  T := CallToolText('editor_list_open', '{}', []);
  CheckTrue(Pos(ExtractFileName(SystemFile), T) = 0, 'the refused file was not even opened: ' + T);
end;

procedure TTestCreateFile.TestCreateUnitOutsideRefused;
var
  T, F : string;
begin
  F := IncludeTrailingPathDelimiter(GetUserDir) + 'mcp_must_not_exist.pas';
  T := CallToolText('project_create_unit', '{"file":' + JsonStr(F) + '}', []);
  CheckTrue(IsError(T), T);
  CheckTrue(Pos('Refused', T) > 0, T);
  CheckFalse(FileExists(F), 'nothing was written');
end;

{ The plugin's package folder is src/, but its tests, docs and README sit above it: the
  repository that holds the package is writable as a whole. }
procedure TTestCreateFile.TestEditInTheRepositoryIsAllowed;
var
  Root, T : string;
begin
  Root := RepoRoot;
  if Root = '' then Ignore('the checkout was not found from ' + ParamStr(0));
  T := CallToolText('editor_edit_text', '{"file":' + JsonStr(Root + 'docs' + PathDelim + 'adr' + PathDelim +
    'README.md') + ',"old_text":"zzz_never_there","new_text":"x"}', []);
  CheckTrue(IsError(T), 'the text is not there: ' + T);
  CheckTrue(Pos('Refused', T) = 0, 'but it was not refused: ' + T);
end;

{ Every writer of code names the file it changes; one outside the allowed folders is refused
  before the tool runs. }
procedure TTestCreateFile.TestCodeToolsRefuseOutside;
var
  F, T : string;
  I    : Integer;
  Args : array[0..7, 0..1] of string;
begin
  if not FileExists(SystemFile) then Ignore('no ' + SystemFile);
  F := JsonStr(SystemFile);
  Args[0][0] := 'code_add_uses';         Args[0][1] := '{"file":' + F + ',"unit_name":"Classes"}';
  Args[1][0] := 'code_add_to_class';     Args[1][1] := '{"file":' + F + ',"class_name":"TX","text":"x"}';
  Args[2][0] := 'code_insert_in_procedure'; Args[2][1] := '{"file":' + F + ',"proc_name":"P","text":"x"}';
  Args[3][0] := 'code_replace_procedure_body'; Args[3][1] := '{"file":' + F + ',"proc_name":"P","new_body":"x"}';
  Args[4][0] := 'code_edit_statement';   Args[4][1] := '{"file":' + F + ',"line":1,"op":"delete"}';
  Args[5][0] := 'code_complete';         Args[5][1] := '{"file":' + F + ',"line":1,"col":1}';
  Args[6][0] := 'code_format';           Args[6][1] := '{"file":' + F + '}';
  Args[7][0] := 'code_rename_identifier'; Args[7][1] := '{"file":' + F + ',"line":1,"col":1,"new_name":"Zed"}';
  for I := 0 to 7 do
  begin
    T := CallToolText(Args[I][0], Args[I][1], []);
    CheckTrue(IsError(T), Args[I][0] + ': ' + T);
    CheckTrue(Pos('Refused', T) > 0, Args[I][0] + ' was not refused by the folder rule: ' + T);
  end;
end;

procedure TTestCreateFile.TestFormToolsRefuseOutside;
var
  F, T : string;
  I    : Integer;
  Args : array[0..3, 0..1] of string;
begin
  if not FileExists(SystemFile) then Ignore('no ' + SystemFile);
  F := JsonStr(SystemFile);
  Args[0][0] := 'form_add_component';    Args[0][1] := '{"file":' + F + ',"class_name":"TButton"}';
  Args[1][0] := 'form_set_properties';   Args[1][1] := '{"file":' + F + ',"component_name":"Form1","properties":{"Caption":"x"}}';
  Args[2][0] := 'form_delete_component'; Args[2][1] := '{"file":' + F + ',"component_name":"Button1"}';
  Args[3][0] := 'form_history';          Args[3][1] := '{"action":"undo","file":' + F + '}';
  for I := 0 to 3 do
  begin
    T := CallToolText(Args[I][0], Args[I][1], []);
    CheckTrue(IsError(T), Args[I][0] + ': ' + T);
    CheckTrue(Pos('Refused', T) > 0, Args[I][0] + ' was not refused by the folder rule: ' + T);
  end;
  { reading a form is not writing }
  T := CallToolText('form_get_lfm', '{"file":' + F + '}', []);
  CheckTrue(Pos('Refused', T) = 0, 'form_get_lfm only reads: ' + T);
end;

{ A dry run changes nothing, so the folder rule does not stop it: it is how the references
  outside are found. }
procedure TTestCreateFile.TestRenameDryRunIsNotRefused;
var
  T : string;
begin
  if not FileExists(SystemFile) then Ignore('no ' + SystemFile);
  T := CallToolText('code_rename_identifier', '{"file":' + JsonStr(SystemFile) +
    ',"line":1,"col":1,"dry_run":true}', []);
  CheckTrue(Pos('Refused', T) = 0, T);
end;

{ No file argument means the active editor; if that holds a file outside the allowed folders
  the writers are refused too. }
procedure TTestCreateFile.TestActiveEditorOutsideRefused;
var
  T : string;
begin
  if not FileExists(SystemFile) then Ignore('no ' + SystemFile);
  T := CallToolText('editor_open', '{"file":' + JsonStr(SystemFile) + '}', []);
  CheckFalse(IsError(T), 'opening to read is allowed: ' + T);
  try
    T := CallToolText('code_add_uses', '{"file":"","unit_name":"Classes"}', []);
    CheckTrue(IsError(T) and (Pos('Refused', T) > 0), 'code_add_uses on the active editor: ' + T);
    T := CallToolText('code_format', '{"file":""}', []);
    CheckTrue(IsError(T) and (Pos('Refused', T) > 0), 'code_format on the active editor: ' + T);
  finally
    CallToolText('editor_close', '{"file":' + JsonStr(SystemFile) + '}', []);
  end;
end;

{ The packages that ship with Lazarus are loaded in the IDE, but their folders are not the user's
  to change. }
procedure TTestCreateFile.TestLazarusOwnPackageRefused;
var
  T, Lpk, F : string;
  J         : TJSONData;
begin
  T := CallToolText('package_get_info', '{"package_name":"LCL"}', []);
  if IsError(T) then Ignore('LCL is not loaded here: ' + T);
  J := GetJSON(T);
  try
    Lpk := TJSONObject(J).Get('package_file', '');
  finally
    J.Free;
  end;
  if Lpk = '' then Fail('no package_file in ' + T);
  F := ExtractFilePath(Lpk) + 'mcp_must_not_exist.pas';
  T := Call('{"file":' + JsonStr(F) + ',"text":"x"}');
  CheckTrue(IsError(T) and (Pos('Refused', T) > 0), 'editor_create_file in the LCL folder: ' + T);
  CheckFalse(FileExists(F), 'nothing was written');
  T := CallToolText('editor_edit_text', '{"file":' + JsonStr(Lpk) + ',"old_text":"a","new_text":"b"}', []);
  CheckTrue(IsError(T) and (Pos('Refused', T) > 0), 'editor_edit_text on lcl.lpk: ' + T);
end;

{ The tools that change a package's .lpk follow the same rule: the LCL's file is not for them. }
procedure TTestCreateFile.TestPackageToolsRefuseStockPackage;
var
  T, Lpk, L : string;
  J         : TJSONData;
  I         : Integer;
  Args      : array[0..7, 0..1] of string;
begin
  T := CallToolText('package_get_info', '{"package_name":"LCL"}', []);
  if IsError(T) then Ignore('LCL is not loaded here: ' + T);
  J := GetJSON(T);
  try
    Lpk := TJSONObject(J).Get('package_file', '');
  finally
    J.Free;
  end;
  if Lpk = '' then Fail('no package_file in ' + T);
  L := JsonStr(Lpk);
  Args[0][0] := 'package_add_file';
  Args[0][1] := '{"package_name":"LCL","file":' + JsonStr(ExtractFilePath(Lpk) + 'nothing.pas') + '}';
  Args[1][0] := 'package_remove_file';
  Args[1][1] := '{"package_name":"LCL","file":' + JsonStr(ExtractFilePath(Lpk) + 'nothing.pas') + '}';
  Args[2][0] := 'package_add_dependency';
  Args[2][1] := '{"package_name":"LCL","required_package":"FCL"}';
  Args[3][0] := 'package_remove_dependency';
  Args[3][1] := '{"package_name":"LCL","required_package":"FCL"}';
  Args[4][0] := 'package_set_info';
  Args[4][1] := '{"package_name":"LCL","description":"x"}';
  Args[5][0] := 'package_set_settings';
  Args[5][1] := '{"package_name":"LCL","custom_options":"x"}';
  Args[6][0] := 'package_move_unit';
  Args[6][1] := '{"file":' + JsonStr(ExtractFilePath(Lpk) + 'nothing.pas') + ',"from_package":"LCL","to_package":"LazMcpAssistant"}';
  Args[7][0] := 'package_set_info';
  Args[7][1] := '{"lpk_path":' + L + ',"description":"x"}';
  for I := 0 to 7 do
  begin
    T := CallToolText(Args[I][0], Args[I][1], []);
    CheckTrue(IsError(T) and (Pos('Refused', T) > 0), Args[I][0] + ' was not refused: ' + T);
  end;
  { a plan changes nothing }
  T := CallToolText('package_move_unit', '{"file":' + JsonStr(ExtractFilePath(Lpk) + 'nothing.pas') +
    ',"from_package":"LCL","to_package":"LazMcpAssistant","dry_run":true}', []);
  CheckTrue(Pos('Refused', T) = 0, 'dry_run is not refused: ' + T);
end;

initialization
  RegisterTest(TTestCreateFile);

end.
