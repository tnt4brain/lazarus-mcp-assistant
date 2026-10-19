{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpIdeState;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IDEIntf, Controls, LazFileUtils, FileUtil,
  LazIDEIntf, McpSettingsFile;

type
  { Everything stored in mcpassistantoptions.xml in the primary config
    directory; see McpSettingsFile. }
  TMcpIdeSettings = McpSettingsFile.TMcpIdeSettings;

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
  Relaunch: string;
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
  { if startlazarus does not bring the IDE back, the script starts this one }
  Relaunch := ' "--relaunch=' + ParamStr(0) + '" "--pcp=' +
              ExcludeTrailingPathDelimiter(LazarusIDE.GetPrimaryConfigPath) + '"';
  {$IFDEF WINDOWS}
  Result := 'cmd /c "SET PATH=' + FpcDir + ';%PATH% && "' + PollExe + '" "' +
            PasFile + '" 180 "' + CfgFile + '"' + Relaunch + '"';
  {$ELSE}
  Result := 'sh -c ''PATH="' + FpcDir + ':$PATH" "' + PollExe + '" "' +
            PasFile + '" 180 "' + CfgFile + '"' + Relaunch + '''';
  {$ENDIF}
end;

{ Lifecycle hooks }

procedure InitializeMcpState;
begin
  if not Assigned(McpSettings) then
  begin
    McpSettings := TMcpIdeSettings.Create;
    if Assigned(LazarusIDE) then
      McpSettings.LoadSettings(AppendPathDelim(LazarusIDE.GetPrimaryConfigPath) +
                               'mcpassistantoptions.xml')
    else
      McpSettings.LoadSettings('mcpassistantoptions.xml');
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
