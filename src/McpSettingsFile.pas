{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpSettingsFile;

{ The plugin's settings file (mcpassistantoptions.xml).  Plain LazUtils code
  with no IDE units, so the test program can load and save it; McpIdeState
  decides where the file lives. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Laz2_XMLCfg, McpTokens;

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
    FWinTerminal: string;           { Windows: default, cmd, powershell, wt, gitbash, custom }
    FWinTerminalCustom: string;     { Windows custom: exe plus argument template }
    FGitPath: string;               { '' = git on PATH }
    FAllowPackageInstall: Boolean;  { assistants may install new packages (ADR-013) }
    FToolCallLog: Boolean;          { mcp-tools.log, one record per tool call (ADR-022) }
    FToolLogFile: string;           { where that file is; '' = in the Lazarus config folder }
    FToolLogPane: Boolean;          { one line per call in the Messages window (ADR-022, Amendment 1) }
    FClientTokens: TMcpTokenStore;  { named tokens, as hashes (ADR-021) }
    procedure LoadDefaultSettings;
    procedure LoadTokens;
    procedure SaveTokens;
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
    property WinTerminal: string read FWinTerminal write FWinTerminal;
    property WinTerminalCustom: string read FWinTerminalCustom write FWinTerminalCustom;
    property GitPath: string read FGitPath write FGitPath;
    property AllowPackageInstall: Boolean read FAllowPackageInstall write FAllowPackageInstall;
    property ToolCallLog: Boolean read FToolCallLog write FToolCallLog;
    property ToolLogFile: string read FToolLogFile write FToolLogFile;
    property ToolLogPane: Boolean read FToolLogPane write FToolLogPane;
    { the named client tokens; saved with the other settings }
    property ClientTokens: TMcpTokenStore read FClientTokens;
  end;

implementation

constructor TMcpIdeSettings.Create;
begin
  inherited Create;
  FListenAddress := '127.0.0.1';
  FXmlConfig := TXMLConfig.Create(nil);
  FClientTokens := TMcpTokenStore.Create;
end;

destructor TMcpIdeSettings.Destroy;
begin
  FClientTokens.Free;
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
  FWinTerminal         := 'default';
  FWinTerminalCustom   := '';
  FGitPath             := '';
  FAllowPackageInstall := False;
  FToolCallLog         := False;
  FToolLogFile         := '';
  FToolLogPane         := False;
end;

procedure TMcpIdeSettings.LoadTokens;
var
  Items : TMcpClientTokens;
  I, N  : Integer;
  P     : string;
begin
  N := FXmlConfig.GetValue('Tokens/Count', 0);
  if N > MCP_MAX_TOKENS then N := MCP_MAX_TOKENS;
  SetLength(Items, 0);
  for I := 1 to N do
  begin
    P := 'Tokens/Item' + IntToStr(I) + '/';
    { an entry without a hash can never match: leave it out }
    if FXmlConfig.GetValue(P + 'Hash', '') = '' then Continue;
    SetLength(Items, Length(Items) + 1);
    with Items[High(Items)] do
    begin
      Id       := FXmlConfig.GetValue(P + 'Id', '');
      Name     := FXmlConfig.GetValue(P + 'Name', '');
      Hash     := FXmlConfig.GetValue(P + 'Hash', '');
      Hint     := FXmlConfig.GetValue(P + 'Hint', '');
      Created  := StrToInt64Def(FXmlConfig.GetValue(P + 'Created', ''), 0);
      LastUsed := StrToInt64Def(FXmlConfig.GetValue(P + 'LastUsed', ''), 0);
    end;
  end;
  FClientTokens.SetItems(Items);
end;

procedure TMcpIdeSettings.SaveTokens;
var
  Items : TMcpClientTokens;
  I     : Integer;
  P     : string;
begin
  Items := FClientTokens.Items;
  FXmlConfig.DeletePath('Tokens');
  if Length(Items) = 0 then Exit;
  FXmlConfig.SetValue('Tokens/Count', Length(Items));
  for I := 0 to High(Items) do
  begin
    P := 'Tokens/Item' + IntToStr(I + 1) + '/';
    FXmlConfig.SetValue(P + 'Id',       Items[I].Id);
    FXmlConfig.SetValue(P + 'Name',     Items[I].Name);
    FXmlConfig.SetValue(P + 'Hash',     Items[I].Hash);
    FXmlConfig.SetValue(P + 'Hint',     Items[I].Hint);
    FXmlConfig.SetValue(P + 'Created',  IntToStr(Items[I].Created));
    FXmlConfig.SetValue(P + 'LastUsed', IntToStr(Items[I].LastUsed));
  end;
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
    FWinTerminal      := FXmlConfig.GetValue('Claude/WinTerminal', 'default');
    FWinTerminalCustom := FXmlConfig.GetValue('Claude/WinTerminalCustom', '');
    FGitPath          := FXmlConfig.GetValue('Tools/GitPath', '');
    FAllowPackageInstall := FXmlConfig.GetValue('Security/AllowPackageInstall', False);
    { the logging section; the file switch was Tools/ToolCallLog before 1.2 }
    FToolCallLog         := FXmlConfig.GetValue('Logging/ToolCallLog',
                              FXmlConfig.GetValue('Tools/ToolCallLog', False));
    FToolLogFile         := FXmlConfig.GetValue('Logging/ToolCallLogFile', '');
    FToolLogPane         := FXmlConfig.GetValue('Logging/ToolCallPane', False);
    LoadTokens;
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
    FXmlConfig.SetValue('Claude/WinTerminal',      FWinTerminal);
    FXmlConfig.SetValue('Claude/WinTerminalCustom', FWinTerminalCustom);
    FXmlConfig.SetValue('Tools/GitPath',           FGitPath);
    FXmlConfig.SetValue('Security/AllowPackageInstall', FAllowPackageInstall);
    FXmlConfig.SetValue('Logging/ToolCallLog',     FToolCallLog);
    FXmlConfig.SetValue('Logging/ToolCallLogFile', FToolLogFile);
    FXmlConfig.SetValue('Logging/ToolCallPane',    FToolLogPane);
    FXmlConfig.DeleteValue('Tools/ToolCallLog');
    SaveTokens;
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
