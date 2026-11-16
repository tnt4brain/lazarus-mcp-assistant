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
    procedure OnFormVisibleChanged(Sender: TObject; Form: TCustomForm);
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

{ Reloads the open editors whose file an agent changed on disk with its own tools,
  so the IDE does not ask the user later.  An editor with unsaved changes is never
  touched.  Returns the number of editors reloaded.  Main thread only. }
function McpReloadChangedFiles: Integer;

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
  LazLogger, CheckLst, CodeCache, CodeToolManager,
  McpDebugGuard,  { GMcpDriven }
  McpReviewFlow, McpReviewPaths, McpDialogWatch;

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
  Screen.AddHandlerFormVisibleChanged(@OnFormVisibleChanged);
end;

procedure TMcpIdeHookManager.UnhookIdeEvents;
begin
  if Assigned(LazarusIDE) then
    LazarusIDE.RemoveHandlerOnProjectBuildingFinished(@OnCompilerFinished);
  Screen.RemoveHandlerActiveFormChanged(@OnActiveFormChanged);
  Screen.RemoveHandlerRemoveForm(@OnFormRemoved);
  Screen.RemoveHandlerFormVisibleChanged(@OnFormVisibleChanged);
end;

var
  GSeenFileAge: TStringList = nil;   { file name -> FileAge when last compared }

{ Not LazarusIDE.DoCheckFilesOnDisk: its dialog, answered automatically, threw away
  the unsaved edit of an editor whose file had changed too (checked live,
  2026-11-13).  Here a modified editor is never overwritten: it goes to the review
  window (McpReviewFlow). }
function McpReloadChangedFiles: Integer;
var
  I, N     : Integer;
  Ed       : TSourceEditorInterface;
  FileName : string;
  Stamp    : string;
  Disk     : TStringList;
  Base     : string;
  Buf      : TCodeBuffer;
  Asked, Kept, Taken : TStringList;   { the files of this pass that went to the user / by policy }
begin
  Result := 0;
  if SourceEditorManagerIntf = nil then Exit;
  if GSeenFileAge = nil then GSeenFileAge := TStringList.Create;
  Disk := TStringList.Create;
  Asked := TStringList.Create;
  Kept := TStringList.Create;
  Taken := TStringList.Create;
  try
    N := SourceEditorManagerIntf.SourceEditorCount;
    for I := 0 to N - 1 do
    try
      Ed := SourceEditorManagerIntf.SourceEditors[I];
      if Ed = nil then Continue;
      FileName := Ed.FileName;
      if (FileName = '') or not FileExists(FileName) then Continue;
      Stamp := McpFileStamp(FileName);          { not FileAge: two seconds are too coarse }
      if GSeenFileAge.Values[FileName] = Stamp then Continue;
      GSeenFileAge.Values[FileName] := Stamp;
      Disk.LoadFromFile(FileName);
      if Ed.Modified then
      begin
        { Unsaved changes: never touched here.  When the file changed since the editor
          and the disk last agreed, the user is asked (ADR-025). }
        if Disk.Text = Ed.Lines.Text then Continue;
        if McpReviewBase(FileName, Base) then
        begin
          if Disk.Text = Base then Continue;           { the disk did not change }
        end
        else
        begin
          Buf := CodeToolBoss.FindFile(FileName);
          if (Buf = nil) or not Buf.FileOnDiskHasChanged then Continue;
        end;
        case McpReviewOffer(Ed, Disk.Text) of
          roAsk       : Asked.Add(ExtractFileName(FileName));
          roEditorWon : Kept.Add(ExtractFileName(FileName));
          roDiskWon   : Taken.Add(ExtractFileName(FileName));
        end;
        Continue;
      end;
      if Disk.Text <> Ed.Lines.Text then
      begin
        if Assigned(LazarusIDE) and (LazarusIDE.DoRevertEditorFile(FileName) = mrOK) then
        begin
          Inc(Result);
          DebugLn(['[MCP Assistant] reloaded ', FileName, ' (changed on disk)']);
        end
        else
          Continue;
      end;
      McpReviewNoteBase(FileName, Ed.Lines.Text);    { editor and disk agree: the base }
    except
      on E: Exception do
        DebugLn(['[MCP Assistant] reload check of an editor: ', E.Message]);
    end;
    McpReviewNotice(Asked, Kept, Taken);       { one sentence for the model, every file in it }
  finally
    Taken.Free;
    Kept.Free;
    Asked.Free;
    Disk.Free;
  end;
end;

{ In the IDE's "files changed on disk" dialog: take the check off every file whose
  open editor has unsaved changes. }
function UncheckModifiedEditors(AForm: TCustomForm): Integer;
var
  List : TComponent;
  I    : Integer;
  Obj  : TObject;
  Ed   : TSourceEditorInterface;
