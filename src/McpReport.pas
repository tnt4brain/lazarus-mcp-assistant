{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpReport;

{ The report bundle (ADR-022, Amendment 1): versions, settings, packages and the
  tails of the logs in one Markdown file, for pasting into a bug report.  This
  unit only puts text together and writes it; what goes in is gathered by the
  server.  Plain LazUtils, no IDE units. }

{$mode objfpc}{$H+}

interface

const
  MCP_REPORT_MAX_BYTES = 256 * 1024;   { the whole file }
  MCP_REPORT_LOG_LINES = 200;          { per log }
  MCP_REPORT_KEEP      = 3;            { newest report files kept }
  MCP_REPORT_PREFIX    = 'mcp-report-';

type
  TMcpReportPart = record
    Title  : string;
    Body   : string;
    Fenced : Boolean;   { shown as code }
    Shrink : Boolean;   { earliest lines go first when the report is too big }
  end;
  TMcpReportParts = array of TMcpReportPart;

  { Writes a report and says where; the server sets it (the tool ide_report is
    registered in a unit that cannot use the server). }
  TMcpReportWriter = function(out APath, AErr: string): Boolean;

var
  McpReportWriter : TMcpReportWriter = nil;

function McpReportPart(const ATitle, ABody: string; AFenced, AShrink: Boolean): TMcpReportPart;

{ The last N lines of AText (a closing line break is not a line). }
function McpTailLines(const AText: string; N: Integer): string;

{ The last N lines of a file; reads at most the last megabyte.  ANote is ''
  or says why there is no text (absent, unreadable). }
function McpReadTail(const AFile: string; N: Integer; out ANote: string): string;

{ AHome, in the forms a path takes in text (plain, with / and JSON-escaped), becomes ~. }
function McpRedactHome(const AText, AHome: string): string;

{ The report: a heading, the parts in order, earliest lines of shrinkable parts cut
  until the text is no longer than AMaxBytes (what is cut is counted in the part). }
function McpComposeReport(const AParts: TMcpReportParts; const AStamp: string;
  AMaxBytes: Integer): string;

{ mcp-report-<UTC time>.md (milliseconds included, so names sort by time). }
function McpReportFileName(AUtc: TDateTime): string;

{ Writes AText to a new file in ADir (never over another) and removes the older
  reports beyond MCP_REPORT_KEEP.  False with AErr on failure. }
function McpWriteReportFile(const ADir, AText: string; AUtc: TDateTime;
  out APath, AErr: string): Boolean;

implementation

uses
  Classes, SysUtils, Math;

function McpReportPart(const ATitle, ABody: string; AFenced, AShrink: Boolean): TMcpReportPart;
begin
  Result.Title  := ATitle;
  Result.Body   := ABody;
  Result.Fenced := AFenced;
  Result.Shrink := AShrink;
end;

function SplitLines(const AText: string): TStringList;
var
  I, Start : Integer;
  Line     : string;
begin
  Result := TStringList.Create;
  Start := 1;
  for I := 1 to Length(AText) + 1 do
    if (I > Length(AText)) or (AText[I] = #10) then
    begin
      if (I > Length(AText)) and (Start > Length(AText)) then Break;  { closing break }
      Line := Copy(AText, Start, I - Start);
      if (Line <> '') and (Line[Length(Line)] = #13) then
        SetLength(Line, Length(Line) - 1);
      Result.Add(Line);
      Start := I + 1;
    end;
end;

function McpTailLines(const AText: string; N: Integer): string;
var
  L : TStringList;
  I : Integer;
begin
  Result := '';
  if N <= 0 then Exit;
  L := SplitLines(AText);
  try
    for I := Max(0, L.Count - N) to L.Count - 1 do
      Result := Result + L[I] + LineEnding;
  finally
    L.Free;
  end;
end;

function McpReadTail(const AFile: string; N: Integer; out ANote: string): string;
const
  MAX_READ = 1024 * 1024;
var
  S      : TFileStream;
  Size   : Int64;
  Buf    : string;
  Cut    : Integer;
begin
  Result := '';
  ANote  := '';
  if not FileExists(AFile) then
  begin
    ANote := 'not present';
    Exit;
  end;
  try
    S := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
    try
      Size := S.Size;
      if Size > MAX_READ then S.Position := Size - MAX_READ;
      SetLength(Buf, S.Size - S.Position);
      if Length(Buf) > 0 then S.ReadBuffer(Buf[1], Length(Buf));
      if Size > MAX_READ then
      begin
        Cut := Pos(#10, Buf);          { the first line is partial }
        if Cut > 0 then Delete(Buf, 1, Cut);
      end;
    finally
      S.Free;
    end;
  except
    on E: Exception do
    begin
      ANote := 'unreadable: ' + E.Message;
      Exit;
    end;
  end;
  Result := McpTailLines(Buf, N);
  if Result = '' then ANote := 'empty';
end;

function McpRedactHome(const AText, AHome: string): string;
var
  H, Fwd, Esc, Esc4 : string;
begin
  Result := AText;
  H := AHome;
  while (Length(H) > 0) and (H[Length(H)] in ['\', '/']) do
    SetLength(H, Length(H) - 1);
  if Length(H) < 3 then Exit;          { a bare drive or root would eat every path }
  Esc4 := StringReplace(H, '\', '\\\\', [rfReplaceAll]);   { JSON inside a JSON string }
  Esc := StringReplace(H, '\', '\\', [rfReplaceAll]);
  Fwd := StringReplace(H, '\', '/', [rfReplaceAll]);
  Result := StringReplace(Result, Esc4, '~', [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, Esc, '~', [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, H,   '~', [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, Fwd, '~', [rfReplaceAll, rfIgnoreCase]);
end;

function Assemble(const AParts: TMcpReportParts; const ABodies: array of TStringList;
  const ACut: array of Integer; const AStamp: string): string;
var
  I, J : Integer;
  Body : string;
begin
  Result := '# MCP Assistant report' + LineEnding + LineEnding +
    AStamp + LineEnding + LineEnding +
    'Read this before you post it: paths and error texts can hold names.' +
    LineEnding;
  for I := 0 to High(AParts) do
  begin
    Result := Result + LineEnding + '## ' + AParts[I].Title + LineEnding + LineEnding;
    if ACut[I] > 0 then
      Result := Result + '(' + IntToStr(ACut[I]) + ' earlier lines cut to fit)' +
        LineEnding + LineEnding;
    Body := '';
    for J := 0 to ABodies[I].Count - 1 do
      Body := Body + ABodies[I][J] + LineEnding;
    if AParts[I].Fenced then
    begin
      Body := StringReplace(Body, '````', '```', [rfReplaceAll]);
      Result := Result + '````' + LineEnding + Body + '````' + LineEnding;
    end
    else
      Result := Result + Body;
  end;
end;

function McpComposeReport(const AParts: TMcpReportParts; const AStamp: string;
  AMaxBytes: Integer): string;
var
  Bodies : array of TStringList;
  Cut    : array of Integer;
  I, Big, BigCount, Drop : Integer;
begin
  SetLength(Bodies, Length(AParts));
  SetLength(Cut, Length(AParts));
  for I := 0 to High(AParts) do
  begin
    Bodies[I] := SplitLines(AParts[I].Body);
    Cut[I] := 0;
  end;
  try
    Result := Assemble(AParts, Bodies, Cut, AStamp);
    while Length(Result) > AMaxBytes do
    begin
      Big := -1;
      BigCount := 1;                   { a part of one line is left alone }
      for I := 0 to High(AParts) do
        if AParts[I].Shrink and (Bodies[I].Count > BigCount) then
        begin
          Big := I;
          BigCount := Bodies[I].Count;
        end;
      if Big < 0 then Break;
      Drop := (Bodies[Big].Count + 3) div 4;
      if Drop >= Bodies[Big].Count then Drop := Bodies[Big].Count - 1;
      for I := 1 to Drop do Bodies[Big].Delete(0);
      Inc(Cut[Big], Drop);
      Result := Assemble(AParts, Bodies, Cut, AStamp);
    end;
    if Length(Result) > AMaxBytes then   { what cannot shrink }
      Result := Copy(Result, 1, AMaxBytes) + LineEnding + '(cut at the size limit)' + LineEnding;
  finally
    for I := 0 to High(Bodies) do Bodies[I].Free;
  end;
end;

function McpReportFileName(AUtc: TDateTime): string;
begin
  Result := MCP_REPORT_PREFIX + FormatDateTime('yyyymmdd"T"hhnnsszzz"Z"', AUtc) + '.md';
end;

procedure PruneReports(const ADir: string);
var
  SR    : TSearchRec;
  Names : TStringList;
  I     : Integer;
begin
  Names := TStringList.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(ADir) + MCP_REPORT_PREFIX + '*.md', faAnyFile, SR) = 0 then
    begin
      repeat
        Names.Add(SR.Name);
      until FindNext(SR) <> 0;
      FindClose(SR);
    end;
    Names.Sort;                        { oldest first: the name is the time }
    for I := 0 to Names.Count - MCP_REPORT_KEEP - 1 do
      DeleteFile(IncludeTrailingPathDelimiter(ADir) + Names[I]);
  finally
    Names.Free;
  end;
end;

function McpWriteReportFile(const ADir, AText: string; AUtc: TDateTime;
  out APath, AErr: string): Boolean;
var
  S    : TFileStream;
  T    : TDateTime;
  Tries: Integer;
begin
  Result := False;
  APath  := '';
  AErr   := '';
  try
    T := AUtc;
    for Tries := 1 to 50 do
    begin
      APath := IncludeTrailingPathDelimiter(ADir) + McpReportFileName(T);
      if not FileExists(APath) then Break;
      T := T + 1 / 86400000;           { next millisecond: never over another report }
    end;
    S := TFileStream.Create(APath, fmCreate);
    try
      if AText <> '' then S.WriteBuffer(AText[1], Length(AText));
    finally
      S.Free;
    end;
    PruneReports(ADir);
    Result := True;
  except
    on E: Exception do
      AErr := E.Message;
  end;
end;

end.
