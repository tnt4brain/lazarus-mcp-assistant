{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpIdeListeners;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, IDEIntf, SrcEditorIntf,
  LazIDEIntf, IDEExternToolIntf, SynEdit, StdCtrls, Forms, fpjson;

type
  { Internal hook manager class using public LazIDEIntf specifications }
  TMcpIdeHookManager = class
  private
    FErrorLog: TJSONArray;
    procedure OnCompilerFinished(Sender: TObject; BuildSuccessful: boolean);
    procedure OnActiveFormChanged(Sender: TObject; Form: TCustomForm);
    procedure OnFormRemoved(Sender: TObject; Form: TCustomForm);
  public
    constructor Create;
    destructor Destroy; override;
    procedure HookIdeEvents;
    procedure UnhookIdeEvents;
    function GetActiveEditorContext: TJSONObject;
    property CurrentCompilerErrors: TJSONArray read FErrorLog;
  end;

var
  McpHookManager: TMcpIdeHookManager = nil;
  { Set on the main thread when TIDEExceptionDlg becomes active; cleared when
    the dialog is removed.  Read from the MCP worker thread without Synchronize
    — main thread sets it before the modal loop starts, worker thread reads it
    once the modal loop is spinning. }
  GMcpLastExceptionLabel: string = '';

procedure InitializeIdeHooks;
procedure FinalizeIdeHooks;

implementation

constructor TMcpIdeHookManager.Create;
begin
  inherited Create;
  FErrorLog := TJSONArray.Create;
end;

destructor TMcpIdeHookManager.Destroy;
begin
  FErrorLog.Free;
  inherited Destroy;
end;

procedure TMcpIdeHookManager.HookIdeEvents;
begin
  if Assigned(LazarusIDE) then
    LazarusIDE.AddHandlerOnProjectBuildingFinished(@OnCompilerFinished);
  Screen.AddHandlerActiveFormChanged(@OnActiveFormChanged);
  Screen.AddHandlerRemoveForm(@OnFormRemoved);
end;

procedure TMcpIdeHookManager.UnhookIdeEvents;
begin
  if Assigned(LazarusIDE) then
    LazarusIDE.RemoveHandlerOnProjectBuildingFinished(@OnCompilerFinished);
  Screen.RemoveHandlerActiveFormChanged(@OnActiveFormChanged);
  Screen.RemoveHandlerRemoveForm(@OnFormRemoved);
end;

procedure TMcpIdeHookManager.OnActiveFormChanged(Sender: TObject; Form: TCustomForm);
var
  C: TComponent;
begin
  if Assigned(Form) and Form.ClassNameIs('TIDEExceptionDlg') and Form.Visible then
  begin
    C := Form.FindComponent('lblMessage');
    if Assigned(C) and (C is TLabel) then
      GMcpLastExceptionLabel := TLabel(C).Caption;
  end;
end;

procedure TMcpIdeHookManager.OnFormRemoved(Sender: TObject; Form: TCustomForm);
begin
  if Assigned(Form) and Form.ClassNameIs('TIDEExceptionDlg') then
    GMcpLastExceptionLabel := '';
end;

procedure TMcpIdeHookManager.OnCompilerFinished(Sender: TObject; BuildSuccessful: boolean);
var
  ErrItem: TJSONObject;
  SelectedMsg: TMessageLine;
begin
  FErrorLog.Clear;

  if BuildSuccessful then Exit;
  if not Assigned(LazarusIDE) then Exit;

  // Query the public manager for the currently focused compiler message line object
  SelectedMsg := LazarusIDE.GetSelectedCompilerMessage;
  if Assigned(SelectedMsg) then
  begin
    ErrItem := TJSONObject.Create;

    // TMessageLine public property bindings
    ErrItem.Add('line', SelectedMsg.Line);
    ErrItem.Add('column', SelectedMsg.Column);
    ErrItem.Add('message', SelectedMsg.Msg);

    // FIXED: Reads the public string property directly from the object
    ErrItem.Add('file', SelectedMsg.Filename);

    FErrorLog.Add(ErrItem);
  end;
end;

function TMcpIdeHookManager.GetActiveEditorContext: TJSONObject;
var
  Editor: TSourceEditorInterface;
  Syn: TSynEdit;
begin
  Result := TJSONObject.Create;
  Editor := SourceEditorManagerIntf.ActiveEditor;

  if Assigned(Editor) then
  begin
    Result.Add('active_file', Editor.FileName);
    Result.Add('selection_text', Editor.Selection);

    if Assigned(Editor.EditorControl) and (Editor.EditorControl is TSynEdit) then
    begin
      Syn := TSynEdit(Editor.EditorControl);
      Result.Add('entire_source', Syn.Lines.Text);
    end
    else
      Result.Add('entire_source', '');
  end
  else
  begin
    Result.Add('active_file', '');
    Result.Add('selection_text', '');
    Result.Add('entire_source', '');
  end;
end;

procedure InitializeIdeHooks;
begin
  if not Assigned(McpHookManager) then
  begin
    McpHookManager := TMcpIdeHookManager.Create;
    McpHookManager.HookIdeEvents;
  end;
end;

procedure FinalizeIdeHooks;
begin
  if Assigned(McpHookManager) then
  begin
    McpHookManager.UnhookIdeEvents;
    FreeAndNil(McpHookManager);
  end;
end;

finalization
  FinalizeIdeHooks;
end.

