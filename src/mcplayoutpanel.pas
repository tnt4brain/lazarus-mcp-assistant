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
  LazLogger, Clipbrd,
  McpToolsProject, McpDebugGuard, McpLauncher, McpOptions, McpTokensOptions, McpRefKeeper,
  McpExceptionLog, McpMarkdownView, McpReviewView, McpReviewFlow;

{ Called from the menu: makes a named token for a client on another machine and puts
  the config for it on the clipboard (ADR-021).  The primary token is never copied. }
{ menu handlers: the signature is fixed by the IDE, Sender is not needed }
{$PUSH}{$WARN 5024 OFF}
procedure CopyMcpConfigToClipboard(Sender: TObject);
begin
  if not IsServerRunning then
  begin
    ShowMessage('The MCP server is not running. Start it first via ' +
                'Tools → MCP Assistant → Start MCP Server (or Launch MCP Assistant).');
    Exit;
  end;
  McpCreateClientToken;
end;
{$POP}

{ Where the running server is, for the messages }
function McpServerAddress: string;
begin
  Result := Format('http://%s:%d/mcp', [GetServerHost, GetServerPort]);
end;

{ Called from the menu: starts the MCP server and no client.  For an assistant that
  is started some other way (OpenCode, Pi, a remote machine ...). }
{ menu handlers: the signature is fixed by the IDE, Sender is not needed }
{$PUSH}{$WARN 5024 OFF}
procedure StartMcpServer(Sender: TObject);
var
  Started : Boolean;
  Msg     : string;
begin
  Started := not IsServerRunning;
  if Started then
    InitializeMcpServer;
  if not IsServerRunning then
  begin
    ShowMessage('MCP server failed to start. Check the IDE log for details.');
    Exit;
  end;
  if Started then
    Msg := 'The MCP server is running at ' + McpServerAddress + '.'
  else
    Msg := 'The MCP server was already running at ' + McpServerAddress + '.';
  ShowMessage(Msg + LineEnding + LineEnding +
              'To connect an assistant, use Tools → MCP Assistant → ' +
              'Copy Server Config to Clipboard...: it makes a token and copies the ' +
              'config. The format is Claude Code''s (mcpServers); for another assistant ' +
              'take the url and the Authorization header from it.');
end;
{$POP}

