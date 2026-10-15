{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsDebugger;

{ Debugger tools: debug_set_breakpoint, debug_remove_breakpoint, debug_list_breakpoints,
  debug_get_state,
  debug_run, debug_pause, debug_stop,
  debug_step_over, debug_step_into, debug_step_out, debug_run_to_line,
  debug_get_call_stack, debug_evaluate,
  debug_get_locals, debug_set_variable,
  debug_get_registers, debug_disassemble.

  Threading model:
    Non-blocking tools  — dispatched via DispatchDebuggerTool, which runs on
                          the IDE main thread (normal SyncCallTool path).
    Blocking tools      — dispatched via DispatchDebuggerBlockingTool, which
                          runs on the MCP worker thread and issues IDE commands
                          through TThread.Synchronize while polling DebugBoss.State
                          on the worker thread between commands. }

{$mode objfpc}{$H+}

interface

implementation

uses
  Classes, SysUtils, Math, Forms, Controls, LazLogger,
  LazIDEIntf, LazFileUtils, SrcEditorIntf,
  BaseDebugManager,
  LazDebuggerIntfBaseTypes,  { TDBGState }
  LazDebuggerIntf,           { TDebuggerDataState (ddsValid, ddsRequested, …) }
  DbgIntfDebuggerBase,       { TDBGType, TDBGEvaluateResultCallback }
  Debugger,                  { TIDEBreakPoint, TIDEBreakPoints }
  IdeDebuggerBase,           { TWatchValue / TLocalsValue .ResultData }
  IdeDebuggerWatchResult,    { TWatchResultData }
  IdeDebuggerWatchValueIntf, { DefaultWatchDisplayFormat }
  IdeDebuggerWatchResPrinter,{ TWatchResultPrinter }
  TypInfo,
  fpjson,
  McpDebugGuard,             { GMcpLastExc, McpMarkDebugDriven }
  McpDebugLease,             { McpLeaseJSON }
  McpIdeListeners,           { GMcpExceptionDialogHwnd }
  McpToolContext;


{ ── Sync helper class ────────────────────────────────────────────────────── }
{ Each method is safe to pass to TThread.Synchronize.
  Fields act as in/out parameters for the synchronised operation.
  Only one debug operation runs at a time (MCP calls are serialised), so a
  single shared instance is sufficient. }

type
  TDbgSyncHelper = class
  public
    { ReadState output }
    OutState    : TDBGState;
    OutFileName : string;
    OutLine     : Integer;
    OutExcValid : Boolean;  { snapshot of GMcpLastExc — strings are main-thread data }
    OutExcSeq   : Integer;
    OutExcJSON  : string;
    OutFeedback : string;   { suppressed debugger messages, accumulated; worker resets }
    { IssueCmd input }
    InCmd       : Integer;  { 0=run 1=pause 2=stop 3=stepover 4=stepinto 5=stepout }
    { Breakpoint in/out: the location (one kind), then the properties to set;
      a property is changed only when its InBpSet* flag is True }
    InBpKind       : TDBGBreakPointKind;
    InBpFile       : string;
    InBpLine       : Integer;
    InBpAddr       : TDBGPtr;
    InBpData       : string;
    InBpScope      : TDBGWatchPointScope;
    InBpWatch      : TDBGWatchPointKind;
    InBpEnabled    : Boolean;
    InBpSetEnabled : Boolean;
    InBpCond       : string;
    InBpSetCond    : Boolean;
    InBpPass       : Integer;
    InBpSetPass    : Boolean;
    InBpOnlyIfNew  : Boolean;  { leave an existing breakpoint as it is (run_to_line) }
    OutBp          : TIDEBreakPoint;
    OutBpCreated   : Boolean;
    OutBpFound     : Boolean;
    { Evaluate in/out }
    InEvalExpr     : string;
    OutEvalRes     : string;
    OutEvalType    : string;
    OutEvalOk      : Boolean;
    FEvalFired     : Boolean;
    OutEvalStarted : Boolean;  { True = DebugBoss.Evaluate returned True }
    { CallStack in/out }
    InMaxFrames   : Integer;
    InCSThread    : Integer;  { 0 = the current thread; reset to 0 after use }
    OutCSThreadId : Integer;
    OutCSCount    : Integer;  { -1 = count not known yet; else frames to return }
    OutCSReady    : Boolean;
    OutCSJSON     : string;
    { Thread/frame selection in/out (debug_select_frame, evaluate) }
    InSelThread    : Integer;
    InSelFrame     : Integer;
    OutSelThread   : Integer;
    OutSelFrame    : Integer;
    { Local variables in/out }
    InLocalsThread : Integer;   { 0 = the current thread }
    InLocalsFrame  : Integer;
    OutLocalsThread: Integer;
    OutLocalsReady : Boolean;
    OutLocalsJSON  : string;
    { Watches / threads out (same init-once / read-only-poll pattern) }
    InWatchThread  : Integer;   { -1 = the current thread and selected frame }
    InWatchFrame   : Integer;
    OutWatchThread : Integer;
    OutWatchFrame  : Integer;
    OutWatchReady  : Boolean;
    OutWatchJSON   : string;
    OutThrReady    : Boolean;
    OutThrJSON     : string;
    { Registers in/out }
    InRegThread    : Integer;   { 0 = the current thread }
    InRegFrame     : Integer;
    OutRegThread   : Integer;
    OutRegReady    : Boolean;
    OutRegJSON     : string;
    OutRegErr      : string;
    { Disassembler in/out }
    InAsmAddr      : TDBGPtr;
    InAsmBefore    : Integer;
    InAsmAfter     : Integer;
    OutAsmReady    : Boolean;
    OutAsmJSON     : string;
    OutAsmErr      : string;
    { Methods }
    procedure ReadState;
    procedure IssueCmd;
    function FindBreakpoint: TIDEBreakPoint;
    procedure AddBreakpoint;     { find or create, then apply the InBpSet* properties }
    procedure RemoveBreakpoint;
    procedure DoEvaluateAndWait;  { single Synchronize: starts eval + waits on main thread }
    procedure ReadSelection;      { current thread and selected frame }
    procedure RequestThread;      { ask for InSelThread; applied asynchronously }
    procedure RequestFrame;       { ask for InSelFrame in the current thread }
    procedure InitCallStack;
    procedure ReadCallStack;
    procedure InitLocals;
    procedure ReadLocals;
    procedure InitWatches;
    procedure ReadWatches;
    procedure ReadWatchNames;  { expressions only — not paused or timed out }
    procedure InitThreads;
    procedure ReadThreads;
    procedure InitRegisters;
    procedure ReadRegisters;
    procedure PrepareDisasm;   { first call starts loading; later calls poll }
    procedure BreakAtExceptionDialog;
    procedure StopLater(Data: PtrInt);
  end;

var
  GSyncHelper : TDbgSyncHelper = nil;

{ The IDE's "Debugger Exception Notification" dialog, if it is showing; it
  appears only in sessions the user drives (McpDebugGuard prevents it in
  MCP-driven ones).  Main thread. }
function FindExceptionDialog: TCustomForm;
var
  I : Integer;
begin
  for I := 0 to Screen.CustomFormCount - 1 do
    if Screen.CustomForms[I].ClassNameIs('TIDEExceptionDlg') and
       Screen.CustomForms[I].Visible and
       (fsModal in Screen.CustomForms[I].FormState) then
      Exit(Screen.CustomForms[I]);
  Result := nil;
end;

{ Take over a session the user started that is waiting in the exception
  dialog: answer it with Break (mrOK; Continue is mrCancel), so the program
  pauses at the exception, and mark the session as MCP-driven.  Runs inside
  the dialog's modal loop; the dialog closes once this returns. }
procedure TDbgSyncHelper.BreakAtExceptionDialog;
var
  Dlg : TCustomForm;
begin
  Dlg := FindExceptionDialog;
  if Dlg = nil then Exit;
  McpMarkDebugDriven;
  DebugLn(['[MCP Assistant] took over the debug session: answered ',
           Dlg.Caption, ' with Break']);
  Dlg.ModalResult := mrOK;
end;

procedure TDbgSyncHelper.StopLater(Data: PtrInt);
begin
  if Assigned(DebugBoss) then
    DebugBoss.DoStopProject;
end;

{ Render a watch/local result the way the IDE's hints and Watches window do.
  The plain Value string is empty for structured values (objects, records). }
function PrintResult(AData: TWatchResultData; const APlain, AExpr: string): string;
const
  MAX_VALUE_LEN = 2000;  { an object dump can be tens of KB }
var
  Printer  : TWatchResultPrinter;
  OldFlags : TWatchResultPrinterFormatFlags;
begin
  Result := APlain;
  if Assigned(AData) and Assigned(DebugBoss) and
     Assigned(DebugBoss.HintWatchPrinter) then
  begin
    Printer  := DebugBoss.HintWatchPrinter;
    OldFlags := Printer.FormatFlags;
    Printer.FormatFlags := [];  { single line }
    try
      try
        Result := Printer.PrintWatchValue(AData, DefaultWatchDisplayFormat, AExpr);
      except
        Result := APlain;
      end;
    finally
      Printer.FormatFlags := OldFlags;
    end;
  end;
  if Length(Result) > MAX_VALUE_LEN then
    Result := Copy(Result, 1, MAX_VALUE_LEN) + '... (truncated; evaluate a field for details)';
end;

function ExceptionJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('type',     GMcpLastExc.ExcType);
  Result.Add('class',    GMcpLastExc.ClassName);
  Result.Add('message',  GMcpLastExc.Message);
  Result.Add('file',     GMcpLastExc.FileName);
  Result.Add('line',     GMcpLastExc.Line);
  Result.Add('function', GMcpLastExc.FuncName);
  Result.Add('address',  Format('$%x', [GMcpLastExc.Address]));
end;

procedure TDbgSyncHelper.ReadState;
var
  Ed  : TSourceEditorInterface;
  Exc : TJSONObject;
begin
  OutState    := dsNone;
  OutFileName := '';
  OutLine     := 0;
  OutExcValid := GMcpLastExc.Valid;
  OutExcSeq   := GMcpLastExc.Seq;
  OutExcJSON  := '';
  if OutExcValid then
  begin
    Exc := ExceptionJSON;
    try
      OutExcJSON := Exc.AsJSON;
    finally
      Exc.Free;
    end;
  end;
  if GMcpLastFeedback <> '' then
  begin
    if OutFeedback <> '' then
      OutFeedback := OutFeedback + LineEnding;
    OutFeedback      := OutFeedback + GMcpLastFeedback;
    GMcpLastFeedback := '';
  end;
  if not Assigned(DebugBoss) then Exit;
  OutState := DebugBoss.State;
  if OutState = dsPause then
  begin
    Ed := SourceEditorManagerIntf.ActiveEditor;
    if Assigned(Ed) then
    begin
      OutFileName := Ed.FileName;
      OutLine     := Ed.CursorTextXY.Y;
    end;
  end;
end;

procedure TDbgSyncHelper.IssueCmd;
begin
  McpMarkDebugDriven;  { no stop/exception/feedback modals for this session }
  case InCmd of
    { Run/continue: use the full F9 path so a fresh session initializes the
      debugger backend and sets ToolStatus=itDebugger before calling
      StartDebugging. DebugBoss.RunDebugger alone requires ToolStatus to already
      be itDebugger, which is not the case when starting from dsNone. }
    0 : LazarusIDE.DoRunProjectWithDebug;
    1 : begin if Assigned(DebugBoss) then DebugBoss.DoPauseProject; end;
    2 : begin if Assigned(DebugBoss) then DebugBoss.DoStopProject; end;
    3 : begin if Assigned(DebugBoss) then DebugBoss.DoStepOverProject; end;
    4 : begin if Assigned(DebugBoss) then DebugBoss.DoStepIntoProject; end;
    5 : begin if Assigned(DebugBoss) then DebugBoss.DoStepOutProject; end;
  end;
end;

function TDbgSyncHelper.FindBreakpoint: TIDEBreakPoint;
var
  I  : Integer;
  BP : TIDEBreakPoint;
begin
  Result := nil;
  if not Assigned(DebugBoss) or not Assigned(DebugBoss.BreakPoints) then Exit;
  for I := 0 to DebugBoss.BreakPoints.Count - 1 do
  begin
    BP := DebugBoss.BreakPoints.Items[I];
    if BP.Kind <> InBpKind then Continue;
    case InBpKind of
      bpkSource  : if (BP.Line = InBpLine) and
                      (CompareFilenames(BP.Source, InBpFile) = 0) then Exit(BP);
      bpkAddress : if BP.Address = InBpAddr then Exit(BP);
      bpkData    : if (BP.WatchScope = InBpScope) and (BP.WatchKind = InBpWatch) and
                      SameText(BP.WatchData, InBpData) then Exit(BP);
    end;
  end;
end;

procedure TDbgSyncHelper.AddBreakpoint;
begin
  OutBpCreated := False;
  OutBp := FindBreakpoint;
  if Assigned(OutBp) and InBpOnlyIfNew then Exit;
  if not Assigned(OutBp) then
  begin
    if not Assigned(DebugBoss) or not Assigned(DebugBoss.BreakPoints) then Exit;
    case InBpKind of
      bpkSource  : OutBp := DebugBoss.BreakPoints.Add(InBpFile, InBpLine);
      bpkAddress : OutBp := DebugBoss.BreakPoints.Add(InBpAddr);
      bpkData    : OutBp := DebugBoss.BreakPoints.Add(InBpData, InBpScope, InBpWatch);
    end;
    if not Assigned(OutBp) then Exit;
    OutBpCreated := True;
    OutBp.Enabled := not InBpSetEnabled or InBpEnabled;
  end
  else if InBpSetEnabled then
    OutBp.Enabled := InBpEnabled;
  if InBpSetCond then
    OutBp.Expression := InBpCond;
  if InBpSetPass then
    OutBp.BreakHitCount := InBpPass;
end;

procedure TDbgSyncHelper.RemoveBreakpoint;
var
  BP : TIDEBreakPoint;
begin
  BP := FindBreakpoint;
  OutBpFound := Assigned(BP);
  if OutBpFound then
    BP.Free;
end;

const
  WATCH_KINDS : array[TDBGWatchPointKind] of string = ('write', 'read', 'readwrite', 'exec');
  WATCH_SCOPES: array[TDBGWatchPointScope] of string = ('local', 'global');

{ A number in Pascal ($1F), C (0x1F) or decimal notation. }
function ParseAddress(const S: string; out AAddr: TDBGPtr): Boolean;
var
  T : string;
  Q : QWord;
begin
  T := Trim(S);
  if SameText(Copy(T, 1, 2), '0x') then
    T := '$' + Copy(T, 3, MaxInt);
  Result := (T <> '') and TryStrToQWord(T, Q);
  if Result then
    AAddr := Q;
end;

{ Fill GSyncHelper's InBp* fields from the arguments of debug_set_breakpoint
  / debug_remove_breakpoint / debug_run_to_line.  Exactly one location:
  file + line, address, or data.  ASymbol receives an address that is
  not a number (a symbol, resolved by the caller while paused); '' else. }
function ReadBreakpointArgs(P: TJSONObject; out ASymbol, AErr: string): Boolean;
var
  Forms : Integer;
  S     : string;
  I     : TDBGWatchPointKind;
begin
  Result  := False;
  ASymbol := '';
  AErr    := '';
  if not Assigned(P) then
  begin
    AErr := 'Give file and line, address, or data';
    Exit;
  end;
  Forms := Ord(P.Get('file', '') <> '') + Ord(P.Get('address', '') <> '') +
           Ord(P.Get('data', '') <> '');
  if Forms <> 1 then
  begin
    AErr := 'Give exactly one location: file and line, address, or data';
    Exit;
  end;
  with GSyncHelper do
  begin
    InBpSetEnabled := Assigned(P.Find('enabled'));
    InBpEnabled    := P.Get('enabled', True);
    InBpSetCond    := Assigned(P.Find('condition'));
    InBpCond       := Trim(P.Get('condition', ''));
    InBpSetPass    := Assigned(P.Find('pass_count'));
    InBpPass       := P.Get('pass_count', 0);
    InBpOnlyIfNew  := False;
    if P.Get('file', '') <> '' then
    begin
      InBpKind := bpkSource;
      InBpFile := CleanAndExpandFilename(P.Get('file', ''));
      InBpLine := P.Get('line', 0);
      if InBpLine < 1 then
      begin
        AErr := 'line required (1-based)';
        Exit;
      end;
    end
    else if P.Get('address', '') <> '' then
    begin
      InBpKind := bpkAddress;
      S := Trim(P.Get('address', ''));
      if not ParseAddress(S, InBpAddr) then
        ASymbol := S;
    end
    else
    begin
      InBpKind  := bpkData;
      InBpData  := Trim(P.Get('data', ''));
      S := LowerCase(P.Get('scope', 'global'));
      if S = 'global' then InBpScope := wpsGlobal
      else if S = 'local' then InBpScope := wpsLocal
      else
      begin
        AErr := 'scope must be global or local';
        Exit;
      end;
      S := LowerCase(P.Get('watch', 'write'));
      InBpWatch := wpkWrite;
      for I := wpkWrite to wpkReadWrite do
        if S = WATCH_KINDS[I] then
        begin
          InBpWatch := I;
          S := '';
        end;
      if S <> '' then
      begin
        AErr := 'watch must be write, read or readwrite';
        Exit;
      end;
    end;
  end;
  Result := True;
end;

{ The breakpoint as debug_set_breakpoint / debug_list_breakpoints report it }
function BreakpointJSON(BP: TIDEBreakPoint): TJSONObject;
begin
  Result := TJSONObject.Create;
  case BP.Kind of
    bpkSource :
    begin
      Result.Add('kind', 'source');
      Result.Add('file', BP.Source);
      Result.Add('line', BP.Line);
    end;
    bpkAddress :
    begin
      Result.Add('kind', 'address');
      Result.Add('address', Format('$%x', [BP.Address]));
    end;
    bpkData :
    begin
      Result.Add('kind',  'data');
      Result.Add('data',  BP.WatchData);
      Result.Add('scope', WATCH_SCOPES[BP.WatchScope]);
      Result.Add('watch', WATCH_KINDS[BP.WatchKind]);
    end;
  end;
  Result.Add('enabled', BP.Enabled);
  if BP.Expression <> '' then
    Result.Add('condition', BP.Expression);
  if BP.BreakHitCount > 0 then
    Result.Add('pass_count', BP.BreakHitCount);
  Result.Add('hit_count', BP.HitCount);
  case BP.Valid of
    vsValid    : Result.Add('valid', 'valid');
    vsInvalid  : Result.Add('valid', 'invalid');
    vsPending  : Result.Add('valid', 'pending');
  else            Result.Add('valid', 'unknown');
  end;
end;

{ One evaluation's callback.  An evaluation that timed out can still call
  back later; only the callback of the latest evaluation (Seq = GEvalSeq)
  writes the result, so a late one cannot pass for the next call's result.
  Everything here runs on the main thread. }
type
  TEvalCall = class
    Seq     : Integer;
    Started : Boolean;  { Evaluate returned True: the callback frees the object }
    Fired   : Boolean;
    procedure Callback(Sender: TObject; ASuccess: Boolean;
      ResultText: string; ResultDBGType: TDBGType);
  end;

var
  GEvalSeq : Integer = 0;

procedure TEvalCall.Callback(Sender: TObject; ASuccess: Boolean;
  ResultText: string; ResultDBGType: TDBGType);
begin
  Fired := True;
  if Seq = GEvalSeq then
  begin
    GSyncHelper.OutEvalOk  := ASuccess;
    GSyncHelper.OutEvalRes := ResultText;
    if Assigned(ResultDBGType) then
      GSyncHelper.OutEvalType := ResultDBGType.TypeName
    else
      GSyncHelper.OutEvalType := '';
    GSyncHelper.FEvalFired := True;
  end;
  if Started then
    Free;  { else DoEvaluateAndWait frees it after Evaluate returns }
end;

procedure TDbgSyncHelper.DoEvaluateAndWait;
{ Runs on the main thread via TThread.Synchronize.  Starts the async evaluation
  and returns immediately — the HTTP thread polls FEvalFired while the main
  thread's own event loop delivers the callback via ProcessAsyncCallQueue.
  OutEvalStarted records whether DebugBoss.Evaluate returned True. }
var
  Call : TEvalCall;
begin
  OutEvalOk      := False;
  OutEvalRes     := '';
  OutEvalType    := '';
  FEvalFired     := False;
  OutEvalStarted := False;
  Inc(GEvalSeq);  { from now on, earlier evaluations' callbacks are ignored }
  if not Assigned(DebugBoss) then
  begin
    FEvalFired := True;
    OutEvalRes := 'DebugBoss not assigned';
    Exit;
  end;
  Call := TEvalCall.Create;
  Call.Seq := GEvalSeq;
  try
    OutEvalStarted := DebugBoss.Evaluate(InEvalExpr, @Call.Callback);
    if not OutEvalStarted and not FEvalFired then
    begin
      FEvalFired := True;
      OutEvalRes := 'Evaluate returned False (dcEvaluate not in Commands or ToolStatus<>itDebugger)';
    end;
  except on E: Exception do
  begin
    FEvalFired := True;
    OutEvalRes := 'Exception: ' + E.Message;
  end;
  end;
  if OutEvalStarted and not Call.Fired then
    Call.Started := True  { the callback is still to come and frees it }
  else
    Call.Free;            { called back already, or never will be }
end;

procedure TDbgSyncHelper.ReadSelection;
var
  Stack : TIdeCallStack;
begin
  OutSelThread := 0;
  OutSelFrame  := 0;
  if not Assigned(DebugBoss) or not Assigned(DebugBoss.Threads) or
     not Assigned(DebugBoss.Threads.CurrentThreads) then Exit;
  OutSelThread := DebugBoss.Threads.CurrentThreads.CurrentThreadId;
  if Assigned(DebugBoss.CallStack) then
  begin
    Stack := DebugBoss.CallStack.CurrentCallStackList.EntriesForThreads[OutSelThread];
    if Assigned(Stack) then
      OutSelFrame := Stack.CurrentIndex;
  end;
end;

procedure TDbgSyncHelper.RequestThread;
begin
  if Assigned(DebugBoss) and Assigned(DebugBoss.Threads) then
    DebugBoss.Threads.ChangeCurrentThread(InSelThread);
end;

procedure TDbgSyncHelper.RequestFrame;
var
  Stack : TIdeCallStack;
begin
  if not Assigned(DebugBoss) or not Assigned(DebugBoss.CallStack) or
     not Assigned(DebugBoss.Threads) then Exit;
  Stack := DebugBoss.CallStack.CurrentCallStackList.EntriesForThreads[
             DebugBoss.Threads.CurrentThreads.CurrentThreadId];
  if Assigned(Stack) then
    Stack.ChangeCurrentIndex(InSelFrame);
end;

procedure TDbgSyncHelper.InitCallStack;
{ Trigger async call-stack load for the current thread.
  CountLimited → HasAtLeastCount → RequestAtLeastCount: this only updates the
  stack's "at least N" info.  CountValidity stays ddsUnknown unless the backend
  happened to read every frame, so ReadCallStack must not wait on it alone. }
var
  Stack : TIdeCallStack;
  TId   : Integer;
begin
  OutCSReady    := False;
  OutCSThreadId := 0;
  OutCSCount    := -1;
  OutCSJSON     := '';
  if not Assigned(DebugBoss) or not Assigned(DebugBoss.CallStack) then Exit;
  if Assigned(DebugBoss.Threads) and
     Assigned(DebugBoss.Threads.CurrentThreads) then
    TId := DebugBoss.Threads.CurrentThreads.CurrentThreadId
  else
    TId := 0;
  if InCSThread > 0 then
    TId := InCSThread;
  OutCSThreadId := TId;
  Stack := DebugBoss.CallStack.CurrentCallStackList.EntriesForThreads[TId];
  if not Assigned(Stack) then Exit;
  Stack.CountLimited(InMaxFrames + 1);  { trigger async load }
end;

procedure TDbgSyncHelper.ReadCallStack;
{ Called from blocking worker via Synchronize until OutCSReady = True.
  Two async phases, each triggered exactly once:
    1. count  — InitCallStack requested "at least InMaxFrames+1" frames; wait
                until either the full count or that minimum is known.
    2. frames — PrepareRange creates the entries as ddsRequested and queues
                one worker per frame; wait until none is still pending.
  Both checks below only read state: HasAtLeastCount re-requests only while its
  validity is ddsUnknown (never the case after InitCallStack), and Entries[I]
  on an entry PrepareRange already created is a plain lookup. }
var
  Stack  : TIdeCallStack;
  Entry  : TIdeCallStackEntry;
  Arr    : TJSONArray;
  EObj   : TJSONObject;
  I      : Integer;
begin
  OutCSReady := False;
  if not Assigned(DebugBoss) or not Assigned(DebugBoss.CallStack) then
  begin
    OutCSReady := True;  { nothing available — stop polling }
    OutCSJSON  := '[]';
    Exit;
  end;
  Stack := DebugBoss.CallStack.CurrentCallStackList.EntriesForThreads[OutCSThreadId];
  if not Assigned(Stack) then
  begin
    OutCSReady := True;
    OutCSJSON  := '[]';
    Exit;
  end;

  { Phase 1 — frame count }
  if OutCSCount < 0 then
  begin
    case Stack.CountValidity of
      ddsValid:
        if Stack.Count < InMaxFrames then
          OutCSCount := Stack.Count
        else
          OutCSCount := InMaxFrames;
      ddsInvalid, ddsError:
        OutCSCount := 0;
    else
      if Stack.HasAtLeastCount(InMaxFrames + 1) = nbTrue then
        OutCSCount := InMaxFrames
      else
        Exit;  { still loading; caller retries }
    end;
    if OutCSCount > 0 then
      Stack.PrepareRange(0, OutCSCount);  { trigger async frame load, once }
    Exit;  { frames are read on the next poll }
  end;

  { Phase 2 — frame details }
  for I := 0 to OutCSCount - 1 do
  begin
    Entry := Stack.Entries[I];
    if Assigned(Entry) and
       (Entry.Validity in [ddsUnknown, ddsRequested, ddsEvaluating]) then
      Exit;  { still loading; caller retries }
  end;

  Arr := TJSONArray.Create;
  try
    for I := 0 to OutCSCount - 1 do
    begin
      Entry := Stack.Entries[I];
      if Entry = nil then Continue;
      EObj := TJSONObject.Create;
      EObj.Add('index',    I);
      EObj.Add('file',     Entry.Source);
      EObj.Add('line',     Entry.Line);
      EObj.Add('function', Entry.FunctionName);
      EObj.Add('address',  Format('$%x', [Entry.Address]));
      Arr.Add(EObj);
    end;
    OutCSJSON  := Arr.AsJSON;
    OutCSReady := True;
  finally
    Arr.Free;
  end;
end;

procedure TDbgSyncHelper.InitLocals;
var
  TId    : Integer;
  Locals : TIDELocals;
begin
  OutLocalsReady  := False;
  OutLocalsJSON   := '[]';
  OutLocalsThread := 0;
  if not Assigned(DebugBoss) or not Assigned(DebugBoss.Locals) then
  begin
    OutLocalsReady := True; Exit;
  end;
  if Assigned(DebugBoss.Threads) and
     Assigned(DebugBoss.Threads.CurrentThreads) then
    TId := DebugBoss.Threads.CurrentThreads.CurrentThreadId
  else
    TId := 0;
  if InLocalsThread > 0 then
    TId := InLocalsThread;
  OutLocalsThread := TId;
  Locals := DebugBoss.Locals.CurrentLocalsList[TId, InLocalsFrame];
  if Assigned(Locals) then
    Locals.Count;  { trigger async load }
end;

procedure TDbgSyncHelper.ReadLocals;
var
  Locals : TIDELocals;
  LVal   : TIdeLocalsValue;
  Arr    : TJSONArray;
  LObj   : TJSONObject;
  I      : Integer;
begin
  OutLocalsReady := False;
  if not Assigned(DebugBoss) or not Assigned(DebugBoss.Locals) then
  begin
    OutLocalsReady := True; Exit;
  end;
  Locals := DebugBoss.Locals.CurrentLocalsList[OutLocalsThread, InLocalsFrame];
  if not Assigned(Locals) then
  begin
    OutLocalsReady := True;
    OutLocalsJSON  := '[]';
    Exit;
  end;
  if Locals is TCurrentLocals then
  begin
    case TCurrentLocals(Locals).Validity of
      ddsValid   : ;  { fall through to build JSON }
      ddsInvalid :
      begin
        OutLocalsReady := True;  { terminal failure — stop polling }
        Exit;
      end;
    else
      Exit;  { ddsUnknown/ddsRequested/ddsEvaluating — still loading, caller retries }
    end;
  end;
  Arr := TJSONArray.Create;
  try
    for I := 0 to Locals.Count - 1 do
    begin
      LVal := TIdeLocalsValue(Locals.Entries[I]);
      LObj := TJSONObject.Create;
      LObj.Add('name',  LVal.DisplayName);
      LObj.Add('value', PrintResult(LVal.ResultData, LVal.Value, LVal.Name));
      Arr.Add(LObj);
    end;
    OutLocalsJSON  := Arr.AsJSON;
    OutLocalsReady := True;
  finally
    Arr.Free;
  end;
end;

{ ── Watches ── }

function CurrentThreadAndFrame(out AThread, AFrame: Integer): Boolean;
var
  Stack : TIdeCallStack;
begin
  AThread := 0;
  AFrame  := 0;
  Result  := Assigned(DebugBoss) and Assigned(DebugBoss.Threads) and
             Assigned(DebugBoss.Threads.CurrentThreads);
  if not Result then Exit;
  AThread := DebugBoss.Threads.CurrentThreads.CurrentThreadId;
  if Assigned(DebugBoss.CallStack) then
  begin
    Stack := DebugBoss.CallStack.CurrentCallStackList.EntriesForThreads[AThread];
    if Assigned(Stack) and (Stack.CurrentIndex > 0) then
      AFrame := Stack.CurrentIndex;  { frame selected in the Call Stack window }
  end;
end;

{ Registers: the Registers window's data, which Count requests when unknown,
  so no window has to be open.  DisplayFormat is left alone: it is shared
  with that window. }
procedure TDbgSyncHelper.InitRegisters;
var
  Regs : TRegisters;
begin
  OutRegReady := False;
  OutRegJSON  := '';
  OutRegErr   := '';
  if not Assigned(DebugBoss) or not Assigned(DebugBoss.Registers) or
     not Assigned(DebugBoss.Registers.Supplier) then
  begin
    OutRegErr   := 'This debugger backend does not provide registers';
    OutRegReady := True;
    Exit;
  end;
  OutRegThread := InRegThread;
  if (OutRegThread <= 0) and Assigned(DebugBoss.Threads) and
     Assigned(DebugBoss.Threads.CurrentThreads) then
    OutRegThread := DebugBoss.Threads.CurrentThreads.CurrentThreadId;
  Regs := DebugBoss.Registers.CurrentRegistersList[OutRegThread, InRegFrame];
  if Assigned(Regs) then
    Regs.Count;   { trigger async load }
end;

procedure TDbgSyncHelper.ReadRegisters;
var
  Regs : TRegisters;
  R    : TRegisterValue;
  Arr  : TJSONArray;
  RObj : TJSONObject;
  I    : Integer;
  Num  : QWord;
begin
  if OutRegReady then Exit;
  if not Assigned(DebugBoss) or not Assigned(DebugBoss.Registers) then
  begin
    OutRegErr := 'The debug session ended'; OutRegReady := True; Exit;
  end;
  Regs := DebugBoss.Registers.CurrentRegistersList[OutRegThread, InRegFrame];
  if not Assigned(Regs) then
  begin
    OutRegErr := 'No registers for this thread and frame'; OutRegReady := True; Exit;
  end;
  case Regs.DataValidity of
    ddsValid: ;
    ddsInvalid, ddsError:
      begin
        OutRegErr := 'The debugger could not read the registers of this thread and frame';
        OutRegReady := True;
        Exit;
      end;
  else
    Exit;   { still loading; caller retries }
  end;
  Arr := TJSONArray.Create;
  try
    for I := 0 to Regs.Count - 1 do
    begin
      R := Regs.Entries[I];
      RObj := TJSONObject.Create;
      Arr.Add(RObj);
      RObj.Add('name', R.Name);
      RObj.Add('value', R.Value);
      { the window's format may be decimal; addresses read better in hex.
        Hex, octal and binary text would be misread as decimal. }
      if (R.DisplayFormat in [rdDefault, rdDecimal]) and (R.Value <> '') and
         (R.Value[1] in ['0'..'9']) and TryStrToQWord(R.Value, Num) then
        RObj.Add('hex', '$' + IntToHex(Num, 1));
      if R.Modified then
        RObj.Add('changed', True);   { since the previous pause }
    end;
    OutRegJSON  := Arr.AsJSON;
    OutRegReady := True;
  finally
    Arr.Free;
  end;
end;

{ Disassembler: the Assembler window's object.  PrepareRange answers at once
  when the range is known (FpDebug disassembles synchronously); otherwise the
  backend loads it and a later call finds it, repeated requests are merged. }
procedure TDbgSyncHelper.PrepareDisasm;
var
  Dis  : TDBGDisassembler;
  E    : TDisassemblerEntry;
  Arr  : TJSONArray;
  EObj : TJSONObject;
  I, Lo, Hi : Integer;
  S    : string;
begin
  if OutAsmReady then Exit;
  if not Assigned(DebugBoss) or not Assigned(DebugBoss.Disassembler) or
     not Assigned(DebugBoss.Disassembler.Master) then
  begin
    OutAsmErr   := 'This debugger backend does not disassemble';
    OutAsmReady := True;
    Exit;
  end;
  Dis := DebugBoss.Disassembler.Master;
  if not Dis.PrepareRange(InAsmAddr, InAsmBefore, InAsmAfter) then
    Exit;   { still loading; caller retries }
  Lo := -Min(InAsmBefore, Dis.CountBefore);
  Hi := Min(InAsmAfter, Dis.CountAfter) - 1;
  Arr := TJSONArray.Create;
  try
    for I := Lo to Hi do
    begin
      E := Dis.Entries[I];
      EObj := TJSONObject.Create;
      Arr.Add(EObj);
      EObj.Add('address', Format('$%x', [E.Addr]));
      if E.Addr = InAsmAddr then
        EObj.Add('at', True);
      if (E.SrcFileName <> '') and (E.SrcStatementIndex = 0) then
      begin
        EObj.Add('file', E.SrcFileName);
        EObj.Add('line', E.SrcFileLine);
      end;
      if E.FuncName <> '' then
      begin
        S := E.FuncName;
        if E.Offset <> 0 then S := S + '+' + IntToStr(E.Offset);
        EObj.Add('function', S);
      end;
      EObj.Add('bytes', E.Dump);
      EObj.Add('asm', E.Statement);
      if E.TargetName <> '' then
        EObj.Add('target', E.TargetName);
    end;
    OutAsmJSON  := Arr.AsJSON;
    OutAsmReady := True;
  finally
    Arr.Free;
  end;
end;

procedure TDbgSyncHelper.InitWatches;
var
  W : TCurrentWatches;
  I : Integer;
begin
  OutWatchReady := False;
  OutWatchJSON  := '[]';
  if not Assigned(DebugBoss) or not Assigned(DebugBoss.Watches) then
  begin
    OutWatchReady := True; Exit;
  end;
  CurrentThreadAndFrame(OutWatchThread, OutWatchFrame);
  if InWatchThread >= 0 then
  begin
    if InWatchThread > 0 then
      OutWatchThread := InWatchThread;
    OutWatchFrame := InWatchFrame;
  end;
  W := DebugBoss.Watches.CurrentWatches;
  for I := 0 to W.Count - 1 do
    if W[I].Enabled then
      W[I].Values[OutWatchThread, OutWatchFrame].Value;  { trigger async load, once }
end;

procedure TDbgSyncHelper.ReadWatches;
var
  W    : TCurrentWatches;
  V    : TIdeWatchValue;
  I    : Integer;
  Arr  : TJSONArray;
  Obj  : TJSONObject;
begin
  OutWatchReady := False;
  if not Assigned(DebugBoss) or not Assigned(DebugBoss.Watches) then
  begin
    OutWatchReady := True; Exit;
  end;
  W := DebugBoss.Watches.CurrentWatches;
  { Validity only reads state; Value would re-request unknown entries }
  for I := 0 to W.Count - 1 do
    if W[I].Enabled and
       (W[I].Values[OutWatchThread, OutWatchFrame].Validity in
         [ddsUnknown, ddsRequested, ddsEvaluating]) then
      Exit;  { still loading; caller retries }
  Arr := TJSONArray.Create;
  try
    for I := 0 to W.Count - 1 do
    begin
      Obj := TJSONObject.Create;
      Obj.Add('expression', W[I].Expression);
      Obj.Add('enabled',    W[I].Enabled);
      if W[I].Enabled then
      begin
        V := W[I].Values[OutWatchThread, OutWatchFrame];
        case V.Validity of
          ddsValid : Obj.Add('value', PrintResult(V.ResultData, V.Value, W[I].Expression));
          ddsError : Obj.Add('error', V.Value);
        else         Obj.Add('error', 'not available in this context');
        end;
        if Assigned(V.TypeInfo) then
          Obj.Add('type', V.TypeInfo.TypeName);
      end;
      Arr.Add(Obj);
    end;
    OutWatchJSON  := Arr.AsJSON;
    OutWatchReady := True;
  finally
    Arr.Free;
  end;
end;

procedure TDbgSyncHelper.ReadWatchNames;
var
  W   : TCurrentWatches;
  I   : Integer;
  Arr : TJSONArray;
  Obj : TJSONObject;
begin
  Arr := TJSONArray.Create;
  try
    if Assigned(DebugBoss) and Assigned(DebugBoss.Watches) then
    begin
      W := DebugBoss.Watches.CurrentWatches;
      for I := 0 to W.Count - 1 do
      begin
        Obj := TJSONObject.Create;
        Obj.Add('expression', W[I].Expression);
        Obj.Add('enabled',    W[I].Enabled);
        Arr.Add(Obj);
      end;
    end;
    OutWatchJSON := Arr.AsJSON;
  finally
    Arr.Free;
  end;
end;

{ ── Threads ── }

procedure TDbgSyncHelper.InitThreads;
begin
  OutThrReady := False;
  OutThrJSON  := '[]';
  if not Assigned(DebugBoss) or not Assigned(DebugBoss.Threads) or
     not Assigned(DebugBoss.Threads.CurrentThreads) then
  begin
    OutThrReady := True; Exit;
  end;
  DebugBoss.Threads.CurrentThreads.Count;  { trigger async load, once }
end;

procedure TDbgSyncHelper.ReadThreads;
var
  T   : TCurrentThreads;
  E   : TIdeThreadEntry;
  I   : Integer;
  Arr : TJSONArray;
  Obj : TJSONObject;
begin
  OutThrReady := False;
  if not Assigned(DebugBoss) or not Assigned(DebugBoss.Threads) or
     not Assigned(DebugBoss.Threads.CurrentThreads) then
  begin
    OutThrReady := True; Exit;
  end;
  T := DebugBoss.Threads.CurrentThreads;
  { Count requests data only while its validity is unknown, so it is safe to
    poll; a paused process always has at least one thread. }
  if T.Count = 0 then Exit;
  Arr := TJSONArray.Create;
  try
    for I := 0 to T.Count - 1 do
    begin
      E   := T[I];
      Obj := TJSONObject.Create;
      Obj.Add('id',      E.ThreadId);
      Obj.Add('name',    E.ThreadName);
      Obj.Add('state',   GetEnumName(TypeInfo(TDbgThreadState), Ord(E.ThreadState)));
      Obj.Add('current', E.ThreadId = T.CurrentThreadId);
      if Assigned(E.TopFrame) then
      begin
        Obj.Add('function', E.TopFrame.FunctionName);
        Obj.Add('file',     E.TopFrame.Source);
        Obj.Add('line',     E.TopFrame.Line);
      end;
      Arr.Add(Obj);
    end;
    OutThrJSON  := Arr.AsJSON;
    OutThrReady := True;
  finally
    Arr.Free;
  end;
end;

{ ── Internal helpers ─────────────────────────────────────────────────────── }

function DbgStateStr(S: TDBGState): string;
begin
  case S of
    dsNone, dsIdle         : Result := 'idle';
    dsStop                 : Result := 'stopped';
    dsPause                  : Result := 'paused';
    dsInternalPause          : Result := 'running';  { internal pause; IDE auto-continues }
    dsInit, dsRun          : Result := 'running';
    dsError                : Result := 'error';
    dsDestroying           : Result := 'stopped';
  else                       Result := 'idle';
  end;
end;

{ AExcSeqBefore: exception sequence sampled before the command was issued, or
  -1 to never report an exception.  Uses the GSyncHelper snapshot taken by the
  last ReadState: a newer exception turns the reason into 'exception' and adds
  its details; suppressed debugger messages are passed on once. }
function MakeStateJSON(S: TDBGState; const AFile: string;
  ALine: Integer; const AReason: string; AExcSeqBefore: Integer = -1): string;
var
  Obj : TJSONObject;
begin
  Obj := TJSONObject.Create;
  try
    Obj.Add('state',  DbgStateStr(S));
    Obj.Add('file',   AFile);
    Obj.Add('line',   ALine);
    if (AExcSeqBefore >= 0) and GSyncHelper.OutExcValid and
       (GSyncHelper.OutExcSeq <> AExcSeqBefore) then
    begin
      Obj.Add('reason',    'exception');
      Obj.Add('exception', GetJSON(GSyncHelper.OutExcJSON));
    end
    else
      Obj.Add('reason', AReason);
    if GSyncHelper.OutFeedback <> '' then
    begin
      Obj.Add('debugger_message', GSyncHelper.OutFeedback);
      GSyncHelper.OutFeedback := '';
    end;
    Result := Obj.AsJSON;
  finally
    Obj.Free;
  end;
end;

var
  GCmdExcSeq : Integer = -1;  { exception sequence when the last command was issued }

{ A session the user started may be waiting in the exception dialog.  Answer
  it with Break and wait (up to 5 s) until the program is paused at the
  exception.  Returns True if it took over. }
function TakeOverFromExceptionDialog: Boolean;
var
  Waited : Integer;
begin
  Result := GMcpExceptionDialogHwnd <> 0;
  if not Result then Exit;
  TThread.Synchronize(nil, @GSyncHelper.BreakAtExceptionDialog);
  Waited := 0;
  repeat
    Sleep(100);
    Inc(Waited, 100);
    TThread.Synchronize(nil, @GSyncHelper.ReadState);
  until ((GMcpExceptionDialogHwnd = 0) and (GSyncHelper.OutState <> dsRun)) or
        (Waited >= 5000);
end;

procedure DoIssueCmd(ACmd: Integer);
var
  TookOver : Boolean;
begin
  TookOver := TakeOverFromExceptionDialog;
  TThread.Synchronize(nil, @GSyncHelper.ReadState);
  GCmdExcSeq              := GSyncHelper.OutExcSeq;
  if TookOver and GSyncHelper.OutExcValid then
    Dec(GCmdExcSeq);  { report the exception we are now paused at }
  GSyncHelper.OutFeedback := '';  { report only messages caused by this command }
  { debug_pause: Break already paused the program }
  if TookOver and (ACmd = 1) and (GSyncHelper.OutState = dsPause) then Exit;
  GSyncHelper.InCmd := ACmd;
  TThread.Synchronize(nil, @GSyncHelper.IssueCmd);
end;

{ Wait up to WaitMs for the debugger to reach an active state (dsInit/dsRun/
  dsPause/dsInternalPause).  Returns true when an active state was detected.
  Checking for NOT-idle is wrong when starting from dsStop: dsStop is neither
  dsNone nor dsIdle, so the old code exited immediately with the pre-launch state. }
function WaitForLaunch(WaitMs: Integer): Boolean;
const
  Interval = 50;
var
  Elapsed : Integer;
begin
  Result  := False;
  Elapsed := 0;
  repeat
    Sleep(Interval);
    Inc(Elapsed, Interval);
    TThread.Synchronize(nil, @GSyncHelper.ReadState);
    if GSyncHelper.OutState in [dsInit, dsRun, dsPause, dsInternalPause] then
    begin
      Result := True;
      Exit;
    end;
  until Elapsed >= WaitMs;
end;

{ Poll until debugger leaves the running state or timeout expires.
  The caller must have already issued the command.
  Set AWaitLaunch=True for debug_run to skip the pre-launch idle window. }
function PollForPause(TimeoutMs: Integer;
  out FinalFile: string; out FinalLine: Integer;
  AWaitLaunch: Boolean = False;
  ALaunchWaitMs: Integer = 5000): TDBGState;
const
  InitialWaitMs  = 150;  { let the command take effect }
  PollIntervalMs = 100;
var
  Elapsed : Integer;
begin
  if AWaitLaunch then
  begin
    if not WaitForLaunch(ALaunchWaitMs) then
    begin
      FinalFile := '';
      FinalLine := 0;
      Result    := dsStop;
      Exit;
    end;
  end
  else
    Sleep(InitialWaitMs);
  Elapsed := InitialWaitMs;
  repeat
    TThread.Synchronize(nil, @GSyncHelper.ReadState);
    if GSyncHelper.OutState in [dsPause, dsStop, dsError, dsNone, dsIdle, dsDestroying] then
    begin
      FinalFile := GSyncHelper.OutFileName;
      FinalLine := GSyncHelper.OutLine;
      Result    := GSyncHelper.OutState;
      Exit;
    end;
    if Elapsed >= TimeoutMs then
    begin
      FinalFile := '';
      FinalLine := 0;
      Result    := dsRun;
      Exit;
    end;
    Sleep(PollIntervalMs);
    Inc(Elapsed, PollIntervalMs);
  until False;
end;

{ ── Non-blocking dispatch (main thread via SyncCallTool) ─────────────────── }

function DispatchDebuggerTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  Lease : TJSONObject;
  Obj   : TJSONObject;
  Arr   : TJSONArray;
  Watch : TCurrentWatch;
  I     : Integer;
  Sym   : string;
  Err   : string;
begin
  Result := False;

  if Name = 'debug_get_state' then
  begin
    Result := True;
    GSyncHelper.ReadState;   { already on main thread }
    Obj := TJSONObject.Create;
    try
      Obj.Add('state',  DbgStateStr(GSyncHelper.OutState));
      Obj.Add('file',   GSyncHelper.OutFileName);
      Obj.Add('line',   GSyncHelper.OutLine);
      Obj.Add('reason', '');
      if FindExceptionDialog <> nil then
        Obj.Add('waiting_for', 'The IDE shows the exception dialog of a session ' +
          'the user started; the program is stopped at the exception. ' +
          'debug_get_exception shows it; debug_pause breaks there and takes ' +
          'the session over (as clicking Break would).');
      Lease := McpLeaseJSON;
      if Assigned(Lease) then
        Obj.Add('lease', Lease);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'debug_set_breakpoint' then
  begin
    Result := True;
    if not Assigned(DebugBoss) then
    begin Ctx.Error := True; Ctx.Result := 'Debugger not available'; Exit; end;
    if not ReadBreakpointArgs(Ctx.Params, Sym, Err) then
    begin Ctx.Error := True; Ctx.Result := Err; Exit; end;
    if Sym <> '' then
    begin
      Ctx.Error := True;
      Ctx.Result := 'address must be a number ($401000, 0x401000)';
      Exit;
    end;
    GSyncHelper.AddBreakpoint;   { already on main thread }
    if not Assigned(GSyncHelper.OutBp) then
    begin Ctx.Error := True; Ctx.Result := 'Failed to add breakpoint'; Exit; end;
    Obj := BreakpointJSON(GSyncHelper.OutBp);
    try
      Obj.Add('created', GSyncHelper.OutBpCreated);
      Ctx.Result := Obj.AsJSON;
    finally Obj.Free; end;
  end

  else if Name = 'debug_remove_breakpoint' then
  begin
    Result := True;
    if not ReadBreakpointArgs(Ctx.Params, Sym, Err) then
    begin Ctx.Error := True; Ctx.Result := Err; Exit; end;
    if Sym <> '' then
    begin
      Ctx.Error := True;
      Ctx.Result := 'address must be a number; debug_list_breakpoints shows it';
      Exit;
    end;
    GSyncHelper.RemoveBreakpoint;   { already on main thread }
    Obj := TJSONObject.Create;
    try
      Obj.Add('removed', GSyncHelper.OutBpFound);
      if not GSyncHelper.OutBpFound then
        Obj.Add('reason', 'not found');
      Ctx.Result := Obj.AsJSON;
    finally Obj.Free; end;
  end

  else if Name = 'debug_list_breakpoints' then
  begin
    Result := True;
    Arr := TJSONArray.Create;
    try
      if Assigned(DebugBoss) and Assigned(DebugBoss.BreakPoints) then
        for I := 0 to DebugBoss.BreakPoints.Count - 1 do
          Arr.Add(BreakpointJSON(DebugBoss.BreakPoints.Items[I]));
      Ctx.Result := Arr.AsJSON;
    finally Arr.Free; end;
  end

  else if Name = 'debug_stop' then
  begin
    Result := True;
    if Assigned(DebugBoss) then
    begin
      McpMarkDebugDriven;        { no "Execution stopped" dialog }
      if FindExceptionDialog <> nil then
      begin
        { inside the exception dialog: Break first, stop once it has closed }
        GSyncHelper.BreakAtExceptionDialog;
        Application.QueueAsyncCall(@GSyncHelper.StopLater, 0);
      end
      else
        DebugBoss.DoStopProject;   { non-blocking, already on main thread }
    end;
    Ctx.Result := MakeStateJSON(dsStop, '', 0, '');
  end

  else if Name = 'debug_set_variable' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('name', '') = '') then
    begin Ctx.Error := True; Ctx.Result := 'name required'; Exit; end;
    if not Assigned(DebugBoss) or (DebugBoss.State <> dsPause) then
    begin Ctx.Error := True; Ctx.Result := 'Debugger is not paused'; Exit; end;
    McpMarkDebugDriven;  { a failed modify reports via a feedback dialog }
    Obj := TJSONObject.Create;
    try
      if DebugBoss.Modify(Ctx.Params.Get('name', ''),
                          Ctx.Params.Get('value', '')) then
      begin
        Obj.Add('modified', True);
        Obj.Add('name',  Ctx.Params.Get('name', ''));
        Obj.Add('value', Ctx.Params.Get('value', ''));
      end
      else
      begin
        Ctx.Error := True;
        Obj.Add('error',
          'Modify rejected — dcModify not in Commands or debugger not ready');
      end;
      Ctx.Result := Obj.AsJSON;
    finally Obj.Free; end;
  end

  else if Name = 'debug_add_watch' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Trim(Ctx.Params.Get('expression', '')) = '') then
    begin Ctx.Error := True; Ctx.Result := 'expression required'; Exit; end;
    if not Assigned(DebugBoss) or not Assigned(DebugBoss.Watches) then
    begin Ctx.Error := True; Ctx.Result := 'Debugger not available'; Exit; end;
    Watch := DebugBoss.Watches.CurrentWatches.Find(Trim(Ctx.Params.Get('expression', '')));
    Obj := TJSONObject.Create;
    try
      if Assigned(Watch) then
        Obj.Add('status', 'exists')
      else
      begin
        Watch := DebugBoss.Watches.CurrentWatches.Add(Trim(Ctx.Params.Get('expression', '')));
        Obj.Add('status', 'added');
      end;
      Watch.Enabled := True;
      Obj.Add('expression', Watch.Expression);
      Obj.Add('count', DebugBoss.Watches.CurrentWatches.Count);
      Ctx.Result := Obj.AsJSON;
    finally Obj.Free; end;
  end

  else if Name = 'debug_remove_watch' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Trim(Ctx.Params.Get('expression', '')) = '') then
    begin Ctx.Error := True; Ctx.Result := 'expression required (or "*" for all)'; Exit; end;
    if not Assigned(DebugBoss) or not Assigned(DebugBoss.Watches) then
    begin Ctx.Error := True; Ctx.Result := 'Debugger not available'; Exit; end;
    I := 0;
    if Trim(Ctx.Params.Get('expression', '')) = '*' then
    begin
      I := DebugBoss.Watches.CurrentWatches.Count;
      DebugBoss.Watches.CurrentWatches.Clear;
    end
    else
    begin
      Watch := DebugBoss.Watches.CurrentWatches.Find(Trim(Ctx.Params.Get('expression', '')));
      if Assigned(Watch) then
      begin
        Watch.Free;
        I := 1;
      end;
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('removed', I);
      Obj.Add('count', DebugBoss.Watches.CurrentWatches.Count);
      Ctx.Result := Obj.AsJSON;
    finally Obj.Free; end;
  end

  else if Name = 'debug_get_output' then
  begin
    Result := True;
    I := 200;
    if Assigned(Ctx.Params) then
      I := Ctx.Params.Get('max_lines', 200);
    Obj := TJSONObject.Create;
    try
      Obj.Add('console',  McpGetConsoleOutput(I));
      Obj.Add('debugger', McpGetDebugOutput(I));
      if Assigned(Ctx.Params) and Ctx.Params.Get('clear', False) then
        McpClearDebugOutput;
      Ctx.Result := Obj.AsJSON;
    finally Obj.Free; end;
  end;

