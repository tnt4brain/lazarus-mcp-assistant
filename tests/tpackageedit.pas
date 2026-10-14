{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TPackageEdit;

{ TTestPackageEdit — the package editing tools against the running IDE, on
  tests/fixtures/fixturepkg/mcpfixturepkg.lpk (runtime only, never installed).
  Each test changes the fixture and changes it back through the tools, so the
  .lpk ends as it was; writing it back from here would make the IDE see it
  changed on disk.  The tools load the fixture by lpk_path; once saved and
  unused, the IDE closes it again when idle, so results are checked in the
  saved .lpk, not with package_get_info.
  Requires a running MCP server. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, THttpHelper;

type
  TTestPackageEdit = class(TTestCase)
  published
    procedure TestAddAndRemoveFile;
    procedure TestAddAndRemoveDependency;
    procedure TestRefusals;
    procedure TestConsentGuard;
  end;

implementation

uses
  Classes, SysUtils, fpjson, jsonparser;

function FixtureDir: string;
begin
  Result := ExtractFilePath(ExpandFileName(ParamStr(0))) + 'fixtures' + PathDelim +
            'fixturepkg' + PathDelim;
end;

function FixtureLpk: string;
begin
  Result := FixtureDir + 'mcpfixturepkg.lpk';
end;

function LpkText: string;
var
  SL : TStringList;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(FixtureLpk);
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

function Call(const ATool, AArgs: string): string;
begin
  Result := CallToolText(ATool, AArgs, []);
end;

function Lpk: string;
begin
  Result := '"lpk_path":' + JsonStr(FixtureLpk);
end;

function IsError(const T: string): Boolean;
begin
  Result := (Pos('TOOL ERROR', T) = 1) or (Pos('RPC ERROR', T) = 1) or (Pos('HTTP ', T) = 1);
end;

{ A change must be saved; another package with unsaved changes in the IDE
  prevents that, which is the user's state, not a failure. }
procedure CheckSaved(ACase: TTestCase; const T: string);
begin
  ACase.CheckFalse(IsError(T), T);
  if Pos('"saved" : false', T) > 0 then
    if Pos('has unsaved changes', T) > 0 then
      ACase.Ignore('the IDE has unsaved package changes: ' + T)
    else
      ACase.Fail('not saved: ' + T);
end;

procedure TTestPackageEdit.TestAddAndRemoveFile;
var
  Extra, T : string;
begin
  Extra := FixtureDir + 'mcpfixtureextra.pas';
  T := Call('package_add_file', '{' + Lpk + ',"file":' + JsonStr(Extra) + '}');
  try
    CheckSaved(Self, T);
    CheckTrue(Pos('"unit" : "McpFixtureExtra"', T) > 0, 'unit name read: ' + T);
    CheckTrue(Pos('"has_register_proc" : true', T) > 0, 'Register found: ' + T);
    CheckEquals(0, Pos('unit_path_added', T), 'same directory, no path: ' + T);
    CheckTrue(Pos('McpFixtureExtra', LpkText) > 0, 'in the saved .lpk');
    T := Call('package_add_file', '{' + Lpk + ',"file":' + JsonStr(Extra) + '}');
    CheckTrue(Pos('already in', T) > 0, 'twice: ' + T);
  finally
    T := Call('package_remove_file', '{' + Lpk + ',"file":' + JsonStr(Extra) + '}');
  end;
  CheckSaved(Self, T);
  CheckEquals(0, Pos('McpFixtureExtra', LpkText), 'removed from the saved .lpk');
end;

procedure TTestPackageEdit.TestAddAndRemoveDependency;
var
  T : string;
begin
  T := Call('package_add_dependency',
    '{' + Lpk + ',"required_package":"LazUtils","min_version":"1.0"}');
  try
    CheckSaved(Self, T);
    CheckTrue(Pos('"status" : "ok"', T) > 0, 'resolved: ' + T);
    CheckTrue(Pos('"min_version" : "1.0"', T) > 0, 'version limit: ' + T);
    CheckTrue(Pos('LazUtils', LpkText) > 0, 'in the saved .lpk');
    T := Call('package_add_dependency', '{' + Lpk + ',"required_package":"LazUtils"}');
    CheckTrue(Pos('already requires', T) > 0, 'twice: ' + T);
  finally
    T := Call('package_remove_dependency', '{' + Lpk + ',"required_package":"LazUtils"}');
  end;
  CheckSaved(Self, T);
  CheckEquals(0, Pos('LazUtils', LpkText), 'removed from the saved .lpk');
end;

procedure TTestPackageEdit.TestRefusals;
var
  T : string;
begin
  T := Call('package_add_dependency', '{' + Lpk + ',"required_package":"NoSuchPackageXyz"}');
  CheckTrue(Pos('could not be resolved', T) > 0, 'unknown package: ' + T);
  { rolled back and not left modified: the next change saves cleanly }
  T := Call('package_add_dependency', '{' + Lpk + ',"required_package":"LazUtils"}');
  Call('package_remove_dependency', '{' + Lpk + ',"required_package":"LazUtils"}');
  CheckSaved(Self, T);
  CheckEquals(0, Pos('NoSuchPackageXyz', LpkText), 'not in the saved .lpk');

  T := Call('package_add_dependency', '{' + Lpk + ',"required_package":"McpFixturePkg"}');
  CheckTrue(Pos('itself', T) > 0, 'self: ' + T);
  T := Call('package_add_dependency',
    '{' + Lpk + ',"required_package":"LazUtils","min_version":"99.0"}');
  CheckTrue((Pos('outside the version limits', T) > 0) or
            (Pos('could not be resolved', T) > 0), 'version limit: ' + T);
  T := Call('package_remove_file',
    '{' + Lpk + ',"file":' + JsonStr(FixtureDir + 'nosuchfile.pas') + '}');
  CheckTrue(Pos('is not in', T) > 0, 'not a package file: ' + T);
end;

procedure TTestPackageEdit.TestConsentGuard;
{ The plugin is installed and the fixture is not: requiring it would bring it
  into the IDE at the next rebuild (ADR-013). }
var
  T : string;
begin
  T := Call('package_add_dependency',
    '{"package_name":"LazMcpAssistant","required_package":"McpFixturePkg"}');
  if not IsError(T) then
    Call('package_remove_dependency',
      '{"package_name":"LazMcpAssistant","required_package":"McpFixturePkg"}');
  CheckTrue(Pos('is installed in the IDE', T) > 0, 'refused: ' + T);
end;

end.
