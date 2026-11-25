{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpProgress;

{ Progress notifications and cancellation of running tool calls (ADR-036).

  Every tools/call enters a registry (session, JSON-RPC id, tool).  If the client sent a
  progressToken and accepts text/event-stream, a helper thread answers the POST as a stream
  once the call has run McpProgressStartMs, and from then on sends a notifications/progress
  event every McpProgressEveryMs; the result goes out as the last event.  A call that ends
  sooner, or a client without a token, gets the plain JSON answer as before.

  A tool may say what it is doing (McpProgressSay) and looks at McpCancelRequested where it
  already waits.  notifications/cancelled sets the flag of the call with the same session and
  id (McpCancelCall).  Both work on the request thread of the call, through a thread variable,
  so a tool needs no extra parameter.

  Only one thread writes to the socket at a time: the helper thread until McpCallStreamResult
  has stopped it, then the request thread.

  Pure RTL (and the FCL's HTTP server): no IDE and no LCL. }

{$mode objfpc}{$H+}

interface

uses
  fpjson, httpdefs, fphttpserver;

const
  McpProgressStartMs = 5000;    { a call this old is answered as a stream }
  McpProgressEveryMs = 15000;   { then a heartbeat this often }

type
  { Called on the thread of the cancel notification: what a tool needs beyond the flag (the IDE
    build has to be told to stop).  True: it stopped the tool itself, so the call is reported as
    cancelled although the tool never looked at the flag.  Set by mcpideserver. }
  TMcpCancelAction = function(const ATool: string): Boolean;

  TMcpCancelResult = (cnCancelled, cnUnknown, cnForeign);

var
  GMcpCancelAction : TMcpCancelAction = nil;

{ HandleRequest, before the JSON-RPC body is handled: where a stream could be written, and
  whether the client accepts one. }
procedure McpStreamPrepare(AResponse: TFPHTTPConnectionResponse; AAcceptsStream: Boolean);

{ The answer was written to the stream: HandleRequest must not write another. }
function McpStreamDone: Boolean;

{ The request thread of a tools/call: enter it in the registry.  AToken is
  params._meta.progressToken or nil. }
procedure McpCallBegin(const ASession, AReqId, ATool: string; AToken: TJSONData);

{ The result of the call (a JSON-RPC response).  True when it was written as the last event of
  a stream, False when the caller answers as usual. }
function McpCallStreamResult(const AResponse: string): Boolean;

{ Leave the registry; always called, also after an exception. }
procedure McpCallEnd;

type
  { The flag of a call that runs on the IDE's main thread (CallOnMain).  The request thread of
    the call copies its cancel flag into Cancel while it waits; the tool, on the main thread,
    reads it through McpCancelRequested and sets Honored; the request thread reads that
    afterwards (McpMarkHonored). }
  TMcpMainCancel = record
    Cancel  : LongInt;
    Honored : LongInt;
  end;
  PMcpMainCancel = ^TMcpMainCancel;

var
  { main thread only: the call it is running now (nested calls save and restore it) }
  GMcpMainCancel : PMcpMainCancel = nil;

{ In a tool, on the call's own thread (or the main thread, for a tool CallOnMain runs). }
function McpCancelRequested: Boolean;

{ The request thread, while it waits for the main thread: has the client cancelled?  Unlike
  McpCancelRequested it does not count as a tool stopping.  And McpMarkHonored: the main-thread
  tool did stop. }
function McpCancelPending: Boolean;
procedure McpMarkHonored;
procedure McpProgressSay(const AMessage: string);

{ After the call: '' unless a tool stopped for a cancel, then "Cancelled by the client after N s". }
function McpCallCancelNote: string;

{ notifications/cancelled: the call of this session and id gets its flag set. }
function McpCancelCall(const ASession, AReqId, AReason: string;
  out ATool: string; out ASeconds: Integer): TMcpCancelResult;

{ Calls in the registry (tests). }
function McpCallCount: Integer;

implementation

uses
  Classes, SysUtils, SyncObjs;

type
  TMcpCall = class;

  TMcpBeat = class(TThread)
  private
    FCall : TMcpCall;
  protected
    procedure Execute; override;
  public
    Stop : TEvent;
    constructor Create(ACall: TMcpCall);
    destructor Destroy; override;
  end;

  TMcpCall = class
    Session   : string;
    ReqId     : string;
    Tool      : string;
    Token     : string;      { the token as JSON text, '' = none }
    Started   : QWord;
    Cancel    : LongInt;     { set with InterlockedExchange }
    Honored   : LongInt;     { a tool saw Cancel and stopped }
    Message   : string;      { guarded by GLock }
    Reason    : string;
    Resp      : TFPHTTPConnectionResponse;
    Streaming : Boolean;     { the headers went out; only the beat thread sets it, before it ends }
    Failed    : Boolean;     { a write failed: the client is gone }
    Beat      : TMcpBeat;
  end;

  { the connection and its socket are protected; this is the way to the socket }
  TRespAccess = class(TFPHTTPConnectionResponse);

threadvar
  GCur       : TMcpCall;
  GResp      : TFPHTTPConnectionResponse;
  GAccepts   : Boolean;
  GStreamEnd : Boolean;

var
  GLock  : TRTLCriticalSection;
  GCalls : TList;

procedure RawWrite(AResp: TFPHTTPConnectionResponse; const S: string);
begin
  if S <> '' then
    TRespAccess(AResp).Connection.Socket.WriteBuffer(S[1], Length(S));
end;

function ElapsedSeconds(ACall: TMcpCall): Integer;
begin
  Result := Integer((GetTickCount64 - ACall.Started) div 1000);
end;

{ ── the helper thread ────────────────────────────────────────────────────── }

constructor TMcpBeat.Create(ACall: TMcpCall);
begin
  FCall := ACall;
  Stop  := TEvent.Create(nil, True, False, '');
  inherited Create(False);
end;

destructor TMcpBeat.Destroy;
begin
  Stop.Free;
  inherited Destroy;
end;

procedure TMcpBeat.Execute;
var
  Msg : string;
  Say : string;
  Evt : string;
begin
  if Stop.WaitFor(McpProgressStartMs) <> wrTimeout then Exit;   { the call ended first }
  try
    FCall.Resp.Code        := 200;
    FCall.Resp.ContentType := 'text/event-stream';
    FCall.Resp.SetCustomHeader('Cache-Control', 'no-cache');
    FCall.Resp.SendHeaders;
    FCall.Streaming := True;
    repeat
      EnterCriticalSection(GLock);
      try
        Msg := FCall.Message;
      finally
        LeaveCriticalSection(GLock);
      end;
      Say := 'still running (' + IntToStr(ElapsedSeconds(FCall)) + ' s)';
      if Msg <> '' then Say := Say + ': ' + Msg;
      with TJSONString.Create(Say) do
      try
        Evt := AsJSON;
      finally
        Free;
      end;
      RawWrite(FCall.Resp, 'event: message' + #10 + 'data: ' +
        '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":' +
        FCall.Token + ',"progress":' + IntToStr(ElapsedSeconds(FCall)) +
        ',"message":' + Evt + '}}' + #10#10);
    until Stop.WaitFor(McpProgressEveryMs) <> wrTimeout;
  except
    { the client closed the stream: the same as a cancel }
    FCall.Failed := True;
    FCall.Streaming := True;
    InterlockedExchange(FCall.Cancel, 1);
    EnterCriticalSection(GLock);
    try
      FCall.Reason := 'the client closed the connection';
    finally
      LeaveCriticalSection(GLock);
    end;
  end;
end;

{ ── request thread ───────────────────────────────────────────────────────── }

procedure McpStreamPrepare(AResponse: TFPHTTPConnectionResponse; AAcceptsStream: Boolean);
begin
  GResp      := AResponse;
  GAccepts   := AAcceptsStream;
  GStreamEnd := False;
  GCur       := nil;
end;

function McpStreamDone: Boolean;
begin
  Result := GStreamEnd;
end;

procedure McpCallBegin(const ASession, AReqId, ATool: string; AToken: TJSONData);
var
  C : TMcpCall;
begin
  C := TMcpCall.Create;
  C.Session := ASession;
  C.ReqId   := AReqId;
  C.Tool    := ATool;
  C.Started := GetTickCount64;
  C.Resp    := GResp;
  if Assigned(AToken) and (AToken.JSONType in [jtNumber, jtString]) then
    C.Token := AToken.AsJSON;
  EnterCriticalSection(GLock);
  try
    GCalls.Add(C);
  finally
    LeaveCriticalSection(GLock);
  end;
  GCur := C;
  { a call that ends the IDE (a rebuild) or the server answers in its own way }
  if (C.Token <> '') and GAccepts and Assigned(GResp) and
     (ATool <> 'ide_rebuild') and (ATool <> 'package_install') and
     (ATool <> 'package_uninstall') then
    C.Beat := TMcpBeat.Create(C);
end;

procedure StopBeat(C: TMcpCall);
begin
  if Assigned(C.Beat) then
  begin
    C.Beat.Stop.SetEvent;
    C.Beat.WaitFor;
    FreeAndNil(C.Beat);
  end;
end;

function McpCallStreamResult(const AResponse: string): Boolean;
var
  C : TMcpCall;
begin
  Result := False;
  C := GCur;
  if C = nil then Exit;
  StopBeat(C);
  if not C.Streaming then Exit;       { it ended before the stream began }
  if not C.Failed then
    try
      RawWrite(C.Resp, 'event: message' + #10 + 'data: ' + AResponse + #10#10);
    except
      { the client went away at the last moment: nothing left to tell it }
    end;
  GStreamEnd := True;
  Result := True;
end;

procedure McpCallEnd;
var
  C : TMcpCall;
begin
  C := GCur;
  if C = nil then Exit;
  GCur := nil;
  StopBeat(C);
  EnterCriticalSection(GLock);
  try
    GCalls.Remove(C);
  finally
    LeaveCriticalSection(GLock);
  end;
  C.Free;
end;

function McpCancelPending: Boolean;
begin
  Result := (GCur <> nil) and (InterlockedCompareExchange(GCur.Cancel, 0, 0) <> 0);
end;

procedure McpMarkHonored;
begin
  if GCur <> nil then InterlockedExchange(GCur.Honored, 1);
end;

function McpCancelRequested: Boolean;
begin
  Result := False;
  if GCur <> nil then
  begin
    Result := InterlockedCompareExchange(GCur.Cancel, 0, 0) <> 0;
    if Result then InterlockedExchange(GCur.Honored, 1);
  end
  else if (GMcpMainCancel <> nil) and (GetCurrentThreadId = MainThreadID) then
  begin
    { a tool running on the main thread: the request thread relays the flag }
    Result := InterlockedCompareExchange(GMcpMainCancel^.Cancel, 0, 0) <> 0;
    if Result then InterlockedExchange(GMcpMainCancel^.Honored, 1);
  end;
end;

procedure McpProgressSay(const AMessage: string);
begin
  if GCur = nil then Exit;
  EnterCriticalSection(GLock);
  try
    GCur.Message := AMessage;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

function McpCallCancelNote: string;
begin
  Result := '';
  if (GCur <> nil) and (InterlockedCompareExchange(GCur.Honored, 0, 0) <> 0) then
  begin
    Result := 'Cancelled by the client after ' + IntToStr(ElapsedSeconds(GCur)) + ' s';
    EnterCriticalSection(GLock);
    try
      if GCur.Reason <> '' then Result := Result + ' (' + GCur.Reason + ')';
    finally
      LeaveCriticalSection(GLock);
    end;
  end;
end;

{ ── cancel notification thread ───────────────────────────────────────────── }

function McpCancelCall(const ASession, AReqId, AReason: string;
  out ATool: string; out ASeconds: Integer): TMcpCancelResult;
var
  I : Integer;
  C : TMcpCall;
  Hit : TMcpCall;
begin
  Hit := nil;
  Result := cnUnknown;
  ATool := '';
  ASeconds := 0;
  EnterCriticalSection(GLock);
  try
    for I := 0 to GCalls.Count - 1 do
    begin
      C := TMcpCall(GCalls[I]);
      if C.ReqId = AReqId then
      begin
        ATool := C.Tool;
        if C.Session <> ASession then
          Result := cnForeign
        else
        begin
          Hit := C;
          Result := cnCancelled;
          C.Reason := AReason;
          ASeconds := ElapsedSeconds(C);
          InterlockedExchange(C.Cancel, 1);
        end;
        Break;
      end;
    end;
  finally
    LeaveCriticalSection(GLock);
  end;
  { outside the lock: the action may take a while.  The call can end meanwhile, and the
    action only needs its tool name. }
  if (Hit <> nil) and Assigned(GMcpCancelAction) then
    if GMcpCancelAction(ATool) then
    begin
      { Hit may be gone by now: look the call up again }
      EnterCriticalSection(GLock);
      try
        for I := 0 to GCalls.Count - 1 do
          if TMcpCall(GCalls[I]) = Hit then
            InterlockedExchange(Hit.Honored, 1);
      finally
        LeaveCriticalSection(GLock);
      end;
    end;
end;

function McpCallCount: Integer;
begin
  EnterCriticalSection(GLock);
  try
    Result := GCalls.Count;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

initialization
  InitCriticalSection(GLock);
  GCalls := TList.Create;

finalization
  GCalls.Free;
  DoneCriticalSection(GLock);

end.
