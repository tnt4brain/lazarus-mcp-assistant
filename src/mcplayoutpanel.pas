{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpLayoutPanel;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  SrcEditorIntf, fpjson, LazIDEIntf, IDEWindowIntf, MenuIntf,
  McpIdeListeners, McpIdeState, McpIdeServer;

type
  TMcpChatForm = class(TForm)
    btnSend:    TButton;
    memChatLog: TMemo;
    memPrompt:  TMemo;
    pnlBottom:  TPanel;
    procedure btnSendClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
  end;

var
  McpChatForm: TMcpChatForm = nil;

procedure Register;
procedure RegisterChatPanel;

implementation

{$R *.lfm}

uses
  LazLogger, Process, Clipbrd,
  McpToolsProject, McpDebugGuard;

{ Called from the menu: copies the current MCP server config JSON to the clipboard. }
procedure CopyMcpConfigToClipboard(Sender: TObject);
var
  Port   : Word;
  Token  : string;
  Config : TJSONObject;
  Server : TJSONObject;
  Headers: TJSONObject;
  Servers: TJSONObject;
begin
  if not IsServerRunning then
  begin
    ShowMessage('MCP server is not running. Launch it first via ' +
                'Tools → Secondary Tools → Launch MCP Assistant.');
    Exit;
  end;
  Port  := GetServerPort;
  Token := GetServerToken;
  if (Port = 0) or (Token = '') then
  begin
    ShowMessage('Server port or token not available yet. Try again in a moment.');
    Exit;
  end;
  Headers := TJSONObject.Create;
  Headers.Add('Authorization', 'Bearer ' + Token);
  Server := TJSONObject.Create;
  Server.Add('type',    'http');
  Server.Add('url',     Format('http://127.0.0.1:%d/mcp', [Port]));
  Server.Add('headers', Headers);
  Servers := TJSONObject.Create;
  Servers.Add('lazarus-ide', Server);
  Config := TJSONObject.Create;
  try
    Config.Add('mcpServers', Servers);
    Clipboard.AsText := Config.FormatJSON;
    ShowMessage('MCP config copied to clipboard.' + LineEnding +
                'Paste it into your .mcp.json or claude_desktop_config.json.');
  finally
    Config.Free;
  end;
end;

{ Called from the menu: starts the MCP server (if needed) and spawns claude. }
procedure LaunchMcpAssistant(Sender: TObject);
var
  ConfigPath : string;
  WorkDir    : string;
  ExtraArgs  : TStringList;
  Proc       : TProcess;
  I          : Integer;
begin
  if not IsServerRunning then
  begin
    InitializeMcpServer;
    if not IsServerRunning then
    begin
      ShowMessage('MCP server failed to start. Check the IDE log for details.');
      Exit;
    end;
  end;

  ConfigPath := WriteMcpConfig;
  if ConfigPath = '' then
  begin
    ShowMessage('Could not write MCP config file.');
    Exit;
  end;

  // Working directory: explicit override > open project dir > empty
  if Assigned(McpSettings) and (McpSettings.WorkingDirectory <> '') then
    WorkDir := McpSettings.WorkingDirectory
  else if Assigned(McpProject) then
    WorkDir := McpProject.GetProjectDirectory
  else
    WorkDir := '';

  Proc := TProcess.Create(nil);
  try
    Proc.Executable := 'claude';
    Proc.Parameters.Add('--mcp-config');
    Proc.Parameters.Add(ConfigPath);
    Proc.Parameters.Add('--strict-mcp-config');
    Proc.Parameters.Add('--append-system-prompt');
    Proc.Parameters.Add(GetSystemPromptText);
    // Extra user-specified CLI args (space-separated)
    if Assigned(McpSettings) and (Trim(McpSettings.ExtraClaudeArgs) <> '') then
    begin
      ExtraArgs := TStringList.Create;
      try
        ExtraArgs.Delimiter     := ' ';
        ExtraArgs.DelimitedText := McpSettings.ExtraClaudeArgs;
        for I := 0 to ExtraArgs.Count - 1 do
          if Trim(ExtraArgs[I]) <> '' then
            Proc.Parameters.Add(ExtraArgs[I]);
      finally
        ExtraArgs.Free;
      end;
    end;
    Proc.Options        := [poNewConsole];
    Proc.InheritHandles := False; // prevent MCP listening socket inheritance
    if WorkDir <> '' then
      Proc.CurrentDirectory := WorkDir;
    try
      Proc.Execute;
      DebugLn('[MCP Assistant] Launched claude with config: ' + ConfigPath);
    except
      on E: Exception do
        ShowMessage('Could not launch claude: ' + E.Message +
          LineEnding + 'Make sure "claude" is in your PATH.');
    end;
  finally
    Proc.Free;
  end;
end;

{ Called from the menu: lets user pick a working directory override for claude. }
procedure SetWorkingDirectory(Sender: TObject);
var
  Dir: string;
begin
  if Assigned(McpSettings) then
    Dir := McpSettings.WorkingDirectory
  else
    Dir := '';
  if SelectDirectory('Select default working directory for Claude', '', Dir) then
  begin
    McpSettings.WorkingDirectory := Dir;
    McpSettings.SaveSettings;
  end;
end;

{ Called from the menu: lets user set extra CLI args appended to the claude launch. }
procedure SetExtraCliOptions(Sender: TObject);
var
  Args: string;
begin
  if Assigned(McpSettings) then
    Args := McpSettings.ExtraClaudeArgs
  else
    Args := '';
  if InputQuery('Extra Claude CLI Options',
    'Additional arguments passed to claude (space-separated):' + LineEnding +
    'Example: --verbose --model claude-opus-5-5',
    Args) then
  begin
    McpSettings.ExtraClaudeArgs := Trim(Args);
    McpSettings.SaveSettings;
  end;
end;

{ ── Form ─────────────────────────────────────────────────────────────────── }

constructor TMcpChatForm.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Name    := 'McpChatFormID';
  Caption := 'MCP Assistant';
end;

procedure TMcpChatForm.btnSendClick(Sender: TObject);
begin
  LaunchMcpAssistant(Sender);
end;

{ ── Window creator callback ───────────────────────────────────────────────── }

procedure CreateMcpChatForm(Sender: TObject; aFormName: string;
  var AForm: TCustomForm; DoDisableAutoSizing: boolean);
begin
  if CompareText(aFormName, 'McpChatFormID') = 0 then
  begin
    IDEWindowCreators.CreateForm(AForm, TMcpChatForm, DoDisableAutoSizing,
      Application);
    AForm.Name := aFormName;
  end;
end;

procedure RegisterChatPanel;
begin
  if Assigned(IDEWindowCreators) then
    IDEWindowCreators.Add(
      'McpChatFormID',
      @CreateMcpChatForm,
      nil,
      '', '', '', '',
      '',
      alNone,
      False
    );
end;

{ ── Package registration ──────────────────────────────────────────────────── }

type
  TMcpAutoStarter = class
    procedure Run(Data: PtrInt);
  end;

procedure TMcpAutoStarter.Run(Data: PtrInt);
begin
  try
    McpEnsureDebugGuard;  { DebugBoss exists once the message loop runs }
    if (McpSettings.ServerToken <> '') and not IsServerRunning then
      InitializeMcpServer;
  except
    on E: Exception do
      DebugLn('[MCP Assistant] Auto-start error: ' + E.ClassName + ': ' + E.Message);
  end;
  Free;
end;

procedure Register;
var
  McpMenu: TIDEMenuSection;
begin
  DebugLn('[MCP Assistant] Registering...');
  try
    InitializeMcpState;
    InitializeIdeHooks;
    RegisterChatPanel;
    RegisterIDECloseHook;
    // Defer auto-start (and the debugger guard) until after the IDE message
    // loop is running
    Application.QueueAsyncCall(@TMcpAutoStarter.Create.Run, 0);
    McpMenu := RegisterIDESubMenu(itmSecondaryTools, 'McpAssistantMenu', 'MCP Assistant');
    RegisterIDEMenuCommand(
      McpMenu, 'LaunchMcpAssistant', 'Launch MCP Assistant',
      nil, @LaunchMcpAssistant);
    RegisterIDEMenuSection(McpMenu, 'McpSep1');
    RegisterIDEMenuCommand(
      McpMenu, 'SetWorkDir', 'Set Working Directory...',
      nil, @SetWorkingDirectory);
    RegisterIDEMenuCommand(
      McpMenu, 'SetExtraArgs', 'Extra CLI Options...',
      nil, @SetExtraCliOptions);
    RegisterIDEMenuSection(McpMenu, 'McpSep2');
    RegisterIDEMenuCommand(
      McpMenu, 'CopyMcpConfig', 'Copy Server Config to Clipboard',
      nil, @CopyMcpConfigToClipboard);
    DebugLn('[MCP Assistant] Registered successfully.');
  except
    on E: Exception do
      DebugLn('[MCP Assistant] Registration error: ' + E.ClassName +
        ': ' + E.Message);
  end;
end;

end.
