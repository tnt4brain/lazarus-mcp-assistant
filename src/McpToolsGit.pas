{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsGit;

{ Git integration tools: git_status, git_diff, git_log, git_add,
  git_commit, git_checkout, git_branches.
  All operations shell out to git.exe; work_dir defaults to the active
  project directory when not supplied by the caller. }

{$mode objfpc}{$H+}

interface

implementation

uses
  Classes, SysUtils, Process, FileUtil, LazFileUtils,
  LazIDEIntf,
  fpjson,
  McpToolContext;

{ ── Schema constants ─────────────────────────────────────────────────────── }

const
  SCHEMA_GIT_STATUS =
    '{"type":"object","properties":{' +
    '"work_dir":{"type":"string","description":"Repository root; defaults to active project directory"}},' +
    '"required":[]}';

  SCHEMA_GIT_DIFF =
    '{"type":"object","properties":{' +
    '"staged":{"type":"boolean","description":"Diff staged (index) changes instead of working-tree (default false)"},' +
    '"path":{"type":"string","description":"Limit diff to this file or directory"},' +
    '"work_dir":{"type":"string","description":"Repository root; defaults to active project directory"}},' +
    '"required":[]}';

  SCHEMA_GIT_LOG =
    '{"type":"object","properties":{' +
    '"max_count":{"type":"integer","description":"Maximum number of commits to show (default 20)"},' +
    '"branch":{"type":"string","description":"Branch or ref to log; defaults to HEAD"},' +
    '"work_dir":{"type":"string","description":"Repository root; defaults to active project directory"}},' +
    '"required":[]}';

  SCHEMA_GIT_ADD =
    '{"type":"object","properties":{' +
    '"paths":{"type":"array","items":{"type":"string"},"description":"Files or directories to stage"},' +
    '"work_dir":{"type":"string","description":"Repository root; defaults to active project directory"}},' +
    '"required":["paths"]}';

  SCHEMA_GIT_COMMIT =
    '{"type":"object","properties":{' +
    '"message":{"type":"string","description":"Commit message"},' +
    '"work_dir":{"type":"string","description":"Repository root; defaults to active project directory"}},' +
    '"required":["message"]}';

  SCHEMA_GIT_CHECKOUT =
    '{"type":"object","properties":{' +
    '"target":{"type":"string","description":"Branch name, tag, commit hash, or file path to restore"},' +
    '"work_dir":{"type":"string","description":"Repository root; defaults to active project directory"}},' +
    '"required":["target"]}';

  SCHEMA_GIT_BRANCHES =
    '{"type":"object","properties":{' +
    '"work_dir":{"type":"string","description":"Repository root; defaults to active project directory"}},' +
    '"required":[]}';

  SCHEMA_GIT_STASH =
    '{"type":"object","properties":{' +
    '"message":{"type":"string","description":"Optional stash description"},' +
    '"work_dir":{"type":"string","description":"Repository root; defaults to active project directory"}},' +
    '"required":[]}';

  SCHEMA_GIT_STASH_POP =
    '{"type":"object","properties":{' +
    '"index":{"type":"integer","description":"Stash index to pop (default 0 = most recent)"},' +
    '"work_dir":{"type":"string","description":"Repository root; defaults to active project directory"}},' +
    '"required":[]}';

  SCHEMA_GIT_RESET =
    '{"type":"object","properties":{' +
    '"target":{"type":"string","description":"Ref or file to reset: e.g. HEAD, HEAD~1, a commit hash, or a file path"},' +
    '"mode":{"type":"string","enum":["mixed","soft"],"description":"mixed (default): unstage changes, keep working tree. soft: keep changes staged."},' +
    '"work_dir":{"type":"string","description":"Repository root; defaults to active project directory"}},' +
    '"required":["target"]}';

{ ── Helpers ──────────────────────────────────────────────────────────────── }

function RunGit(const Args: array of string; const WorkDir: string;
  out Output: string): Boolean;
var
  GitExe    : string;
  Proc      : TProcess;
  Chunk     : string;
  BytesRead : LongInt;
  I         : Integer;
const
  BufSize = 4096;
begin
  GitExe := FindDefaultExecutablePath('git');
  if GitExe = '' then
  begin
    Output := 'git executable not found on PATH';
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
  I         : Integer;
begin
  Result := False;

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
    Ok := RunGit(['commit', '-m', Message], WorkDir, Output);
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
    'between the index and HEAD). Optionally scoped to a single path.',
    SCHEMA_GIT_DIFF, MCP_ANN_RO));
  Tools.Add(MakeTool('git_log',
    'Show recent commit history as one-line summaries. max_count defaults to 20.',
    SCHEMA_GIT_LOG, MCP_ANN_RO));
  Tools.Add(MakeTool('git_add',
    'Stage files for the next commit. Pass an array of file or directory paths.',
    SCHEMA_GIT_ADD, MCP_ANN_WRITE));
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
