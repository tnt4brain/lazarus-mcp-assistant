{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpSettingsFile;

{ The plugin's settings file (mcpassistantoptions.xml).  Plain LazUtils code
  with no IDE units, so the test program can load and save it; McpIdeState
  decides where the file lives. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Laz2_XMLCfg;

type
  { The user-facing part is edited on the Tools > Options page (McpOptions);
    Token, Port and LastConfigPath are server state. }
  TMcpIdeSettings = class
  private
    FXmlConfig: TXMLConfig;
    FServerToken: string;
    FServerPort: Word;
    FListenAddress: string;         { IPv4 the server listens on; 0.0.0.0 = every interface }
    FLastConfigPath: string;
    FClaudePath: string;            { '' = claude on PATH }
    FWorkingDirectory: string;      { '' = project directory }
    FExtraClaudeArgs: string;
    FTerminalCommand: string;       { '' = auto-detect (Linux/macOS only) }
    FGitPath: string;               { '' = git on PATH }
    FAllowPackageInstall: Boolean;  { assistants may install new packages (ADR-013) }
    procedure LoadDefaultSettings;
    function GetConfigFileName: string;
  public
    constructor Create;
    destructor Destroy; override;
    { Reads AFileName (defaults when it doesn't exist); SaveSettings writes
      back to the same file. }
    procedure LoadSettings(const AFileName: string);
    procedure SaveSettings;

    property ConfigFileName: string read GetConfigFileName;
    property ServerToken: string read FServerToken write FServerToken;
    property ServerPort: Word read FServerPort write FServerPort;
    property ListenAddress: string read FListenAddress write FListenAddress;
    property LastConfigPath: string read FLastConfigPath write FLastConfigPath;
    property ClaudePath: string read FClaudePath write FClaudePath;
    property WorkingDirectory: string read FWorkingDirectory write FWorkingDirectory;
    property ExtraClaudeArgs: string read FExtraClaudeArgs write FExtraClaudeArgs;
    property TerminalCommand: string read FTerminalCommand write FTerminalCommand;
    property GitPath: string read FGitPath write FGitPath;
    property AllowPackageInstall: Boolean read FAllowPackageInstall write FAllowPackageInstall;
  end;

implementation

constructor TMcpIdeSettings.Create;
begin
  inherited Create;
  FListenAddress := '127.0.0.1';
  FXmlConfig := TXMLConfig.Create(nil);
end;

destructor TMcpIdeSettings.Destroy;
begin
  FXmlConfig.Free;
  inherited Destroy;
end;

procedure TMcpIdeSettings.LoadDefaultSettings;
begin
  FListenAddress       := '127.0.0.1';
  FClaudePath          := '';
  FWorkingDirectory    := '';
  FExtraClaudeArgs     := '';
  FTerminalCommand     := '';
  FGitPath             := '';
  FAllowPackageInstall := False;
end;

function TMcpIdeSettings.GetConfigFileName: string;
begin
  Result := FXmlConfig.Filename;
end;

procedure TMcpIdeSettings.LoadSettings(const AFileName: string);
begin
  FXmlConfig.Filename := AFileName;

  if not FileExists(FXmlConfig.Filename) then
  begin
    LoadDefaultSettings;
    Exit;
  end;

  try
    FServerToken      := FXmlConfig.GetValue('Server/Token', '');
    FServerPort       := FXmlConfig.GetValue('Server/Port', 0);
    FLastConfigPath   := FXmlConfig.GetValue('Server/LastConfigPath', '');
    FListenAddress    := FXmlConfig.GetValue('Server/ListenAddress', '127.0.0.1');
    FClaudePath      := FXmlConfig.GetValue('Claude/Path', '');
    FWorkingDirectory := FXmlConfig.GetValue('Claude/WorkingDirectory', '');
    FExtraClaudeArgs  := FXmlConfig.GetValue('Claude/ExtraArgs', '');
    FTerminalCommand  := FXmlConfig.GetValue('Claude/TerminalCommand', '');
    FGitPath          := FXmlConfig.GetValue('Tools/GitPath', '');
    FAllowPackageInstall := FXmlConfig.GetValue('Security/AllowPackageInstall', False);
  except
    LoadDefaultSettings;
  end;
end;

procedure TMcpIdeSettings.SaveSettings;
begin
  if FXmlConfig.Filename = '' then Exit;
  try
    FXmlConfig.SetValue('Server/Token',          FServerToken);
    FXmlConfig.SetValue('Server/Port',           Integer(FServerPort));
    FXmlConfig.SetValue('Server/LastConfigPath', FLastConfigPath);
    FXmlConfig.SetValue('Server/ListenAddress',  FListenAddress);
    FXmlConfig.SetValue('Claude/Path',             FClaudePath);
    FXmlConfig.SetValue('Claude/WorkingDirectory', FWorkingDirectory);
    FXmlConfig.SetValue('Claude/ExtraArgs',        FExtraClaudeArgs);
    FXmlConfig.SetValue('Claude/TerminalCommand',  FTerminalCommand);
    FXmlConfig.SetValue('Tools/GitPath',           FGitPath);
    FXmlConfig.SetValue('Security/AllowPackageInstall', FAllowPackageInstall);
    { settings of the removed API client; ApiKey was stored in plain text }
    FXmlConfig.DeleteValue('Server/ExecutablePath');
    FXmlConfig.DeleteValue('Server/Arguments');
    FXmlConfig.DeletePath('System');
    FXmlConfig.DeleteValue('Claude/ApiKey');
    FXmlConfig.DeleteValue('Claude/Model');
    FXmlConfig.Flush;
  except
  end;
end;

end.
