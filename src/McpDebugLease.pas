{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpDebugLease;

{ Several MCP clients (assistants) can talk to one IDE at a time; the IDE has
  one debugger.  See ADR-012.

  Client identity
    The Mcp-Session-Id the server hands out in the initialize response (and as
    an mcp_session cookie), echoed back by the client on later requests.
    Requests with neither share the identity 'anonymous'.  Unknown ids (e.g.
    after an IDE restart) are accepted as they are: the id itself is the key.

  Debug session lease
    The first client that drives the debugger (any debug_* tool that is not
    read-only) owns the session until it ends.  Meanwhile other clients get
    read-only tools plus everything that cannot break the session; the
    debugger-driving tools and build/run/rebuild/package (un)install are
    refused with a message naming the owner.
    The lease is an idle timeout: every owner call refreshes it, and it never
    runs out while an owner call is in flight (debug_run may wait long for a
    breakpoint).  When it runs out, a watchdog stops the MCP-driven session
    on the main thread and releases the lease.

  Debugger lock
    The debugger tools share state with the IDE's debugger, so at most one
    debug_* call runs at a time, whoever calls it (the owner's parallel calls
    included), except debug_stop and debug_get_state, which must work while
    a debug_run is blocked.  Other callers wait up to DEBUG_LOCK_WAIT_MS. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, fpjson;

const
  ANONYMOUS_CLIENT     = 'anonymous';
  DEFAULT_LEASE_IDLE_S = 300;
  MAX_LEASE_IDLE_S     = 3600;
  DEBUG_LOCK_WAIT_MS   = 60000;

{ ── Client sessions (any thread) ── }
function  McpNewSessionId: string;
procedure McpRegisterSession(const AId, AClientName: string);
{ DELETE /mcp: forget the session and release its lease. }
procedure McpForgetSession(const AId: string);
function  McpClientLabel(const AId: string): string;

{ ── Tool gate, called on the request thread around every tools/call ──
  McpGateEnter returns False (with AMsg) if the call is refused; otherwise
  McpGateLeave must follow.  AArgs may be nil. }
function  McpGateEnter(const AToolName, AClientId: string; AArgs: TJSONObject;
  out AMsg: string): Boolean;
procedure McpGateLeave(const AToolName, AClientId: string);

{ ── Main thread ── }
{ Debugger session ended (from McpDebugGuard's state handler). }
procedure McpLeaseSessionEnded;
{ Lease state for debug_get_state; nil when nobody holds it. }
function  McpLeaseJSON: TJSONObject;

procedure McpFinalizeLease;

var
  { Written on the main thread by McpDebugGuard: a debug session is live. }
  GMcpSessionLive : Boolean = False;

implementation

uses
  StrUtils, IDEMsgIntf, IDEExternToolIntf,
  BaseDebugManager, LazDebuggerIntfBaseTypes,
  McpToolContext, McpDebugGuard;

type
  TLeaseWatchdog = class(TThread)
  protected
    procedure Execute; override;
    procedure ExpireOnMain;
  end;

var
  GLock         : TCriticalSection = nil;   { guards everything below }
  GSessions     : TStringList = nil;        { id=client name }
  GReadOnly     : TStringList = nil;        { sorted names of read-only tools }
  GOwner        : string = '';              { '' = lease free }
  GOwnerLabel   : string = '';
  GIdleMs       : QWord = DEFAULT_LEASE_IDLE_S * 1000;
  GLastActivity : QWord = 0;
  GInFlight     : Integer = 0;              { owner calls running }
  GAcquiredAt   : TDateTime = 0;
  GDebugBusy    : LongInt = 0;              { debugger lock, 0/1 }
  GWatchdog     : TLeaseWatchdog = nil;

function Lock: TCriticalSection;
begin
  if GLock = nil then
    GLock := TCriticalSection.Create;  { created in initialization; never nil in practice }
  Result := GLock;
end;

{ ── Sessions ─────────────────────────────────────────────────────────────── }

function McpNewSessionId: string;
var
  G : TGUID;
begin
  CreateGUID(G);
  Result := LowerCase(Copy(GUIDToString(G), 2, 36));
end;

procedure McpRegisterSession(const AId, AClientName: string);
begin
  if AId = '' then Exit;
  Lock.Enter;
  try
    GSessions.Values[AId] := AClientName;
  finally
    Lock.Leave;
  end;
end;

function LabelLocked(const AId: string): string;
var
  N : string;
begin
  if AId = ANONYMOUS_CLIENT then Exit('anonymous client (no Mcp-Session-Id)');
  N := GSessions.Values[AId];
  if N = '' then N := 'client';
  Result := N + ' (session ' + Copy(AId, 1, 8) + ')';
end;

function McpClientLabel(const AId: string): string;
begin
  Lock.Enter;
  try
    Result := LabelLocked(AId);
  finally
    Lock.Leave;
  end;
end;

procedure ReleaseLocked;
begin
  GOwner      := '';
  GOwnerLabel := '';
  GInFlight   := 0;
end;

procedure McpForgetSession(const AId: string);
var
  I : Integer;
begin
  if AId = '' then Exit;
  Lock.Enter;
  try
    I := GSessions.IndexOfName(AId);
    if I >= 0 then GSessions.Delete(I);
    { The client is gone; its session is no longer driven by anyone.  The
      watchdog stops it once the lease is free and nobody claims it. }
    if GOwner = AId then
      GLastActivity := 0;   { expire at the next watchdog tick }
  finally
    Lock.Leave;
  end;
end;

{ ── Tool classification ──────────────────────────────────────────────────── }

{ Read-only tools are those annotated readOnlyHint=true (ADR-010). }
procedure EnsureReadOnlyListLocked;
var
  Tools : TJSONArray;
  T     : TJSONObject;
  Ann   : TJSONObject;
  I     : Integer;
begin
  if GReadOnly <> nil then Exit;
  GReadOnly := TStringList.Create;
  GReadOnly.Sorted := True;
  Tools := TJSONArray.Create;
  try
    McpRegisterSchemas(Tools);
    for I := 0 to Tools.Count - 1 do
    begin
      T   := TJSONObject(Tools[I]);
      Ann := T.Get('annotations', TJSONObject(nil));
      if Assigned(Ann) and Ann.Get('readOnlyHint', False) then
        GReadOnly.Add(T.Get('name', ''));
    end;
  finally
    Tools.Free;
  end;
end;

function IsDebugTool(const AName: string): Boolean;
begin
  Result := Copy(AName, 1, 6) = 'debug_';
end;

{ The escape hatches stay usable while a debug_run blocks: debug_stop only
  posts a command, debug_get_state only reads the state, both on the main
  thread. }
function TakesDebugLock(const AName: string): Boolean;
begin
  Result := IsDebugTool(AName) and (AName <> 'debug_stop') and
            (AName <> 'debug_get_state');
end;

{ Tools another client may not use while someone else owns the session:
  everything that drives the debugger, and what would end or disturb the
  session (rebuilding the exe, restarting the IDE, replacing the project). }
function BreaksSessionLocked(const AName: string): Boolean;
begin
  if GReadOnly.IndexOf(AName) >= 0 then Exit(False);
  Result := IsDebugTool(AName) or
            (AName = 'project_build') or (AName = 'project_run') or
            (AName = 'project_create') or (AName = 'ide_rebuild') or
            (AName = 'package_install') or (AName = 'package_uninstall');
end;

{ ── Debugger lock ────────────────────────────────────────────────────────── }

function AcquireDebugLock(ATimeoutMs: Integer): Boolean;
var
  Deadline : QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    if InterlockedCompareExchange(GDebugBusy, 1, 0) = 0 then Exit(True);
    Sleep(20);
  until GetTickCount64 >= Deadline;
  Result := False;
end;

procedure ReleaseDebugLock;
begin
  InterlockedExchange(GDebugBusy, 0);
end;

{ ── Gate ─────────────────────────────────────────────────────────────────── }

procedure EnsureWatchdog;
begin
  if GWatchdog = nil then
    GWatchdog := TLeaseWatchdog.Create(False);
end;

procedure CallDone(const AToolName, AClientId: string); forward;

function McpGateEnter(const AToolName, AClientId: string; AArgs: TJSONObject;
  out AMsg: string): Boolean;
var
  Secs      : Int64;
  NeedLease : Boolean;
begin
  AMsg := '';
  Lock.Enter;
  try
    EnsureReadOnlyListLocked;
    NeedLease := IsDebugTool(AToolName) and (GReadOnly.IndexOf(AToolName) < 0);
    if (GOwner <> '') and (GOwner <> AClientId) and BreaksSessionLocked(AToolName) then
    begin
      Secs := 0;
      if GInFlight = 0 then
        Secs := (Int64(GLastActivity + GIdleMs) - Int64(GetTickCount64)) div 1000;
      if Secs < 0 then Secs := 0;
      AMsg := Format('Refused: the debug session belongs to %s. While it is live, ' +
        'other clients can use read-only tools and tools that do not affect the ' +
        'session (editing, code_*, form_*, git_*). The lease ends when that client ' +
        'stops the session, or after %d s without calls from it (%s).',
        [GOwnerLabel, GIdleMs div 1000,
         IfThen(GInFlight > 0, 'it has a call running now',
                Format('expires in about %d s', [Secs]))]);
      Exit(False);
    end;
    if NeedLease and (GOwner = '') then
    begin
      GOwner      := AClientId;
      GOwnerLabel := LabelLocked(AClientId);
      GAcquiredAt := Now;
      GIdleMs     := DEFAULT_LEASE_IDLE_S * 1000;
      EnsureWatchdog;
    end;
    if (GOwner <> '') and (GOwner = AClientId) then
    begin
      if Assigned(AArgs) and (AArgs.Find('lease_idle_timeout') <> nil) then
      begin
        Secs := AArgs.Get('lease_idle_timeout', Int64(DEFAULT_LEASE_IDLE_S));
        if Secs < 10 then Secs := 10;
        if Secs > MAX_LEASE_IDLE_S then Secs := MAX_LEASE_IDLE_S;
        GIdleMs := Secs * 1000;
      end;
      { read-only calls are short; only the others hold the lease open }
      if GReadOnly.IndexOf(AToolName) < 0 then
        Inc(GInFlight);
      GLastActivity := GetTickCount64;
    end;
  finally
    Lock.Leave;
  end;

  if TakesDebugLock(AToolName) and not AcquireDebugLock(DEBUG_LOCK_WAIT_MS) then
  begin
    CallDone(AToolName, AClientId);  { undo the in-flight count; no lock to release }
    AMsg := Format('Debugger busy: another debug_* call has been running for over %d s. ' +
                   'Retry later or call debug_get_state.', [DEBUG_LOCK_WAIT_MS div 1000]);
    Exit(False);
  end;
  Result := True;
end;

procedure McpGateLeave(const AToolName, AClientId: string);
begin
  if TakesDebugLock(AToolName) then
    ReleaseDebugLock;
  CallDone(AToolName, AClientId);
end;

procedure CallDone(const AToolName, AClientId: string);
begin
  Lock.Enter;
  try
    if (GOwner <> '') and (GOwner = AClientId) then
    begin
      if (GReadOnly.IndexOf(AToolName) < 0) and (GInFlight > 0) then
        Dec(GInFlight);
      GLastActivity := GetTickCount64;
    end;
  finally
    Lock.Leave;
  end;
end;

{ ── Main-thread side ─────────────────────────────────────────────────────── }

procedure LogToIDE(const AMsg: string);
begin
  if Assigned(IDEMessagesWindow) then
    IDEMessagesWindow.AddCustomMessage(mluProgress, AMsg, '', 0, 0, 'MCP Server');
end;

procedure McpLeaseSessionEnded;
begin
  Lock.Enter;
  try
    { Keep the lease while an owner call is in flight: it is the call that
      ended the session (debug_stop) or is about to start the next one. }
    if (GOwner <> '') and (GInFlight = 0) then
      ReleaseLocked;
  finally
    Lock.Leave;
  end;
end;

function McpLeaseJSON: TJSONObject;
var
  Secs : Int64;
begin
  Result := nil;
  Lock.Enter;
  try
    if GOwner = '' then Exit;
    Result := TJSONObject.Create;
    Result.Add('owner', GOwnerLabel);
    Result.Add('idle_timeout_s', Int64(GIdleMs div 1000));
    if GInFlight > 0 then
      Result.Add('owner_call_running', True)
    else
    begin
      Secs := (Int64(GLastActivity + GIdleMs) - Int64(GetTickCount64)) div 1000;
      if Secs < 0 then Secs := 0;
      Result.Add('expires_in_s', Secs);
    end;
  finally
    Lock.Leave;
  end;
end;

{ ── Watchdog ─────────────────────────────────────────────────────────────── }

procedure TLeaseWatchdog.Execute;
var
  Due : Boolean;
begin
  while not Terminated do
  begin
    Sleep(1000);
    if Terminated then Break;
    Lock.Enter;
    try
      { GMcpSessionLive is a hint here; ExpireOnMain re-checks the debugger }
      Due := (GOwner <> '') and (GInFlight = 0) and
             ((GetTickCount64 >= GLastActivity + GIdleMs) or not GMcpSessionLive);
    finally
      Lock.Leave;
    end;
    if Due then
      Queue(@ExpireOnMain);  { never block: the IDE may be waiting for us to end }
  end;
end;

procedure TLeaseWatchdog.ExpireOnMain;
var
  Who      : string;
  Expired  : Boolean;
  Live     : Boolean;
  StopIt   : Boolean;
begin
  { GMcpSessionLive only follows state changes the guard has seen; ask the
    debugger itself }
  Live := Assigned(DebugBoss) and
          (DebugBoss.State in [dsInit, dsRun, dsPause, dsInternalPause]);
  Lock.Enter;
  try
    if (GOwner = '') or (GInFlight > 0) then Exit;
    Expired := GetTickCount64 >= GLastActivity + GIdleMs;
    if not Expired and Live then Exit;
    Who := GOwnerLabel;
    ReleaseLocked;
  finally
    Lock.Leave;
  end;
  if not Expired then Exit;  { no session (never started, or already over) }
  { Stop only a session MCP still drives; if the user took it over with the
    IDE's own commands, leave it running. }
  StopIt := Live and GMcpDriven;
  if StopIt then
    DebugBoss.DoStopProject;  { GMcpDriven: no "Execution stopped" dialog }
  LogToIDE(Format('MCP: debug session lease of %s expired after %d s without calls%s.',
    [Who, GIdleMs div 1000, IfThen(StopIt, '; session stopped', '')]));
end;

procedure McpFinalizeLease;
begin
  if Assigned(GWatchdog) then
  begin
    GWatchdog.Terminate;
    GWatchdog.WaitFor;
    FreeAndNil(GWatchdog);
  end;
end;

initialization
  GLock     := TCriticalSection.Create;
  GSessions := TStringList.Create;

finalization
  McpFinalizeLease;
  FreeAndNil(GReadOnly);
  FreeAndNil(GSessions);
  FreeAndNil(GLock);

end.