begin
  Result := 0;
  List := AForm.FindComponent('FilesListBox');
  if not (List is TCheckListBox) then Exit(1);      { unknown dialog: leave it to the user }
  for I := 0 to TCheckListBox(List).Count - 1 do
  begin
    Obj := TCheckListBox(List).Items.Objects[I];
    if Obj is TCodeBuffer then
    begin
      Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(TCodeBuffer(Obj).Filename);
      if Assigned(Ed) and Ed.Modified and TCheckListBox(List).Checked[I] then
      begin
        TCheckListBox(List).Checked[I] := False;
        DebugLn(['[MCP Assistant] kept ', TCodeBuffer(Obj).Filename,
                 ' (unsaved editor changes) out of the disk reload']);
      end;
    end;
    if TCheckListBox(List).Checked[I] then Inc(Result);
  end;
end;

type
  { The review pass, after the IDE's dialog is gone (not inside its activation). }
  TMcpDeferredReload = class
    procedure Run(Data: PtrInt);
  end;

procedure TMcpDeferredReload.Run(Data: PtrInt);
begin
  try
    McpReloadChangedFiles;
  finally
    Free;
  end;
end;

{ The text a dialog shows: its labels, check boxes and the lines of its lists (the files
  of "Some files have changed on disk"), a few dozen lines at most. }
procedure CollectFormText(AParent: TWinControl; var AText: string; var ALines: Integer);
var
  I    : Integer;
  C    : TControl;
  Item : string;

  procedure AddLine(const S: string);
  begin
    if (S = '') or (ALines >= 30) then Exit;
    if AText <> '' then AText := AText + LineEnding;
    AText := AText + S;
    Inc(ALines);
  end;

begin
  for I := 0 to AParent.ControlCount - 1 do
  begin
    C := AParent.Controls[I];
    if C is TCustomLabel then
      AddLine(Trim(TCustomLabel(C).Caption))
    else if C is TCustomCheckBox then
      AddLine('[option] ' + NormalizeButtonCaption(TCustomCheckBox(C).Caption))
    else if C is TCustomListBox then
      for Item in TCustomListBox(C).Items do
        AddLine(Item)
    else if C is TCustomMemo then
      { what a consent dialog asks about is in a read-only memo }
      for Item in TCustomMemo(C).Lines do
        AddLine(Trim(Item));
    if C is TWinControl then
      CollectFormText(TWinControl(C), AText, ALines);
  end;
end;

{ Report a form that is modal and visible to McpDialogWatch (ide_get_open_dialogs). }
procedure TrackModalForm(AForm: TCustomForm);
var
  Txt, Btns : string;
  Lines     : Integer;
  Cap       : string;
  Found     : TCustomButton;
  Avail     : TStringList;
begin
  if not (Assigned(AForm) and AForm.Visible and (fsModal in AForm.FormState)) then Exit;
  Txt := '';
  Lines := 0;
  CollectFormText(AForm, Txt, Lines);
  Btns := '';
  Avail := TStringList.Create;
  try
    Found := nil;
    FindButtonByCaption(AForm, '', Found, Avail);
    for Cap in Avail do
    begin
      if Btns <> '' then Btns := Btns + ', ';
      Btns := Btns + Cap;
    end;
  finally
    Avail.Free;
  end;
  McpTrackModalForm(AForm, AForm.Caption, Txt, Btns);
end;

procedure TMcpIdeHookManager.OnFormVisibleChanged(Sender: TObject; Form: TCustomForm);
begin
  if not Assigned(Form) then Exit;
  if Form.Visible and (fsModal in Form.FormState) then
    TrackModalForm(Form)
  else
    McpUntrackModalForm(Form);
end;

procedure TMcpIdeHookManager.OnActiveFormChanged(Sender: TObject; Form: TCustomForm);
var
  C: TComponent;
begin
  if not Assigned(Form) or not Form.Visible then Exit;
  TrackModalForm(Form);   { its list is filled by now: the first report may have been empty }
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
  else if Form.ClassNameIs('TDiskDiffsDlg') then
    begin
      { "Some files have changed on disk" — typically files an agent edited.
        The dialog pre-checks every file whose project unit is not modified,
        so a file open in an editor but not in the project, with unsaved
        changes, was checked and reloaded over them.  Uncheck those first: they go
        to the review window (ADR-025).  During a tool call the dialog is answered
        as it is; otherwise (the IDE just got the focus back) only when nothing
        is left checked, so the user still decides about the rest. }
      { the review pass runs when the dialog is gone (OnFormRemoved), however it was answered }
      if (UncheckModifiedEditors(Form) = 0) or (GMcpToolCallsActive > 0) then
        AutoAnswer(Form, mrOK);
    end;
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
var
  Reload: TMcpDeferredReload;
begin
  McpUntrackModalForm(Form);
  if Assigned(Form) and Form.ClassNameIs('TDiskDiffsDlg') then
  begin
    { the IDE has done its own reload; now the files it left alone go to the review }
    Reload := TMcpDeferredReload.Create;
    Application.QueueAsyncCall(@Reload.Run, 0);
  end;
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
  FreeAndNil(GSeenFileAge);
end.