{ Called from the menu: starts the MCP server (if needed) and spawns the assistant
  that is set up (claude unless the options say otherwise). }
{ menu handlers: the signature is fixed by the IDE, Sender is not needed }
{$PUSH}{$WARN 5024 OFF}
procedure LaunchMcpAssistant(Sender: TObject);
var
  ConfigPath : string;
  WorkDir    : string;
  Req        : TMcpLaunchRequest;
  Err        : string;
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

  Req := Default(TMcpLaunchRequest);
  Req.ClaudeExe       := '';
  Req.ConfigArgs      := MCP_DEFAULT_CONFIG_ARGS;
  Req.ExtraArgs       := '';
  Req.TerminalCommand := '';
  if Assigned(McpSettings) then
  begin
    Req.ClaudeExe       := McpSettings.ClaudePath;
    Req.ConfigArgs      := McpSettings.ConfigArgs;
    Req.ExtraArgs       := McpSettings.ExtraClaudeArgs;
    Req.TerminalCommand := McpSettings.TerminalCommand;
    Req.WinTerminal     := McpSettings.WinTerminal;
    Req.WinCustom       := McpSettings.WinTerminalCustom;
  end;
  Req.WorkDir       := WorkDir;
  { Windows: open the terminal on the monitor of the IDE's main window }
  if Assigned(Application.MainForm) and Application.MainForm.HandleAllocated then
    with Screen.MonitorFromWindow(Application.MainForm.Handle).WorkareaRect do
    begin
      Req.HasPos := True;
      Req.PosX   := Left + 60;
      Req.PosY   := Top + 60;
    end;
  Req.McpConfigPath := ConfigPath;
  Err := McpLaunchClaude(Req);
  if Err = '' then
    DebugLn('[MCP Assistant] Launched claude with config: ' + ConfigPath)
  else
    { the server is up by now: only the assistant could not be started }
    ShowMessage(Err + LineEnding + LineEnding +
      'The MCP server is running at ' + McpServerAddress + '; only the assistant ' +
      'could not be started. Its executable, arguments and the terminal are set in ' +
      'Tools > Options > MCP Assistant. Another assistant can connect to the ' +
      'running server: see Tools > MCP Assistant > Copy Server Config to Clipboard...');
end;
{$POP}

{ Called from the menu: the bug-report bundle (ADR-022, Amendment 1), as ide_report does. }
{ menu handlers: the signature is fixed by the IDE, Sender is not needed }
{$PUSH}{$WARN 5024 OFF}
procedure WriteMcpReport(Sender: TObject);
var
  Path, Err : string;
begin
  if McpWriteReport(Path, Err) then
    ShowMessage('Report written to' + LineEnding + Path + LineEnding + LineEnding +
                'Read it before you post it: paths and error texts can hold names.')
  else
    ShowMessage('Could not write the report: ' + Err);
end;
{$POP}

{ Called from the menu: the options dialog with only our pages.  The filter
  must name the group: without one the IDE filters by the frame's
  SupportedOptionsClass, which is nil here, and the dialog came up empty. }
{ menu handlers: the signature is fixed by the IDE, Sender is not needed }
{$PUSH}{$WARN 5024 OFF}
procedure OpenMcpOptions(Sender: TObject);
begin
  LazarusIDE.DoOpenIDEOptions(TMcpOptionsFrame, 'MCP Assistant Options',
    [TMcpOptionsGroup], []);
end;
{$POP}

{ Called from the menu: toggles whether assistants may install packages that
  are not installed yet (each install is still confirmed; ADR-013). }
{ menu handlers: the signature is fixed by the IDE, Sender is not needed }
{$PUSH}{$WARN 5024 OFF}
procedure ToggleAllowPackageInstall(Sender: TObject);
begin
  if not Assigned(McpSettings) then Exit;
  McpSettings.AllowPackageInstall := not McpSettings.AllowPackageInstall;
  McpSettings.SaveSettings;
  McpSyncAllowInstallMenu;
end;
{$POP}

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

{ the IDE's form-creator callback: the signature is fixed, Sender is not needed }
{$PUSH}{$WARN 5024 OFF}
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
{$POP}

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

{ QueueAsyncCall fixes the signature; Data is not needed here }
{$PUSH}{$WARN 5024 OFF}
procedure TMcpAutoStarter.Run(Data: PtrInt);
begin
  try
    McpEnsureDebugGuard;  { DebugBoss exists once the message loop runs }
    if (McpSettings.ServerToken <> '') and not IsServerRunning then
      InitializeMcpServer;
  except
    on E: Exception do
    begin
      DebugLn('[MCP Assistant] Auto-start error: ' + E.ClassName + ': ' + E.Message);
      { the IDE's debug output is gone in a GUI program: mcp-exceptions.log keeps the reason }
      McpLogException(E);
    end;
  end;
  Free;
end;
{$POP}

procedure Register;
var
  McpMenu: TIDEMenuSection;
begin
  DebugLn('[MCP Assistant] Registering...');
  try
    InitializeMcpState;
    InitializeIdeHooks;
    InitializeRefKeeper;
    InitializeExceptionLog;
    RegisterChatPanel;
    RegisterMarkdownWindow;
    RegisterReviewWindow;
    RegisterIDECloseHook;
    // Defer auto-start (and the debugger guard) until after the IDE message
    // loop is running
    Application.QueueAsyncCall(@TMcpAutoStarter.Create.Run, 0);
    McpMenu := RegisterIDESubMenu(itmSecondaryTools, 'McpAssistantMenu', 'MCP Assistant');
    RegisterIDEMenuCommand(
      McpMenu, 'LaunchMcpAssistant', 'Launch MCP Assistant',
      nil, @LaunchMcpAssistant);
    RegisterIDEMenuCommand(
      McpMenu, 'StartMcpServer', 'Start MCP Server (no assistant)',
      nil, @StartMcpServer);
    { the Markdown viewer for the user's own files: README, ADRs, docs }
    RegisterIDEMenuCommand(
      McpMenu, 'McpViewMarkdown', 'View Markdown...',
      nil, @McpMarkdownViewActive);
    RegisterIDEMenuCommand(
      itmViewIDEInternalsWindows, 'McpViewMarkdownWin', 'Markdown Viewer...',
      nil, @McpMarkdownViewActive);
    RegisterIDEMenuCommand(
      SourceEditorMenuRoot, 'McpViewMarkdownEditor', 'View as Markdown',
      nil, @McpMarkdownViewActive);
    RegisterIDEMenuCommand(
      McpMenu, 'McpReviewActive', 'Review Active File Against Disk...',
      nil, @McpReviewActiveEditor);
    RegisterIDEMenuSection(McpMenu, 'McpSep1');
    RegisterIDEMenuCommand(
      McpMenu, 'McpOptions', 'Options...',
      nil, @OpenMcpOptions);
    McpAllowInstallCmd := RegisterIDEMenuCommand(
      McpMenu, 'AllowPackageInstall', 'Allow Assistants to Install Packages',
      nil, @ToggleAllowPackageInstall);
    McpAllowInstallCmd.ShowAlwaysCheckable := True;
    McpSyncAllowInstallMenu;
    RegisterMcpOptionsPage;
    RegisterIDEMenuCommand(
      McpMenu, 'McpWriteReport', 'Write Report',
      nil, @WriteMcpReport);
    RegisterIDEMenuSection(McpMenu, 'McpSep2');
    RegisterIDEMenuCommand(
      McpMenu, 'CopyMcpConfig', 'Copy Server Config to Clipboard...',
      nil, @CopyMcpConfigToClipboard);
    DebugLn('[MCP Assistant] Registered successfully.');
  except
    on E: Exception do
      DebugLn('[MCP Assistant] Registration error: ' + E.ClassName +
        ': ' + E.Message);
  end;
end;

end.