end;

{ ── Blocking dispatch (MCP worker thread) ───────────────────────────────── }

{ Evaluate AExpr in the selected thread and frame and wait up to 5 s for the
  result.  Worker thread; the debugger must be paused.  On failure AErr says
  why and the result is False. }
function EvaluateOnWorker(const AExpr: string; out AValue, AType, AErr: string): Boolean;
var
  Elapsed : Integer;
begin
  AValue := '';
  AType  := '';
  AErr   := '';
  GSyncHelper.InEvalExpr := AExpr;
  { start on the main thread (returns at once); the main loop delivers the
    callback, so only poll here }
  TThread.Synchronize(nil, @GSyncHelper.DoEvaluateAndWait);
  Elapsed := 0;
  while not GSyncHelper.FEvalFired and (Elapsed < 5000) do
  begin
    Sleep(50);
    Inc(Elapsed, 50);
  end;
  Result := GSyncHelper.FEvalFired and GSyncHelper.OutEvalOk;
  if Result then
  begin
    AValue := GSyncHelper.OutEvalRes;
    AType  := GSyncHelper.OutEvalType;
  end
  else if not GSyncHelper.FEvalFired then
    AErr := 'Evaluation timed out (5 s) — Evaluate returned: ' +
            BoolToStr(GSyncHelper.OutEvalStarted, True)
  else
    AErr := 'Evaluation failed: ' + GSyncHelper.OutEvalRes;
