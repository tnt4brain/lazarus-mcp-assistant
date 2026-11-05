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
    procedure AutoAnswer(AForm: TCustomForm; AResult: TModalResult);
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
  { LCL handle of the exception dialog; 0 when absent.
    Set on the main thread in OnActiveFormChanged before the modal loop starts.
    Read from the worker thread without Synchronize. }
  GMcpExceptionDialogHwnd: THandle = 0;
  { Number of MCP tools/call requests currently executing (interlocked).
    While > 0 nobody is at the keyboard for the IDE, so known IDE modals are
    answered automatically — see OnActiveFormChanged. }
  GMcpToolCallsActive: LongInt = 0;

procedure InitializeIdeHooks;
procedure FinalizeIdeHooks;

{ Shared button-finding, used both by the automatic path below (matched by
  ModalResult -- language-independent, since this fires with nobody at the
  keyboard to read a caption) and by ide_answer_dialog in McpToolsProject.pas
  (matched by caption -- what the caller actually read via
  ide_get_open_dialogs). Recurses into AParent's controls (TButtonPanel and
  friends nest the actual buttons a level or two down). TCustomButton only --
  clicking a TCheckBox/TRadioButton (also TButtonControl) wouldn't close the
  dialog, since only TCustomButton sets the parent form's ModalResult (see
  TCustomButton.Click in LCL's buttons.inc). }

{ Strips the '&' accelerator marker and trims, so "&Yes" matches "yes". }
function NormalizeButtonCaption(const S: string): string;

{ Collects every button's caption into AAvailable (may be nil), and the
  first one whose caption matches AWanted into AFound. }
procedure FindButtonByCaption(AParent: TWinControl; const AWanted: string;
  var AFound: TCustomButton; AAvailable: TStringList);

{ The first button whose ModalResult property equals AResult. }
function FindButtonByModalResult(AParent: TWinControl; AResult: TModalResult): TCustomButton;

implementation

uses
  LazLogger,
  McpDebugGuard;  { GMcpDriven }

function NormalizeButtonCaption(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    if S[I] <> '&' then
      Result := Result + S[I];
  Result := Trim(Result);
end;

procedure FindButtonByCaption(AParent: TWinControl; const AWanted: string;
  var AFound: TCustomButton; AAvailable: TStringList);
var
  I   : Integer;
  C   : TControl;
  Cap : string;
begin
  for I := 0 to AParent.ControlCount - 1 do
  begin
    C := AParent.Controls[I];
    if C is TCustomButton then
    begin
      Cap := NormalizeButtonCaption(TCustomButton(C).Caption);
      if Assigned(AAvailable) and (Cap <> '') then AAvailable.Add(Cap);
      if (AFound = nil) and SameText(Cap, NormalizeButtonCaption(AWanted)) then
        AFound := TCustomButton(C);
    end;
    if C is TWinControl then
      FindButtonByCaption(TWinControl(C), AWanted, AFound, AAvailable);
  end;
end;

function FindButtonByModalResult(AParent: TWinControl; AResult: TModalResult): TCustomButton;
var
  I : Integer;
  C : TControl;
begin
  Result := nil;
  for I := 0 to AParent.ControlCount - 1 do
  begin
    C := AParent.Controls[I];
    if (C is TCustomButton) and (TCustomButton(C).ModalResult = AResult) then
      Exit(TCustomButton(C));
    if C is TWinControl then
    begin
      Result := FindButtonByModalResult(TWinControl(C), AResult);
      if Assigned(Result) then Exit;
    end;
  end;
end;

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
  if not Assigned(Form) or not Form.Visible then Exit;
  if Form.ClassNameIs('TIDEExceptionDlg') then
  begin
    C := Form.FindComponent('lblMessage');
    if Assigned(C) and (C is TLabel) then
      GMcpLastExceptionLabel := TLabel(C).Caption;
    GMcpExceptionDialogHwnd := Form.Handle;
    { Normally McpDebugGuard prevents this dialog in MCP-driven sessions;
      this is the fallback.  mrOK = Break (mrCancel would continue). }
    if GMcpDriven then
      AutoAnswer(Form, mrOK);
  end
  else if Form.ClassNameIs('TDiskDiffsDlg') and (GMcpToolCallsActive > 0) then
    { "Some files have changed on disk" — typically files an agent edited.
      Pre-checked are only files without unsaved editor changes, so OK
      reloads exactly those and keeps the user's unsaved edits. }
    AutoAnswer(Form, mrOK);
end;

type
  TMcpAutoAnswer = class
    Form   : TCustomForm;
    Answer : TModalResult;
    procedure Apply(Data: PtrInt);
  end;

procedure TMcpAutoAnswer.Apply(Data: PtrInt);
var
  Btn : TCustomButton;
begin
  { The form may have been closed meanwhile; only touch it if still alive. }
  if (Screen.CustomFormIndex(Form) >= 0) and (fsModal in Form.FormState) then
  begin
    DebugLn(['[MCP Assistant] auto-answered ', Form.ClassName, ' (', Form.Caption,
             ') with modal result ', Answer]);
    { Same path ide_answer_dialog takes for a real click, found by
      ModalResult rather than caption: a caption changes with the IDE's
      locale, a ModalResult doesn't. Falls back to the old direct poke if
      the dialog has no button wired to this result (shouldn't happen for
      the two classes handled here, but this path must never leave the
      dialog stuck). }
    Btn := FindButtonByModalResult(Form, Answer);
    if Assigned(Btn) then
      Btn.Click
    else
      Form.ModalResult := Answer;
  end;
  Free;
end;

procedure TMcpIdeHookManager.AutoAnswer(AForm: TCustomForm; AResult: TModalResult);
var
  A : TMcpAutoAnswer;
begin
  { Deferred: the modal loop has not started yet while the form activates,
    and ShowModal resets ModalResult when it does. }
  A := TMcpAutoAnswer.Create;
  A.Form   := AForm;
  A.Answer := AResult;
  Application.QueueAsyncCall(@A.Apply, 0);
end;

procedure TMcpIdeHookManager.OnFormRemoved(Sender: TObject; Form: TCustomForm);
begin
  if Assigned(Form) and Form.ClassNameIs('TIDEExceptionDlg') then
  begin
    GMcpLastExceptionLabel  := '';
    GMcpExceptionDialogHwnd := 0;
  end;
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

