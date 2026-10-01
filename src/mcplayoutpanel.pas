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
  LazLogger, Process;

{ Called from the menu: starts the MCP server (if needed) and spawns claude. }
procedure LaunchMcpAssistant(Sender: TObject);
var
  ConfigPath : string;
  Proc       : TProcess;
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

  Proc := TProcess.Create(nil);
  try
    Proc.Executable := 'claude';
    Proc.Parameters.Add('--mcp-config');
    Proc.Parameters.Add(ConfigPath);
    Proc.Parameters.Add('--strict-mcp-config');
    Proc.Options        := [poNewConsole];
    Proc.InheritHandles := False; // prevent MCP listening socket inheritance
    if Assigned(McpProject) and (McpProject.GetProjectDirectory <> '') then
      Proc.CurrentDirectory := McpProject.GetProjectDirectory;
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
    if not IsServerRunning then
      InitializeMcpServer;
  except
    on E: Exception do
      DebugLn('[MCP Assistant] Auto-start error: ' + E.ClassName + ': ' + E.Message);
  end;
  Free;
end;

procedure Register;
begin
  DebugLn('[MCP Assistant] Registering...');
  try
    InitializeMcpState;
    InitializeIdeHooks;
    RegisterChatPanel;
    RegisterIDECloseHook;
    // Defer auto-start until after the IDE message loop is running
    if McpSettings.ServerToken <> '' then
      Application.QueueAsyncCall(@TMcpAutoStarter.Create.Run, 0);
    RegisterIDEMenuCommand(
      itmSecondaryTools,
      'LaunchMcpAssistant',
      'Launch MCP Assistant',
      nil,
      @LaunchMcpAssistant);
    DebugLn('[MCP Assistant] Registered successfully.');
  except
    on E: Exception do
      DebugLn('[MCP Assistant] Registration error: ' + E.ClassName +
        ': ' + E.Message);
  end;
end;

end.
