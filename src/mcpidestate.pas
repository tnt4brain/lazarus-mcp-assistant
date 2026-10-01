{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpIdeState;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Laz2_XMLCfg, IDEIntf, Controls, LazFileUtils, LazIDEIntf;

type
  TMcpIdeSettings = class
  private
    FXmlConfig: TXMLConfig;
    FExecutablePath: string;
    FArguments: string;
    FQuietMode: Boolean;
    FApiKey: string;
    FModel: string;
    procedure LoadDefaultSettings;
  public
    constructor Create;
    destructor Destroy; override;
    procedure LoadSettings;
    procedure SaveSettings;

    property ExecutablePath: string read FExecutablePath write FExecutablePath;
    property Arguments: string read FArguments write FArguments;
    property QuietMode: Boolean read FQuietMode write FQuietMode;
    property ApiKey: string read FApiKey write FApiKey;
    property Model: string read FModel write FModel;
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

implementation

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
  FExecutablePath := '/usr/local/bin/mcp-server';
  FArguments := 'run';
  FQuietMode := False;
  FApiKey := '';
  FModel  := 'claude-opus-5-5';
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
    FExecutablePath := FXmlConfig.GetValue('Server/ExecutablePath', '/usr/local/bin/mcp-server');
    FArguments      := FXmlConfig.GetValue('Server/Arguments', 'run');
    FQuietMode      := FXmlConfig.GetValue('System/QuietMode', False);
    FApiKey         := FXmlConfig.GetValue('Claude/ApiKey', '');
    FModel          := FXmlConfig.GetValue('Claude/Model', 'claude-opus-5-5');
    if FModel = '' then FModel := 'claude-opus-5-5';
  except
    LoadDefaultSettings;
  end;
end;

procedure TMcpIdeSettings.SaveSettings;
begin
  if FXmlConfig.Filename = '' then Exit;
  try
    FXmlConfig.SetValue('Server/ExecutablePath', FExecutablePath);
    FXmlConfig.SetValue('Server/Arguments',      FArguments);
    FXmlConfig.SetValue('System/QuietMode',      FQuietMode);
    FXmlConfig.SetValue('Claude/ApiKey',         FApiKey);
    FXmlConfig.SetValue('Claude/Model',          FModel);
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
