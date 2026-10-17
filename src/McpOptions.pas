{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpOptions;

{ The plugin's page in Tools > Options ("MCP Assistant").  Values live in
  McpSettings (mcpassistantoptions.xml): ReadSettings shows them, OK
  (WriteSettings) stores and saves them, Cancel changes nothing.  Server
  state (token, port, last config path) is not shown. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, StdCtrls, EditBtn, Forms,
  IDEOptionsIntf, IDEOptEditorIntf, MenuIntf;

type
  { Options group; the settings themselves are in McpSettings. }
  TMcpOptionsGroup = class(TAbstractIDEEnvironmentOptions)
  public
    class function GetGroupCaption: string; override;
    class function GetInstance: TAbstractIDEOptions; override;
  end;

  TMcpOptionsFrame = class(TAbstractIDEOptionsEditor)
  private
    FTop             : Integer;
    FClaudeGroup     : TGroupBox;
    FToolsGroup      : TGroupBox;
    FSecurityGroup   : TGroupBox;
    FClaudePath      : TFileNameEdit;
    FWorkDir         : TDirectoryEdit;
    FExtraArgs       : TEdit;
    FTerminal        : TEdit;
    FGitPath         : TFileNameEdit;
    FAllowInstall    : TCheckBox;
    FServerGroup     : TGroupBox;
    FListen          : TEdit;
    FListenNote      : TLabel;
    FFileLabel       : TLabel;
    procedure ListenChanged(Sender: TObject);
    function AddGroup(const ACaption: string): TGroupBox;
    function AddLabel(AParent: TWinControl; const ACaption: string): TLabel;
    procedure Place(AControl: TControl; AParent: TWinControl; ASpaceAfter: Integer = 8);
    procedure UpdateHints;
  public
    constructor Create(AOwner: TComponent); override;
    function GetTitle: string; override;
    procedure Setup(ADialog: TAbstractOptionsEditorDialog); override;
    procedure ReadSettings(AOptions: TAbstractIDEOptions); override;
    procedure WriteSettings(AOptions: TAbstractIDEOptions); override;
    class function SupportedOptionsClass: TAbstractIDEOptionsClass; override;
  end;

var
  McpOptionsGroupIndex : Integer;
  { Tools > MCP Assistant > Allow Assistants to Install Packages }
  McpAllowInstallCmd   : TIDEMenuCommand = nil;

{ Register the page; call from the package's Register. }
procedure RegisterMcpOptionsPage;
{ Make the menu checkmark match McpSettings.AllowPackageInstall. }
procedure McpSyncAllowInstallMenu;

implementation

{$R *.lfm}

uses
  FileUtil,
  McpIdeState, McpLauncher, McpIdeServer, McpUtils;

{ TMcpOptionsGroup }

class function TMcpOptionsGroup.GetGroupCaption: string;
begin
  Result := 'MCP Assistant';
end;

class function TMcpOptionsGroup.GetInstance: TAbstractIDEOptions;
begin
  Result := nil;  { no options object: the frame reads McpSettings }
end;

{ TMcpOptionsFrame }

function TMcpOptionsFrame.AddGroup(const ACaption: string): TGroupBox;
begin
  Result := TGroupBox.Create(Self);
  Result.Caption  := ACaption;
  Result.AutoSize := True;
  Result.ChildSizing.LeftRightSpacing := 8;
  Result.ChildSizing.TopBottomSpacing := 6;
  Result.Align    := alTop;
  Result.BorderSpacing.Bottom := 8;
  Result.Top      := FTop;  { alTop keeps creation order via Top }
  Inc(FTop, 1000);
  Result.Parent   := Self;
end;

function TMcpOptionsFrame.AddLabel(AParent: TWinControl; const ACaption: string): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Caption := ACaption;
  Result.WordWrap := True;
  Place(Result, AParent, 2);
end;

procedure TMcpOptionsFrame.Place(AControl: TControl; AParent: TWinControl;
  ASpaceAfter: Integer);
begin
  AControl.Align := alTop;
  AControl.BorderSpacing.Bottom := ASpaceAfter;
  AControl.Top   := FTop;
  Inc(FTop, 100);
  AControl.Parent := AParent;
end;

constructor TMcpOptionsFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FTop := 0;

  FClaudeGroup := AddGroup('Claude Code (Launch MCP Assistant)');
  AddLabel(FClaudeGroup, 'Claude Code executable (empty: claude on PATH):');
  FClaudePath := TFileNameEdit.Create(Self);
  Place(FClaudePath, FClaudeGroup);
  AddLabel(FClaudeGroup, 'Working directory (empty: the project''s directory):');
  FWorkDir := TDirectoryEdit.Create(Self);
  Place(FWorkDir, FClaudeGroup);
  AddLabel(FClaudeGroup, 'Extra command-line options (space-separated), ' +
                         'e.g. --model claude-opus-5-5:');
  FExtraArgs := TEdit.Create(Self);
  Place(FExtraArgs, FClaudeGroup);
  {$IFDEF WINDOWS}
  AddLabel(FClaudeGroup, 'Terminal (Linux/macOS only; Windows opens a new console):');
  {$ELSE}
  AddLabel(FClaudeGroup, 'Terminal command, before "sh <script>" ' +
                         '(empty: detect), e.g. gnome-terminal -- or kitty -e:');
  {$ENDIF}
  FTerminal := TEdit.Create(Self);
  Place(FTerminal, FClaudeGroup);
  {$IFDEF WINDOWS}
  FTerminal.Enabled := False;
  {$ENDIF}

  FToolsGroup := AddGroup('Tools');
  AddLabel(FToolsGroup, 'git executable (empty: git on PATH):');
  FGitPath := TFileNameEdit.Create(Self);
  Place(FGitPath, FToolsGroup);

  FServerGroup := AddGroup('Server');
  AddLabel(FServerGroup, 'Listen on this IPv4 address (127.0.0.1: this machine only; ' +
                         '0.0.0.0: every interface):');
  FListen := TEdit.Create(Self);
  FListen.OnChange := @ListenChanged;
  Place(FListen, FServerGroup);
  FListenNote := AddLabel(FServerGroup, '');

  FSecurityGroup := AddGroup('Security');
  FAllowInstall := TCheckBox.Create(Self);
  FAllowInstall.Caption := 'Allow assistants to install packages ' +
                           '(each install is still shown to you for confirmation)';
  Place(FAllowInstall, FSecurityGroup, 2);

  FFileLabel := TLabel.Create(Self);
  FFileLabel.Align := alTop;
  FFileLabel.Top   := FTop;
  FFileLabel.Parent := Self;
end;

procedure TMcpOptionsFrame.ListenChanged(Sender: TObject);
var
  A: string;
begin
  A := Trim(FListen.Text);
  if not McpValidListenAddress(A) then
    FListenNote.Caption := 'Not an IPv4 address: the change is not saved.'
  else if McpIsLoopback(A) then
    FListenNote.Caption := 'Only programs on this machine can connect. Applied when OK is pressed.'
  else
    FListenNote.Caption := 'Warning: other machines can connect. Everyone who has the token ' +
      'can drive this IDE (edit files, run programs), and the connection is not encrypted: ' +
      'use it on a network you trust, or tunnel it (ssh -L). Applied when OK is pressed.';
end;

function TMcpOptionsFrame.GetTitle: string;
begin
  Result := 'General';
end;

procedure TMcpOptionsFrame.Setup(ADialog: TAbstractOptionsEditorDialog);
begin
end;

{ Grey text in an empty field: what is used when the field stays empty. }
function FoundOnPath(const AExe: string): string;
begin
  Result := FindDefaultExecutablePath(AExe);
  if Result <> '' then
    Result := Result + '  (from PATH)'
  else
    Result := AExe + ' is not on PATH: enter its full path';
end;

procedure TMcpOptionsFrame.UpdateHints;
{$IFNDEF WINDOWS}
var
  Argv : TStringList;
{$ENDIF}
begin
  FClaudePath.TextHint := FoundOnPath('claude');
  if Assigned(McpProject) and (McpProject.GetProjectDirectory <> '') then
    FWorkDir.TextHint := McpProject.GetProjectDirectory + '  (the project''s directory)'
  else
    FWorkDir.TextHint := 'the open project''s directory';
  FExtraArgs.TextHint := 'none';
  {$IFDEF WINDOWS}
  FTerminal.TextHint := 'not used on Windows';
  {$ELSE}
  Argv := TStringList.Create;
  try
    if McpTerminalArgs('', 'script', GetEnvironmentVariable('PATH'),
         {$IFDEF DARWIN}True{$ELSE}False{$ENDIF}, Argv) then
    begin
      {$IFDEF DARWIN}
      FTerminal.TextHint := 'Terminal.app';
      {$ELSE}
      FTerminal.TextHint := Argv[0] + ' ' + Argv[1] + '  (detected)';
      {$ENDIF}
    end
    else
      FTerminal.TextHint := 'no terminal found: enter one, e.g. kitty -e';
  finally
    Argv.Free;
  end;
  {$ENDIF}
  FGitPath.TextHint := FoundOnPath('git');
end;

procedure TMcpOptionsFrame.ReadSettings(AOptions: TAbstractIDEOptions);
begin
  if not Assigned(McpSettings) then Exit;
  UpdateHints;
  FClaudePath.Text     := McpSettings.ClaudePath;
  FWorkDir.Text        := McpSettings.WorkingDirectory;
  FExtraArgs.Text      := McpSettings.ExtraClaudeArgs;
  FTerminal.Text       := McpSettings.TerminalCommand;
  FGitPath.Text        := McpSettings.GitPath;
  FAllowInstall.Checked := McpSettings.AllowPackageInstall;
  FListen.Text         := McpSettings.ListenAddress;
  ListenChanged(nil);
  FFileLabel.Caption   := 'Stored in ' + McpSettings.ConfigFileName;
end;

procedure TMcpOptionsFrame.WriteSettings(AOptions: TAbstractIDEOptions);
var
  Addr: string;
begin
  if not Assigned(McpSettings) then Exit;
  Addr := Trim(FListen.Text);
  if McpValidListenAddress(Addr) and (Addr <> McpSettings.ListenAddress) then
  begin
    McpSettings.ListenAddress := Addr;
    McpSettings.SaveSettings;
    { the server listens on the new address from now on; clients reconnect }
    if IsServerRunning then
    begin
      FinalizeMcpServer;
      InitializeMcpServer;
    end;
  end;
  McpSettings.ClaudePath          := Trim(FClaudePath.Text);
  McpSettings.WorkingDirectory    := Trim(FWorkDir.Text);
  McpSettings.ExtraClaudeArgs     := Trim(FExtraArgs.Text);
  McpSettings.TerminalCommand     := Trim(FTerminal.Text);
  McpSettings.GitPath             := Trim(FGitPath.Text);
  McpSettings.AllowPackageInstall := FAllowInstall.Checked;
  McpSettings.SaveSettings;
  McpSyncAllowInstallMenu;
end;

class function TMcpOptionsFrame.SupportedOptionsClass: TAbstractIDEOptionsClass;
begin
  Result := nil;
end;

{ Registration }

procedure RegisterMcpOptionsPage;
begin
  RegisterIDEOptionsEditor(McpOptionsGroupIndex, TMcpOptionsFrame, 1);
end;

procedure McpSyncAllowInstallMenu;
begin
  if Assigned(McpAllowInstallCmd) and Assigned(McpSettings) then
    McpAllowInstallCmd.Checked := McpSettings.AllowPackageInstall;
end;

initialization
  McpOptionsGroupIndex := GetFreeIDEOptionsGroupIndex(GroupEditor);
  RegisterIDEOptionsGroup(McpOptionsGroupIndex, TMcpOptionsGroup, False);
end.
