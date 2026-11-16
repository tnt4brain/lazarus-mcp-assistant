{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpTestHooks;

{ Test fixture code, not a tool: the FPCUnit suite runs as a separate process
  (ADR-005) with no access to Screen/MessageDlg except through this plugin, so
  a dialog test needs *something* reachable inside the IDE process to raise a
  real, generic one on demand -- without waiting for a real ambiguous unit or
  a real disk change to produce one by accident.

  This is registered with RegisterMcpGroup only, never RegisterMcpSchemas /
  MakeTool: it has no schema, no description, and never appears in tools/list,
  so no real MCP client -- including an AI assistant reading the tool list --
  ever sees or can discover it. It also refuses outright unless MCP_TEST_HOOKS=1
  was set in the IDE's environment at startup, so even its bare name reaching
  the server over HTTP does nothing in a normal session. }

{$mode objfpc}{$H+}

interface

procedure RegisterTestHooks;

implementation

uses
  SysUtils, TypInfo, System.UITypes, fpjson, Forms,
  IDEDialogs, McpToolContext;

const
  SHOW_HOOK_NAME  = '__test_show_dialog__';
  CLOSE_HOOK_NAME = '__test_close_last_dialog__';
  LOG_HOOK_NAME   = '__test_get_log__';

type
  { Screen.AddHandlerActiveFormChanged/AddHandlerFormAdded want a method,
    not a plain function. }
  TTestDialogCapture = class
    procedure OnActiveFormChanged(Sender: TObject; Form: TCustomForm);
    procedure OnFormAdded(Sender: TObject; Form: TCustomForm);
  end;

var
  { Captured independently of Screen.GetCurrentModalForm -- the very thing
    ide_answer_dialog turned out not to find reliably -- so the test
    fixture's own cleanup does not depend on the bug it exists to catch.
    Set the instant SHOW_HOOK_NAME's dialog activates, while GCapturing.
    OnActiveFormChanged, not AddHandlerFormAdded: this is the exact
    mechanism McpIdeListeners already relies on for TMcpAutoAnswer, so it
    is known to fire for a dialog shown this way. }
  GLastDialogForm : TCustomForm = nil;
  GCapturing      : Boolean = False;
  GCapture        : TTestDialogCapture = nil;
  { Diagnostics only, while the capture above is being debugged. }
  GFireCount      : Integer = 0;
  GLastSeenClass  : string = '';
  GLastSeenVisible: Boolean = False;
  { Logged synchronously during DispatchShowDialog, read only after
    IDEMessageDialog returns (i.e. after the dialog has already closed) --
    no concurrency involved, unlike polling Screen from a second call. }
  GFormAddedLog   : string = '';

procedure TTestDialogCapture.OnActiveFormChanged(Sender: TObject; Form: TCustomForm);
begin
  Inc(GFireCount);
  if Assigned(Form) then
  begin
    GLastSeenClass   := Form.ClassName;
    GLastSeenVisible := Form.Visible;
  end
  else
  begin
    GLastSeenClass   := '<nil>';
    GLastSeenVisible := False;
  end;
  if GCapturing and Assigned(Form) and Form.Visible then
  begin
    GLastDialogForm := Form;
    GCapturing := False;
  end;
end;

procedure TTestDialogCapture.OnFormAdded(Sender: TObject; Form: TCustomForm);
var
  Entry : string;
begin
  if Assigned(Form) then
    Entry := Format('%s(visible=%s,modal=%s)', [Form.ClassName,
      BoolToStr(Form.Visible, True), BoolToStr(fsModal in Form.FormState, True)])
  else
    Entry := '<nil>';
  if GFormAddedLog = '' then GFormAddedLog := Entry
  else GFormAddedLog := GFormAddedLog + '; ' + Entry;
end;

function StrToMsgDlgBtn(const AName: string; out ABtn: TMsgDlgBtn): Boolean;
var
  B : TMsgDlgBtn;
begin
  for B := Low(TMsgDlgBtn) to High(TMsgDlgBtn) do
    if SameText(Copy(GetEnumName(TypeInfo(TMsgDlgBtn), Ord(B)), 3, MaxInt), AName) then
    begin
      ABtn := B;
      Exit(True);
    end;
  Result := False;
end;

function ButtonsFromArgs(AList: TJSONArray): TMsgDlgButtons;
var
  En : TJSONEnum;
  Btn : TMsgDlgBtn;
begin
  Result := [];
  if not Assigned(AList) then Exit([mbOK]);
  for En in AList do
    if StrToMsgDlgBtn(En.Value.AsString, Btn) then
      Include(Result, Btn);
  if Result = [] then Result := [mbOK];
end;

function HooksEnabled(var Ctx: TMcpToolCall; const AHookName: string): Boolean;
begin
  Result := GetEnvironmentVariable('MCP_TEST_HOOKS') = '1';
  if not Result then
  begin
    Ctx.Error  := True;
    Ctx.Result := AHookName + ' is disabled (set MCP_TEST_HOOKS=1 to enable it)';
  end;
end;

function DispatchShowDialog(var Ctx: TMcpToolCall): Boolean;
var
  Caption, Text : string;
  Buttons       : TJSONArray;
  ModalRes      : Integer;
begin
  Result := True;
  if not HooksEnabled(Ctx, SHOW_HOOK_NAME) then Exit;

  Caption := '';
  Text    := '';
  Buttons := nil;
  if Assigned(Ctx.Params) then
  begin
    Caption := Ctx.Params.Get('caption', '');
    Text    := Ctx.Params.Get('text', '');
    Buttons := TJSONArray(Ctx.Params.Find('buttons'));
  end;

  { IDEMessageDialog, not MessageDlg: only the former goes through
    LazMessageWorker, which McpDialogWatch wraps -- the same path every real
    IDE dialog (including "Ambiguous unit found") takes, so this produces a
    dialog ide_get_open_dialogs/ide_answer_dialog cannot tell apart from a
    real one. Blocks here until answered; the caller sees CallOnMain's
    existing abandon-after-grace-period behavior, same as any other tool
    call stuck behind a dialog. }
  GCapturing    := True;
  GFormAddedLog := '';
  ModalRes := IDEMessageDialog(Caption, Text, mtConfirmation, ButtonsFromArgs(Buttons));
  Ctx.Result := Format('dialog closed with modal result %d; formsAdded: %s',
    [ModalRes, GFormAddedLog]);
end;

function DispatchCloseLastDialog(var Ctx: TMcpToolCall): Boolean;
begin
  Result := True;
  if not HooksEnabled(Ctx, CLOSE_HOOK_NAME) then Exit;

  if not Assigned(GLastDialogForm) or (Screen.CustomFormIndex(GLastDialogForm) < 0) then
  begin
    Ctx.Result := Format('no tracked test dialog to close ' +
      '(diag: fires=%d, last seen class=%s, visible=%s, GCapturing=%s, ' +
      'Screen.CustomFormCount=%d)',
      [GFireCount, GLastSeenClass, BoolToStr(GLastSeenVisible, True),
       BoolToStr(GCapturing, True), Screen.CustomFormCount]);
    Exit;
  end;
  if fsModal in GLastDialogForm.FormState then
    GLastDialogForm.ModalResult := mrCancel;
  Ctx.Result := 'closed the tracked test dialog';
  GLastDialogForm := nil;
end;

function DispatchGetLog(var Ctx: TMcpToolCall): Boolean;
begin
  Result := True;
  if not HooksEnabled(Ctx, LOG_HOOK_NAME) then Exit;
  Ctx.Result := Format('fires=%d, lastSeenClass=%s, lastSeenVisible=%s, ' +
    'GCapturing=%s, formsAdded=%s, Screen.CustomFormCount=%d',
    [GFireCount, GLastSeenClass, BoolToStr(GLastSeenVisible, True),
     BoolToStr(GCapturing, True), GFormAddedLog, Screen.CustomFormCount]);
end;

function DispatchTestHooks(const Name: string; var Ctx: TMcpToolCall): Boolean;
begin
  if Name = SHOW_HOOK_NAME then Exit(DispatchShowDialog(Ctx));
  if Name = CLOSE_HOOK_NAME then Exit(DispatchCloseLastDialog(Ctx));
  if Name = LOG_HOOK_NAME then Exit(DispatchGetLog(Ctx));
  Result := False;
end;

procedure RegisterTestHooks;
begin
  GCapture := TTestDialogCapture.Create;
  Screen.AddHandlerActiveFormChanged(@GCapture.OnActiveFormChanged);
  Screen.AddHandlerFormAdded(@GCapture.OnFormAdded);
  RegisterMcpGroup(@DispatchTestHooks);
end;

initialization
  RegisterTestHooks;

finalization
  if Assigned(GCapture) then
  begin
    Screen.RemoveHandlerActiveFormChanged(@GCapture.OnActiveFormChanged);
    Screen.RemoveHandlerFormAdded(@GCapture.OnFormAdded);
    FreeAndNil(GCapture);
  end;

end.