end;

{ Symbol or Symbol+Offset (decimal, $hex or 0xhex) to a code address, by
  evaluating @Symbol: FpDebug prints '^procedure($00000001000016E0)'.
  Worker thread; the debugger must be paused. }
function ResolveSymbol(const ASpec: string; out AAddr: TDBGPtr; out AErr: string): Boolean;
var
  Sym, Value, Typ : string;
  P, E            : Integer;
  Offset          : TDBGPtr;
begin
  Result := False;
  AErr   := '';
  P := Pos('+', ASpec);
  Offset := 0;
  if P > 0 then
  begin
    Sym := Trim(Copy(ASpec, 1, P - 1));
    if not ParseAddress(Copy(ASpec, P + 1, MaxInt), Offset) then
    begin
      AErr := 'Bad offset in ' + ASpec;
      Exit;
    end;
  end
  else
    Sym := Trim(ASpec);
  if not EvaluateOnWorker('@' + Sym, Value, Typ, AErr) then
  begin
    AErr := 'Could not resolve ' + Sym + '. Symbols resolve only from debug ' +
            'info (your own code); for other code give the address as a number, ' +
            'e.g. from debug_get_call_stack. (' + AErr + ')';
    Exit;
  end;
  { @Variable is an address too, but a code breakpoint there would write
    into the variable's memory }
  if (Pos('procedure', LowerCase(Typ)) = 0) and (Pos('function', LowerCase(Typ)) = 0) then
  begin
    AErr := Sym + ' is data (' + Typ + '), not code. Use data to stop when it changes.';
    Exit;
  end;
  P := Pos('$', Value);
  E := P + 1;
  while (E <= Length(Value)) and (Value[E] in ['0'..'9', 'a'..'f', 'A'..'F']) do
    Inc(E);
  if (P = 0) or not ParseAddress(Copy(Value, P, E - P), AAddr) then
  begin
    AErr := 'No address in the value of @' + Sym + ': ' + Value;
    Exit;
  end;
  Inc(AAddr, Offset);
  Result := True;
end;

{ Make AThread (0 = keep the current one) and its frame AFrame the IDE's
  selection, as clicking them in the Threads and Call Stack windows would,
  and wait until the debugger has applied it.  AFrameJSON describes the
  frame.  Worker thread; the debugger must be paused. }
function SelectThreadFrame(AThread, AFrame: Integer;
  out AFrameJSON, AErr: string): Boolean;
var
  Elapsed : Integer;
  Frames  : TJSONData;
begin
  Result     := False;
  AFrameJSON := '';
  AErr       := '';
  if AFrame < 0 then
  begin
    AErr := 'frame must be 0 or more';
    Exit;
  end;
  TThread.Synchronize(nil, @GSyncHelper.ReadSelection);
  if (AThread > 0) and (GSyncHelper.OutSelThread <> AThread) then
  begin
    GSyncHelper.InSelThread := AThread;
    TThread.Synchronize(nil, @GSyncHelper.RequestThread);
    Elapsed := 0;
    repeat
      Sleep(50);
      Inc(Elapsed, 50);
      TThread.Synchronize(nil, @GSyncHelper.ReadSelection);
    until (GSyncHelper.OutSelThread = AThread) or (Elapsed >= 5000);
    if GSyncHelper.OutSelThread <> AThread then
    begin
      AErr := Format('Thread %d could not be selected; debug_list_threads shows the ids',
                     [AThread]);
      Exit;
    end;
  end;

  { load the stack far enough to know the frame exists, and to describe it }
  GSyncHelper.InMaxFrames := AFrame + 1;
  TThread.Synchronize(nil, @GSyncHelper.InitCallStack);
  Elapsed := 0;
  while not GSyncHelper.OutCSReady and (Elapsed < 10000) do
  begin
    Sleep(100);
    Inc(Elapsed, 100);
    TThread.Synchronize(nil, @GSyncHelper.ReadCallStack);
  end;
  if not GSyncHelper.OutCSReady or (GSyncHelper.OutCSCount <= AFrame) then
  begin
    AErr := Format('Frame %d does not exist (the stack has %d frames)',
                   [AFrame, Max(GSyncHelper.OutCSCount, 0)]);
    Exit;
  end;
  Frames := GetJSON(GSyncHelper.OutCSJSON);
  try
    if (Frames is TJSONArray) and (TJSONArray(Frames).Count > AFrame) then
      AFrameJSON := TJSONArray(Frames).Items[AFrame].AsJSON;
  finally
    Frames.Free;
  end;

  if GSyncHelper.OutSelFrame <> AFrame then
  begin
    GSyncHelper.InSelFrame := AFrame;
    TThread.Synchronize(nil, @GSyncHelper.RequestFrame);
    Elapsed := 0;
    repeat
      Sleep(50);
      Inc(Elapsed, 50);
      TThread.Synchronize(nil, @GSyncHelper.ReadSelection);
    until (GSyncHelper.OutSelFrame = AFrame) or (Elapsed >= 5000);
    if GSyncHelper.OutSelFrame <> AFrame then
    begin
      AErr := Format('Frame %d could not be selected', [AFrame]);
      Exit;
    end;
  end;
  Result := True;
end;

{ Load AThread's stack (0 = current thread) down to AFrame, so the frame is
  known to exist and backends that read per-frame data from the loaded stack
  (FpDebug's registers) find it; AFrameJSON describes the frame.  Worker
  thread; the debugger must be paused. }
function LoadStackTo(AThread, AFrame: Integer; out AFrameJSON, AErr: string): Boolean;
var
  Elapsed : Integer;
  Frames  : TJSONData;
begin
  Result     := False;
  AFrameJSON := '';
  AErr       := '';
  GSyncHelper.InCSThread  := AThread;
  GSyncHelper.InMaxFrames := AFrame + 1;
  TThread.Synchronize(nil, @GSyncHelper.InitCallStack);
  GSyncHelper.InCSThread  := 0;
  Elapsed := 0;
  while not GSyncHelper.OutCSReady and (Elapsed < 10000) do
  begin
    Sleep(100);
    Inc(Elapsed, 100);
    TThread.Synchronize(nil, @GSyncHelper.ReadCallStack);
  end;
  if not GSyncHelper.OutCSReady or (GSyncHelper.OutCSCount <= AFrame) then
  begin
    AErr := Format('Frame %d does not exist (the stack has %d frames)',
                   [AFrame, Max(GSyncHelper.OutCSCount, 0)]);
    Exit;
  end;
  Frames := GetJSON(GSyncHelper.OutCSJSON);
  try
    if (Frames is TJSONArray) and (TJSONArray(Frames).Count > AFrame) then
      AFrameJSON := TJSONArray(Frames).Items[AFrame].AsJSON;
  finally
    Frames.Free;
  end;
  Result := AFrameJSON <> '';
  if not Result then
    AErr := Format('Frame %d could not be read', [AFrame]);
end;

function DispatchDebuggerBlockingTool(const Name: string;
  var Ctx: TMcpToolCall): Boolean;
var
  TimeoutMs : Integer;
  Elapsed   : Integer;
  S         : TDBGState;
  FinalFile : string;
  FinalLine : Integer;
  Obj       : TJSONObject;
  TempBp    : Boolean;
  Value     : string;
  Typ       : string;
  Err       : string;
  Addr      : TDBGPtr;
  Selected  : Boolean;
  OldThread : Integer;
  OldFrame  : Integer;
  FrameJSON : string;
  FrameData : TJSONData;

  procedure Finish(const AReason: string);
  var
    R : string;
  begin
    if S = dsRun then R := 'timeout' else R := AReason;
    Ctx.Result := MakeStateJSON(S, FinalFile, FinalLine, R, GCmdExcSeq);
  end;

begin
  Result    := False;
  Elapsed   := 0;
  FinalFile := '';
  FinalLine := 0;
  Obj       := nil;

  if Name = 'debug_run' then
  begin
    Result    := True;
    TimeoutMs := 30000;
    if Assigned(Ctx.Params) then
      TimeoutMs := Ctx.Params.Get('timeout_s', 30) * 1000;
    DoIssueCmd(0);
    S := PollForPause(TimeoutMs, FinalFile, FinalLine, True { AWaitLaunch }, 10000);
    Finish('run');
  end

  else if Name = 'debug_pause' then
  begin
    Result    := True;
    TimeoutMs := 5000;
    DoIssueCmd(1);
    S := PollForPause(TimeoutMs, FinalFile, FinalLine);
    Finish('paused');
  end

  else if Name = 'debug_step_over' then
  begin
    Result    := True;
    TimeoutMs := 10000;
    if Assigned(Ctx.Params) then
      TimeoutMs := Ctx.Params.Get('timeout_s', 10) * 1000;
    DoIssueCmd(3);
    S := PollForPause(TimeoutMs, FinalFile, FinalLine);
    Finish('step');
  end

  else if Name = 'debug_step_into' then
  begin
    Result    := True;
    TimeoutMs := 10000;
    if Assigned(Ctx.Params) then
      TimeoutMs := Ctx.Params.Get('timeout_s', 10) * 1000;
    DoIssueCmd(4);
    S := PollForPause(TimeoutMs, FinalFile, FinalLine);
    Finish('step');
  end

  else if Name = 'debug_step_out' then
  begin
    Result    := True;
    TimeoutMs := 30000;
    if Assigned(Ctx.Params) then
      TimeoutMs := Ctx.Params.Get('timeout_s', 30) * 1000;
    DoIssueCmd(5);
    S := PollForPause(TimeoutMs, FinalFile, FinalLine);
    Finish('step');
  end

  else if Name = 'debug_run_to_line' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('file', '') = '') then
    begin Ctx.Error := True; Ctx.Result := 'file required'; Exit; end;
    TimeoutMs := 30000;
    if Assigned(Ctx.Params) then
      TimeoutMs := Ctx.Params.Get('timeout_s', 30) * 1000;
    { Temporary breakpoint, unless the line has one already: that one is the
      user's, with its condition and pass count, and is left exactly as it is }
    GSyncHelper.InBpKind       := bpkSource;
    GSyncHelper.InBpFile       := CleanAndExpandFilename(Ctx.Params.Get('file', ''));
    GSyncHelper.InBpLine       := Ctx.Params.Get('line', 0);
    GSyncHelper.InBpSetEnabled := False;
    GSyncHelper.InBpSetCond    := False;
    GSyncHelper.InBpSetPass    := False;
    GSyncHelper.InBpOnlyIfNew  := True;
    TThread.Synchronize(nil, @GSyncHelper.AddBreakpoint);
    if not Assigned(GSyncHelper.OutBp) then
    begin Ctx.Error := True; Ctx.Result := 'Failed to add temp breakpoint'; Exit; end;
    TempBp := GSyncHelper.OutBpCreated;
    { Run until pause }
    DoIssueCmd(0);
    S := PollForPause(TimeoutMs, FinalFile, FinalLine, True { AWaitLaunch }, 10000);
    if TempBp then
      TThread.Synchronize(nil, @GSyncHelper.RemoveBreakpoint);
    Finish('breakpoint');
  end

  else if Name = 'debug_evaluate' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('expression', '') = '') then
    begin Ctx.Error := True; Ctx.Result := 'expression required'; Exit; end;
    TThread.Synchronize(nil, @GSyncHelper.ReadState);
    if GSyncHelper.OutState <> dsPause then
    begin Ctx.Error := True; Ctx.Result := 'Debugger is not paused'; Exit; end;
    { thread/frame: select them for this evaluation only, then restore }
    Selected := Assigned(Ctx.Params.Find('thread')) or Assigned(Ctx.Params.Find('frame'));
    if Selected then
    begin
      TThread.Synchronize(nil, @GSyncHelper.ReadSelection);
      OldThread := GSyncHelper.OutSelThread;
      OldFrame  := GSyncHelper.OutSelFrame;
      if not SelectThreadFrame(Ctx.Params.Get('thread', 0), Ctx.Params.Get('frame', 0),
                               FrameJSON, Err) then
      begin
        SelectThreadFrame(OldThread, OldFrame, FrameJSON, Typ);
        Ctx.Error := True; Ctx.Result := Err; Exit;
      end;
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('expression', Ctx.Params.Get('expression', ''));
      if EvaluateOnWorker(Ctx.Params.Get('expression', ''), Value, Typ, Err) then
      begin
        Obj.Add('value', Value);
        Obj.Add('type',  Typ);
      end
      else
      begin
        Ctx.Error := True;
        Obj.Add('error', Err);
      end;
      if Selected then
      begin
        Obj.Add('frame', GetJSON(FrameJSON));
        SelectThreadFrame(OldThread, OldFrame, FrameJSON, Err);
      end;
      Ctx.Result := Obj.AsJSON;
    finally Obj.Free; end;
  end

  else if Name = 'debug_select_frame' then
  begin
    Result := True;
    TThread.Synchronize(nil, @GSyncHelper.ReadState);
    if GSyncHelper.OutState <> dsPause then
    begin Ctx.Error := True; Ctx.Result := 'Debugger is not paused'; Exit; end;
    if not Assigned(Ctx.Params) or not Assigned(Ctx.Params.Find('frame')) then
    begin Ctx.Error := True; Ctx.Result := 'frame required (0 = top)'; Exit; end;
    if not SelectThreadFrame(Ctx.Params.Get('thread', 0), Ctx.Params.Get('frame', 0),
                             FrameJSON, Err) then
    begin Ctx.Error := True; Ctx.Result := Err; Exit; end;
    TThread.Synchronize(nil, @GSyncHelper.ReadSelection);
    Obj := TJSONObject.Create;
    try
      Obj.Add('thread', GSyncHelper.OutSelThread);
      Obj.Add('frame',  GetJSON(FrameJSON));
      Ctx.Result := Obj.AsJSON;
    finally Obj.Free; end;
  end

  else if ((Name = 'debug_set_breakpoint') or (Name = 'debug_remove_breakpoint')) and
          Assigned(Ctx.Params) and (Ctx.Params.Get('address', '') <> '') and
          not ParseAddress(Ctx.Params.Get('address', ''), Addr) then
  begin
    { A symbol: resolve it here, where waiting for the debugger is allowed,
      then let the main-thread handler work with the number. }
    TThread.Synchronize(nil, @GSyncHelper.ReadState);
    if GSyncHelper.OutState <> dsPause then
    begin
      Result := True;
      Ctx.Error := True;
      if Name = 'debug_remove_breakpoint' then
        Ctx.Result := 'A symbol needs a paused session; give the address as ' +
                      'debug_list_breakpoints shows it'
      else
        Ctx.Result := 'A symbol address needs a paused session; give a number, ' +
                      'or pause first';
      Exit;
    end;
    if not ResolveSymbol(Ctx.Params.Get('address', ''), Addr, Err) then
    begin
      Result := True;
      Ctx.Error := True; Ctx.Result := Err;
      Exit;
    end;
    Ctx.Params.Strings['address'] := Format('$%x', [Addr]);
    Result := False;   { not handled: dispatch continues on the main thread }
  end

  else if Name = 'debug_get_call_stack' then
  begin
    Result := True;
    TThread.Synchronize(nil, @GSyncHelper.ReadState);
    if GSyncHelper.OutState <> dsPause then
    begin Ctx.Error := True; Ctx.Result := 'Debugger is not paused'; Exit; end;
    GSyncHelper.InMaxFrames := 20;
    if Assigned(Ctx.Params) then
      GSyncHelper.InMaxFrames := Ctx.Params.Get('max_frames', 20);
    TThread.Synchronize(nil, @GSyncHelper.InitCallStack);
    { Poll via Synchronize — each call reads CountValidity on main thread }
    TimeoutMs := 10000;
    Elapsed   := 0;
    while not GSyncHelper.OutCSReady and (Elapsed < TimeoutMs) do
    begin
      Sleep(100);
      Inc(Elapsed, 100);
      TThread.Synchronize(nil, @GSyncHelper.ReadCallStack);
    end;
    if not GSyncHelper.OutCSReady then
      GSyncHelper.OutCSJSON := '[]';  { timeout fallback }
    Ctx.Result := GSyncHelper.OutCSJSON;
  end

  else if Name = 'debug_get_locals' then
  begin
    Result := True;
    TThread.Synchronize(nil, @GSyncHelper.ReadState);
    if GSyncHelper.OutState <> dsPause then
    begin Ctx.Error := True; Ctx.Result := 'Debugger is not paused'; Exit; end;
    GSyncHelper.InLocalsFrame  := 0;
    GSyncHelper.InLocalsThread := 0;
    if Assigned(Ctx.Params) then
    begin
      GSyncHelper.InLocalsFrame  := Ctx.Params.Get('frame', 0);
      GSyncHelper.InLocalsThread := Ctx.Params.Get('thread', 0);
    end;
    TThread.Synchronize(nil, @GSyncHelper.InitLocals);
    TimeoutMs := 5000;
    Elapsed   := 0;
    while not GSyncHelper.OutLocalsReady and (Elapsed < TimeoutMs) do
    begin
      Sleep(100);
      Inc(Elapsed, 100);
      TThread.Synchronize(nil, @GSyncHelper.ReadLocals);
    end;
    if not GSyncHelper.OutLocalsReady then
      GSyncHelper.OutLocalsJSON := '[]';
    Ctx.Result := GSyncHelper.OutLocalsJSON;
  end

  else if Name = 'debug_get_registers' then
  begin
    Result := True;
    TThread.Synchronize(nil, @GSyncHelper.ReadState);
    if GSyncHelper.OutState <> dsPause then
    begin Ctx.Error := True; Ctx.Result := 'Debugger is not paused'; Exit; end;
    GSyncHelper.InRegThread := 0;
    GSyncHelper.InRegFrame  := 0;
    if Assigned(Ctx.Params) then
    begin
      GSyncHelper.InRegThread := Ctx.Params.Get('thread', 0);
      GSyncHelper.InRegFrame  := Max(Ctx.Params.Get('frame', 0), 0);
    end;
    { FpDebug reads a higher frame's registers from the loaded stack }
    if (GSyncHelper.InRegFrame > 0) and
       not LoadStackTo(GSyncHelper.InRegThread, GSyncHelper.InRegFrame, FrameJSON, Err) then
    begin Ctx.Error := True; Ctx.Result := Err; Exit; end;
    TThread.Synchronize(nil, @GSyncHelper.InitRegisters);
    Elapsed := 0;
    while not GSyncHelper.OutRegReady and (Elapsed < 5000) do
    begin
      Sleep(100);
      Inc(Elapsed, 100);
      TThread.Synchronize(nil, @GSyncHelper.ReadRegisters);
    end;
    if not GSyncHelper.OutRegReady then
      GSyncHelper.OutRegErr := 'Registers did not arrive within 5 s';
    if GSyncHelper.OutRegErr <> '' then
    begin Ctx.Error := True; Ctx.Result := GSyncHelper.OutRegErr; Exit; end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('thread', GSyncHelper.OutRegThread);
      Obj.Add('frame', GSyncHelper.InRegFrame);
      Obj.Add('registers', GetJSON(GSyncHelper.OutRegJSON));
      Ctx.Result := Obj.AsJSON;
    finally Obj.Free; end;
  end

  else if Name = 'debug_disassemble' then
  begin
    Result := True;
    TThread.Synchronize(nil, @GSyncHelper.ReadState);
    if GSyncHelper.OutState <> dsPause then
    begin Ctx.Error := True; Ctx.Result := 'Debugger is not paused'; Exit; end;
    GSyncHelper.InAsmBefore := 5;
    GSyncHelper.InAsmAfter  := 15;
    Value := '';
    if Assigned(Ctx.Params) then
    begin
      GSyncHelper.InAsmBefore := EnsureRange(Ctx.Params.Get('lines_before', 5), 0, 100);
      GSyncHelper.InAsmAfter  := EnsureRange(Ctx.Params.Get('lines_after', 15), 1, 200);
      Value := Trim(Ctx.Params.Get('address', ''));
    end;
    if Value <> '' then
    begin
      if not ParseAddress(Value, Addr) and not ResolveSymbol(Value, Addr, Err) then
      begin Ctx.Error := True; Ctx.Result := Err; Exit; end;
    end
    else
    begin
      { the frame's address: where it executes (frame 0) or returns to }
      OldThread := 0;
      OldFrame  := 0;
      if Assigned(Ctx.Params) then
      begin
        OldThread := Ctx.Params.Get('thread', 0);
        OldFrame  := Max(Ctx.Params.Get('frame', 0), 0);
      end;
      if not LoadStackTo(OldThread, OldFrame, FrameJSON, Err) then
      begin Ctx.Error := True; Ctx.Result := Err; Exit; end;
      Addr := 0;
      FrameData := GetJSON(FrameJSON);
      try
        if FrameData is TJSONObject then
          ParseAddress(TJSONObject(FrameData).Get('address', ''), Addr);
      finally
        FrameData.Free;
      end;
      if Addr = 0 then
      begin Ctx.Error := True; Ctx.Result := 'The frame has no address'; Exit; end;
    end;
    GSyncHelper.InAsmAddr   := Addr;
    GSyncHelper.OutAsmReady := False;
    GSyncHelper.OutAsmErr   := '';
    Elapsed := 0;
    TThread.Synchronize(nil, @GSyncHelper.PrepareDisasm);
    while not GSyncHelper.OutAsmReady and (Elapsed < 10000) do
    begin
      Sleep(100);
      Inc(Elapsed, 100);
      TThread.Synchronize(nil, @GSyncHelper.PrepareDisasm);
    end;
    if not GSyncHelper.OutAsmReady then
      GSyncHelper.OutAsmErr := 'The disassembly did not arrive within 10 s';
    if GSyncHelper.OutAsmErr <> '' then
    begin Ctx.Error := True; Ctx.Result := GSyncHelper.OutAsmErr; Exit; end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('address', Format('$%x', [Addr]));
      Obj.Add('instructions', GetJSON(GSyncHelper.OutAsmJSON));
      Ctx.Result := Obj.AsJSON;
    finally Obj.Free; end;
  end

  else if Name = 'debug_list_watches' then
  begin
    Result := True;
    TThread.Synchronize(nil, @GSyncHelper.ReadState);
    GSyncHelper.InWatchThread := -1;   { the current selection }
    if Assigned(Ctx.Params) and
       (Assigned(Ctx.Params.Find('thread')) or Assigned(Ctx.Params.Find('frame'))) then
    begin
      GSyncHelper.InWatchThread := Ctx.Params.Get('thread', 0);
      GSyncHelper.InWatchFrame  := Ctx.Params.Get('frame', 0);
    end;
    TThread.Synchronize(nil, @GSyncHelper.InitWatches);
    if GSyncHelper.OutState = dsPause then
    begin
      TimeoutMs := 5000;
      Elapsed   := 0;
      while not GSyncHelper.OutWatchReady and (Elapsed < TimeoutMs) do
      begin
        Sleep(100);
        Inc(Elapsed, 100);
        TThread.Synchronize(nil, @GSyncHelper.ReadWatches);
      end;
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('state', DbgStateStr(GSyncHelper.OutState));
      if GSyncHelper.OutWatchReady then
        Obj.Add('watches', GetJSON(GSyncHelper.OutWatchJSON))
      else
      begin
        TThread.Synchronize(nil, @GSyncHelper.ReadWatchNames);
        Obj.Add('watches', GetJSON(GSyncHelper.OutWatchJSON));
        if GSyncHelper.OutState = dsPause then
          Obj.Add('note', 'Values did not arrive within 5 s')
        else
          Obj.Add('note', 'Values are available only while the debugger is paused');
      end;
      Ctx.Result := Obj.AsJSON;
    finally Obj.Free; end;
  end

  else if Name = 'debug_list_threads' then
  begin
    Result := True;
    TThread.Synchronize(nil, @GSyncHelper.ReadState);
    if GSyncHelper.OutState <> dsPause then
    begin Ctx.Error := True; Ctx.Result := 'Debugger is not paused'; Exit; end;
    TThread.Synchronize(nil, @GSyncHelper.InitThreads);
    TimeoutMs := 5000;
    Elapsed   := 0;
    while not GSyncHelper.OutThrReady and (Elapsed < TimeoutMs) do
    begin
      Sleep(100);
      Inc(Elapsed, 100);
      TThread.Synchronize(nil, @GSyncHelper.ReadThreads);
    end;
    Ctx.Result := GSyncHelper.OutThrJSON;
  end

  else if Name = 'debug_get_exception' then
  begin
    Result := True;
    { McpDebugGuard records every exception the debugger reports (class,
      message, location) before any dialog would appear.  The record lives
      until the program is resumed past it or a new session starts. }
    TThread.Synchronize(nil, @GSyncHelper.ReadState);
    Obj := TJSONObject.Create;
    try
      Obj.Add('has_exception', GSyncHelper.OutExcValid);
      Obj.Add('state', DbgStateStr(GSyncHelper.OutState));
      if GSyncHelper.OutExcValid then
        Obj.Add('exception', GetJSON(GSyncHelper.OutExcJSON))
      else if GSyncHelper.OutState in [dsNone, dsIdle, dsStop] then
        Obj.Add('note', 'Debugger is not running.')
      else
        Obj.Add('note', 'No exception since the program was last resumed.');
      Ctx.Result := Obj.AsJSON;
    finally Obj.Free; end;
  end;

end;

{ ── Schema constants ─────────────────────────────────────────────────────── }

const
  { one location: file + line, address, or data (+ scope, watch) }
  BP_LOCATION_PROPS =
    '"file":{"type":"string","description":"Absolute path (source breakpoint)"},' +
    '"line":{"type":"integer","description":"1-based line number"},' +
    '"address":{"type":"string","description":"Code address ($401000, 0x401000), or ' +
      'Proc / Proc+12 from code with debug info (resolved while paused; valid ' +
      'for this session only)"},' +
    '"data":{"type":"string","description":"Variable to watch (data breakpoint)"},' +
    '"scope":{"type":"string","enum":["global","local"],"description":"For data; default global"},' +
    '"watch":{"type":"string","enum":["write","read","readwrite"],"description":"For data; default write"}';

  SCHEMA_SET_BREAKPOINT =
    '{"type":"object","properties":{' + BP_LOCATION_PROPS + ',' +
    '"condition":{"type":"string","description":"Break only when this Pascal expression is true; \"\" clears"},' +
    '"pass_count":{"type":"integer","description":"Break from the Nth hit on; 0 clears"},' +
    '"enabled":{"type":"boolean","description":"Default true"}}}';

  SCHEMA_REMOVE_BREAKPOINT =
    '{"type":"object","properties":{' + BP_LOCATION_PROPS + '}}';

  SCHEMA_NO_PARAMS =
    '{"type":"object","properties":{}}';

  SCHEMA_TIMEOUT_ONLY =
    '{"type":"object","properties":{' +
    '"timeout_s":{"type":"integer","description":"Default 10 (step out: 30)"}}}';

  SCHEMA_RUN_DEBUGGER =
    '{"type":"object","properties":{' +
    '"timeout_s":{"type":"integer","description":"Seconds to wait for pause; default 30"},' +
    '"lease_idle_timeout":{"type":"integer","description":"Seconds without calls from you after which ' +
      'your debug session is stopped and released to other clients; default 300, 10..3600"}}}';

  SCHEMA_RUN_TO_LINE =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path"},' +
    '"line":{"type":"integer","description":"1-based line number to run to"},' +
    '"timeout_s":{"type":"integer","description":"Default 30"}},' +
    '"required":["file","line"]}';

  THREAD_FRAME_PROPS =
    '"thread":{"type":"integer","description":"Thread id (debug_list_threads); default current"},' +
    '"frame":{"type":"integer","description":"Stack frame, 0 = top; default selected"}';

  SCHEMA_EVALUATE_EXPRESSION =
    '{"type":"object","properties":{' +
    '"expression":{"type":"string","description":"Pascal expression to evaluate. Raw ' +
      'memory: ^Byte($1000A0)[0..15] (the type must be one the program uses)"},' +
    THREAD_FRAME_PROPS + '},' +
    '"required":["expression"]}';

  SCHEMA_SELECT_FRAME =
    '{"type":"object","properties":{' + THREAD_FRAME_PROPS + '},' +
    '"required":["frame"]}';

  SCHEMA_LIST_WATCHES =
    '{"type":"object","properties":{' + THREAD_FRAME_PROPS + '}}';

  SCHEMA_GET_CALL_STACK =
    '{"type":"object","properties":{' +
    '"max_frames":{"type":"integer","description":"Maximum frames to return; default 20"}}}';

  SCHEMA_GET_LOCAL_VARIABLES =
    '{"type":"object","properties":{' +
    '"thread":{"type":"integer","description":"Thread id (debug_list_threads); default current"},' +
    '"frame":{"type":"integer","description":"Stack frame index; default 0"}}}';

  SCHEMA_GET_REGISTERS =
    '{"type":"object","properties":{' +
    '"thread":{"type":"integer","description":"Thread id (debug_list_threads); default current"},' +
    '"frame":{"type":"integer","description":"Stack frame index; default 0"}}}';

  SCHEMA_DISASSEMBLE =
    '{"type":"object","properties":{' +
    '"address":{"type":"string","description":"$hex, 0xhex, decimal, or Proc / Proc+12 ' +
      '(debug info only). Default: the frame''s address"},' +
    '"thread":{"type":"integer","description":"Thread id; default current"},' +
    '"frame":{"type":"integer","description":"Stack frame index; default 0 (where the ' +
      'program stopped); higher frames show their return address"},' +
    '"lines_before":{"type":"integer","description":"Default 5, at most 100"},' +
    '"lines_after":{"type":"integer","description":"Including the instruction at the ' +
      'address. Default 15, at most 200"}}}';

  SCHEMA_SET_LOCAL_VARIABLE =
    '{"type":"object","properties":{' +
    '"name":{"type":"string","description":"Variable or parameter name"},' +
    '"value":{"type":"string","description":"New value expressed as a string"}},' +
    '"required":["name","value"]}';

  SCHEMA_EXCEPTION_INFO =
    '{"type":"object","properties":{}}';

  SCHEMA_WATCH_EXPRESSION =
    '{"type":"object","properties":{' +
    '"expression":{"type":"string","description":"Pascal expression, as in the Watches window"}},' +
    '"required":["expression"]}';

  SCHEMA_REMOVE_WATCH =
    '{"type":"object","properties":{' +
    '"expression":{"type":"string","description":"Watch expression to remove, or \"*\" for all"}},' +
    '"required":["expression"]}';

  SCHEMA_GET_OUTPUT =
    '{"type":"object","properties":{' +
    '"max_lines":{"type":"integer","description":"Last N lines of each stream (default 200, 0 = all buffered)"},' +
    '"clear":{"type":"boolean","description":"Clear the buffers after reading (default false)"}}}';

{ ── Schema registration ──────────────────────────────────────────────────── }

procedure RegisterDebuggerSchemas(Tools: TJSONArray);
begin
  { Group 1 — Breakpoints }
  Tools.Add(MakeTool('debug_set_breakpoint',
    'Add a source, address or data breakpoint, or change one that exists at ' +
    'that location (condition, pass_count, enabled). No session needed, except ' +
    'to resolve a symbol.',
    SCHEMA_SET_BREAKPOINT, MCP_ANN_WRITE_IDEM));
  Tools.Add(MakeTool('debug_remove_breakpoint',
    'Remove the breakpoint at a location, given as for debug_set_breakpoint.',
    SCHEMA_REMOVE_BREAKPOINT, MCP_ANN_WRITE_IDEM));
  Tools.Add(MakeTool('debug_list_breakpoints',
    'List all breakpoints: kind and location, condition, pass count, hit count, ' +
    'enabled and valid.',
    SCHEMA_NO_PARAMS, MCP_ANN_RO));
  { Group 2 — State query (escape hatch) }
  Tools.Add(MakeTool('debug_get_state',
    'Return the current debugger state and source location. ' +
    'Works in any state (idle, running, paused, stopped). ' +
    'Call this after a timed-out blocking tool to assess what is happening. ' +
    'lease shows which client owns the session and when its lease expires.',
    SCHEMA_NO_PARAMS, MCP_ANN_RO));
  { Group 3 — Session control (blocking) }
  Tools.Add(MakeTool('debug_run',
    'Start debugging or continue from a pause (F9); blocks until the program ' +
    'pauses or ends, or returns state=timeout. The client that drives the ' +
    'debugger owns the session (see lease_idle_timeout).',
    SCHEMA_RUN_DEBUGGER, MCP_ANN_WRITE));
  Tools.Add(MakeTool('debug_pause',
    'Pause a running debug session. Blocks until the program pauses.',
    SCHEMA_NO_PARAMS, MCP_ANN_WRITE));
  Tools.Add(MakeTool('debug_stop',
    'Stop the debug session unconditionally. Non-blocking; safe in any ' +
    'state including after a timed-out step.',
    SCHEMA_NO_PARAMS, MCP_ANN_WRITE_IDEM));
  Tools.Add(MakeTool('debug_step_over',
    'Step over the current line (F8). Blocks until the debugger pauses at ' +
    'the next line.',
    SCHEMA_TIMEOUT_ONLY, MCP_ANN_WRITE));
  Tools.Add(MakeTool('debug_step_into',
    'Step into the call at the current line (F7). Blocks until the debugger ' +
    'pauses.',
    SCHEMA_TIMEOUT_ONLY, MCP_ANN_WRITE));
  Tools.Add(MakeTool('debug_step_out',
    'Step out of the current procedure (Shift+F8). Blocks until the debugger ' +
    'pauses after returning.',
    SCHEMA_TIMEOUT_ONLY, MCP_ANN_WRITE));
  Tools.Add(MakeTool('debug_run_to_line',
    'Run until (file, line) is reached, through a temporary breakpoint ' +
    'removed on pause. A breakpoint already on that line is used and kept, ' +
    'with its condition.',
    SCHEMA_RUN_TO_LINE, MCP_ANN_WRITE));
  { Group 4 — State inspection }
  Tools.Add(MakeTool('debug_get_call_stack',
    'Return call stack frames when the debugger is paused. Returns up to ' +
    'max_frames frames with file, line, function name and address.',
    SCHEMA_GET_CALL_STACK, MCP_ANN_RO));
  Tools.Add(MakeTool('debug_evaluate',
    'Evaluate a Pascal expression while paused, in the selected frame or in ' +
    'the given thread/frame (selected for this call only).',
    SCHEMA_EVALUATE_EXPRESSION, MCP_ANN_RO));
  Tools.Add(MakeTool('debug_select_frame',
    'Select a thread and stack frame while paused, as the Threads and Call ' +
    'Stack windows do; later evaluations and watches use it.',
    SCHEMA_SELECT_FRAME, MCP_ANN_WRITE_IDEM));
  Tools.Add(MakeTool('debug_get_locals',
    'Return local variables and parameters in the current stack frame. ' +
    'Debugger must be paused.',
    SCHEMA_GET_LOCAL_VARIABLES, MCP_ANN_RO));
  Tools.Add(MakeTool('debug_get_registers',
    'CPU registers of a thread and frame while paused, as the Registers window ' +
    'shows them; "changed" marks values that changed since the previous pause.',
    SCHEMA_GET_REGISTERS, MCP_ANN_RO));
  Tools.Add(MakeTool('debug_disassemble',
    'Machine code around an address or a stack frame while paused, with source ' +
    'lines, function+offset and call/jump targets; "at" marks the requested instruction.',
    SCHEMA_DISASSEMBLE, MCP_ANN_RO));
  Tools.Add(MakeTool('debug_set_variable',
    'Modify a local variable or parameter in the current stack frame. ' +
    'Debugger must be paused. Call debug_get_locals afterwards to verify.',
    SCHEMA_SET_LOCAL_VARIABLE, MCP_ANN_WRITE_IDEM));
  Tools.Add(MakeTool('debug_add_watch',
    'Add an expression to the IDE Watches window (kept across sessions). ' +
    'Values are read with debug_list_watches while paused.',
    SCHEMA_WATCH_EXPRESSION, MCP_ANN_WRITE));
  Tools.Add(MakeTool('debug_remove_watch',
    'Remove a watch expression from the Watches window, or all with "*".',
    SCHEMA_REMOVE_WATCH, MCP_ANN_WRITE_IDEM));
  Tools.Add(MakeTool('debug_list_watches',
    'List the Watches window entries. While paused, each comes with its value ' +
    'and type in the selected (or given) thread and stack frame.',
    SCHEMA_LIST_WATCHES, MCP_ANN_RO));
  Tools.Add(MakeTool('debug_list_threads',
    'List the debuggee''s threads (id, name, state, current flag, top frame ' +
    'function/file/line). Debugger must be paused.',
    SCHEMA_NO_PARAMS, MCP_ANN_RO));
  Tools.Add(MakeTool('debug_get_output',
    'Return what the program wrote to its console (stdout/stderr) and the ' +
    'debugger''s own output/messages in the current or last debug session.',
    SCHEMA_GET_OUTPUT, MCP_ANN_RO));
  Tools.Add(MakeTool('debug_get_exception',
    'Return information about the current exception when the debugger is paused ' +
    'at an exception. Returns has_exception=false if not paused at an exception. ' +
    'Uses FPC RTL ExceptObject to read class name and message.',
    SCHEMA_EXCEPTION_INFO, MCP_ANN_RO));
end;

initialization
  GSyncHelper := TDbgSyncHelper.Create;
  RegisterMcpGroup(@DispatchDebuggerTool);
  RegisterMcpBlockingGroup(@DispatchDebuggerBlockingTool);
  RegisterMcpSchemas(@RegisterDebuggerSchemas);

finalization
  FreeAndNil(GSyncHelper);

end.
