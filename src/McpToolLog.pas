{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolLog;

{ mcp-tools.log (ADR-022): one JSON object per line for each tools/call, a
  "begin" line when it arrives and an "end" line when it returns, so a call that
  hangs or takes the IDE down leaves its "begin" behind.  No argument values and
  no results are recorded: only the argument names and a hash of the arguments.
  Plain LazUtils code with no IDE units, so the test program can use it.
  Thread-safe; the log never raises, and switches itself off after five failed
  writes in a row. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpjson;

type
  TMcpLogCaller = record
    Client  : string;   { "name version" from clientInfo }
    Token   : string;   { the token's name, never its value }
    Session : string;   { short session id }
  end;

  TMcpStrings = array of string;

  { What of a call's arguments goes into the log. }
  TMcpArgsPrint = record
    Keys : TMcpStrings;   { top-level argument names, sorted }
    Hash : string;        { first 12 hex digits of SHA-1 of the canonical JSON }
  end;

const
  MCP_TOOL_LOG_NAME     = 'mcp-tools.log';
  MCP_TOOL_LOG_MAX      = 4 * 1024 * 1024;   { then it becomes .1 (.2, .3) }
  MCP_TOOL_LOG_MAX_ERR  = 300;               { characters of error text }
  MCP_TOOL_LOG_FAILURES = 5;                 { failed writes in a row, then off }
  MCP_TOOL_LOG_FORMAT   = 1;
  MCP_TOOL_PANE_ERR     = 120;               { characters of error text in a Messages line }

{ ── The arguments ── }

{ Canonical JSON of AData: keys sorted by their UTF-8 bytes, no whitespace,
  control characters as \u00xx, secrets redacted (keys that contain token,
  password, secret, authorization or key; URL user-info and so named query
  values).  Integers and booleans as usual; a float with 15 digits, or 17 when
  15 do not read back the same. }
function  McpCanonicalJson(AData: TJSONData): string;
{ Names and hash of the arguments as received (nil: none, which hash as an empty object). }
function  McpArgsPrint(AArgs: TJSONObject): TMcpArgsPrint;

{ ── The log ── }

{ The folder of mcp-tools.log; call once, on the main thread. }
procedure McpToolLogSetDir(const ADir: string);
{ The log file, wherever the user wants it; '' = mcp-tools.log in the folder given to
  McpToolLogSetDir.  The rotated files (.1 to .3) go next to it. }
procedure McpToolLogSetFile(const AFile: string);
procedure McpToolLogSetEnabled(AEnabled: Boolean);
{ On, and not switched off by failures. }
function  McpToolLogEnabled: Boolean;
function  McpToolLogPath: string;
{ Tests: the size at which the file is rotated. }
procedure McpToolLogSetMaxBytes(ABytes: Int64);

{ The project active at the end of the last call that ran on the main thread
  (file name only); written there, read by any thread. }
procedure McpToolLogSetProject(const AName: string);

{ Server start and session records. }
procedure McpToolLogStart(const APlugin, ALazarus, AFpc, AOS: string);
procedure McpToolLogSession(const ACaller: TMcpLogCaller;
  const AProtocol, AAsked: string);

{ A call arrives; returns its seq_id (0 when not logging). }
function  McpToolLogBegin(const ATool: string; const ACaller: TMcpLogCaller): LongInt;
{ A call returns to the client.  Does nothing for ASeq = 0. }
procedure McpToolLogEnd(ASeq: LongInt; const ATool: string;
  const ACaller: TMcpLogCaller; ADurationMs: Int64; ASuccess: Boolean;
  const AError: string; const APrint: TMcpArgsPrint);

{ The line a finished call gets in the Messages window: 'tool  N ms', or
  'tool  N ms  failed: <error>' with the error on one line, cut to MCP_TOOL_PANE_ERR. }
function  McpToolPaneLine(const ATool: string; ADurationMs: Int64; ASuccess: Boolean;
  const AError: string): string;

implementation

uses
  Classes, SyncObjs, DateUtils, sha1, McpSessionLog;

const
  REDACTED = '<redacted>';

var
  GLock     : TCriticalSection;
  GDir      : string = '';
  GFile     : string = '';   { a path the user chose; '' = GDir + MCP_TOOL_LOG_NAME }
  GPath     : string = '';
  GEnabled  : Boolean = False;
  GFailed   : Boolean = False;     { switched off after repeated write errors }
  GFailures : Integer = 0;
  GMax      : Int64 = MCP_TOOL_LOG_MAX;
  GSize     : Int64 = -1;          { -1: not read from the file yet }
  GSeq      : LongInt = 0;
  GProject  : string = '';

{ ── JSON text ────────────────────────────────────────────────────────────── }

{ Length of the well-formed UTF-8 sequence starting at S[I], 0 if there is none. }
function Utf8SeqLen(const S: string; I: Integer): Integer;
var
  B, B1 : Byte;
  N, K  : Integer;
begin
  B := Byte(S[I]);
  if B < $80 then Exit(1);
  if (B >= $C2) and (B <= $DF) then N := 2
  else if (B >= $E0) and (B <= $EF) then N := 3
  else if (B >= $F0) and (B <= $F4) then N := 4
  else Exit(0);
  if I + N - 1 > Length(S) then Exit(0);
  B1 := Byte(S[I + 1]);
  case B of
    $E0: if B1 < $A0 then Exit(0);
    $ED: if B1 > $9F then Exit(0);
    $F0: if B1 < $90 then Exit(0);
    $F4: if B1 > $8F then Exit(0);
  end;
  for K := 1 to N - 1 do
    if (Byte(S[I + K]) < $80) or (Byte(S[I + K]) > $BF) then Exit(0);
  Result := N;
end;

{ S as a JSON string.  Bytes that are not UTF-8 (a Windows message in the
  system code page, say) become '?', so the file stays valid UTF-8. }
function JsonStr(const S: string): string;
var
  I, N : Integer;
  B    : Byte;
begin
  Result := '"';
  I := 1;
  while I <= Length(S) do
  begin
    B := Byte(S[I]);
    if B < $20 then
    begin
      Result := Result + '\u00' + LowerCase(IntToHex(B, 2));
      Inc(I);
    end
    else if S[I] = '"' then begin Result := Result + '\"'; Inc(I); end
    else if S[I] = '\' then begin Result := Result + '\\'; Inc(I); end
    else if B < $80 then begin Result := Result + S[I]; Inc(I); end
    else
    begin
      N := Utf8SeqLen(S, I);
      if N = 0 then
      begin
        Result := Result + '?';
        Inc(I);
      end
      else
      begin
        Result := Result + Copy(S, I, N);
        Inc(I, N);
      end;
    end;
  end;
  Result := Result + '"';
end;

{ The first N characters' worth of bytes of S, never ending inside a sequence. }
function CutText(const S: string; AMax: Integer): string;
var
  N : Integer;
begin
  if Length(S) <= AMax then Exit(S);
  N := AMax;
  while (N > 0) and (Byte(S[N + 1]) >= $80) and (Byte(S[N + 1]) <= $BF) do
    Dec(N);
  Result := Copy(S, 1, N) + '...';
end;

{ ── Canonical JSON and redaction ─────────────────────────────────────────── }

function SensitiveName(const AName: string): Boolean;
var
  L : string;
begin
  L := LowerCase(AName);
  Result := (Pos('token', L) > 0) or (Pos('password', L) > 0) or
            (Pos('secret', L) > 0) or (Pos('authorization', L) > 0) or
            (Pos('key', L) > 0);
end;

{ A URL without its user-info, and with the values of sensitive query
  parameters removed.  Anything that is not a URL comes back unchanged. }
function RedactUrl(const S: string): string;
var
  P, AuthEnd, At, Q, H, I, E : Integer;
  Head, Rest, Query, Frag, Part, Name : string;
  Parts : TStringList;
begin
  Result := S;
  P := Pos('://', S);
  if (P < 2) or (P > 12) then Exit;
  Head := Copy(S, 1, P + 2);
  Rest := Copy(S, P + 3, MaxInt);
  { user-info: up to the last @ of the authority }
  AuthEnd := Length(Rest) + 1;
  for I := 1 to Length(Rest) do
    if Rest[I] in ['/', '?', '#'] then begin AuthEnd := I; Break; end;
  At := 0;
  for I := 1 to AuthEnd - 1 do
    if Rest[I] = '@' then At := I;
  if At > 0 then Delete(Rest, 1, At);
  { query values }
  Q := Pos('?', Rest);
  if Q > 0 then
  begin
    Frag := '';
    H := Pos('#', Rest);
    if (H > 0) and (H > Q) then
    begin
      Frag := Copy(Rest, H, MaxInt);
      E := H - 1;
    end
    else
      E := Length(Rest);
    Query := Copy(Rest, Q + 1, E - Q);
    Parts := TStringList.Create;
    try
      Parts.Delimiter := '&';
      Parts.StrictDelimiter := True;
      Parts.DelimitedText := Query;
      for I := 0 to Parts.Count - 1 do
      begin
        Part := Parts[I];
        P := Pos('=', Part);
        if P > 0 then
        begin
          Name := Copy(Part, 1, P - 1);
          if SensitiveName(Name) then Parts[I] := Name + '=' + REDACTED;
        end;
      end;
      Query := Parts.DelimitedText;
    finally
      Parts.Free;
    end;
    Rest := Copy(Rest, 1, Q) + Query + Frag;
  end;
  Result := Head + Rest;
end;

function FloatText(F: Double): string;
var
  FS : TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := FloatToStrF(F, ffGeneral, 15, 0, FS);
  if StrToFloat(Result, FS) <> F then
    Result := FloatToStrF(F, ffGeneral, 17, 0, FS);
end;

{ Indexes of the members of AObj, ordered by name (stable for equal names). }
procedure SortedMembers(AObj: TJSONObject; out AOrder: array of Integer);
var
  I, J, T : Integer;
begin
  for I := 0 to AObj.Count - 1 do AOrder[I] := I;
  for I := 1 to AObj.Count - 1 do
  begin
    T := AOrder[I];
    J := I - 1;
    while (J >= 0) and (CompareStr(AObj.Names[AOrder[J]], AObj.Names[T]) > 0) do
    begin
      AOrder[J + 1] := AOrder[J];
      Dec(J);
    end;
    AOrder[J + 1] := T;
  end;
end;

function McpCanonicalJson(AData: TJSONData): string;
var
  I     : Integer;
  Order : array of Integer;
  Obj   : TJSONObject;
begin
  if AData = nil then Exit('null');
  case AData.JSONType of
    jtObject:
      begin
        Obj := TJSONObject(AData);
        SetLength(Order, Obj.Count);
        if Obj.Count > 0 then SortedMembers(Obj, Order);
        Result := '{';
        for I := 0 to Obj.Count - 1 do
        begin
          if I > 0 then Result := Result + ',';
          Result := Result + JsonStr(Obj.Names[Order[I]]) + ':';
          if SensitiveName(Obj.Names[Order[I]]) then
            Result := Result + JsonStr(REDACTED)
          else
            Result := Result + McpCanonicalJson(Obj.Items[Order[I]]);
        end;
        Result := Result + '}';
      end;
    jtArray:
      begin
        Result := '[';
        for I := 0 to AData.Count - 1 do
        begin
          if I > 0 then Result := Result + ',';
          Result := Result + McpCanonicalJson(AData.Items[I]);
        end;
        Result := Result + ']';
      end;
    jtString:  Result := JsonStr(RedactUrl(AData.AsString));
    jtBoolean: if AData.AsBoolean then Result := 'true' else Result := 'false';
    jtNull:    Result := 'null';
    jtNumber:
      case TJSONNumber(AData).NumberType of
        ntInteger, ntInt64: Result := IntToStr(AData.AsInt64);
        ntQWord:            Result := IntToStr(AData.AsQWord);
      else
        Result := FloatText(AData.AsFloat);
      end;
  else
    Result := 'null';
  end;
end;

function McpArgsPrint(AArgs: TJSONObject): TMcpArgsPrint;
var
  Order : array of Integer;
  I     : Integer;
  Canon : string;
begin
  Result.Keys := nil;
  if (AArgs = nil) or (AArgs.Count = 0) then
    Canon := '{}'
  else
  begin
    SetLength(Order, AArgs.Count);
    SortedMembers(AArgs, Order);
    SetLength(Result.Keys, AArgs.Count);
    for I := 0 to AArgs.Count - 1 do
      Result.Keys[I] := AArgs.Names[Order[I]];
    Canon := McpCanonicalJson(AArgs);
  end;
  Result.Hash := Copy(LowerCase(SHA1Print(SHA1String(Canon))), 1, 12);
end;

{ ── The file ─────────────────────────────────────────────────────────────── }

function FileSizeOf(const AName: string): Int64;
var
  SR : TSearchRec;
begin
  Result := 0;
  if FindFirst(AName, faAnyFile, SR) = 0 then
  begin
    Result := SR.Size;
    FindClose(SR);
  end;
end;

procedure RotateLocked;
begin
  SysUtils.DeleteFile(GPath + '.3');
  RenameFile(GPath + '.2', GPath + '.3');
  RenameFile(GPath + '.1', GPath + '.2');
  RenameFile(GPath, GPath + '.1');
  GSize := 0;
end;

{ Appends one line; True when it was written. }
function AppendLocked(const ALine: string): Boolean;
var
  H    : THandle;
  Text : string;
begin
  Result := False;
  Text := ALine + LineEnding;
  try
    if GSize < 0 then
      if FileExists(GPath) then GSize := FileSizeOf(GPath) else GSize := 0;
    if (GSize > 0) and (GSize + Length(Text) > GMax) then RotateLocked;
    if FileExists(GPath) then
      H := FileOpen(GPath, fmOpenWrite or fmShareDenyNone)
    else
      H := FileCreate(GPath);
    if H = feInvalidHandle then Exit;
    try
      FileSeek(H, 0, fsFromEnd);
      Result := FileWrite(H, Text[1], Length(Text)) = Length(Text);
    finally
      FileClose(H);
    end;
    if Result then Inc(GSize, Length(Text));
  except
    Result := False;
  end;
end;

procedure WriteLine(const ALine: string);
var
  JustFailed : Boolean;
begin
  JustFailed := False;
  GLock.Enter;
  try
    if (GPath = '') or not GEnabled or GFailed then Exit;
    if AppendLocked(ALine) then
      GFailures := 0
    else
    begin
      Inc(GFailures);
      if GFailures >= MCP_TOOL_LOG_FAILURES then
      begin
        GFailed := True;
        JustFailed := True;
      end;
    end;
  finally
    GLock.Leave;
  end;
  if JustFailed then
    McpLogSession(MCP_TOOL_LOG_NAME + ': switched off after ' +
                  IntToStr(MCP_TOOL_LOG_FAILURES) + ' failed writes in a row');
end;

{ GLock held }
procedure UpdatePath;
begin
  if GFile <> '' then
    GPath := GFile
  else if GDir <> '' then
    GPath := IncludeTrailingPathDelimiter(GDir) + MCP_TOOL_LOG_NAME
  else
    GPath := '';
  GSize := -1;
end;

procedure McpToolLogSetDir(const ADir: string);
begin
  if ADir = '' then Exit;
  GLock.Enter;
  try
    GDir := ADir;
    UpdatePath;
  finally
    GLock.Leave;
  end;
end;

procedure McpToolLogSetFile(const AFile: string);
begin
  GLock.Enter;
  try
    GFile := Trim(AFile);
    UpdatePath;
  finally
    GLock.Leave;
  end;
end;

procedure McpToolLogSetEnabled(AEnabled: Boolean);
begin
  GLock.Enter;
  try
    GEnabled := AEnabled;
    if AEnabled then
    begin
      GFailed   := False;
      GFailures := 0;
    end;
  finally
    GLock.Leave;
  end;
end;

function McpToolLogEnabled: Boolean;
begin
  GLock.Enter;
  try
    Result := GEnabled and not GFailed and (GPath <> '');
  finally
    GLock.Leave;
  end;
end;

function McpToolLogPath: string;
begin
  GLock.Enter;
  try
    Result := GPath;
  finally
    GLock.Leave;
  end;
end;

procedure McpToolLogSetMaxBytes(ABytes: Int64);
begin
  GLock.Enter;
  try
    GMax := ABytes;
  finally
    GLock.Leave;
  end;
end;

procedure McpToolLogSetProject(const AName: string);
begin
  GLock.Enter;
  try
    GProject := AName;
  finally
    GLock.Leave;
  end;
end;

{ ── Records ──────────────────────────────────────────────────────────────── }

function Stamp: string;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz"Z"', LocalTimeToUniversal(Now));
end;

function UtcOffsetText: string;
var
  Minutes : Integer;
  Sign    : string;
begin
  Minutes := Round((Now - LocalTimeToUniversal(Now)) * 1440);
  if Minutes < 0 then Sign := '-' else Sign := '+';
  Minutes := Abs(Minutes);
  Result := Sign + Format('%.2d:%.2d', [Minutes div 60, Minutes mod 60]);
end;

function CallerJson(const C: TMcpLogCaller): string;
begin
  Result := '{';
  if C.Client <> '' then Result := Result + '"client":' + JsonStr(C.Client) + ',';
  if C.Token <> '' then Result := Result + '"token":' + JsonStr(C.Token) + ',';
  if C.Session <> '' then Result := Result + '"session":' + JsonStr(C.Session) + ',';
  if Result[Length(Result)] = ',' then SetLength(Result, Length(Result) - 1);
  Result := Result + '}';
end;

procedure McpToolLogStart(const APlugin, ALazarus, AFpc, AOS: string);
begin
  if not McpToolLogEnabled then Exit;
  WriteLine('{"event":"start","timestamp":"' + Stamp + '","plugin":' + JsonStr(APlugin) +
    ',"log_format":' + IntToStr(MCP_TOOL_LOG_FORMAT) + ',"lazarus":' + JsonStr(ALazarus) +
    ',"fpc":' + JsonStr(AFpc) + ',"os":' + JsonStr(AOS) +
    ',"utc_offset":"' + UtcOffsetText + '"}');
end;

procedure McpToolLogSession(const ACaller: TMcpLogCaller;
  const AProtocol, AAsked: string);
begin
  if not McpToolLogEnabled then Exit;
  WriteLine('{"event":"session","timestamp":"' + Stamp + '","caller":' +
    CallerJson(ACaller) + ',"protocol":' + JsonStr(AProtocol) +
    ',"protocol_asked":' + JsonStr(AAsked) + '}');
end;

function McpToolLogBegin(const ATool: string; const ACaller: TMcpLogCaller): LongInt;
begin
  Result := 0;
  if not McpToolLogEnabled then Exit;
  Result := InterlockedIncrement(GSeq);
  WriteLine('{"event":"begin","timestamp":"' + Stamp + '","seq_id":' + IntToStr(Result) +
    ',"caller":' + CallerJson(ACaller) + ',"tool":' + JsonStr(ATool) + '}');
end;

procedure McpToolLogEnd(ASeq: LongInt; const ATool: string;
  const ACaller: TMcpLogCaller; ADurationMs: Int64; ASuccess: Boolean;
  const AError: string; const APrint: TMcpArgsPrint);
var
  Line, Proj, Resp : string;
  I : Integer;
begin
  if ASeq = 0 then Exit;
  GLock.Enter;
  try
    Proj := GProject;
  finally
    GLock.Leave;
  end;
  if ASuccess then Resp := '{"success":true}'
  else
  begin
    Resp := '{"success":false';
    if AError <> '' then
      Resp := Resp + ',"error":' + JsonStr(CutText(AError, MCP_TOOL_LOG_MAX_ERR));
    Resp := Resp + '}';
  end;
  Line := '{"event":"end","timestamp":"' + Stamp + '","seq_id":' + IntToStr(ASeq) +
    ',"caller":' + CallerJson(ACaller) + ',"tool":' + JsonStr(ATool) +
    ',"duration_ms":' + IntToStr(ADurationMs) + ',"response":' + Resp +
    ',"project":' + JsonStr(Proj) + ',"arg_keys":[';
  for I := 0 to High(APrint.Keys) do
  begin
    if I > 0 then Line := Line + ',';
    Line := Line + JsonStr(APrint.Keys[I]);
  end;
  Line := Line + '],"args_hash":' + JsonStr(APrint.Hash) + '}';
  WriteLine(Line);
end;

function McpToolPaneLine(const ATool: string; ADurationMs: Int64; ASuccess: Boolean;
  const AError: string): string;
var
  Err : string;
  I   : Integer;
begin
  Result := ATool + '  ' + IntToStr(ADurationMs) + ' ms';
  if ASuccess then Exit;
  Err := '';
  for I := 1 to Length(AError) do
    if AError[I] in [#9, #10, #13] then
    begin
      { a line break or a tab is one space, however many in a row }
      if (Err = '') or (Err[Length(Err)] <> ' ') then Err := Err + ' ';
    end
    else
      Err := Err + AError[I];
  Result := Result + '  failed';
  if Trim(Err) <> '' then
    Result := Result + ': ' + CutText(Trim(Err), MCP_TOOL_PANE_ERR);
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  GLock.Free;

end.
