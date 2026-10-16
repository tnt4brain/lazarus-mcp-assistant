{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TPackageManage;

{ TTestPackageManage — package_create / open / list / get_info / settings /
  compile on a package the test writes into a temp directory.  Once saved and
  unused the IDE closes it again when idle.  Requires a running MCP server. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, THttpHelper;

type
  TTestPackageManage = class(TTestCase)
  published
    procedure TestCreateSettingsCompile;
    procedure TestCreateRefusals;
    procedure TestListAndInfoErrors;
  end;

implementation

uses
  Classes, SysUtils, FileUtil;

function Call(const ATool, AArgs: string): string;
begin
  Result := CallToolText(ATool, AArgs, []);
end;

function IsError(const T: string): Boolean;
begin
  Result := (Pos('TOOL ERROR', T) = 1) or (Pos('RPC ERROR', T) = 1) or (Pos('HTTP ', T) = 1);
end;

function TempPkgDir(const ASub: string): string;
begin
  Result := GetTempDir(False) + 'mcppkgmanage' + PathDelim + ASub + PathDelim;
end;

procedure TTestPackageManage.TestCreateSettingsCompile;
var
  Dir, Lpk, T, A : string;
begin
  Dir := TempPkgDir('a');
  Lpk := Dir + 'McpTmpPkgA.lpk';
  A   := '"lpk_path":' + JsonStr(Lpk);
  try
    T := Call('package_create', '{"name":"McpTmpPkgA","directory":' + JsonStr(Dir) +
              ',"unit_name":"McpTmpUnitA","version":"1.2","description":"temp"}');
    CheckFalse(IsError(T), T);
    CheckTrue(Pos('"created":true', T) > 0, 'created: ' + T);
    CheckTrue(FileExists(Lpk), '.lpk written');
    CheckTrue(FileExists(Dir + 'mcptmpunita.pas'), 'unit written');
    CheckTrue(Pos('"version" : "1.2', T) > 0, 'version: ' + T);
    CheckTrue(Pos('"unit" : "McpTmpUnitA"', T) > 0, 'unit listed: ' + T);

    T := Call('project_list_files', '{' + A + '}');
    CheckTrue(Pos('mcptmpunita.pas', LowerCase(T)) > 0, 'the package''s files: ' + T);
    CheckEquals(0, Pos('mcpserver_tests', T), 'not the project''s: ' + T);
    T := Call('project_search', '{"query":"implementation",' + A + '}');
    CheckTrue(Pos('mcptmpunita.pas', LowerCase(T)) > 0, 'searched in the package: ' + T);

    T := Call('package_get_settings', '{' + A + '}');
    CheckFalse(IsError(T), T);
    CheckTrue(Pos('"package_type" : "RunTime"', T) > 0, 'type: ' + T);

    T := Call('package_set_settings', '{' + A + ',"custom_options":"-dMCPTMP"}');
    CheckFalse(IsError(T), T);
    CheckTrue(Pos('-dMCPTMP', T) > 0, 'changed: ' + T);
    if Pos('"saved" : false', T) > 0 then
      Ignore('the IDE has unsaved package changes: ' + T);
    T := Call('package_get_info', '{' + A + '}');
    CheckTrue(Pos('-dMCPTMP', T) > 0, 'info shows it: ' + T);

    T := Call('package_compile', '{' + A + ',"method":"ide"}');
    CheckFalse(IsError(T), T);
    CheckTrue(Pos('"method" : "ide"', T) > 0, 'IDE compiler: ' + T);
    CheckTrue(Pos('"success" : true', T) > 0, 'compiles: ' + T);

    T := Call('package_compile', '{' + A + ',"method":"lazbuild"}');
    CheckFalse(IsError(T), T);
    CheckTrue(Pos('"method" : "lazbuild"', T) > 0, 'lazbuild: ' + T);
    CheckTrue(Pos('"success" : true', T) > 0, 'compiles: ' + T);

    { a compile error comes back as data }
    Call('editor_open', '{"file":' + JsonStr(Dir + 'mcptmpunita.pas') + '}');
    Call('editor_close', '{"file":' + JsonStr(Dir + 'mcptmpunita.pas') + '}');
    with TStringList.Create do
    try
      Text := 'unit McpTmpUnitA;' + LineEnding + '{$mode objfpc}{$H+}' + LineEnding +
              'interface' + LineEnding + 'implementation' + LineEnding +
              'procedure P; begin NoSuchIdent := 1; end;' + LineEnding + 'end.' + LineEnding;
      SaveToFile(Dir + 'mcptmpunita.pas');
    finally
      Free;
    end;
    T := Call('package_compile', '{' + A + ',"method":"ide","clean":true}');
    CheckTrue(Pos('"success" : false', T) > 0, 'fails: ' + T);
    CheckTrue(Pos('NoSuchIdent', T) > 0, 'says what: ' + T);
  finally
    DeleteDirectory(Dir, False);
  end;
end;

procedure TTestPackageManage.TestCreateRefusals;
var
  Dir, T : string;
begin
  Dir := TempPkgDir('b');
  T := Call('package_create', '{"name":"not valid","directory":' + JsonStr(Dir) + '}');
  CheckTrue(Pos('Pascal identifier', T) > 0, T);
  T := Call('package_create', '{"name":"McpTmpPkgB","directory":"relative"}');
  CheckTrue(Pos('absolute', T) > 0, T);
  T := Call('package_create', '{"name":"McpTmpPkgB","directory":' + JsonStr(Dir) +
            ',"requires":["NoSuchPackageXyz"]}');
  CheckTrue(Pos('Package not found: NoSuchPackageXyz', T) > 0, T);
  CheckFalse(FileExists(Dir + 'McpTmpPkgB.lpk'), 'nothing written');
  T := Call('package_create', '{"name":"McpTmpPkgB","directory":' + JsonStr(Dir) +
            ',"type":"Bogus"}');
  CheckTrue(Pos('type must be', T) > 0, T);
end;

procedure TTestPackageManage.TestListAndInfoErrors;
var
  T : string;
begin
  T := Call('package_get_info', '{}');
  CheckTrue(Pos('package_name or lpk_path required', T) > 0, T);
  T := Call('package_get_info', '{"lpk_path":"C:/nowhere/x.lpk"}');
  CheckTrue(Pos('No such .lpk', T) > 0, T);
  T := Call('package_set_settings', '{"package_name":"LazUtils"}');
  CheckTrue(Pos('Give at least one of', T) > 0, T);
  T := Call('package_compile', '{"package_name":"NoSuchPackageXyz"}');
  CheckTrue(Pos('Package not loaded', T) > 0, T);
  T := Call('package_list', '{"name_contains":"LazMcpAssistant"}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"name" : "LazMcpAssistant"', T) > 0, 'the plugin is listed: ' + T);
  T := Call('package_list', '{"name_contains":"LazUtils"}');
  CheckTrue(Pos('"count" : 0', T) > 0, 'IDE packages hidden by default: ' + T);
  T := Call('package_list', '{"name_contains":"LazUtils","include_ide":true}');
  CheckTrue(Pos('"name" : "LazUtils"', T) > 0, 'and shown on request: ' + T);
end;

initialization
  RegisterTest(TTestPackageManage);

end.
