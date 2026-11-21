{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsGitHistory;

{ Git tools that reshape history (ADR-028, section 3): git_merge, git_merge_abort,
  git_rebase, git_rebase_continue, git_rebase_abort, git_resolve, git_squash.

  They change files and history, so each refuses to start unless the tracked files are
  clean, no editor holds unsaved changes and no merge, rebase or cherry-pick is already
  in progress.  Before anything changes, a backup ref (refs/mcp-backup/<branch>/<UTC
  time>) is made at HEAD and returned: one git_reset to it undoes the operation, and
  unlike the reflog it does not expire.  A conflict is left in git's own state (no
  automatic abort); the result lists the files and the next steps.

  Main thread. }

{$mode objfpc}{$H+}

interface

uses
  Classes, McpToolsGitRemote;

{ The warning for commits that are about to be rewritten (ARange, such as upstream..HEAD)
  and are already on a remote-tracking branch; '' when none is. }
function PublishedWarning(const G: TGit; const ARange: string): string;

{ Backup refs, newest first: "ref<TAB>commit".  Older than ADays days (by the time in the
  ref's name) are deleted by DeleteBackups, which returns the refs it deleted. }
procedure ListBackups(const G: TGit; ARefs: TStrings);
function DeleteBackups(const G: TGit; ADays: Integer; ADeleted: TStrings): Boolean;

implementation

uses
  SysUtils, DateUtils, LazFileUtils, fpjson,
  McpToolContext, McpGitRun, McpGitConflicts;

const
  SCHEMA_GIT_MERGE =
    '{"type":"object","properties":{' +
    '"ref":{"type":"string","description":"What to merge into the current branch: a branch, a remote-tracking branch (origin/x), a tag or a commit"},' +
    '"ff":{"type":"string","enum":["auto","only","never"],"description":"auto (default): fast-forward when possible, else a merge commit. only: fail rather than make a merge commit. never: always make a merge commit"},' +
    '"squash":{"type":"boolean","description":"Take the changes in without committing (git merge --squash); commit them with git_commit. Needs ff=auto"},' +
    '"work_dir":{"type":"string","description":"A directory inside the repository (default: the project''s directory)"}},' +
    '"required":["ref"]}';

  SCHEMA_WORK_DIR_ONLY =
    '{"type":"object","properties":{' +
    '"work_dir":{"type":"string","description":"A directory inside the repository (default: the project''s directory)"}},' +
    '"required":[]}';

  SCHEMA_GIT_REBASE =
    '{"type":"object","properties":{' +
    '"upstream":{"type":"string","description":"The commit the current branch is replayed on top of when it is not given an onto: the commits after it are replayed. A branch, tag or commit"},' +
    '"onto":{"type":"string","description":"Replay them on top of this instead of upstream"},' +
    '"work_dir":{"type":"string","description":"A directory inside the repository (default: the project''s directory)"}},' +
    '"required":["upstream"]}';

  SCHEMA_GIT_RESOLVE =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"A path git lists as conflicted"},' +
    '"side":{"type":"string","enum":["ours","theirs","upstream","commit","delete"],"description":"Whole-file resolution. In a merge: ours (the current branch) or theirs (the merged ref). In a rebase git swaps them, so say what each side is: upstream (what you are rebasing onto) or commit (the commit being replayed). delete removes the file. The file is then staged"},' +
    '"work_dir":{"type":"string","description":"A directory inside the repository (default: the project''s directory)"}},' +
    '"required":["file","side"]}';

  SCHEMA_GIT_SQUASH =
    '{"type":"object","properties":{' +
    '"count":{"type":"integer","description":"Squash the last N commits of the current branch into one (N is 2 or more)"},' +
    '"since":{"type":"string","description":"Or: squash every commit after this one (it stays), it must be an ancestor of HEAD"},' +
    '"message":{"type":"string","description":"The message of the new commit"},' +
    '"work_dir":{"type":"string","description":"A directory inside the repository (default: the project''s directory)"}},' +
    '"required":["message"]}';

  HISTORY_TIMEOUT_MS = 10 * 60 * 1000;
  BACKUP_PREFIX      = 'refs/mcp-backup/';

{ ── Helpers ──────────────────────────────────────────────────────────────── }

{ Output of a -z command: the fields, NUL-separated. }
procedure SplitZ(const AText: string; AList: TStrings);
var
  Start, I : Integer;
begin
  AList.Clear;
  Start := 1;
  for I := 1 to Length(AText) do
    if AText[I] = #0 then
    begin
      if I > Start then
        AList.Add(Copy(AText, Start, I - Start));
      Start := I + 1;
    end;
  if Start <= Length(AText) then
    AList.Add(Copy(AText, Start, MaxInt));
end;

function UnmergedFiles(const G: TGit; AFiles: TStrings): Boolean;
var
  Output : string;
begin
  AFiles.Clear;
  Result := Query(G, ['diff', '--name-only', '--diff-filter=U', '-z'], Output);
  if Result then
    SplitZ(Output, AFiles);
end;

{ Tracked files that differ from HEAD, in the index or in the tree.  Untracked files do
  not count: git itself refuses when one would be overwritten. }
function DirtyFiles(const G: TGit; AFiles: TStrings; out AOutput: string): Boolean;
var
  Fields : TStringList;
  Entry  : string;
  I      : Integer;
begin
  AFiles.Clear;
  Result := Query(G, ['status', '--porcelain=v1', '-z', '--untracked-files=no'], AOutput);
  if not Result then Exit;
  Fields := TStringList.Create;
  try
    SplitZ(AOutput, Fields);
    I := 0;
    while I < Fields.Count do
    begin
      Entry := Fields[I];
      if Length(Entry) > 3 then
        AFiles.Add(Copy(Entry, 4, MaxInt));
      { a rename or copy is followed by its old path }
      if (Length(Entry) > 1) and ((Entry[1] in ['R', 'C']) or (Entry[2] in ['R', 'C'])) then
        Inc(I);
      Inc(I);
    end;
  finally
    Fields.Free;
  end;
end;

{ A path inside git's directory, as a file system path. }
function GitPathOf(const G: TGit; const AName: string): string;
begin
  Result := QueryText(G, ['rev-parse', '--git-path', AName]);
  if (Result <> '') and not FilenameIsAbsolute(Result) then
    Result := ExpandFileName(IncludeTrailingPathDelimiter(G.Dir) + Result);
end;

type
  TInProgress = (ipNone, ipMerge, ipRebase, ipCherryPick);

function OperationInProgress(const G: TGit): TInProgress;
begin
  if FileExists(GitPathOf(G, 'MERGE_HEAD')) then
    Exit(ipMerge);
  if DirectoryExists(GitPathOf(G, 'rebase-merge')) or DirectoryExists(GitPathOf(G, 'rebase-apply')) then
    Exit(ipRebase);
  if FileExists(GitPathOf(G, 'CHERRY_PICK_HEAD')) then
    Exit(ipCherryPick);
  Result := ipNone;
end;

function InProgressText(AKind: TInProgress): string;
begin
  case AKind of
    ipMerge:      Result := 'A merge is already in progress: finish it (git_commit), or undo it with git_merge_abort.';
    ipRebase:     Result := 'A rebase is already in progress: git_rebase_continue, or undo it with git_rebase_abort.';
    ipCherryPick: Result := 'A cherry-pick is already in progress: finish it, or undo it with git_cherry_pick and abort=true.';
  else
    Result := '';
  end;
end;

{ The checks every operation that starts passes; '' when it may start. }
function Preflight(const G: TGit; out ABranch: string): string;
var
  Dirty  : TStringList;
  Output : string;
  Busy   : TInProgress;
begin
  ABranch := CurrentBranch(G);
  if ABranch = '' then
    Exit('HEAD is detached: check out a branch first (git_checkout).');
  Busy := OperationInProgress(G);
  if Busy <> ipNone then
    Exit(InProgressText(Busy));
  Dirty := TStringList.Create;
  try
    if not DirtyFiles(G, Dirty, Output) then
      Exit('git could not read the status: ' + Trim(Output));
    if Dirty.Count > 0 then
      Exit('The working tree has uncommitted changes to tracked files; commit or stash them first ' +
        '(git_commit, git_stash). Nothing is stashed for you. Files: ' + Dirty.CommaText);
  finally
    Dirty.Free;
  end;
  Result := '';
end;

{ git needs to be AMajor.AMinor or newer for the flags the tool pins; '' when it is. }
function VersionRefusal(const G: TGit; const ATool: string; AMajor, AMinor: Integer): string;
var
  Found  : string;
  Parts  : TStringList;
  Ma, Mi : Integer;
begin
  Found := QueryText(G, ['--version']);
  Parts := TStringList.Create;
  try
    Parts.Delimiter       := '.';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText   := Copy(Found, Pos('version ', Found) + Length('version '), MaxInt);
    Ma := 0;
    Mi := 0;
    if Parts.Count > 1 then
    begin
      Ma := StrToIntDef(Parts[0], 0);
      Mi := StrToIntDef(Parts[1], 0);
    end;
  finally
    Parts.Free;
  end;
  if (Ma > AMajor) or ((Ma = AMajor) and (Mi >= AMinor)) then
    Exit('');
  Result := ATool + ' needs git ' + IntToStr(AMajor) + '.' + IntToStr(AMinor) +
    ' or newer, to name every behavior on the command line; this is "' + Found + '".';
end;

{ A ref at HEAD under refs/mcp-backup/<branch>/<UTC time>; one git_reset undoes what follows. }
function MakeBackup(const G: TGit; const ABranch: string; out ARef, AWhy: string): Boolean;
var
  Stamp  : string;
  N      : Integer;
  Output : string;
begin
  Stamp := FormatDateTime('yyyymmdd"T"hhnnss"Z"', LocalTimeToUniversal(Now));
  ARef  := BACKUP_PREFIX + ABranch + '/' + Stamp;
  N     := 1;
  while RefExists(G, ARef) do
  begin
    Inc(N);
    ARef := BACKUP_PREFIX + ABranch + '/' + Stamp + '-' + IntToStr(N);
  end;
  Result := Query(G, ['update-ref', ARef, 'HEAD'], Output);
  if Result then
    AWhy := ''
  else
    AWhy := 'Could not make the backup ref ' + ARef + ' (nothing was changed): ' + Trim(Output);
end;

function PublishedWarning(const G: TGit; const ARange: string): string;
var
  Total, Unpublished : Integer;
  Oldest, OnRemote   : string;
begin
  Result := '';
  Total := StrToIntDef(QueryText(G, ['rev-list', '--count', ARange]), 0);
  if Total = 0 then Exit;
  Unpublished := StrToIntDef(QueryText(G, ['rev-list', '--count', ARange, '--not', '--remotes']), Total);
  if Total - Unpublished <= 0 then Exit;
  { published commits are the oldest ones: name a branch that has the first }
  Oldest   := QueryText(G, ['rev-list', '--reverse', '-n', '1', ARange]);
  OnRemote := QueryText(G, ['branch', '-r', '--contains', Oldest, '--format=%(refname:short)']);
  OnRemote := Trim(Copy(OnRemote, 1, Pos(#10, OnRemote + #10) - 1));
  Result := IntToStr(Total - Unpublished) + ' commit(s) are already on ' + OnRemote +
    '; the branch would need a force-push (git_push with force). They are also in someone else''s ' +
    'history if anyone fetched them.';
end;

{ What to do next, by what stopped. }
function NextSteps(const AKind, ABackup: string): string;
begin
  case AKind of
    'merge':
      Result := 'Resolve each file (edit it and git_add it, or git_resolve with ours or theirs), ' +
        'then git_commit to finish the merge; or git_merge_abort to give up.';
    'rebase':
      Result := 'Resolve each file (edit it and git_add it, or git_resolve with upstream or commit), ' +
        'then git_rebase_continue; or git_rebase_abort to give up.';
  else
    Result := 'Resolve each file (edit it and git_add it, or git_resolve), then git_commit.';
  end;
  Result := Result + ' After it is finished, git_reset to ' + ABackup + ' undoes it.';
end;

{ What the Review window offers, for the "next" text of a conflict. }
function ReviewNote(AReview: TJSONObject): string;
var
  Files, Undecided : TJSONArray;
begin
  Files     := AReview.Arrays['files'];
  Undecided := AReview.Arrays['needs_decision'];
  Result := '';
  if Files.Count > 0 then
    Result := ' The user can resolve ' + IntToStr(Files.Count) + ' text file(s) in the IDE''s Review window ' +
      '(Resolve = write and stage; git_status shows what is still unmerged): leave those to them, or ' +
      'resolve them yourself.';
  if Undecided.Count > 0 then
    Result := Result + ' ' + IntToStr(Undecided.Count) + ' file(s) are not a text merge (see ' +
      'review.needs_decision): settle them with git_resolve.';
end;

{ The answer of an operation: ok, conflict (git is left in its own state) or error. }
procedure FinishOp(var Ctx: TMcpToolCall; const G: TGit; AOk: Boolean;
  const ACommand, AOutput, ABackup, AWarning, AKind: string);
var
  Files  : TStringList;
  Obj    : TJSONObject;
  Arr    : TJSONArray;
  Review : TJSONObject;
  File_, Status : string;
begin
  Files := TStringList.Create;
  try
    UnmergedFiles(G, Files);
    if Files.Count > 0 then
      Status := 'conflict'
    else if AOk then
      Status := 'ok'
    else
      Status := 'error';
    Obj := TJSONObject.Create;
    Obj.Add('status', Status);
    Obj.Add('command', ACommand);
    Obj.Add('output', Trim(AOutput));
    if ABackup <> '' then
      Obj.Add('backup', ABackup);
    if AWarning <> '' then
      Obj.Add('warning', AWarning);
    if Status = 'conflict' then
    begin
      Arr := TJSONArray.Create;
      for File_ in Files do
        Arr.Add(File_);
      Obj.Add('conflicted', Arr);
      Review := ShowConflicts(G, AKind);
      Obj.Add('review', Review);
      Obj.Add('next', NextSteps(AKind, ABackup) + ReviewNote(Review));
    end
    else
      SyncConflicts(G);
    Reply(Ctx, Status <> 'error', Obj);
  finally
    Files.Free;
  end;
end;

{ A commit-ish that resolves; '' when it does, else why not. }
function CommitRefusal(const G: TGit; const AName, ARef: string): string;
begin
  if (ARef = '') or (ARef[1] = '-') or not RefExists(G, ARef + '^{commit}') then
    Result := AName + ' is not a commit, branch or tag of this repository: ' + ARef
  else
    Result := '';
end;

{ ── Backups ──────────────────────────────────────────────────────────────── }

procedure ListBackups(const G: TGit; ARefs: TStrings);
var
  Output : string;
begin
  ARefs.Clear;
  if Query(G, ['for-each-ref', '--sort=-refname', '--format=%(refname)%09%(objectname:short)',
    BACKUP_PREFIX], Output) then
    ARefs.Text := Trim(Output);
end;

{ The UTC time in a backup ref's name; 0 when it has none. }
function BackupTime(const ARef: string): TDateTime;
var
  Stamp : string;
begin
  Stamp := Copy(ARef, LastDelimiter('/', ARef) + 1, 16);   { yyyymmddThhmmssZ }
  if (Length(Stamp) <> 16) or (Stamp[9] <> 'T') then Exit(0);
  if not TryEncodeDate(StrToIntDef(Copy(Stamp, 1, 4), 0), StrToIntDef(Copy(Stamp, 5, 2), 0),
    StrToIntDef(Copy(Stamp, 7, 2), 0), Result) then Exit(0);
  Result := Result + EncodeTime(StrToIntDef(Copy(Stamp, 10, 2), 0), StrToIntDef(Copy(Stamp, 12, 2), 0),
    StrToIntDef(Copy(Stamp, 14, 2), 0), 0);
end;

function DeleteBackups(const G: TGit; ADays: Integer; ADeleted: TStrings): Boolean;
var
  All    : TStringList;
  Line, Ref, Output : string;
  Cut    : TDateTime;
  Stamp  : TDateTime;
begin
  Result := True;
  ADeleted.Clear;
  Cut := IncDay(LocalTimeToUniversal(Now), -ADays);
  All := TStringList.Create;
  try
    ListBackups(G, All);
    for Line in All do
    begin
      Ref   := Copy(Line, 1, Pos(#9, Line + #9) - 1);
      Stamp := BackupTime(Ref);
      if (Stamp = 0) or (Stamp > Cut) then Continue;
      if Query(G, ['update-ref', '-d', Ref], Output) then
        ADeleted.Add(Ref)
      else
        Result := False;
    end;
  finally
    All.Free;
  end;
end;

{ ── git_merge ────────────────────────────────────────────────────────────── }

procedure GitMerge(var Ctx: TMcpToolCall);
var
  Main   : TMainPart;
  G      : TGit;
  Ref, Flag, Branch, Why, BackupRef, Output, Cmd : string;
  Squash, Ok : Boolean;
  Args   : TStringList;
begin
  Main := TMainPart.Create(Ctx, 'git_merge', True);
  Args := TStringList.Create;
  try
    Main.Prepare;
    if Refused(Ctx, Main.Why) then Exit;
    G := Main.Git;

    Ref    := StrParam(Ctx, 'ref');
    Squash := BoolParam(Ctx, 'squash');
    case StrParam(Ctx, 'ff', 'auto') of
      'auto':  Flag := '--ff';
      'only':  Flag := '--ff-only';
      'never': Flag := '--no-ff';
    else
      Refused(Ctx, 'ff must be auto, only or never');
      Exit;
    end;
    if Squash and (Flag <> '--ff') then
    begin
      Refused(Ctx, 'squash needs ff=auto: a squash merge makes no merge commit.');
      Exit;
    end;
    if Refused(Ctx, VersionRefusal(G, 'git_merge', 2, 27)) then Exit;
    if Refused(Ctx, CommitRefusal(G, 'ref', Ref)) then Exit;
    Why := Preflight(G, Branch);
    if Refused(Ctx, Why) then Exit;
    if not MakeBackup(G, Branch, BackupRef, Why) then
    begin
      Refused(Ctx, Why);
      Exit;
    end;

    Args.AddStrings(['-c', 'merge.conflictStyle=diff3', 'merge', '--no-edit', '--no-autostash',
      '--no-verify-signatures', Flag]);
    if Squash then
      Args.Add('--squash');
    Args.AddStrings(['--', Ref]);
    Cmd := CommandText(Args.ToStringArray);
    Ok  := RunGitTimed(G.Exe, Args.ToStringArray, G.Dir, HISTORY_TIMEOUT_MS, Output);
    if Squash then
      FinishOp(Ctx, G, Ok, Cmd, Output, BackupRef,
        'Nothing is committed: the changes are staged. Commit them with git_commit.', 'squash')
    else
      FinishOp(Ctx, G, Ok, Cmd, Output, BackupRef, '', 'merge');
  finally
    Args.Free;
    Main.Free;
  end;
end;

{ ── abort and continue ───────────────────────────────────────────────────── }

procedure AbortOp(var Ctx: TMcpToolCall; const AToolName: string; AKind: TInProgress;
  const AFlag, AWord: string);
var
  Main   : TMainPart;
  G      : TGit;
  Output : string;
  Ok     : Boolean;
  Obj    : TJSONObject;
begin
  Main := TMainPart.Create(Ctx, AToolName, False);
  try
    Main.Prepare;
    if Refused(Ctx, Main.Why) then Exit;
    G := Main.Git;
    if OperationInProgress(G) <> AKind then
    begin
      Refused(Ctx, 'No ' + AWord + ' is in progress.');
      Exit;
    end;
    Ok  := Query(G, [AWord, AFlag], Output);
    SyncConflicts(G);
    Obj := TJSONObject.Create;
    Obj.Add('command', CommandText([AWord, AFlag]));
    Obj.Add('output', Trim(Output));
    Reply(Ctx, Ok, Obj);
  finally
    Main.Free;
  end;
end;

procedure GitRebaseContinue(var Ctx: TMcpToolCall);
var
  Main   : TMainPart;
  G      : TGit;
  Files  : TStringList;
  Output, Cmd : string;
  Ok     : Boolean;
begin
  Main := TMainPart.Create(Ctx, 'git_rebase_continue', False);
  Files := TStringList.Create;
  try
    Main.Prepare;
    if Refused(Ctx, Main.Why) then Exit;
    G := Main.Git;
    if OperationInProgress(G) <> ipRebase then
    begin
      Refused(Ctx, 'No rebase is in progress.');
      Exit;
    end;
    UnmergedFiles(G, Files);
    if Files.Count > 0 then
    begin
      Refused(Ctx, 'Files are still unmerged; resolve each one (edit and git_add it, or git_resolve): ' +
        Files.CommaText);
      Exit;
    end;
    Cmd := CommandText(['rebase', '--continue']);
    Ok  := RunGitTimed(G.Exe, ['rebase', '--continue'], G.Dir, HISTORY_TIMEOUT_MS, Output);
    FinishOp(Ctx, G, Ok, Cmd, Output, '', '', 'rebase');
  finally
    Files.Free;
    Main.Free;
  end;
end;

{ ── git_rebase ───────────────────────────────────────────────────────────── }

procedure GitRebase(var Ctx: TMcpToolCall);
var
  Main   : TMainPart;
  G      : TGit;
  Upstream, Onto, Branch, Why, BackupRef, Output, Cmd : string;
  Args   : TStringList;
  Ok     : Boolean;
begin
  Main := TMainPart.Create(Ctx, 'git_rebase', True);
  Args := TStringList.Create;
  try
    Main.Prepare;
    if Refused(Ctx, Main.Why) then Exit;
    G := Main.Git;

    Upstream := StrParam(Ctx, 'upstream');
    Onto     := StrParam(Ctx, 'onto');
    if Refused(Ctx, VersionRefusal(G, 'git_rebase', 2, 38)) then Exit;
    if Refused(Ctx, CommitRefusal(G, 'upstream', Upstream)) then Exit;
    if (Onto <> '') and Refused(Ctx, CommitRefusal(G, 'onto', Onto)) then Exit;
    Why := Preflight(G, Branch);
    if Refused(Ctx, Why) then Exit;
    if not MakeBackup(G, Branch, BackupRef, Why) then
    begin
      Refused(Ctx, Why);
      Exit;
    end;

    Args.AddStrings(['-c', 'merge.conflictStyle=diff3', 'rebase', '--no-autostash',
      '--no-autosquash', '--no-update-refs', '--no-rebase-merges', '--no-fork-point',
      '--no-reapply-cherry-picks', '--empty=drop']);
    if Onto <> '' then
      Args.AddStrings(['--onto', Onto]);
    Args.AddStrings(['--', Upstream]);
    Cmd := CommandText(Args.ToStringArray);
    Why := PublishedWarning(G, Upstream + '..HEAD');
    Ok  := RunGitTimed(G.Exe, Args.ToStringArray, G.Dir, HISTORY_TIMEOUT_MS, Output);
    FinishOp(Ctx, G, Ok, Cmd, Output, BackupRef, Why, 'rebase');
  finally
    Args.Free;
    Main.Free;
  end;
end;

{ ── git_resolve ──────────────────────────────────────────────────────────── }

procedure GitResolve(var Ctx: TMcpToolCall);
var
  Main   : TMainPart;
  G      : TGit;
  Files  : TStringList;
  File_, Side, Flag, Output, Cmd : string;
  Kind   : TInProgress;
  Ok     : Boolean;
  Obj    : TJSONObject;
begin
  Main  := TMainPart.Create(Ctx, 'git_resolve', False);
  Files := TStringList.Create;
  try
    Main.Prepare;
    if Refused(Ctx, Main.Why) then Exit;
    G     := Main.Git;
    File_ := StringReplace(StrParam(Ctx, 'file'), '\', '/', [rfReplaceAll]);
    Side  := StrParam(Ctx, 'side');
    Kind  := OperationInProgress(G);

    UnmergedFiles(G, Files);
    if Files.IndexOf(File_) < 0 then
    begin
      Refused(Ctx, 'Not a conflicted file: ' + File_ + '. Conflicted: ' + Files.CommaText);
      Exit;
    end;

    { in a rebase git's "ours" is the upstream and "theirs" the commit being replayed }
    case Side of
      'ours', 'theirs':
        if Kind = ipRebase then
        begin
          Refused(Ctx, 'In a rebase git swaps the sides: say upstream (what you rebase onto) or commit ' +
            '(the commit being replayed).');
          Exit;
        end
        else
          Flag := '--' + Side;
      'upstream', 'commit':
        if Kind <> ipRebase then
        begin
          Refused(Ctx, 'upstream and commit are for a rebase; in a merge say ours or theirs.');
          Exit;
        end
        else if Side = 'upstream' then
          Flag := '--ours'
        else
          Flag := '--theirs';
      'delete': Flag := '';
    else
      Refused(Ctx, 'side must be ours, theirs, upstream, commit or delete');
      Exit;
    end;

    if Side = 'delete' then
    begin
      Cmd := CommandText(['rm', '--', File_]);
      Ok  := Query(G, ['rm', '--', File_], Output);
    end
    else
    begin
      Cmd := CommandText(['checkout', Flag, '--', File_]) + ' && ' + CommandText(['add', '--', File_]);
      Ok  := Query(G, ['checkout', Flag, '--', File_], Output);
      if Ok then
        Ok := Query(G, ['add', '--', File_], Output);
    end;

    Obj := TJSONObject.Create;
    Obj.Add('command', Cmd);
    Obj.Add('output', Trim(Output));
    if Ok then
    begin
      UnmergedFiles(G, Files);
      Obj.Add('still_conflicted', Files.CommaText);
      SyncConflicts(G);
    end;
    Reply(Ctx, Ok, Obj);
  finally
    Files.Free;
    Main.Free;
  end;
end;

{ ── git_squash ───────────────────────────────────────────────────────────── }

procedure GitSquash(var Ctx: TMcpToolCall);
var
  Main   : TMainPart;
  G      : TGit;
  Message, Since, Branch, Base, Why, BackupRef, Output, Warning, NewHead : string;
  Count  : Integer;
  Obj    : TJSONObject;
begin
  Main := TMainPart.Create(Ctx, 'git_squash', True);
  try
    Main.Prepare;
    if Refused(Ctx, Main.Why) then Exit;
    G       := Main.Git;
    Message := Trim(StrParam(Ctx, 'message'));
    Since   := StrParam(Ctx, 'since');
    if Message = '' then
    begin
      Refused(Ctx, 'message is required: the message of the new commit.');
      Exit;
    end;
    Why := Preflight(G, Branch);
    if Refused(Ctx, Why) then Exit;

    if Since <> '' then
    begin
      if Refused(Ctx, CommitRefusal(G, 'since', Since)) then Exit;
      if not Query(G, ['merge-base', '--is-ancestor', Since, 'HEAD'], Output) then
      begin
        Refused(Ctx, 'since must be an ancestor of HEAD: ' + Since);
        Exit;
      end;
      Base  := QueryText(G, ['rev-parse', Since + '^{commit}']);
      Count := StrToIntDef(QueryText(G, ['rev-list', '--count', Base + '..HEAD']), 0);
    end
    else
    begin
      Count := 0;
      if Assigned(Ctx.Params) then
        Count := Ctx.Params.Get('count', 0);
      if Count < 2 then
      begin
        Refused(Ctx, 'Pass count (2 or more) or since.');
        Exit;
      end;
      Base := QueryText(G, ['rev-parse', '-q', '--verify', 'HEAD~' + IntToStr(Count)]);
      if Base = '' then
      begin
        Refused(Ctx, 'The branch has fewer than ' + IntToStr(Count + 1) + ' commits.');
        Exit;
      end;
    end;
    if Count < 2 then
    begin
      Refused(Ctx, 'There are ' + IntToStr(Count) + ' commit(s) after that: nothing to squash.');
      Exit;
    end;
    if StrToIntDef(QueryText(G, ['rev-list', '--merges', '--count', Base + '..HEAD']), 0) > 0 then
    begin
      Refused(Ctx, 'The range contains a merge commit; squash does not rewrite merges.');
      Exit;
    end;

    if not MakeBackup(G, Branch, BackupRef, Why) then
    begin
      Refused(Ctx, Why);
      Exit;
    end;
    Warning := PublishedWarning(G, Base + '..HEAD');

    if not Query(G, ['reset', '--soft', Base], Output) then
    begin
      FinishOp(Ctx, G, False, 'git reset --soft ' + Base, Output, BackupRef, Warning, 'squash');
      Exit;
    end;
    if not RunGitTimed(G.Exe, ['commit', '-F', '-'], G.Dir, HISTORY_TIMEOUT_MS, Output,
      Message + LineEnding) then
    begin
      { a hook refused it: put the branch back as it was; --soft kept the files }
      Query(G, ['reset', '--soft', BackupRef], Why);
      FinishOp(Ctx, G, False, 'git commit -F -', Output + LineEnding + 'The branch was put back as it was.',
        BackupRef, Warning, 'squash');
      Exit;
    end;

    NewHead := QueryText(G, ['rev-parse', 'HEAD']);
    Obj := TJSONObject.Create;
    Obj.Add('status', 'ok');
    Obj.Add('squashed', Count);
    Obj.Add('head', NewHead);
    Obj.Add('backup', BackupRef);
    if Warning <> '' then
      Obj.Add('warning', Warning);
    Reply(Ctx, True, Obj);
  finally
    Main.Free;
  end;
end;

{ ── Dispatch and registration ────────────────────────────────────────────── }

function DispatchGitHistoryTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
begin
  Result := True;
  try
    case Name of
      'git_merge':           GitMerge(Ctx);
      'git_merge_abort':     AbortOp(Ctx, Name, ipMerge, '--abort', 'merge');
      'git_rebase':          GitRebase(Ctx);
      'git_rebase_continue': GitRebaseContinue(Ctx);
      'git_rebase_abort':    AbortOp(Ctx, Name, ipRebase, '--abort', 'rebase');
      'git_resolve':         GitResolve(Ctx);
      'git_squash':          GitSquash(Ctx);
    else
      Result := False;
    end;
  except
    on E: Exception do
      Refused(Ctx, Name + ' failed: ' + E.ClassName + ': ' + E.Message);
  end;
end;

procedure RegisterGitHistorySchemas(Tools: TJSONArray);
begin
  Tools.Add(MakeTool('git_merge',
    'Merge a branch, tag or commit into the current branch (git merge). Refused unless the tracked ' +
    'files are clean, no editor has unsaved changes and nothing else is in progress; a backup ref ' +
    'is made first and returned (git_reset to it undoes the merge). On a conflict git is left in the ' +
    'merge: the result lists the files and the next steps.',
    SCHEMA_GIT_MERGE, MCP_ANN_DEST));
  Tools.Add(MakeTool('git_merge_abort',
    'Give up a merge that stopped on a conflict (git merge --abort); the files go back as they were.',
    SCHEMA_WORK_DIR_ONLY, MCP_ANN_DEST));
  Tools.Add(MakeTool('git_rebase',
    'Replay the commits of the current branch after upstream on top of upstream, or of onto (git ' +
    'rebase; never interactive). Same refusals and backup ref as git_merge. The result warns when ' +
    'commits that are already on a remote would be rewritten. On a conflict git is left in the ' +
    'rebase: the result lists the files and the next steps.',
    SCHEMA_GIT_REBASE, MCP_ANN_DEST));
  Tools.Add(MakeTool('git_rebase_continue',
    'Go on with a rebase that stopped on a conflict, after every conflicted file is resolved and ' +
    'staged (git rebase --continue). Refused while any file is still unmerged.',
    SCHEMA_WORK_DIR_ONLY, MCP_ANN_WRITE));
  Tools.Add(MakeTool('git_rebase_abort',
    'Give up a rebase that stopped on a conflict (git rebase --abort); the branch goes back as it was.',
    SCHEMA_WORK_DIR_ONLY, MCP_ANN_DEST));
  Tools.Add(MakeTool('git_resolve',
    'Settle a conflicted file as a whole, taking one side or deleting it, and stage it. For files ' +
    'where the sides can be combined, edit the file instead and git_add it.',
    SCHEMA_GIT_RESOLVE, MCP_ANN_DEST));
  Tools.Add(MakeTool('git_squash',
    'Turn the last count commits (or every commit after since) of the current branch into one with ' +
    'the given message. Same refusals and backup ref as git_merge; refuses a range with a merge ' +
    'commit. The result warns when commits that are already on a remote would be rewritten.',
    SCHEMA_GIT_SQUASH, MCP_ANN_DEST));
end;

initialization
  RegisterMcpGroup(@DispatchGitHistoryTool);
  RegisterMcpSchemas(@RegisterGitHistorySchemas);

end.
