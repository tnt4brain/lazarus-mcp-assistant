{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolHelpers;

{ Standalone helper functions used by tool dispatch groups and HandleToolsCall.
  None of these touch the IDE main thread — they are safe to call from the
  server thread without Synchronize. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, LazFileUtils, FileUtil, Process, fpjson, jsonparser;

{ Read the interface section of a Pascal unit (everything above 'implementation'). }
function McpGetUnitInterface(const FilePath: string; out IsError: Boolean): string;

{ Run lazbuild on a .lpk or .lpi and return filtered compiler output. }
function McpRunLazbuild(const LpkPath: string; out IsError: Boolean): string;

{ Compile and run the FPCUnit test project at ResolvedLpi (must be non-empty
  and fully resolved by the caller). }
function McpRunTests(const ResolvedLpi, JUnitOut: string;
  out IsError: Boolean): string;

{ Search all files listed in FileListJSON (JSON array of paths) for Query. }
function McpDoSearchInProject(const FileListJSON, Query: string): string;

{ TODO/FIXME/DONE comments in the given files, as a JSON array. }
function McpDoListTodos(const FileListJSON: string; AIncludeDone: Boolean): string;

{ Convert a 1-based byte offset in S to 1-based (ALine, ACol). }
procedure McpOffsetToLineCol(const S: string; Offset: Integer;
                             out ALine, ACol: Integer);

implementation

{ ── Unit interface extractor ─────────────────────────────────────────────── }

function McpGetUnitInterface(const FilePath: string; out IsError: Boolean): string;
var
  Lines : TStringList;
  I     : Integer;
  ULine : string;
begin
  IsError := False;
  if not FileExists(FilePath) then
  begin
    IsError := True;
    Result  := 'Error: file not found: ' + FilePath;
    Exit;
  end;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(FilePath);
      for I := 0 to Lines.Count - 1 do
      begin
        ULine := Trim(LowerCase(Lines[I]));
        if (ULine = 'implementation') or
           (Copy(ULine, 1, 15) = 'implementation ') or
           (Copy(ULine, 1, 15) = 'implementation{') then
        begin
          while Lines.Count > I do
            Lines.Delete(Lines.Count - 1);
          Result := Lines.Text;
          Exit;
        end;
      end;
      Result := Lines.Text; // no implementation keyword — return everything
    except
      on E: Exception do
      begin
        IsError := True;
        Result  := 'Error reading file: ' + E.Message;
      end;
    end;
  finally
    Lines.Free;
  end;
end;

{ ── lazbuild output filter ───────────────────────────────────────────────── }

{ On success: keep only Error/Warning/Hint lines + the "N lines compiled" summary.
  On failure: return everything so the full error context is visible. }
function FilterLazbuildOutput(const Raw: string; IsError: Boolean): string;
var
  Lines : TStringList;
  I     : Integer;
  Line  : string;
begin
  if Raw = '' then begin Result := '(no output)'; Exit; end;
  if IsError then begin Result := Raw; Exit; end;
  Lines := TStringList.Create;
  try
    Lines.Text := Raw;
    Result := '';
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      if (Pos(') Error:',   Line) > 0) or
         (Pos(') Warning:', Line) > 0) or
         (Pos(') Hint:',    Line) > 0) or
         (Pos('lines compiled', Line) > 0) then
        Result := Result + Line + LineEnding;
    end;
    if Result = '' then Result := '(compiled clean, no diagnostics)';
  finally
    Lines.Free;
  end;
end;

{ ── lazbuild runner ──────────────────────────────────────────────────────── }

{ lazbuild next to the running IDE, else on PATH.  A Linux IDE rebuilt by the
  user runs from ~/.lazarus/bin, which has no lazbuild. }
function LazbuildPath: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
            'lazbuild' + GetExeExt;
  if not FileExists(Result) and (FindDefaultExecutablePath('lazbuild') <> '') then
    Result := FindDefaultExecutablePath('lazbuild');
end;

function McpRunLazbuild(const LpkPath: string; out IsError: Boolean): string;
var
  LazbuildExe : string;
  Proc        : TProcess;
  Chunk       : string = '';
  BytesRead   : LongInt;
const
  BufSize = 4096;
begin
  IsError := False;
  LazbuildExe := LazbuildPath;
  if not FileExists(LazbuildExe) then
  begin
    IsError := True;
    Result  := 'lazbuild not found at: ' + LazbuildExe;
    Exit;
  end;

  Result := '';
  Proc   := TProcess.Create(nil);
  try
    Proc.Executable := LazbuildExe;
    Proc.Parameters.Add(LpkPath);
    Proc.Options    := [poUsePipes, poStdErrToOutput];
    Proc.Execute;
    repeat
      SetLength(Chunk, BufSize);
      BytesRead := Proc.Output.Read(Chunk[1], BufSize);
      if BytesRead > 0 then
      begin
        SetLength(Chunk, BytesRead);
        Result := Result + Chunk;
      end;
    until (BytesRead = 0) and not Proc.Running;
    Proc.WaitOnExit;
    IsError := Proc.ExitCode <> 0;
    Result  := FilterLazbuildOutput(Result, IsError);
  finally
    Proc.Free;
  end;
end;

{ ── FPCUnit summary parser ───────────────────────────────────────────────── }

{ Parse the FPCUnit plain-text summary line:
    Time:HH.SSS N:X E:X F:X I:X
  Returns True if the line was found; fills out-params. }
function ParseFPCUnitSummary(const Output: string;
  out Total, Errors, Failures, Ignored: Integer): Boolean;
var
  Lines : TStringList;
  I     : Integer;
  Line  : string;

  function ReadInt(const S, Key: string): Integer;
  var
    K, E : Integer;
  begin
    K := Pos(Key, S);
    if K = 0 then begin Result := -1; Exit; end;
    Inc(K, Length(Key));
    E := K;
    while (E <= Length(S)) and (S[E] in ['0'..'9']) do Inc(E);
    Result := StrToIntDef(Copy(S, K, E - K), -1);
  end;

begin
  Result   := False;
  Total    := 0;
  Errors   := 0;
  Failures := 0;
  Ignored  := 0;
  Lines    := TStringList.Create;
  try
    Lines.Text := Output;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      if (Pos(' N:', Line) > 0) and (Pos(' E:', Line) > 0) and
         (Pos(' F:', Line) > 0) and (Pos(' I:', Line) > 0) then
      begin
        Total    := ReadInt(Line, 'N:');
        Errors   := ReadInt(Line, 'E:');
        Failures := ReadInt(Line, 'F:');
        Ignored  := ReadInt(Line, 'I:');
        Result := (Total >= 0);
        if Result then Exit;
      end;
    end;
  finally
    Lines.Free;
  end;
end;

{ ── Test runner ──────────────────────────────────────────────────────────── }

function McpRunTests(const ResolvedLpi, JUnitOut: string;
  out IsError: Boolean): string;
var
  LazbuildExe : string;
  TestExe     : string;
  BuildOut    : string;
  RunOut      : string;
  Proc        : TProcess;
  Chunk       : string = '';
  BytesRead   : LongInt;
  Total, Errors, Failures, Ignored : Integer;
  Parsed      : Boolean;
  Obj         : TJSONObject;
const
  BufSize = 4096;
begin
  IsError := False;
  LazbuildExe := LazbuildPath;
  if not FileExists(LazbuildExe) then
  begin
    IsError := True;
    Result  := 'lazbuild not found at: ' + LazbuildExe;
    Exit;
  end;

  if not FileExists(ResolvedLpi) then
  begin
    IsError := True;
    Result  := 'Test project not found: ' + ResolvedLpi;
    Exit;
  end;

  // Step 1: compile.
  BuildOut := '';
  Proc     := TProcess.Create(nil);
  try
    Proc.Executable := LazbuildExe;
    Proc.Parameters.Add(ResolvedLpi);
    Proc.Options := [poUsePipes, poStdErrToOutput];
    Proc.Execute;
    repeat
      SetLength(Chunk, BufSize);
      BytesRead := Proc.Output.Read(Chunk[1], BufSize);
      if BytesRead > 0 then begin SetLength(Chunk, BytesRead); BuildOut := BuildOut + Chunk; end;
    until (BytesRead = 0) and not Proc.Running;
    Proc.WaitOnExit;
    IsError := Proc.ExitCode <> 0;
  finally
    Proc.Free;
  end;

  if IsError then
  begin
    Obj := TJSONObject.Create;
    try
      Obj.Add('compiled', False);
      Obj.Add('run',      False);
      Obj.Add('output',   BuildOut);
      Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
    Exit;
  end;

  // Step 2: run.
  TestExe := ChangeFileExt(ResolvedLpi, GetExeExt);
  if not FileExists(TestExe) then
    TestExe := ChangeFileExt(ResolvedLpi, '') + GetExeExt;

  if not FileExists(TestExe) then
  begin
    IsError := True;
    Obj := TJSONObject.Create;
    try
      Obj.Add('compiled', True);
      Obj.Add('run',      False);
      Obj.Add('output',   'Compiled but binary not found at: ' + TestExe);
      Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
    Exit;
  end;

  RunOut := '';
  Proc   := TProcess.Create(nil);
  try
    Proc.Executable := TestExe;
    Proc.Parameters.Add('--all');
    Proc.Parameters.Add('--format=plain');
    if JUnitOut <> '' then
      Proc.Parameters.Add('--junit-out=' + JUnitOut);
    Proc.Options := [poUsePipes, poStdErrToOutput];
    Proc.Execute;
    repeat
      SetLength(Chunk, BufSize);
      BytesRead := Proc.Output.Read(Chunk[1], BufSize);
      if BytesRead > 0 then begin SetLength(Chunk, BytesRead); RunOut := RunOut + Chunk; end;
    until (BytesRead = 0) and not Proc.Running;
    Proc.WaitOnExit;
    // Non-zero exit = test failures — not a tool error.
  finally
    Proc.Free;
  end;

  Parsed := ParseFPCUnitSummary(RunOut, Total, Errors, Failures, Ignored);

  Obj := TJSONObject.Create;
  try
    Obj.Add('compiled', True);
    Obj.Add('run',      True);
    if Parsed then
    begin
      Obj.Add('total',    Total);
      Obj.Add('errors',   Errors);
      Obj.Add('failures', Failures);
      Obj.Add('ignored',  Ignored);
      Obj.Add('passed',   (Errors = 0) and (Failures = 0));
    end;
    if JUnitOut <> '' then
      Obj.Add('junit_out', JUnitOut);
    Obj.Add('output', RunOut);
    Result := Obj.AsJSON;
  finally
    Obj.Free;
  end;
  IsError := False;
end;

{ ── Project-wide text search ─────────────────────────────────────────────── }

function McpDoSearchInProject(const FileListJSON, Query: string): string;
var
  FileList : TJSONArray;
  Results  : TJSONArray;
  Match    : TJSONObject;
  Lines    : TStringList;
  FilePath : string;
  Q        : string;
  I, J     : Integer;
begin
  if Query = '' then
    Exit('{"error":"query argument required"}');

  Q       := LowerCase(Query);
  Results := TJSONArray.Create;
  Lines   := TStringList.Create;
  try
    FileList := TJSONArray(GetJSON(FileListJSON));
    try
      for I := 0 to FileList.Count - 1 do
      begin
        FilePath := FileList.Strings[I];
        if not FileExists(FilePath) then Continue;
        try
          Lines.LoadFromFile(FilePath);
          for J := 0 to Lines.Count - 1 do
            if Pos(Q, LowerCase(Lines[J])) > 0 then
            begin
              Match := TJSONObject.Create;
              Match.Add('file', FilePath);
              Match.Add('line', J + 1);
              Match.Add('text', Trim(Lines[J]));
              Results.Add(Match);
            end;
        except
          // skip unreadable files
        end;
      end;
    finally
      FileList.Free;
    end;
    Result := Results.AsJSON;
  finally
    Lines.Free;
    Results.Free;
  end;
end;

{ ── ToDo list scanner ────────────────────────────────────────────────────── }

{ Same markers the IDE's ToDo List understands ({ TODO ...}, {#todo ...},
  { DONE ...}, {#done ...}) plus // TODO and FIXME comments. }
function McpDoListTodos(const FileListJSON: string; AIncludeDone: Boolean): string;
const
  Markers : array[0..9] of string = (
    '{ todo', '{todo', '{#todo', '{ #todo', '// todo', '//todo', '(* todo',
    'fixme', '{ done', '{#done');
var
  FileList : TJSONArray;
  Results  : TJSONArray;
  Item     : TJSONObject;
  Lines    : TStringList;
  FilePath : string;
  L        : string;
  Kind     : string;
  I, J, M  : Integer;
begin
  Results := TJSONArray.Create;
  Lines   := TStringList.Create;
  try
    FileList := TJSONArray(GetJSON(FileListJSON));
    try
      for I := 0 to FileList.Count - 1 do
      begin
        FilePath := FileList.Strings[I];
        if not FileExists(FilePath) then Continue;
        try
          Lines.LoadFromFile(FilePath);
        except
          Continue;  { skip unreadable files }
        end;
        for J := 0 to Lines.Count - 1 do
        begin
          L := LowerCase(Lines[J]);
          for M := Low(Markers) to High(Markers) do
            if Pos(Markers[M], L) > 0 then
            begin
              if M >= 8 then Kind := 'done'
              else if M = 7 then Kind := 'fixme'
              else Kind := 'todo';
              if (Kind = 'done') and not AIncludeDone then Break;
              Item := TJSONObject.Create;
              Item.Add('file', FilePath);
              Item.Add('line', J + 1);
              Item.Add('kind', Kind);
              Item.Add('text', Trim(Lines[J]));
              Results.Add(Item);
              Break;
            end;
        end;
      end;
    finally
      FileList.Free;
    end;
    Result := Results.AsJSON;
  finally
    Lines.Free;
    Results.Free;
  end;
end;

{ ── Offset-to-line/col helper ────────────────────────────────────────────── }

procedure McpOffsetToLineCol(const S: string; Offset: Integer;
                             out ALine, ACol: Integer);
var
  K : Integer;
begin
  ALine := 1;
  ACol  := 1;
  for K := 1 to Offset - 1 do
  begin
    if S[K] = #10 then begin Inc(ALine); ACol := 1; end
    else if S[K] <> #13 then Inc(ACol);
  end;
end;

end.
