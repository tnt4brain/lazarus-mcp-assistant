{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpExceptionLog;

{ Records every exception that reaches the IDE's own error dialog
  (TApplication.HandleException): an access violation in a paint or idle
  handler, in a deferred event, in code an earlier tool call set going.
  Exceptions inside a tool call never get there: the server catches them and
  returns them as the tool's error.

  For each one: time, class, message, stack, and the last MCP tool called
  (how long before, and whether a tool call was running).  The last
  MAX_ENTRIES are kept for ide_get_exceptions; every entry is also appended
  to mcp-exceptions.log in the IDE's config folder, which survives a crash.

  With a handler registered, LCL calls the handlers instead of showing its
  dialog, so the handler shows the same dialog itself: nothing changes for
  the user. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

procedure InitializeExceptionLog;
procedure FinalizeExceptionLog;

{ Called by the server on the main thread before each tool call. }
procedure McpNoteToolCall(const ATool: string);

{ Record E (in an except block) like an exception the IDE's dialog showed,
  without showing it. }
procedure McpLogException(E: Exception);

implementation

uses
  Classes, Forms, LazFileUtils, LazIDEIntf, fpjson,
  McpToolContext, McpIdeListeners;

const
  MAX_ENTRIES = 50;
  LOG_NAME    = 'mcp-exceptions.log';

  SCHEMA_IDE_GET_EXCEPTIONS =
    '{"type":"object","properties":{' +
    '"clear":{"type":"boolean","description":"Forget the listed exceptions afterwards (the log file is kept)"}}}';

type
  TExcEntry = record
    At         : TDateTime;
    ExcClass   : string;
    Msg        : string;
    Trace      : string;
    LastTool   : string;
    ToolAgoMs  : Int64;
    DuringCall : Boolean;
  end;

  TExcLogger = class
    procedure OnException(Sender: TObject; E: Exception);
  end;

var
  Logger      : TExcLogger = nil;
  Entries     : array of TExcEntry;
  GLastTool   : string = '';
  GLastToolAt : TDateTime = 0;

procedure McpNoteToolCall(const ATool: string);
begin
  GLastTool   := ATool;
  GLastToolAt := Now;
end;

function LogFileName: string;
begin
  Result := '';
  if Assigned(LazarusIDE) then
    Result := AppendPathDelim(LazarusIDE.GetPrimaryConfigPath) + LOG_NAME;
end;

function CurrentTrace: string;
var
  Frames : PCodePointer;
  I      : Integer;
begin
  Result := BackTraceStrFunc(ExceptAddr);
  Frames := ExceptFrames;
  for I := 0 to ExceptFrameCount - 1 do
    Result := Result + LineEnding + BackTraceStrFunc(Frames[I]);
end;

procedure AppendToFile(const E: TExcEntry);
var
  FN : string;
  F  : TextFile;
begin
  FN := LogFileName;
  if FN = '' then Exit;
  try
    AssignFile(F, FN);
    if FileExists(FN) then Append(F) else Rewrite(F);
    try
      WriteLn(F, '=== ', FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', E.At), '  ',
                 E.ExcClass, ': ', E.Msg);
      if E.LastTool <> '' then
        WriteLn(F, 'last MCP tool: ', E.LastTool, ', ', E.ToolAgoMs, ' ms before',
                   BoolToStr(E.DuringCall, ' (a tool call was running)', ''));
      WriteLn(F, E.Trace);
    finally
      CloseFile(F);
    end;
  except
    { a log that cannot be written must not raise another exception here }
  end;
end;

procedure TExcLogger.OnException(Sender: TObject; E: Exception);
begin
  McpLogException(E);
  { what LCL does when no handler is registered }
  Application.ShowException(E);
end;

procedure McpLogException(E: Exception);
var
  X : TExcEntry;
begin
  try
    X.At         := Now;
    X.ExcClass   := E.ClassName;
    X.Msg        := E.Message;
    X.Trace      := CurrentTrace;
    X.LastTool   := GLastTool;
    X.ToolAgoMs  := 0;
    if GLastToolAt > 0 then
      X.ToolAgoMs := Round((X.At - GLastToolAt) * MSecsPerDay);
    X.DuringCall := GMcpToolCallsActive > 0;
    if Length(Entries) >= MAX_ENTRIES then
      Delete(Entries, 0, 1);
    SetLength(Entries, Length(Entries) + 1);
    Entries[High(Entries)] := X;
    AppendToFile(X);
  except
  end;
end;

function DispatchExceptionLog(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  Obj, Item : TJSONObject;
  Arr       : TJSONArray;
  I         : Integer;
begin
  Result := Name = 'ide_get_exceptions';
  if not Result then Exit;
  Obj := TJSONObject.Create;
  try
    Arr := TJSONArray.Create;
    for I := 0 to High(Entries) do
    begin
      Item := TJSONObject.Create;
      Item.Add('time',    FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Entries[I].At));
      Item.Add('class',   Entries[I].ExcClass);
      Item.Add('message', Entries[I].Msg);
      Item.Add('stack',   Entries[I].Trace);
      if Entries[I].LastTool <> '' then
      begin
        Item.Add('last_tool', Entries[I].LastTool);
        Item.Add('last_tool_ms_before', Entries[I].ToolAgoMs);
        Item.Add('during_tool_call', Entries[I].DuringCall);
      end;
      Arr.Add(Item);
    end;
    Obj.Add('count', Arr.Count);
    Obj.Add('exceptions', Arr);
    Obj.Add('log_file', LogFileName);
    if Assigned(Ctx.Params) and Ctx.Params.Get('clear', False) then
      SetLength(Entries, 0);
    Ctx.Result := Obj.AsJSON;
  finally
    Obj.Free;
  end;
end;

procedure RegisterExceptionLogSchemas(Tools: TJSONArray);
begin
  Tools.Add(MakeTool('ide_get_exceptions',
    'Unhandled exceptions the IDE showed in its error dialog since it started ' +
    '(access violations and others, outside tool calls), newest last: class, ' +
    'message, stack, and the last MCP tool called before. Also appended to ' +
    'log_file, which survives a restart.',
    SCHEMA_IDE_GET_EXCEPTIONS, MCP_ANN_RO));
end;

procedure InitializeExceptionLog;
begin
  if Assigned(Logger) then Exit;
  Logger := TExcLogger.Create;
  Application.AddOnExceptionHandler(@Logger.OnException);
end;

procedure FinalizeExceptionLog;
begin
  if not Assigned(Logger) then Exit;
  Application.RemoveOnExceptionHandler(@Logger.OnException);
  FreeAndNil(Logger);
end;

initialization
  RegisterMcpGroup(@DispatchExceptionLog);
  RegisterMcpSchemas(@RegisterExceptionLogSchemas);

finalization
  FinalizeExceptionLog;
end.
