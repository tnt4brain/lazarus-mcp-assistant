{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpIdeState;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Laz2_XMLCfg, IDEIntf, Controls, LazFileUtils, FileUtil,
  LazIDEIntf;

type
  { Everything stored in mcpassistantoptions.xml in the primary config
    directory.  The user-facing part is edited on the Tools > Options page
    (McpOptions); Token, Port and LastConfigPath are server state. }
  TMcpIdeSettings = class
  private
    FXmlConfig: TXMLConfig;
    FServerToken: string;
    FServerPort: Word;
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
    procedure LoadSettings;
    procedure SaveSettings;

    property ConfigFileName: string read GetConfigFileName;
    property ServerToken: string read FServerToken write FServerToken;
    property ServerPort: Word read FServerPort write FServerPort;
    property LastConfigPath: string read FLastConfigPath write FLastConfigPath;
    property ClaudePath: string read FClaudePath write FClaudePath;
    property WorkingDirectory: string read FWorkingDirectory write FWorkingDirectory;
    property ExtraClaudeArgs: string read FExtraClaudeArgs write FExtraClaudeArgs;
    property TerminalCommand: string read FTerminalCommand write FTerminalCommand;
    property GitPath: string read FGitPath write FGitPath;
    property AllowPackageInstall: Boolean read FAllowPackageInstall write FAllowPackageInstall;
  end;

  TMcpProjectState = class
  public
     BerryConfigPath: string;
    function GetProjectDirectory: string;
    function GetTargetOSAndCPU: string;
    function IsProjectOpen: Boolean;
  end;

var
  McpSettings: TMcpIdeSettings = nil;
  McpProject: TMcpProjectState = nil;

procedure InitializeMcpState;
procedure FinalizeMcpState;

{ git executable: the configured path, else git on PATH; '' if neither. }
function McpGitExecutable: string;

{ Shell command that waits until the restarted IDE answers: instantfpc runs
  wait_for_restart.pas from the parent of ALpkPath's directory, or of the
  installed plugin's when ALpkPath is ''.  '' if the script is not found.
  Main thread. }
function McpPollCommand(const ALpkPath: string = ''): string;

implementation

uses
  PackageIntf;

{ TMcpIdeSettings }

constructor TMcpIdeSettings.Create;
begin
  inherited Create;
  FXmlConfig := TXMLConfig.Create(nil);
  // FIXED: Constructor is now 100% passive. It does not look up LazarusIDE path options on boot!
end;

destructor TMcpIdeSettings.Destroy;
begin
  FXmlConfig.Free;
  inherited Destroy;
end;

procedure TMcpIdeSettings.LoadDefaultSettings;
begin
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

procedure TMcpIdeSettings.LoadSettings;
begin
  if Assigned(LazarusIDE) then
    FXmlConfig.Filename := AppendPathDelim(LazarusIDE.GetPrimaryConfigPath) + 'mcpassistantoptions.xml'
  else
    FXmlConfig.Filename := 'mcpassistantoptions.xml';

  if not FileExists(FXmlConfig.Filename) then
  begin
    LoadDefaultSettings;
    Exit;
  end;

  try
    FServerToken      := FXmlConfig.GetValue('Server/Token', '');
    FServerPort       := FXmlConfig.GetValue('Server/Port', 0);
    FLastConfigPath   := FXmlConfig.GetValue('Server/LastConfigPath', '');
    FClaudePath       := FXmlConfig.GetValue('Claude/Path', '');
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

{ TMcpProjectState }

function TMcpProjectState.IsProjectOpen: Boolean;
begin
  Result := Assigned(LazarusIDE) and Assigned(LazarusIDE.ActiveProject) and
            (LazarusIDE.ActiveProject.ProjectInfoFile <> '');
end;

function TMcpProjectState.GetProjectDirectory: string;
begin
  if IsProjectOpen then
    Result := ExtractFileDir(LazarusIDE.ActiveProject.ProjectInfoFile)
  else
    Result := '';
end;

function TMcpProjectState.GetTargetOSAndCPU: string;
begin
  if IsProjectOpen then
    Result := LazarusIDE.GetFPCFrontEndOptions
  else
    Result := 'unknown-unknown';
end;

{ Helpers }

function McpGitExecutable: string;
begin
  Result := '';
  if Assigned(McpSettings) then
    Result := McpSettings.GitPath;
  if Result = '' then
    Result := FindDefaultExecutablePath('git');
end;

function McpPollCommand(const ALpkPath: string): string;
var
  IDEPkg  : TIDEPackage;
  LpkPath : string;
  FpcDir  : string;
  PollExe : string;
  PasFile : string;
  CfgFile : string;
begin
  Result  := '';
  PasFile := '';
  if ALpkPath <> '' then
    PasFile := ExtractFilePath(ExcludeTrailingPathDelimiter(
                 ExtractFilePath(ALpkPath))) + 'wait_for_restart.pas';
  if not FileExists(PasFile) then
  begin
    IDEPkg := PackageEditingInterface.FindPackageWithName('LazMcpAssistant');
    if not Assigned(IDEPkg) then Exit;
    LpkPath := IDEPkg.Filename;
    PasFile := ExtractFilePath(ExcludeTrailingPathDelimiter(
                 ExtractFilePath(LpkPath))) + 'wait_for_restart.pas';
    if not FileExists(PasFile) then Exit;
  end;
  FpcDir  := ExtractFilePath(LazarusIDE.GetFPCompilerFilename);
  PollExe := FpcDir + 'instantfpc' + GetExeExt;
  FpcDir  := ExcludeTrailingPathDelimiter(FpcDir);
  if Assigned(McpSettings) then
    CfgFile := McpSettings.ConfigFileName
  else
    CfgFile := '';
  {$IFDEF WINDOWS}
  Result := 'cmd /c "SET PATH=' + FpcDir + ';%PATH% && "' + PollExe + '" "' +
            PasFile + '" 180 "' + CfgFile + '""';
  {$ELSE}
  Result := 'sh -c ''PATH="' + FpcDir + ':$PATH" "' + PollExe + '" "' +
            PasFile + '" 180 "' + CfgFile + '"''';
  {$ENDIF}
end;

{ Lifecycle hooks }

procedure InitializeMcpState;
begin
  if not Assigned(McpSettings) then
  begin
    McpSettings := TMcpIdeSettings.Create;
    McpSettings.LoadSettings;
  end;
  if not Assigned(McpProject) then
    McpProject := TMcpProjectState.Create;
end;

procedure FinalizeMcpState;
begin
  if Assigned(McpSettings) then
  begin
    McpSettings.SaveSettings;
    FreeAndNil(McpSettings);
  end;
  if Assigned(McpProject) then
    FreeAndNil(McpProject);
end;

initialization
finalization
  FinalizeMcpState;
end.
