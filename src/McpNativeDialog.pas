{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpNativeDialog;

{ Windows only: answers a dialog that MessageDlg/IDEMessageDialog raised as a
  native TaskDialog rather than an LCL form.

  Root cause (see commit history / FR notes around this unit): on Windows
  Vista+ with a themed comctl32, TWin32WidgetSet.PromptUser
  (lcl/interfaces/win32/win32lclintf.inc) calls TaskDialogIndirect directly.
  No TCustomForm is ever created, so Screen.GetCurrentModalForm, the
  Screen.OnFormAdded/OnActiveFormChanged handlers McpIdeListeners already
  relies on for real LCL dialogs, and everything else that goes through
  Screen all miss it -- there is nothing LCL to find. ide_answer_dialog's own
  refusal text already named this case correctly; this unit is what answers
  it instead of only reporting it.

  ADR-011 tried exactly this (posting BM_CLICK to a dialog's button) and
  rejected it as the *general, proactive* mechanism for suppressing dialogs
  before they are seen, because at that point the dialog may not exist yet,
  its window class depends on the widgetset, and guessing an answer for an
  unknown dialog is worse than blocking. None of that applies here:
  ide_answer_dialog only runs after the caller has already confirmed, via
  ide_get_open_dialogs, exactly which dialog is open and already named the
  exact button to press -- the same "manual testing aid" use ADR-011 kept,
  now wired into the tool instead of a throwaway script. Windows-only by
  construction (the native TaskDialog case only exists on Windows). }

{$mode objfpc}{$H+}

interface

{ Finds the native (#32770 / TaskDialogIndirect) dialog window on the main
  thread and clicks the button whose visible caption matches AWantedButton.
  AExpectCaption, if non-empty, must match the dialog's title; otherwise
  there must be exactly one native dialog open. Returns the dialog's actual
  caption in ADialogCaption either way (for the caller's own mismatch
  message). On any platform other than Windows this always fails cleanly. }
function TryAnswerNativeDialog(const AExpectCaption, AWantedButton: string;
  out ADialogCaption, AErr: string): Boolean;

implementation

{$IFDEF WINDOWS}
uses
  Classes, SysUtils, Windows, McpIdeListeners, McpUtils;  { MainThreadID; NormalizeButtonCaption }

const
  DialogWindowClass = '#32770';

type
  TFindDialog = record
    ExpectCaption : string;
    Found         : HWND;
    FoundCaption  : string;
    MatchCount    : Integer;
  end;
  PFindDialog = ^TFindDialog;

  TFindButton = record
    Wanted    : string;
    Found     : HWND;
    Available : string;
  end;
  PFindButton = ^TFindButton;

function GetWinText(AWnd: HWND): string;
var
  Buf : array[0..1023] of WideChar;
  N   : Integer;
begin
  N := GetWindowTextW(AWnd, @Buf[0], Length(Buf));
  if N <= 0 then Exit('');
  Result := UTF8Encode(WideString(Copy(WideString(PWideChar(@Buf[0])), 1, N)));
end;

function GetWinClass(AWnd: HWND): string;
var
  Buf : array[0..255] of WideChar;
  N   : Integer;
begin
  N := GetClassNameW(AWnd, @Buf[0], Length(Buf));
  if N <= 0 then Exit('');
  Result := UTF8Encode(WideString(Copy(WideString(PWideChar(@Buf[0])), 1, N)));
end;

function EnumDialogProc(AWnd: HWND; ALParam: LPARAM): WINBOOL; stdcall;
var
  F   : PFindDialog;
  Cap : string;
begin
  Result := True;
  F := PFindDialog(McpIntToPtr(ALParam));
  if not IsWindowVisible(AWnd) then Exit;
  if GetWinClass(AWnd) <> DialogWindowClass then Exit;
  Cap := GetWinText(AWnd);
  if (F^.ExpectCaption <> '') then
  begin
    if not SameText(Trim(Cap), Trim(F^.ExpectCaption)) then Exit;
    F^.Found        := AWnd;
    F^.FoundCaption := Cap;
    F^.MatchCount   := 1;
    Result := False;  { exact match requested: stop }
  end
  else
  begin
    Inc(F^.MatchCount);
    F^.Found        := AWnd;  { last one wins if ambiguous; MatchCount flags it }
    F^.FoundCaption := Cap;
  end;
end;

function EnumButtonProc(AWnd: HWND; ALParam: LPARAM): WINBOOL; stdcall;
var
  F    : PFindButton;
  Text : string;
begin
  Result := True;
  F := PFindButton(McpIntToPtr(ALParam));
  if GetWinClass(AWnd) <> 'Button' then Exit;
  Text := NormalizeButtonCaption(GetWinText(AWnd));
  if Text = '' then Exit;
  if F^.Available <> '' then F^.Available := F^.Available + ', ';
  F^.Available := F^.Available + Text;
  if SameText(Text, F^.Wanted) then
  begin
    F^.Found := AWnd;
    Result := False;
  end;
end;

function TryAnswerNativeDialog(const AExpectCaption, AWantedButton: string;
  out ADialogCaption, AErr: string): Boolean;
var
  FD : TFindDialog;
  FB : TFindButton;
begin
  Result := False;
  ADialogCaption := '';
  AErr := '';

  FD := Default(TFindDialog);
  FD.ExpectCaption := AExpectCaption;
  EnumThreadWindows(MainThreadID, @EnumDialogProc, McpPtrToInt(@FD));

  if FD.Found = 0 then
  begin
    if AExpectCaption <> '' then
      AErr := Format('No native dialog titled "%s" is open.', [AExpectCaption])
    else
      AErr := 'No native dialog is open.';
    Exit;
  end;
  if (AExpectCaption = '') and (FD.MatchCount > 1) then
  begin
    AErr := Format('%d native dialogs are open; pass "caption" to pick one.',
      [FD.MatchCount]);
    Exit;
  end;

  ADialogCaption := FD.FoundCaption;

  FB := Default(TFindButton);
  FB.Wanted := NormalizeButtonCaption(AWantedButton);
  EnumChildWindows(FD.Found, @EnumButtonProc, McpPtrToInt(@FB));
  if FB.Found = 0 then
  begin
    AErr := Format('No button "%s" on "%s". Available: %s',
      [AWantedButton, ADialogCaption, FB.Available]);
    Exit;
  end;

  SendMessage(FB.Found, BM_CLICK, 0, 0);
  Result := True;
end;

{$ELSE}

function TryAnswerNativeDialog(const AExpectCaption, AWantedButton: string;
  out ADialogCaption, AErr: string): Boolean;
begin
  ADialogCaption := '';
  AErr := 'Native dialog answering is only implemented on Windows.';
  Result := False;
end;

{$ENDIF}

end.
