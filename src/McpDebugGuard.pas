{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpDebugGuard;

{ Keeps IDE modals out of MCP-driven debug sessions and records what they
  would have shown.

  A state-change handler registered with DebugBoss runs on every debugger
  state change — before TDebugManager decides whether to show the
  "Execution stopped" dialog — and (re)wraps the debugger's OnException,
  OnFeedback, OnConsoleOutput and OnDbgOutput events.  The IDE re-assigns
  those events each time it initialises the debugger, so the wrap is checked
  on every notification.

  Behaviour differs only while GMcpDriven is set (by an MCP debugger command,
  cleared when the session ends):
    - stop / exit-code message  → suppressed via SetSkipStopMessage
    - exception                 → recorded, debugger breaks, no dialog
    - feedback (error/warning)  → recorded, answered OK, no dialog
  Sessions the user starts and drives keep the normal IDE dialogs.  Exceptions
  and program output are recorded in every session.

  Everything here runs on the IDE main thread. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
  BaseDebugManager,
  LazDebuggerIntfBaseTypes,  { TDBGState }
  DbgIntfDebuggerBase;

type
  TMcpExceptionRec = record
    Valid     : Boolean;
    Seq       : Integer;    { incremented per exception; lets callers detect new ones }
    ExcType   : string;     { external | internal | runerror }
    ClassName : string;
    Message   : string;
    FileName  : string;
    Line      : Integer;
    Address   : QWord;
    FuncName  : string;
  end;

var
  GMcpDriven       : Boolean = False;
  GMcpLastExc      : TMcpExceptionRec;
  GMcpLastFeedback : string = '';     { last suppressed feedback text }

{ Call on the main thread before an MCP tool issues a debugger command. }
procedure McpMarkDebugDriven;
{ Register the state handler if DebugBoss exists and it is not registered yet.
  Safe to call repeatedly (main thread only). }
procedure McpEnsureDebugGuard;
{ Unhook from the debugger; call from the IDE-close handler while DebugBoss
  is still alive. }
procedure McpShutdownDebugGuard;
procedure McpFinalizeDebugGuard;
{ Last AMaxLines lines of debuggee console output and debugger output. }
function McpGetConsoleOutput(AMaxLines: Integer): string;
function McpGetDebugOutput(AMaxLines: Integer): string;
procedure McpClearDebugOutput;

implementation

const
  MAX_BUFFERED_LINES = 2000;

type
  TMcpDebugGuard = class
  private
    FRegistered    : Boolean;
    FShutdown      : Boolean;   { IDE closing: forward everything unchanged }
    FDebugger      : TDebuggerIntf;     { debugger the originals belong to }
    FOrigException : TDBGExceptionEvent;
    FOrigFeedback  : TDBGFeedbackEvent;
    FOrigConsole   : TDBGOutputEvent;
    FOrigDbgOutput : TDBGOutputEvent;
    FConsole       : TStringList;
    FDbgOutput     : TStringList;
    procedure Install(ADebugger: TDebuggerIntf);
    procedure Uninstall;
    procedure StateChanged(ADebugger: TDebuggerIntf; AOldState: TDBGState);
    procedure DoException(Sender: TObject; const AExceptionType: TDBGExceptionType;
      const AExceptionClass: String; const AExceptionLocation: TDBGLocationRec;
      const AExceptionText: String; out AContinue: Boolean);
    function DoFeedback(Sender: TObject; const AText, AInfo: String;
      AType: TDBGFeedbackType; AButtons: TDBGFeedbackResults): TDBGFeedbackResult;
    procedure DoConsoleOutput(Sender: TObject; const AText: String);
    procedure DoDbgOutput(Sender: TObject; const AText: String);
  public
    constructor Create;
    destructor Destroy; override;
  end;

var
  GGuard : TMcpDebugGuard = nil;

procedure AppendCapped(AList: TStringList; const AText: string);
var
  Lines : TStringList;
begin
  Lines := TStringList.Create;  { AText may hold several lines }
  try
    Lines.Text := AText;
    AList.AddStrings(Lines);
  finally
    Lines.Free;
  end;
  while AList.Count > MAX_BUFFERED_LINES do
    AList.Delete(0);
end;

function TailOf(AList: TStringList; AMaxLines: Integer): string;
var
  I, First : Integer;
begin
  Result := '';
  if AList = nil then Exit;
  First := 0;
  if (AMaxLines > 0) and (AList.Count > AMaxLines) then
    First := AList.Count - AMaxLines;
  for I := First to AList.Count - 1 do
    Result := Result + AList[I] + LineEnding;
end;

{ TMcpDebugGuard }

constructor TMcpDebugGuard.Create;
begin
  inherited Create;
  FConsole   := TStringList.Create;
  FDbgOutput := TStringList.Create;
end;

destructor TMcpDebugGuard.Destroy;
begin
  { No DebugBoss access here: unit finalization runs after the IDE has torn
    down the debug manager.  McpShutdownDebugGuard unhooks while it is alive. }
  FConsole.Free;
  FDbgOutput.Free;
  inherited Destroy;
end;

procedure TMcpDebugGuard.Install(ADebugger: TDebuggerIntf);
var
  Mine : TDBGExceptionEvent;
begin
  if ADebugger = nil then Exit;
  Mine := @DoException;
  if (ADebugger = FDebugger) and
     (TMethod(ADebugger.OnException).Code = TMethod(Mine).Code) and
     (TMethod(ADebugger.OnException).Data = TMethod(Mine).Data) then
    Exit;  { already wrapped }
  { New debugger object, or the IDE re-assigned its handlers: keep the IDE's
    handlers as the ones to forward to. }
  FDebugger      := ADebugger;
  FOrigException := ADebugger.OnException;
  FOrigFeedback  := ADebugger.OnFeedback;
  FOrigConsole   := ADebugger.OnConsoleOutput;
  FOrigDbgOutput := ADebugger.OnDbgOutput;
  ADebugger.OnException     := @DoException;
  ADebugger.OnFeedback      := @DoFeedback;
  ADebugger.OnConsoleOutput := @DoConsoleOutput;
  ADebugger.OnDbgOutput     := @DoDbgOutput;
end;

procedure TMcpDebugGuard.Uninstall;
begin
  { The debugger object may already be gone (it is freed without a state
    notification), so never write to it here.  The wrappers stay attached but
    turn into plain pass-through. }
  FShutdown := True;
  GMcpDriven := False;
end;

procedure TMcpDebugGuard.StateChanged(ADebugger: TDebuggerIntf;
  AOldState: TDBGState);
begin
  if (ADebugger = nil) or FShutdown then Exit;
  Install(ADebugger);

  case ADebugger.State of
    dsInit:
      if AOldState in [dsNone, dsIdle, dsStop] then
      begin
        { new session: forget the previous one }
        GMcpLastExc.Valid := False;
        FConsole.Clear;
        FDbgOutput.Clear;
      end;
    dsRun:
      if AOldState = dsPause then
        GMcpLastExc.Valid := False;  { resumed past the exception }
    dsStop, dsNone, dsIdle, dsError:
      if GMcpDriven then
      begin
        { Runs before TDebugManager shows "Execution stopped" (exit code) }
        if ADebugger.State = dsStop then
          ADebugger.SetSkipStopMessage;
        if AOldState in [dsInit, dsRun, dsPause, dsInternalPause] then
          GMcpDriven := False;  { session over }
      end;
  end;
end;

procedure TMcpDebugGuard.DoException(Sender: TObject;
  const AExceptionType: TDBGExceptionType; const AExceptionClass: String;
  const AExceptionLocation: TDBGLocationRec; const AExceptionText: String;
  out AContinue: Boolean);
begin
  AContinue := False;
  if FShutdown then
  begin
    if Assigned(FOrigException) then
      FOrigException(Sender, AExceptionType, AExceptionClass,
        AExceptionLocation, AExceptionText, AContinue);
    Exit;
  end;
  GMcpLastExc.Valid     := True;
  Inc(GMcpLastExc.Seq);
  case AExceptionType of
    deInternal : GMcpLastExc.ExcType := 'internal';
    deRunError : GMcpLastExc.ExcType := 'runerror';
  else           GMcpLastExc.ExcType := 'external';
  end;
  GMcpLastExc.ClassName := AExceptionClass;
  GMcpLastExc.Message   := AExceptionText;
  GMcpLastExc.FileName  := AExceptionLocation.SrcFullName;
  if GMcpLastExc.FileName = '' then
    GMcpLastExc.FileName := AExceptionLocation.SrcFile;
  GMcpLastExc.Line      := AExceptionLocation.SrcLine;
  GMcpLastExc.Address   := AExceptionLocation.Address;
  GMcpLastExc.FuncName  := AExceptionLocation.FuncName;

  if GMcpDriven then
    Exit;  { AContinue=False: break at the exception, no dialog }
  if Assigned(FOrigException) then
    FOrigException(Sender, AExceptionType, AExceptionClass,
      AExceptionLocation, AExceptionText, AContinue);
end;

function TMcpDebugGuard.DoFeedback(Sender: TObject; const AText,
  AInfo: String; AType: TDBGFeedbackType;
  AButtons: TDBGFeedbackResults): TDBGFeedbackResult;
begin
  if (GMcpDriven and not FShutdown) or not Assigned(FOrigFeedback) then
  begin
    GMcpLastFeedback := AText;
    if AInfo <> '' then
      GMcpLastFeedback := GMcpLastFeedback + LineEnding + AInfo;
    AppendCapped(FDbgOutput, '[feedback] ' + AText);
    if (frOk in AButtons) or (AButtons = []) then
      Result := frOk
    else
      Result := frStop;
    Exit;
  end;
  Result := FOrigFeedback(Sender, AText, AInfo, AType, AButtons);
end;

procedure TMcpDebugGuard.DoConsoleOutput(Sender: TObject; const AText: String);
begin
  AppendCapped(FConsole, AText);
  if Assigned(FOrigConsole) then
    FOrigConsole(Sender, AText);
end;

procedure TMcpDebugGuard.DoDbgOutput(Sender: TObject; const AText: String);
begin
  AppendCapped(FDbgOutput, AText);
  if Assigned(FOrigDbgOutput) then
    FOrigDbgOutput(Sender, AText);
end;

{ ── Public API ───────────────────────────────────────────────────────────── }

procedure McpEnsureDebugGuard;
begin
  if not Assigned(DebugBoss) then Exit;
  if GGuard = nil then
    GGuard := TMcpDebugGuard.Create;
  if not GGuard.FRegistered then
  begin
    { The debugger object is only reachable through the notification; the
      first state change of every session installs the wrappers. }
    DebugBoss.RegisterStateChangeHandler(@GGuard.StateChanged);
    GGuard.FRegistered := True;
  end;
end;

procedure McpMarkDebugDriven;
begin
  McpEnsureDebugGuard;
  GMcpDriven := True;
end;

procedure McpShutdownDebugGuard;
begin
  if GGuard = nil then Exit;
  GGuard.Uninstall;
  if GGuard.FRegistered and Assigned(DebugBoss) and not DebugBoss.Destroying then
    DebugBoss.UnregisterStateChangeHandler(@GGuard.StateChanged);
  GGuard.FRegistered := False;
end;

procedure McpFinalizeDebugGuard;
begin
  FreeAndNil(GGuard);
end;

function McpGetConsoleOutput(AMaxLines: Integer): string;
begin
  if GGuard = nil then Exit('');
  Result := TailOf(GGuard.FConsole, AMaxLines);
end;

function McpGetDebugOutput(AMaxLines: Integer): string;
begin
  if GGuard = nil then Exit('');
  Result := TailOf(GGuard.FDbgOutput, AMaxLines);
end;

procedure McpClearDebugOutput;
begin
  if GGuard = nil then Exit;
  GGuard.FConsole.Clear;
  GGuard.FDbgOutput.Clear;
end;

finalization
  McpFinalizeDebugGuard;

end.
