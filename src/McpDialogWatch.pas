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

{ The open dialogs as [{caption, text, buttons, source}]; any thread.  The
  caller frees the array. }
function McpOpenDialogs: TJSONArray;

{ One line for a tool result: '"Broken dependency": The project requires ...'. }
function McpDescribeDialogs(ADialogs: TJSONArray): string;

implementation

uses
  Classes, SysUtils, SyncObjs, TypInfo, System.UITypes
  {$IFDEF WINDOWS}, Windows{$ENDIF},
  LazMsgWorker;

type
  TOpenDialog_ = record
    Id      : Integer;
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

{ QuestionDlg's array of const: result codes and button captions mixed; the
  strings are the captions. }
function ButtonArrayText(const AButtons: array of const): string;
var
  I : Integer;
  S : string;
begin
  Result := '';
  for I := 0 to High(AButtons) do
  begin
    S := '';
    case AButtons[I].VType of
      vtAnsiString    : S := string(AButtons[I].VAnsiString);
      vtUnicodeString : S := UnicodeString(AButtons[I].VUnicodeString);
      vtString        : S := string(AButtons[I].VString^);
      vtWideString    : S := WideString(AButtons[I].VWideString);
      vtPChar         : S := string(AButtons[I].VPChar);
    end;
    if (S = '') or (S = 'isdefault') or (S = 'iscancel') then Continue;
    if Result <> '' then Result := Result + ', ';
    Result := Result + S;
  end;
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
  EnumChildWindows(AWnd, @EnumChildProc, LPARAM(@Col));
  O := TJSONObject.Create;
  O.Add('caption', WindowText(AWnd));
  O.Add('text',    Col.Texts);
  O.Add('buttons', '');
  O.Add('source',  'native window (' + Cls + ')');
  C^.Dialogs.Add(O);
end;
{$ENDIF}

function McpOpenDialogs: TJSONArray;
var
  I   : Integer;
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
  I : Integer;
  O : TJSONObject;
  S : string;
begin
  Result := '';
  for I := 0 to ADialogs.Count - 1 do
  begin
    O := TJSONObject(ADialogs[I]);
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
