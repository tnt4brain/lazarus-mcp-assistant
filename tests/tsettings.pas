{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TSettings;

{ TTestSettingsFile — mcpassistantoptions.xml round trip (McpSettingsFile),
  on a temporary file.  No running server required. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TTestSettingsFile = class(TTestCase)
  private
    FFile : string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestMissingFileGivesDefaults;
    procedure TestRoundTrip;
    procedure TestObsoleteKeysRemoved;
  end;

implementation

uses
  Classes, SysUtils, McpSettingsFile;

procedure TTestSettingsFile.SetUp;
begin
  FFile := IncludeTrailingPathDelimiter(GetTempDir) +
           Format('mcp-settings-test-%d.xml', [Random(1000000)]);
  DeleteFile(FFile);
end;

procedure TTestSettingsFile.TearDown;
begin
  DeleteFile(FFile);
end;

procedure TTestSettingsFile.TestMissingFileGivesDefaults;
var
  S : TMcpIdeSettings;
begin
  S := TMcpIdeSettings.Create;
  try
    S.LoadSettings(FFile);
    CheckEquals(FFile, S.ConfigFileName);
    CheckEquals('', S.ClaudePath);
    CheckEquals('', S.GitPath);
    CheckFalse(S.AllowPackageInstall, 'installing packages is off by default');
  finally
    S.Free;
  end;
end;

procedure TTestSettingsFile.TestRoundTrip;
var
  S : TMcpIdeSettings;
begin
  S := TMcpIdeSettings.Create;
  try
    S.LoadSettings(FFile);
    S.ServerToken         := 'tok123';
    S.ServerPort          := 54321;
    S.LastConfigPath      := 'C:\cfg\mcp.json';
    S.ClaudePath          := '/opt/claude/bin/claude';
    S.WorkingDirectory    := 'D:\work dir';
    S.ExtraClaudeArgs     := '--model opus "quoted arg"';
    S.TerminalCommand     := 'kitty -e';
    S.GitPath             := 'C:\Program Files\Git\cmd\git.exe';
    S.AllowPackageInstall := True;
    S.SaveSettings;
  finally
    S.Free;
  end;
  CheckTrue(FileExists(FFile), 'SaveSettings writes the file');

  S := TMcpIdeSettings.Create;
  try
    S.LoadSettings(FFile);
    CheckEquals('tok123', S.ServerToken);
    CheckEquals(54321, S.ServerPort);
    CheckEquals('C:\cfg\mcp.json', S.LastConfigPath);
    CheckEquals('/opt/claude/bin/claude', S.ClaudePath);
    CheckEquals('D:\work dir', S.WorkingDirectory);
    CheckEquals('--model opus "quoted arg"', S.ExtraClaudeArgs);
    CheckEquals('kitty -e', S.TerminalCommand);
    CheckEquals('C:\Program Files\Git\cmd\git.exe', S.GitPath);
    CheckTrue(S.AllowPackageInstall);
  finally
    S.Free;
  end;
end;

procedure TTestSettingsFile.TestObsoleteKeysRemoved;
var
  SL : TStringList;
  S  : TMcpIdeSettings;
begin
  SL := TStringList.Create;
  try
    SL.Text :=
      '<?xml version="1.0" encoding="UTF-8"?>' + LineEnding +
      '<CONFIG>' + LineEnding +
      '  <Server Token="old" Port="1234" ExecutablePath="x" Arguments="y"/>' + LineEnding +
      '  <Claude ApiKey="sk-secret" Model="m" Path="/bin/claude"/>' + LineEnding +
      '  <System Prompt="p"/>' + LineEnding +
      '</CONFIG>';
    SL.SaveToFile(FFile);

    S := TMcpIdeSettings.Create;
    try
      S.LoadSettings(FFile);
      CheckEquals('old', S.ServerToken);
      CheckEquals('/bin/claude', S.ClaudePath);
      S.SaveSettings;
    finally
      S.Free;
    end;

    SL.LoadFromFile(FFile);
    CheckEquals(0, Pos('sk-secret', SL.Text), 'the plain-text API key is deleted');
    CheckEquals(0, Pos('ExecutablePath', SL.Text));
    CheckEquals(0, Pos('<System', SL.Text));
    CheckEquals(0, Pos('Model=', SL.Text));
    CheckTrue(Pos('/bin/claude', SL.Text) > 0, 'current settings are kept');
  finally
    SL.Free;
  end;
end;

initialization
  Randomize;
  RegisterTest(TTestSettingsFile);
end.
