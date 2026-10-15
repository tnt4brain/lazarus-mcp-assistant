{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsGit;

{ Git integration tools: git_status, git_diff, git_blame, git_log, git_add,
  git_commit, git_checkout, git_branches.
  All operations shell out to git (McpGitExecutable); work_dir defaults to the active
  project directory when not supplied by the caller. }

{$mode objfpc}{$H+}

interface

implementation

uses
  Classes, SysUtils, DateUtils, Math, Process, FileUtil, LazFileUtils,
  LazIDEIntf, SrcEditorIntf, CodeToolManager, CodeCache, LConvEncoding,
  fpjson,
  McpToolContext, McpIdeState, McpToolsCodeTools;

{ ── Schema constants ─────────────────────────────────────────────────────── }

const
  SCHEMA_GIT_STATUS =
    '{"type":"object","properties":{' +
    '"work_dir":{"type":"string","description":"Default: project directory"}},' +
    '"required":[]}';

  SCHEMA_GIT_DIFF =
    '{"type":"object","properties":{' +
    '"staged":{"type":"boolean","description":"Diff staged (index) changes instead of working-tree (default false)"},' +
    '"path":{"type":"string","description":"Limit diff to this file or directory"},' +
    '"active_file":{"type":"boolean","description":"Diff the active editor''s file, in its own repository (saved content only)"},' +
    '"work_dir":{"type":"string","description":"Default: project directory"}},' +
    '"required":[]}';

  SCHEMA_GIT_BLAME =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Default: the active editor''s file"},' +
    '"start_line":{"type":"integer","description":"Default: the cursor line of the active editor"},' +
    '"end_line":{"type":"integer","description":"Default: start_line; at most 200 lines"}}}';

  SCHEMA_GIT_LOG =
    '{"type":"object","properties":{' +
    '"max_count":{"type":"integer","description":"Maximum number of commits to show (default 20)"},' +
    '"branch":{"type":"string","description":"Branch or ref to log; defaults to HEAD"},' +
    '"work_dir":{"type":"string","description":"Default: project directory"}},' +
    '"required":[]}';

  SCHEMA_GIT_ADD =
    '{"type":"object","properties":{' +
    '"paths":{"type":"array","items":{"type":"string"},"description":"Files or directories to stage"},' +
    '"work_dir":{"type":"string","description":"Default: project directory"}},' +
    '"required":["paths"]}';

  SCHEMA_GIT_COMMIT =
    '{"type":"object","properties":{' +
    '"message":{"type":"string","description":"Commit message"},' +
    '"work_dir":{"type":"string","description":"Default: project directory"}},' +
    '"required":["message"]}';

  SCHEMA_GIT_CHECKOUT =
    '{"type":"object","properties":{' +
    '"target":{"type":"string","description":"Branch name, tag, commit hash, or file path to restore"},' +
    '"work_dir":{"type":"string","description":"Default: project directory"}},' +
    '"required":["target"]}';

  SCHEMA_GIT_BRANCHES =
    '{"type":"object","properties":{' +
    '"work_dir":{"type":"string","description":"Default: project directory"}},' +
    '"required":[]}';

  SCHEMA_GIT_STASH =
    '{"type":"object","properties":{' +
    '"message":{"type":"string","description":"Optional stash description"},' +
    '"work_dir":{"type":"string","description":"Default: project directory"}},' +
    '"required":[]}';

  SCHEMA_GIT_STASH_POP =
    '{"type":"object","properties":{' +
    '"index":{"type":"integer","description":"Stash index to pop (default 0 = most recent)"},' +
    '"work_dir":{"type":"string","description":"Default: project directory"}},' +
    '"required":[]}';

  SCHEMA_GIT_RESET =
    '{"type":"object","properties":{' +
    '"target":{"type":"string","description":"Ref or file to reset: e.g. HEAD, HEAD~1, a commit hash, or a file path"},' +
    '"mode":{"type":"string","enum":["mixed","soft"],"description":"mixed (default): unstage changes, keep working tree. soft: keep changes staged."},' +
    '"work_dir":{"type":"string","description":"Default: project directory"}},' +
    '"required":["target"]}';

{ ── Helpers ──────────────────────────────────────────────────────────────── }

{ AInput, if any, is written to git's standard input (git commit -F -): on
  Windows TProcess joins the arguments into one command line without escaping
  double quotes, so free text must not be an argument. }
function RunGit(const Args: array of string; const WorkDir: string;
  out Output: string; const AInput: string = ''): Boolean;
var
  GitExe    : string;
  Proc      : TProcess;
  Chunk     : string;
  BytesRead : LongInt;
  I         : Integer;
const
  BufSize = 4096;
begin
  GitExe := McpGitExecutable;
  if GitExe = '' then
  begin
    Output := 'git executable not found on PATH; the user can set its path in ' +
              'Tools > Options > MCP Assistant';
    Result := False;
    Exit;
  end;
  Output := '';
  Proc   := TProcess.Create(nil);
  try
    Proc.Executable := GitExe;
    for I := 0 to High(Args) do
      Proc.Parameters.Add(Args[I]);
    Proc.Options := [poUsePipes, poStdErrToOutput];
    if WorkDir <> '' then
      Proc.CurrentDirectory := WorkDir;
    Proc.Execute;
    if AInput <> '' then
      Proc.Input.Write(AInput[1], Length(AInput));
    Proc.CloseInput;
    Chunk := '';
    repeat
      SetLength(Chunk, BufSize);
      BytesRead := Proc.Output.Read(Chunk[1], BufSize);
      if BytesRead > 0 then
      begin
        SetLength(Chunk, BytesRead);
        Output := Output + Chunk;
      end;
    until (BytesRead = 0) and not Proc.Running;
    Proc.WaitOnExit;
    Result := Proc.ExitCode = 0;
  finally
    Proc.Free;
  end;
end;

function GetGitWorkDir(const Ctx: TMcpToolCall): string;
begin
  if Assigned(Ctx.Params) then
    Result := Ctx.Params.Get('work_dir', '')
  else
    Result := '';
  if (Result = '') and Assigned(LazarusIDE.ActiveProject) and
     (LazarusIDE.ActiveProject.ProjectInfoFile <> '') then
    Result := ExtractFilePath(LazarusIDE.ActiveProject.ProjectInfoFile);
end;

const
  BLAME_MAX_LINES = 200;

{ git blame --porcelain: per line "<sha> <orig> <final> [<count>]", the commit's
  headers the first time the sha appears, then TAB + the line text. }
{ Encoding of the file on disk as CodeTools detected it ('utf8', 'utf8bom',
  'cp1251', ...); '' for UTF-8 or unknown. Main thread. }
function FileEncoding(const AFileName: string): string;
var
  Code : TCodeBuffer;
begin
  Result := '';
  Code := CodeToolBoss.FindFile(AFileName);
  if Code = nil then
    Code := McpLoadCode(AFileName, True);
  if Assigned(Code) then
    Result := LowerCase(Code.DiskEncoding);
  if (Result = EncodingUTF8) or (Result = EncodingUTF8BOM) then
    Result := '';
end;

{ AEnc: the file's encoding when it isn't UTF-8; git prints line text as stored. }
function ParseBlame(const AOut, AEnc: string): TJSONArray;
var
  SL      : TStringList;
  Commits : TStringList;   { sha=index into Infos }
  Infos   : array of record Author, Date, Summary: string; end;
  Parts   : TStringArray;
  S, Sha  : string;
  I, Idx, FinalLine : Integer;
  LObj    : TJSONObject;
begin
  Result  := TJSONArray.Create;
  SL      := TStringList.Create;
  Commits := TStringList.Create;
  try
    SL.Text := AOut;
    Infos := nil;
    Idx := -1;
    FinalLine := 0;
    for I := 0 to SL.Count - 1 do
    begin
      S := SL[I];
      if S = '' then Continue;
      if S[1] = #9 then
      begin
        if Idx < 0 then Continue;
        LObj := TJSONObject.Create;
        Result.Add(LObj);
        LObj.Add('line', FinalLine);
        if StringOfChar('0', 40) = Commits.Names[Idx] then
          LObj.Add('commit', 'uncommitted')
        else
        begin
          LObj.Add('commit', Copy(Commits.Names[Idx], 1, 10));
          LObj.Add('author', Infos[Idx].Author);
          LObj.Add('date', Infos[Idx].Date);
          LObj.Add('summary', Infos[Idx].Summary);
        end;
        if AEnc <> '' then
          LObj.Add('text', ConvertEncoding(Copy(S, 2, MaxInt), AEnc, EncodingUTF8))
        else
          LObj.Add('text', Copy(S, 2, MaxInt));
        Continue;
      end;
      Parts := S.Split([' ']);
      if (Length(Parts) >= 3) and (Length(Parts[0]) = 40) then
      begin
        Sha := Parts[0];
        FinalLine := StrToIntDef(Parts[2], 0);
        Idx := Commits.IndexOfName(Sha);
        if Idx < 0 then
        begin
          Idx := Commits.Add(Sha + '=');
          SetLength(Infos, Commits.Count);
        end;
      end
      else if Idx >= 0 then
      begin
        if Parts[0] = 'author' then
          Infos[Idx].Author := Copy(S, 8, MaxInt)
        else if Parts[0] = 'author-time' then
          Infos[Idx].Date := FormatDateTime('yyyy-mm-dd hh:nn',
            UnixToDateTime(StrToInt64Def(Copy(S, 13, MaxInt), 0), False))
        else if Parts[0] = 'summary' then
          Infos[Idx].Summary := Copy(S, 9, MaxInt);
      end;
    end;
  finally
    Commits.Free;
    SL.Free;
  end;
end;

{ The line ending the file on disk uses (its first line break), and its UTF-8
  BOM if it has one: the editor's text has neither. }
function FileLineBreak(const AFileName: string; out ABom: string): string;
var
  FS  : TFileStream;
  Buf : string;
  P   : Integer;
begin
  Result := LineEnding;
  ABom   := '';
  try
    FS := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Buf, Min(FS.Size, 65536));
      if Buf <> '' then
        SetLength(Buf, FS.Read(Buf[1], Length(Buf)));
    finally
      FS.Free;
    end;
  except
    Exit;
  end;
  if Copy(Buf, 1, 3) = #$EF#$BB#$BF then
    ABom := #$EF#$BB#$BF;
  P := Pos(#10, Buf);
  if P > 1 then
    if Buf[P - 1] = #13 then Result := #13#10 else Result := #10
  else if P = 1 then
    Result := #10;
end;

{ git_blame on the main thread: file and line default to the active editor; an
  editor with unsaved changes is blamed as shown (--contents), so line numbers
  match what the user sees. }
procedure GitBlame(var Ctx: TMcpToolCall);
var
  FileName, TmpFile, Output : string;
  Ed        : TSourceEditorInterface;
  StartLine, EndLine : Integer;
  Modified, Ok : Boolean;
  GitArgs   : TStringList;
  SL        : TStringList;
  FS        : TFileStream;
  Bom, Data, Enc : string;
  Obj       : TJSONObject;
begin
  FileName  := '';
  StartLine := 0;
  EndLine   := 0;
  if Assigned(Ctx.Params) then
  begin
    FileName  := Ctx.Params.Get('file', '');
    StartLine := Ctx.Params.Get('start_line', 0);
    EndLine   := Ctx.Params.Get('end_line', 0);
  end;
  Ed := nil;
  if FileName = '' then
  begin
    Ed := SourceEditorManagerIntf.ActiveEditor;
    if not Assigned(Ed) then
    begin
      Ctx.Error := True; Ctx.Result := 'No file given and no editor is active'; Exit;
    end;
    FileName := Ed.FileName;
    if StartLine <= 0 then
      StartLine := Ed.CursorTextXY.Y;
  end
  else
    Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(FileName);
  if StartLine <= 0 then
  begin
    Ctx.Error := True; Ctx.Result := 'start_line required for a file that is not the active editor'; Exit;
  end;
  if EndLine < StartLine then EndLine := StartLine;
  if EndLine - StartLine >= BLAME_MAX_LINES then
    EndLine := StartLine + BLAME_MAX_LINES - 1;
  if not FilenameIsAbsolute(FileName) then
  begin
    Ctx.Error := True; Ctx.Result := 'Not a file on disk: ' + FileName; Exit;
  end;
  if Assigned(Ed) and (EndLine > Ed.Lines.Count) then
    EndLine := Ed.Lines.Count;
  Modified := Assigned(Ed) and Ed.Modified;
  Enc      := FileEncoding(FileName);
  TmpFile  := '';
  GitArgs  := TStringList.Create;
  try
    GitArgs.Add('blame');
    GitArgs.Add('--porcelain');
    GitArgs.Add('-L');
    GitArgs.Add(IntToStr(StartLine) + ',' + IntToStr(EndLine));
    if Modified then
    begin
      TmpFile := GetTempFileName('', 'mcpblame');
      { written as the file on disk is: same line breaks (else every line
        differs) and the same BOM (else line 1 does) }
      SL := TStringList.Create;
      try
        SL.Text := Ed.Lines.Text;
        SL.LineBreak := FileLineBreak(FileName, Bom);
        Data := SL.Text;
        if Enc <> '' then   { the editor holds UTF-8 }
          Data := ConvertEncoding(Data, EncodingUTF8, Enc);
        Data := Bom + Data;
      finally
        SL.Free;
      end;
      FS := TFileStream.Create(TmpFile, fmCreate);
      try
        if Data <> '' then
          FS.WriteBuffer(Data[1], Length(Data));
      finally
        FS.Free;
      end;
      GitArgs.Add('--contents');
      GitArgs.Add(TmpFile);
    end;
    GitArgs.Add('--');
    GitArgs.Add(FileName);
    Ok := RunGit(GitArgs.ToStringArray, ExtractFilePath(FileName), Output);
  finally
    GitArgs.Free;
    if TmpFile <> '' then DeleteFile(TmpFile);
  end;
  if not Ok then
  begin
    Ctx.Error := True; Ctx.Result := Trim(Output); Exit;
  end;
  Obj := TJSONObject.Create;
  try
    Obj.Add('file', FileName);
    if Modified then
      Obj.Add('editor_modified', True);   { blamed as shown in the editor }
    if Enc <> '' then
      Obj.Add('encoding', Enc);
    Obj.Add('lines', ParseBlame(Output, Enc));
    Ctx.Result := Obj.AsJSON;
  finally
    Obj.Free;
  end;
end;

{ ── Dispatch ─────────────────────────────────────────────────────────────── }

function DispatchGitTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  WorkDir   : string;
  Output    : string;
  Ok        : Boolean;
  Staged    : Boolean;
  DiffPath  : string;
  MaxCount  : Integer;
  Branch    : string;
  Target    : string;
  Message   : string;
  PathsJSON : TJSONData;
  PathsArr  : TJSONArray;
  Obj       : TJSONObject;
  GitArgs   : TStringList;
  ActiveEd  : TSourceEditorInterface;
  I         : Integer;
begin
  Result := False;

  if Name = 'git_blame' then
  begin
    Result := True;
    GitBlame(Ctx);
    Exit;
  end;

  if Name = 'git_status' then
  begin
    Result  := True;
    WorkDir := GetGitWorkDir(Ctx);
    Ok      := RunGit(['status', '--porcelain=v1'], WorkDir, Output);
    Obj     := TJSONObject.Create;
    try
      if Trim(Output) = '' then Output := '(working tree clean)';
      Obj.Add('output',   Output);
      Obj.Add('work_dir', WorkDir);
      if not Ok then Ctx.Error := True;
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'git_diff' then
  begin
    Result   := True;
    WorkDir  := GetGitWorkDir(Ctx);
    Staged   := Assigned(Ctx.Params) and Ctx.Params.Get('staged', False);
    DiffPath := '';
    if Assigned(Ctx.Params) then DiffPath := Ctx.Params.Get('path', '');
    ActiveEd := nil;
    if Assigned(Ctx.Params) and Ctx.Params.Get('active_file', False) then
    begin
      ActiveEd := SourceEditorManagerIntf.ActiveEditor;
      if not Assigned(ActiveEd) or not FilenameIsAbsolute(ActiveEd.FileName) then
      begin
        Ctx.Error := True; Ctx.Result := 'No active editor with a file on disk'; Exit;
      end;
      DiffPath := ActiveEd.FileName;
      WorkDir  := ExtractFilePath(DiffPath);   { the file's own repository }
    end;
    GitArgs  := TStringList.Create;
    try
      GitArgs.Add('diff');
      if Staged   then GitArgs.Add('--staged');
      if DiffPath <> '' then
      begin
        GitArgs.Add('--');
        GitArgs.Add(DiffPath);
      end;
      Ok := RunGit(GitArgs.ToStringArray, WorkDir, Output);
    finally
      GitArgs.Free;
    end;
    Obj := TJSONObject.Create;
    try
      if Trim(Output) = '' then Output := '(no diff)';
      Obj.Add('output',   Output);
      Obj.Add('work_dir', WorkDir);
      if Assigned(ActiveEd) then
      begin
        Obj.Add('file', DiffPath);
        if ActiveEd.Modified then
          Obj.Add('editor_modified', True);   { unsaved edits are not in the diff }
      end;
      if not Ok then Ctx.Error := True;
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'git_log' then
  begin
    Result   := True;
    WorkDir  := GetGitWorkDir(Ctx);
    MaxCount := 20;
    Branch   := '';
    if Assigned(Ctx.Params) then
    begin
      MaxCount := Ctx.Params.Get('max_count', 20);
      Branch   := Ctx.Params.Get('branch', '');
    end;
    GitArgs := TStringList.Create;
    try
      GitArgs.Add('log');
      GitArgs.Add('--oneline');
      GitArgs.Add('--max-count=' + IntToStr(MaxCount));
      if Branch <> '' then GitArgs.Add(Branch);
      Ok := RunGit(GitArgs.ToStringArray, WorkDir, Output);
    finally
      GitArgs.Free;
    end;
    Obj := TJSONObject.Create;
    try
      if Trim(Output) = '' then Output := '(no commits)';
      Obj.Add('output',   Output);
      Obj.Add('work_dir', WorkDir);
      if not Ok then Ctx.Error := True;
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'git_add' then
  begin
    Result  := True;
    WorkDir := GetGitWorkDir(Ctx);
    if not Assigned(Ctx.Params) then
    begin
      Ctx.Error  := True;
      Ctx.Result := 'paths required';
      Exit;
    end;
    PathsJSON := Ctx.Params.Find('paths');
    if not (PathsJSON is TJSONArray) then
    begin
      Ctx.Error  := True;
      Ctx.Result := 'paths must be a JSON array of strings';
      Exit;
    end;
    PathsArr := TJSONArray(PathsJSON);
    if PathsArr.Count = 0 then
    begin
      Ctx.Error  := True;
      Ctx.Result := 'paths array is empty';
      Exit;
    end;
    GitArgs := TStringList.Create;
    try
      GitArgs.Add('add');
      for I := 0 to PathsArr.Count - 1 do
        GitArgs.Add(PathsArr.Strings[I]);
      Ok := RunGit(GitArgs.ToStringArray, WorkDir, Output);
    finally
      GitArgs.Free;
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('output',   Output);
      Obj.Add('work_dir', WorkDir);
      if not Ok then Ctx.Error := True;
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'git_commit' then
  begin
    Result  := True;
    WorkDir := GetGitWorkDir(Ctx);
    Message := '';
    if Assigned(Ctx.Params) then Message := Ctx.Params.Get('message', '');
    if Message = '' then
    begin
      Ctx.Error  := True;
      Ctx.Result := 'message required';
      Exit;
    end;
    Ok := RunGit(['commit', '-F', '-'], WorkDir, Output, Message);
    Obj := TJSONObject.Create;
    try
      Obj.Add('output',   Output);
      Obj.Add('work_dir', WorkDir);
      if not Ok then Ctx.Error := True;
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'git_checkout' then
  begin
    Result  := True;
    WorkDir := GetGitWorkDir(Ctx);
    Target  := '';
    if Assigned(Ctx.Params) then Target := Ctx.Params.Get('target', '');
    if Target = '' then
    begin
      Ctx.Error  := True;
      Ctx.Result := 'target required';
      Exit;
    end;
    Ok := RunGit(['checkout', Target], WorkDir, Output);
    Obj := TJSONObject.Create;
    try
      Obj.Add('output',   Output);
      Obj.Add('work_dir', WorkDir);
      if not Ok then Ctx.Error := True;
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'git_branches' then
  begin
    Result  := True;
    WorkDir := GetGitWorkDir(Ctx);
    Ok := RunGit(['branch', '-a', '--format=%(HEAD) %(refname:short)'],
                 WorkDir, Output);
    Obj := TJSONObject.Create;
    try
      if Trim(Output) = '' then Output := '(no branches)';
      Obj.Add('output',   Output);
      Obj.Add('work_dir', WorkDir);
      if not Ok then Ctx.Error := True;
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'git_stash' then
  begin
    Result  := True;
    WorkDir := GetGitWorkDir(Ctx);
    Message := '';
    if Assigned(Ctx.Params) then Message := Ctx.Params.Get('message', '');
    GitArgs := TStringList.Create;
    try
      GitArgs.Add('stash');
      GitArgs.Add('push');
      if Message <> '' then
      begin
        GitArgs.Add('-m');
        GitArgs.Add(Message);
      end;
      Ok := RunGit(GitArgs.ToStringArray, WorkDir, Output);
    finally
      GitArgs.Free;
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('output',   Output);
      Obj.Add('work_dir', WorkDir);
      if not Ok then Ctx.Error := True;
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'git_stash_pop' then
  begin
    Result  := True;
    WorkDir := GetGitWorkDir(Ctx);
    I := 0;
    if Assigned(Ctx.Params) then I := Ctx.Params.Get('index', 0);
    Ok := RunGit(['stash', 'pop', 'stash@{' + IntToStr(I) + '}'],
                 WorkDir, Output);
    Obj := TJSONObject.Create;
    try
      Obj.Add('output',   Output);
      Obj.Add('work_dir', WorkDir);
      if not Ok then Ctx.Error := True;
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'git_reset' then
  begin
    Result  := True;
    WorkDir := GetGitWorkDir(Ctx);
    Target  := '';
    if Assigned(Ctx.Params) then Target := Ctx.Params.Get('target', '');
    if Target = '' then
    begin
      Ctx.Error  := True;
      Ctx.Result := 'target required';
      Exit;
    end;
    GitArgs := TStringList.Create;
    try
      GitArgs.Add('reset');
      if Assigned(Ctx.Params) and (Ctx.Params.Get('mode', 'mixed') = 'soft') then
        GitArgs.Add('--soft')
      else
        GitArgs.Add('--mixed');
      GitArgs.Add(Target);
      Ok := RunGit(GitArgs.ToStringArray, WorkDir, Output);
    finally
      GitArgs.Free;
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('output',   Output);
      Obj.Add('work_dir', WorkDir);
      if not Ok then Ctx.Error := True;
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end;
end;

{ ── Schema registration ──────────────────────────────────────────────────── }

procedure RegisterGitSchemas(Tools: TJSONArray);
begin
  Tools.Add(MakeTool('git_status',
    'Show the working tree status (--porcelain=v1). Returns a compact list of ' +
    'modified/staged/untracked files. work_dir defaults to the active project directory.',
    SCHEMA_GIT_STATUS, MCP_ANN_RO));
  Tools.Add(MakeTool('git_diff',
    'Show changes between the working tree and the index (or, with staged=true, ' +
    'between the index and HEAD). Optionally scoped to a path, or to the active ' +
    'editor''s file.',
    SCHEMA_GIT_DIFF, MCP_ANN_RO));
  Tools.Add(MakeTool('git_blame',
    'Who last changed lines, and in which commit: author, date, summary per line. ' +
    'Defaults to the active editor''s file and cursor line; unsaved edits count as uncommitted.',
    SCHEMA_GIT_BLAME, MCP_ANN_RO));
  Tools.Add(MakeTool('git_log',
    'Show recent commit history as one-line summaries. max_count defaults to 20.',
    SCHEMA_GIT_LOG, MCP_ANN_RO));
  Tools.Add(MakeTool('git_add',
    'Stage files for the next commit. Pass an array of file or directory paths.',
    SCHEMA_GIT_ADD, MCP_ANN_WRITE_IDEM));
  Tools.Add(MakeTool('git_commit',
    'Commit currently staged changes with the given message. ' +
    'Stage files first with git_add.',
    SCHEMA_GIT_COMMIT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('git_checkout',
    'Switch to a branch, restore a file, or detach HEAD at a commit. ' +
    'Pass a branch name, tag, commit hash, or file path as target.',
    SCHEMA_GIT_CHECKOUT, MCP_ANN_DEST));
  Tools.Add(MakeTool('git_branches',
    'List all local and remote branches. The current branch is prefixed with *.',
    SCHEMA_GIT_BRANCHES, MCP_ANN_RO));
  Tools.Add(MakeTool('git_stash',
    'Stash uncommitted changes (staged and unstaged) with an optional message. ' +
    'Use git_stash_pop to restore them.',
    SCHEMA_GIT_STASH, MCP_ANN_WRITE));
  Tools.Add(MakeTool('git_stash_pop',
    'Apply and remove a stash entry. index defaults to 0 (most recent stash).',
    SCHEMA_GIT_STASH_POP, MCP_ANN_WRITE));
  Tools.Add(MakeTool('git_reset',
    'Reset the current HEAD to target. mode=mixed (default) unstages changes ' +
    'and moves HEAD; mode=soft keeps changes staged. ' +
    'Hard reset is intentionally not supported — use the terminal for that.',
    SCHEMA_GIT_RESET, MCP_ANN_DEST));
end;

initialization
  RegisterMcpGroup(@DispatchGitTool);
  RegisterMcpSchemas(@RegisterGitSchemas);

end.
