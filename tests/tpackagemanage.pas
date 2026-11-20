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
    procedure TestConcurrentUninstallsKeepTheirOwnNames;
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
  Dir, Lpk, T, A, Id, Pkg, Unt, UnitFile : string;
begin
  { a package cannot be unloaded from outside (package_uninstall restarts the IDE), so one from an
    earlier run of this suite is still loaded in the same IDE session: every run gets its own names }
  Id  := IntToStr(GetProcessID);
  Pkg := 'McpTmpPkgA' + Id;
  Unt := 'McpTmpUnitA' + Id;
  UnitFile := LowerCase(Unt) + '.pas';
  Dir := TempPkgDir('a' + Id);
  Lpk := Dir + Pkg + '.lpk';
  A   := '"lpk_path":' + JsonStr(Lpk);
  try
    T := Call('package_create', '{"name":"' + Pkg + '","directory":' + JsonStr(Dir) +
              ',"unit_name":"' + Unt + '","version":"1.2","description":"temp"}');
    CheckFalse(IsError(T), T);
    CheckTrue(Pos('"created":true', T) > 0, 'created: ' + T);
    CheckTrue(FileExists(Lpk), '.lpk written');
    CheckTrue(FileExists(Dir + UnitFile), 'unit written');
    CheckTrue(Pos('"version":"1.2', T) > 0, 'version: ' + T);
    CheckTrue(Pos('"unit":"' + Unt + '"', T) > 0, 'unit listed: ' + T);

    T := Call('project_list_files', '{' + A + '}');
    CheckTrue(Pos(UnitFile, LowerCase(T)) > 0, 'the package''s files: ' + T);
    CheckEquals(0, Pos('mcpserver_tests', T), 'not the project''s: ' + T);
    T := Call('project_search', '{"query":"implementation",' + A + '}');
    CheckTrue(Pos(UnitFile, LowerCase(T)) > 0, 'searched in the package: ' + T);

    T := Call('package_get_settings', '{' + A + '}');
    CheckFalse(IsError(T), T);
    CheckTrue(Pos('"package_type":"RunTime"', T) > 0, 'type: ' + T);

    T := Call('package_set_settings', '{' + A + ',"custom_options":"-dMCPTMP"}');
    CheckFalse(IsError(T), T);
    CheckTrue(Pos('-dMCPTMP', T) > 0, 'changed: ' + T);
    if Pos('"saved":false', T) > 0 then
      Ignore('the IDE has unsaved package changes: ' + T);
    T := Call('package_get_info', '{' + A + '}');
    CheckTrue(Pos('-dMCPTMP', T) > 0, 'info shows it: ' + T);

    T := Call('package_compile', '{' + A + ',"method":"ide"}');
    CheckFalse(IsError(T), T);
    CheckTrue(Pos('"method":"ide"', T) > 0, 'IDE compiler: ' + T);
    CheckTrue(Pos('"success":true', T) > 0, 'compiles: ' + T);

    T := Call('package_compile', '{' + A + ',"method":"lazbuild"}');
    CheckFalse(IsError(T), T);
    CheckTrue(Pos('"method":"lazbuild"', T) > 0, 'lazbuild: ' + T);
    CheckTrue(Pos('"success":true', T) > 0, 'compiles: ' + T);

    { a compile error comes back as data }
    Call('editor_open', '{"file":' + JsonStr(Dir + UnitFile) + '}');
    Call('editor_close', '{"file":' + JsonStr(Dir + UnitFile) + '}');
    with TStringList.Create do
    try
      Text := 'unit ' + Unt + ';' + LineEnding + '{$mode objfpc}{$H+}' + LineEnding +
              'interface' + LineEnding + 'implementation' + LineEnding +
              'procedure P; begin NoSuchIdent := 1; end;' + LineEnding + 'end.' + LineEnding;
      SaveToFile(Dir + UnitFile);
    finally
      Free;
    end;
    T := Call('package_compile', '{' + A + ',"method":"ide","clean":true}');
    { Lazarus 5.0RC1 (not 4.6): after a failed package compile the IDE itself jumps to the first error
      and shows "Read Error: Unable to read file" for it, a modal that blocks everything behind it.
      Reproduces with a plain Compile in the IDE, no plugin call involved.  Close it, so that the
      other suites can run, and say so.
      (package_compile answers that the IDE waits for a dialog.) }
    if Pos('waiting for an answer in a dialog', T) > 0 then
    begin
      Call('ide_answer_dialog', '{"button":"Abort"}');
      Ignore('this IDE opens a Read Error dialog after a failed package compile (a Lazarus 5.0 ' +
             'regression, not the plugin): ' + T);
    end;
    CheckTrue(Pos('"success":false', T) > 0, 'fails: ' + T);
    CheckTrue(Pos('NoSuchIdent', T) > 0, 'says what: ' + T);
  finally
    { a compile error may have opened the unit: close it before its file goes }
    Call('editor_close', '{"file":' + JsonStr(Dir + UnitFile) + '}');
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
  { a package of ours, so the folder rule lets the call reach the argument check; with no setting
    given nothing is changed }
  T := Call('package_set_settings', '{"package_name":"LazMcpAssistant"}');
  CheckTrue(Pos('Give at least one of', T) > 0, T);
  T := Call('package_compile', '{"package_name":"NoSuchPackageXyz"}');
  CheckTrue(Pos('Package not loaded', T) > 0, T);
  T := Call('package_list', '{"name_contains":"LazMcpAssistant"}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"name":"LazMcpAssistant"', T) > 0, 'the plugin is listed: ' + T);
  T := Call('package_list', '{"name_contains":"LazUtils"}');
  CheckTrue(Pos('"count":0', T) > 0, 'IDE packages hidden by default: ' + T);
  T := Call('package_list', '{"name_contains":"LazUtils","include_ide":true}');
  CheckTrue(Pos('"name":"LazUtils"', T) > 0, 'and shown on request: ' + T);
