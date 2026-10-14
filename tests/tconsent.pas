{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TConsent;

{ TTestConsent — the ADR-013 gate refuses installing a new package while the
  user hasn't allowed installs.  Requires a running MCP server.

  Safety: the tests never change the setting and never see the consent dialog.
  They are ignored when installs are allowed, and the package path doesn't
  exist, so even then the request would fail with "not found" before any
  dialog or rebuild. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, THttpHelper;

type
  TTestConsent = class(TTestCase)
  protected
    procedure SetUp; override;
  published
    procedure TestPackageInstallRefused;
    procedure TestRebuildWithPackageRefused;
  end;

implementation

uses
  Classes, SysUtils;

function ProbeLpk: string;
begin
  Result := ExtractFilePath(ExpandFileName(ParamStr(0))) +
            'fixtures' + PathDelim + 'no-such-package' + PathDelim + 'mcpconsentprobe.lpk';
end;

procedure TTestConsent.SetUp;
var
  SL : TStringList;
begin
  SL := TStringList.Create;
  try
    if (GOptionsFile = '') or not FileExists(GOptionsFile) then
      Ignore('settings file unknown');
    SL.LoadFromFile(GOptionsFile);
    if Pos('AllowPackageInstall="True"', SL.Text) > 0 then
      Ignore('installing packages is allowed in this IDE; the refusal can''t be tested');
  finally
    SL.Free;
  end;
end;

procedure TTestConsent.TestPackageInstallRefused;
var
  T : string;
begin
  T := CallToolText('package_install', '{"lpk_path":' + JsonStr(ProbeLpk) + '}', []);
  CheckEquals(1, Pos('TOOL ERROR: Refused', T), 'refused: ' + T);
  CheckTrue(Pos('turned off', T) > 0, 'says why: ' + T);
  CheckTrue(Pos('do not try to change the setting yourself', T) > 0,
    'tells the assistant not to change the setting: ' + T);
end;

procedure TTestConsent.TestRebuildWithPackageRefused;
var
  T : string;
begin
  T := CallToolText('ide_rebuild', '{"lpk_path":' + JsonStr(ProbeLpk) + '}', []);
  CheckEquals(1, Pos('TOOL ERROR: Refused', T), 'refused before any rebuild: ' + T);
  CheckEquals(200, McpPost('{"jsonrpc":"2.0","id":1,"method":"ping"}').Code,
    'the IDE is still up');
end;

end.
