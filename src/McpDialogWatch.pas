{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpDialogWatch;

{ What dialogs the IDE has open, readable from any thread.  A modal dialog
  blocks the IDE's main thread, so a tool call waiting on it would hang with
  nobody told why (a "Broken dependency" box failed every later build silently,
  FR item 13).  Two sources:

  1. The IDE's message and question dialogs (IDEMessageDialog, MessageDlg,
     QuestionDlg ...) all pass LazMessageWorker/LazQuestionWorker.  They are
     wrapped like the debugger events are (ADR-011): while one is up it is listed
     with its caption, text and buttons.  Cross-platform.
  2. Windows only: the dialog windows of the main thread that are not in the
     list above (a TTaskDialog, a plain MessageBox): title, and the text of
     their controls where Windows exposes it.

  Nothing here answers a dialog (ADR-011: guessing "OK" on an unknown question
  is worse than blocking); it only reports them. }

{$mode objfpc}{$H+}

interface

uses
  fpjson;

{ Install the wrappers; main thread.  Safe to call repeatedly (the IDE sets
  its workers once, early). }
procedure McpEnsureDialogWatch;
procedure McpRemoveDialogWatch;

{ The open dialogs as an array of objects (caption, text, buttons, source); any thread.  The
  caller frees the array.

  AWithForms adds the ordinary LCL forms that are modal right now ("Some files have
  changed on disk", the plugin's consent dialogs ...), which McpIdeListeners reports
  with McpTrackModalForm.  Only ide_get_open_dialogs asks for them: the gate that
  refuses a build behind a dialog does not, because the IDE's Project Wizard is such a
  form too and project_open must still work from it. }
function McpOpenDialogs(AWithForms: Boolean = False): TJSONArray;

{ Main thread: AForm is modal and visible now / is not any more or is gone. }
procedure McpTrackModalForm(AForm: TObject; const ACaption, AText, AButtons: string);
procedure McpUntrackModalForm(AForm: TObject);

{ One line for a tool result: '"Broken dependency": The project requires ...'. }
function McpDescribeDialogs(ADialogs: TJSONArray): string;

implementation

uses
  Classes, SysUtils, SyncObjs, TypInfo, System.UITypes, Forms
  {$IFDEF WINDOWS}, Windows{$ENDIF},
  LCLStrConsts, LazMsgWorker;

type
  TOpenDialog_ = record
    Id      : Integer;
    Caption : string;
    Text    : string;
    Buttons : string;
  end;

  { a modal LCL form: Form is only compared, never dereferenced off the main thread }
  TModalForm_ = record
    Form    : Pointer;
    Caption : string;
    Text    : string;
    Buttons : string;
  end;

  TDialogWatch = class
  public
    OrigMessage  : TLazMessageWorker;
    OrigQuestion : TLazQuestionWorker;
    function Msg(const aCaption, aMsg: string; DlgType: TMsgDlgType;
      Buttons: TMsgDlgButtons; const HelpKeyword: string = ''): Integer;
    function Question(const aCaption, aMsg: string; DlgType: TMsgDlgType;
      Buttons: array of const; const HelpKeyword: string = ''): Integer;
  end;

var
  GLock    : SyncObjs.TCriticalSection;
  GOpen    : array of TOpenDialog_;
  GModal   : array of TModalForm_;
  GNextId  : Integer = 0;
  GWatch   : TDialogWatch = nil;

function Enter(const ACaption, AText, AButtons: string): Integer;
begin
  GLock.Enter;
  try
    Inc(GNextId);
    Result := GNextId;
    SetLength(GOpen, Length(GOpen) + 1);
    with GOpen[High(GOpen)] do
    begin
      Id := Result; Caption := ACaption; Text := AText; Buttons := AButtons;
    end;
  finally
    GLock.Leave;
  end;
end;

procedure Leave(AId: Integer);
var
  I, J : Integer;
begin
  GLock.Enter;
  try
    for I := 0 to High(GOpen) do
      if GOpen[I].Id = AId then
      begin
        for J := I to High(GOpen) - 1 do
          GOpen[J] := GOpen[J + 1];
        SetLength(GOpen, Length(GOpen) - 1);
        Break;
      end;
  finally
    GLock.Leave;
  end;
end;

function ButtonSetText(AButtons: TMsgDlgButtons): string;
var
  B : TMsgDlgBtn;
begin
  Result := '';
  for B := Low(TMsgDlgBtn) to High(TMsgDlgBtn) do
    if B in AButtons then
    begin
      if Result <> '' then Result := Result + ', ';
      Result := Result + Copy(GetEnumName(TypeInfo(TMsgDlgBtn), Ord(B)), 3, MaxInt);
    end;
end;

{ The caption QuestionDlg gives a button whose result code has no string after
  it: the LCL's own text for that code, so the same words the dialog shows. }
function DefaultButtonCaption(AResult: Integer): string;
begin
  case AResult of
    mrOk       : Result := rsmbOk;
    mrCancel   : Result := rsmbCancel;
    mrYes      : Result := rsmbYes;
    mrNo       : Result := rsmbNo;
    mrAbort    : Result := rsmbAbort;
    mrRetry    : Result := rsmbRetry;
    mrIgnore   : Result := rsmbIgnore;
    mrAll      : Result := rsmbAll;
    mrYesToAll : Result := rsmbYesToAll;
    mrNoToAll  : Result := rsmbNoToAll;
  else
    Result := '';
  end;
end;

{ QuestionDlg's array of const: a result code starts a button, the strings
  after it are its caption and the flags 'isdefault' / 'iscancel'.  A code
  with no caption string is a button with the default caption (the IDE's
  "Source modified" dialog ends in a bare mrAbort). }
function ButtonArrayText(const AButtons: array of const): string;
var
  I       : Integer;
  S       : string;
  Caption : string;
  HasText : Boolean;
  Code    : Integer;

  procedure Flush;
  begin
    if Code = MaxInt then Exit;
    if not HasText then Caption := DefaultButtonCaption(Code);
    if Caption <> '' then
    begin
      if Result <> '' then Result := Result + ', ';
      Result := Result + Caption;
    end;
    Code := MaxInt;
  end;

begin
  Result := '';
  Code := MaxInt;
  Caption := '';
  HasText := False;
  for I := 0 to High(AButtons) do
    if AButtons[I].VType = vtInteger then
    begin
      Flush;
      Code := AButtons[I].VInteger;
      Caption := '';
      HasText := False;
    end
    else
    begin
      S := '';
      case AButtons[I].VType of
        vtAnsiString    : S := string(AButtons[I].VAnsiString);
        vtUnicodeString : S := UTF8Encode(UnicodeString(AButtons[I].VUnicodeString));
        vtString        : S := string(AButtons[I].VString^);
        vtWideString    : S := UTF8Encode(WideString(AButtons[I].VWideString));
        vtPChar         : S := string(AButtons[I].VPChar);
        vtChar          : S := AButtons[I].VChar;
      end;
      if SameText(S, 'isdefault') or SameText(S, 'iscancel') then Continue;
      if (S <> '') and not HasText then
      begin
        Caption := S;
        HasText := True;
      end;
    end;
  Flush;
end;

function TDialogWatch.Msg(const aCaption, aMsg: string; DlgType: TMsgDlgType;
  Buttons: TMsgDlgButtons; const HelpKeyword: string): Integer;
var
  Id : Integer;
begin
  Id := Enter(aCaption, aMsg, ButtonSetText(Buttons));
  try
    Result := OrigMessage(aCaption, aMsg, DlgType, Buttons, HelpKeyword);
  finally
    Leave(Id);
  end;
end;

function TDialogWatch.Question(const aCaption, aMsg: string; DlgType: TMsgDlgType;
  Buttons: array of const; const HelpKeyword: string): Integer;
var
  Id : Integer;
begin
  Id := Enter(aCaption, aMsg, ButtonArrayText(Buttons));
  try
    Result := OrigQuestion(aCaption, aMsg, DlgType, Buttons, HelpKeyword);
  finally
    Leave(Id);
  end;
end;

procedure McpEnsureDialogWatch;
var
  Mine : TLazMessageWorker;
begin
  if not Assigned(LazMessageWorker) or not Assigned(LazQuestionWorker) then Exit;
  if Assigned(GWatch) then
  begin
    Mine := @GWatch.Msg;
    if (TMethod(LazMessageWorker).Data = TMethod(Mine).Data) then Exit;  { still ours }
    FreeAndNil(GWatch);  { the IDE replaced the workers: wrap the new ones }
  end;
  GWatch := TDialogWatch.Create;
  GWatch.OrigMessage  := LazMessageWorker;
  GWatch.OrigQuestion := LazQuestionWorker;
  LazMessageWorker  := @GWatch.Msg;
  LazQuestionWorker := @GWatch.Question;
end;

procedure McpRemoveDialogWatch;
begin
  if Assigned(GWatch) then
  begin
    { only if nobody wrapped us since }
    if TMethod(LazMessageWorker).Data = Pointer(GWatch) then
    begin
      LazMessageWorker  := GWatch.OrigMessage;
      LazQuestionWorker := GWatch.OrigQuestion;
      FreeAndNil(GWatch);
    end;
    { else leaked on purpose: the wrapper may still be called }
  end;
end;

{$IFDEF WINDOWS}
type
  TNativeCollect = record
    Dialogs : TJSONArray;
    Texts   : string;
    Buttons : string;
  end;
  PNativeCollect = ^TNativeCollect;

function WindowText(AWnd: HWND): string;
var
  Buf : array[0..1023] of WideChar;
  N   : Integer;
begin
  N := GetWindowTextW(AWnd, @Buf[0], Length(Buf));
  if N <= 0 then Exit('');
  Result := UTF8Encode(WideString(Copy(WideString(PWideChar(@Buf[0])), 1, N)));
end;

function WindowClass(AWnd: HWND): string;
var
  Buf : array[0..255] of WideChar;
  N   : Integer;
begin
  N := GetClassNameW(AWnd, @Buf[0], Length(Buf));
  if N <= 0 then Exit('');
  Result := UTF8Encode(WideString(Copy(WideString(PWideChar(@Buf[0])), 1, N)));
end;

function EnumChildProc(AWnd: HWND; ALParam: LPARAM): WINBOOL; stdcall;
var
  C : PNativeCollect;
  T : string;
begin
  C := PNativeCollect(ALParam);
  T := WindowText(AWnd);
  if T <> '' then
    if WindowClass(AWnd) = 'Button' then
    begin
      { a push button of the dialog: what the user will be asked to press }
      if C^.Buttons <> '' then C^.Buttons := C^.Buttons + ', ';
      C^.Buttons := C^.Buttons + T;
    end
    else
    begin
      if C^.Texts <> '' then C^.Texts := C^.Texts + ' | ';
      C^.Texts := C^.Texts + T;
    end;
  Result := True;
end;

function EnumThreadProc(AWnd: HWND; ALParam: LPARAM): WINBOOL; stdcall;
var
  C   : PNativeCollect;
  Col : TNativeCollect;
  O   : TJSONObject;
  Cls : string;
begin
  Result := True;
  C := PNativeCollect(ALParam);
  if not IsWindowVisible(AWnd) then Exit;
  Cls := WindowClass(AWnd);
  if Cls <> '#32770' then Exit;   { the dialog box window class }
  Col.Dialogs := nil;
  Col.Texts   := '';
  Col.Buttons := '';
  EnumChildWindows(AWnd, @EnumChildProc, LPARAM(@Col));
  O := TJSONObject.Create;
  O.Add('caption', WindowText(AWnd));
  O.Add('text',    Col.Texts);
  O.Add('buttons', Col.Buttons);
  O.Add('source',  'native window (' + Cls + ')');
  C^.Dialogs.Add(O);
end;
{$ENDIF}

procedure McpTrackModalForm(AForm: TObject; const ACaption, AText, AButtons: string);
var
  I : Integer;
begin
  GLock.Enter;
  try
    for I := 0 to High(GModal) do
      if GModal[I].Form = Pointer(AForm) then
      begin
        GModal[I].Caption := ACaption;     { shown again: the texts may have changed }
        GModal[I].Text    := AText;
        GModal[I].Buttons := AButtons;
        Exit;
      end;
    SetLength(GModal, Length(GModal) + 1);
    with GModal[High(GModal)] do
    begin
      Form := Pointer(AForm); Caption := ACaption; Text := AText; Buttons := AButtons;
    end;
  finally
    GLock.Leave;
  end;
end;

procedure McpUntrackModalForm(AForm: TObject);
var
  I, J : Integer;
begin
  GLock.Enter;
  try
    for I := 0 to High(GModal) do
      if GModal[I].Form = Pointer(AForm) then
      begin
        for J := I to High(GModal) - 1 do
          GModal[J] := GModal[J + 1];
        SetLength(GModal, Length(GModal) - 1);
        Break;
      end;
  finally
    GLock.Leave;
  end;
end;

{ Main thread, GLock held: forget a form that is gone or no longer modal, in case a
  hide or removal was missed.  The pointer is only looked up in Screen's list. }
procedure PruneModalForms;
var
  I, J : Integer;
  F    : TCustomForm;
begin
  I := 0;
  while I <= High(GModal) do
  begin
    J := Screen.CustomFormIndex(TCustomForm(GModal[I].Form));
    if J >= 0 then
    begin
      F := Screen.CustomForms[J];
      if F.Visible and (fsModal in F.FormState) then
      begin
        Inc(I);
        Continue;
      end;
    end;
    for J := I to High(GModal) - 1 do
      GModal[J] := GModal[J + 1];
    SetLength(GModal, Length(GModal) - 1);
  end;
end;

function McpOpenDialogs(AWithForms: Boolean): TJSONArray;
var
  I, K : Integer;
  O   : TJSONObject;
  {$IFDEF WINDOWS}
  Col : TNativeCollect;
  J   : Integer;
  Dup : Boolean;
  {$ENDIF}
begin
  Result := TJSONArray.Create;
  GLock.Enter;
  try
    for I := 0 to High(GOpen) do
    begin
      O := TJSONObject.Create;
      O.Add('caption', GOpen[I].Caption);
      O.Add('text',    GOpen[I].Text);
      O.Add('buttons', GOpen[I].Buttons);
      O.Add('source',  'IDE dialog');
      Result.Add(O);
    end;
    if AWithForms then
    begin
      if GetCurrentThreadId = MainThreadID then PruneModalForms;
      for I := 0 to High(GModal) do
      begin
        { a message or question dialog is both: listed once, with its full text above }
        K := 0;
        while (K < Result.Count) and
              (TJSONObject(Result[K]).Get('caption', '') <> GModal[I].Caption) do
          Inc(K);
        if K < Result.Count then Continue;
        O := TJSONObject.Create;
        O.Add('caption', GModal[I].Caption);
        O.Add('text',    GModal[I].Text);
        O.Add('buttons', GModal[I].Buttons);
        O.Add('source',  'modal form');
        Result.Add(O);
      end;
    end;
  finally
    GLock.Leave;
  end;
  {$IFDEF WINDOWS}
  Col.Dialogs := TJSONArray.Create;
  try
    EnumThreadWindows(MainThreadID, @EnumThreadProc, LPARAM(@Col));
    for I := 0 to Col.Dialogs.Count - 1 do
    begin
      O := TJSONObject(Col.Dialogs[I]);
      Dup := False;
      for J := 0 to Result.Count - 1 do
        if TJSONObject(Result[J]).Get('caption', '') = O.Get('caption', '') then
          Dup := True;   { the same dialog, seen with its full text above }
      if not Dup then
        Result.Add(O.Clone);
    end;
  finally
    Col.Dialogs.Free;
  end;
  {$ENDIF}
end;

function McpDescribeDialogs(ADialogs: TJSONArray): string;
var
  En : TJSONEnum;
  O : TJSONObject;
  S : string;
begin
  Result := '';
  for En in ADialogs do
  begin
    O := TJSONObject(En.Value);
    S := '"' + O.Get('caption', '') + '"';
    if O.Get('text', '') <> '' then S := S + ': ' + O.Get('text', '');
    if O.Get('buttons', '') <> '' then S := S + ' [' + O.Get('buttons', '') + ']';
    if Result <> '' then Result := Result + '; ';
    Result := Result + S;
  end;
end;

initialization
  GLock := SyncObjs.TCriticalSection.Create;

finalization
  GLock.Free;

end.
