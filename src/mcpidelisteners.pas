{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpIdeListeners;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, IDEIntf, SrcEditorIntf,
  LazIDEIntf, IDEExternToolIntf, SynEdit, fpjson;

type
  { Internal hook manager class using public LazIDEIntf specifications }
  TMcpIdeHookManager = class
  private
    FErrorLog: TJSONArray;
    procedure OnCompilerFinished(Sender: TObject; BuildSuccessful: boolean);
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
end;

procedure TMcpIdeHookManager.UnhookIdeEvents;
begin
  if Assigned(LazarusIDE) then
    LazarusIDE.RemoveHandlerOnProjectBuildingFinished(@OnCompilerFinished);
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