end;

type
  TUninstallThread = class(TThread)
  public
    Index  : Integer;
    Answer : string;
    procedure Execute; override;
  end;

procedure TUninstallThread.Execute;
begin
  Answer := Call('package_uninstall', '{"package_name":"McpNoSuchPkg' + IntToStr(Index) + 'X"}');
end;

{ The package_install, package_uninstall and ide_rebuild calls share one helper object in
  the plugin.  A call must take the in-flight guard before it writes into it: else a
  concurrent call overwrites the names of the one running (and, when strings are shared,
  can crash the IDE: Lazarus 5.0RC1, issue #29).  Every answer names its own package,
  or says a rebuild is in progress. }
procedure TTestPackageManage.TestConcurrentUninstallsKeepTheirOwnNames;
const
  N      = 8;
  ROUNDS = 6;
var
  Ths    : array[1..N] of TUninstallThread;
  I, R   : Integer;
  Own    : string;
begin
  for R := 1 to ROUNDS do
  begin
    for I := 1 to N do
    begin
      Ths[I] := TUninstallThread.Create(True);
      Ths[I].Index := I;
    end;
    for I := 1 to N do Ths[I].Start;
    for I := 1 to N do Ths[I].WaitFor;
    try
      for I := 1 to N do
      begin
        Own := 'McpNoSuchPkg' + IntToStr(I) + 'X';
        CheckTrue((Pos(Own, Ths[I].Answer) > 0) or
                  (Pos('already in progress', Ths[I].Answer) > 0) or
                  (Pos('needs an open project', Ths[I].Answer) > 0),
                  'round ' + IntToStr(R) + ', thread ' + IntToStr(I) + ': ' + Ths[I].Answer);
        CheckEquals(0, Pos('McpNoSuchPkg', StringReplace(Ths[I].Answer, Own, '', [])),
                    'another thread''s package name in: ' + Ths[I].Answer);
      end;
    finally
      for I := 1 to N do Ths[I].Free;
    end;
  end;
  CheckFalse(IsError(Call('ide_ping', '{}')), 'the IDE still answers');
end;

initialization
  RegisterTest(TTestPackageManage);

end.
