{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TGitHistory;

{ TTestGitHistory — git_merge, git_rebase, git_squash, git_resolve and the aborts (ADR-028,
  section 3), with the backup refs of git_branches and the warning of git_reset.

  Each test works in a throwaway repository in the temp folder with a hostile
  configuration (merge.ff=only, pull.rebase=true, rebase.updateRefs=true,
  rebase.autoSquash=true, init.defaultBranch=trunk): what the tools pin on the command line
  has to win over it.  The history: a base commit, then "trunk" and "feature" each with
  commits of their own; a.txt is what they conflict on.

  Requires a running MCP server and git (2.38 or newer for the rebase tests). }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, THttpHelper;

type
  TTestGitHistory = class(TTestCase)
  private
    FBase : string;
    FDir  : string;
    function Git(const AArgs: array of string): string;
    function GitFails(const AArgs: array of string): Boolean;
    function Tool(const ATool, AArgs: string): string;
    procedure Commit(const AFile, AText: string);
    function Head: string;
    function Parents(const ARev: string): Integer;
    function ReadFile(const AFile: string): string;
    procedure Diverge(AConflict: Boolean);
    procedure NeedsRebase(const T: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestMergeFastForwardAndNever;
    procedure TestMergeFfOnlyRefusesDivergedBranch;
    procedure TestMergeSquashStagesOnly;
    procedure TestMergeConflictAbort;
    procedure TestMergeConflictResolveAndCommit;
    procedure TestDirtyTreeRefusedButUntrackedIsNot;
    procedure TestOperationInProgressRefused;
    procedure TestRebaseKeepsOtherBranchesAndWarns;
    procedure TestRebaseConflictContinue;
    procedure TestRebaseConflictAbort;
    procedure TestSquashByCountAndSince;
    procedure TestSquashRefusals;
    procedure TestBackupsListedAndDeleted;
    procedure TestResetWarnsAboutPublishedCommits;
    procedure TestResolveRefusals;
    procedure TestConflictOpensReviewPages;
    procedure TestRebaseConflictOpensReviewPages;
  end;

implementation

uses
  Classes, SysUtils, FileUtil, Process, fpjson, jsonparser;

function IsError(const T: string): Boolean;
begin
  Result := (Pos('TOOL ERROR', T) = 1) or (Pos('RPC ERROR', T) = 1) or (Pos('HTTP ', T) = 1);
end;

{ The JSON object of a tool result, with or without the "TOOL ERROR: " in front. }
function ResultObject(const T: string): TJSONObject;
var
  D : TJSONData;
begin
  D := GetJSON(Copy(T, Pos('{', T), MaxInt));
  if not (D is TJSONObject) then
  begin
    D.Free;
    raise Exception.Create('not a JSON object: ' + T);
  end;
  Result := TJSONObject(D);
end;

function ResultStr(const T, AName: string): string;
var
  O : TJSONObject;
begin
  O := ResultObject(T);
  try
    Result := O.Get(AName, '');
  finally
    O.Free;
  end;
end;

{ How many space-separated words S has. }
function WordCount(const S: string): Integer;
var
  Words : TStringList;
begin
  Words := TStringList.Create;
  try
    Words.Delimiter       := ' ';
    Words.StrictDelimiter := True;
    Words.DelimitedText   := Trim(S);
    Result := Words.Count;
  finally
    Words.Free;
  end;
end;

function TTestGitHistory.Git(const AArgs: array of string): string;
var
  O : string;
begin
  if not RunCommandInDir(FDir, 'git', AArgs, O, [poNoConsole], swoHide) then
    Fail('git ' + AArgs[0] + ' failed: ' + O);
  Result := Trim(O);
end;

function TTestGitHistory.GitFails(const AArgs: array of string): Boolean;
var
  O : string;
begin
  Result := not RunCommandInDir(FDir, 'git', AArgs, O, [poNoConsole], swoHide);
end;

function TTestGitHistory.Tool(const ATool, AArgs: string): string;
var
  Extra : string;
begin
  Extra := '"work_dir":' + JsonStr(FDir);
  if AArgs = '' then
    Result := CallToolText(ATool, '{' + Extra + '}', [])
  else
    Result := CallToolText(ATool, '{' + AArgs + ',' + Extra + '}', []);
end;

procedure TTestGitHistory.Commit(const AFile, AText: string);
var
  SL : TStringList;
begin
  SL := TStringList.Create;
  try
    SL.Text := AText;
    SL.SaveToFile(FDir + PathDelim + AFile);
  finally
    SL.Free;
  end;
  Git(['add', AFile]);
  Git(['commit', '-q', '-m', 'edit ' + AFile + ': ' + AText]);
end;

function TTestGitHistory.Head: string;
begin
  Result := Git(['rev-parse', 'HEAD']);
end;

{ How many parents ARev has. }
function TTestGitHistory.Parents(const ARev: string): Integer;
begin
  Result := WordCount(Git(['rev-list', '--parents', '-n', '1', ARev])) - 1;
end;

function TTestGitHistory.ReadFile(const AFile: string): string;
var
  SL : TStringList;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(FDir + PathDelim + AFile);
    Result := Trim(SL.Text);
  finally
    SL.Free;
  end;
end;

procedure TTestGitHistory.SetUp;
var
  O : string;
begin
  { a folder per test, new each run: git's read-only object files can outlive
    DeleteDirectory on Windows }
  FBase := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'mcpgithistory' + PathDelim;
  FDir  := FBase + TestName + IntToStr(GetTickCount64) + PathDelim;
  ForceDirectories(FDir);
  if not RunCommandInDir(FDir, 'git', ['init', '-q'], O, [poNoConsole], swoHide) then
    Ignore('git not usable here: ' + O);
  Git(['symbolic-ref', 'HEAD', 'refs/heads/trunk']);
  Git(['config', 'user.name', 'MCP Test']);
  Git(['config', 'user.email', 'mcp@test.invalid']);
  Git(['config', 'core.autocrlf', 'false']);
  { the hostile configuration: none of it may change what the tools do }
  Git(['config', 'merge.ff', 'only']);
  Git(['config', 'pull.rebase', 'true']);
  Git(['config', 'rebase.updateRefs', 'true']);
  Git(['config', 'rebase.autoSquash', 'true']);
  Git(['config', 'init.defaultBranch', 'trunk']);
  Commit('a.txt', 'base');
end;

procedure TTestGitHistory.TearDown;
begin
  DeleteDirectory(FDir, False);
end;

{ trunk and feature each have commits of their own after the base; with AConflict both
  change a.txt, else feature adds f.txt and trunk adds t.txt.  Ends on trunk. }
procedure TTestGitHistory.Diverge(AConflict: Boolean);
begin
  Git(['checkout', '-q', '-b', 'feature']);
  if AConflict then
    Commit('a.txt', 'feature')
  else
    Commit('f.txt', 'feature');
  Git(['checkout', '-q', 'trunk']);
  if AConflict then
    Commit('a.txt', 'trunk')
  else
    Commit('t.txt', 'trunk');
end;

procedure TTestGitHistory.NeedsRebase(const T: string);
begin
  if Pos('needs git', T) > 0 then
    Ignore(T);
end;

procedure TTestGitHistory.TestMergeFastForwardAndNever;
var
  T : string;
begin
  Git(['checkout', '-q', '-b', 'ahead']);
  Commit('f.txt', 'ahead');
  Git(['checkout', '-q', 'trunk']);

  { merge.ff=only is in the configuration: the tool says auto, and a fast-forward it is }
  T := Tool('git_merge', '"ref":"ahead"');
  CheckFalse(IsError(T), T);
  CheckEquals('ok', ResultStr(T, 'status'), T);
  CheckEquals(Git(['rev-parse', 'ahead']), Head, 'fast-forwarded');
  CheckTrue(Pos('refs/mcp-backup/trunk/', ResultStr(T, 'backup')) = 1, 'a backup ref was made: ' + T);

  Git(['checkout', '-q', '-b', 'more']);
  Commit('g.txt', 'more');
  Git(['checkout', '-q', 'trunk']);
  T := Tool('git_merge', '"ref":"more","ff":"never"');
  CheckEquals('ok', ResultStr(T, 'status'), T);
  CheckEquals(2, Parents('HEAD'), 'ff=never: a merge commit even where a fast-forward was possible');
end;

procedure TTestGitHistory.TestMergeFfOnlyRefusesDivergedBranch;
var
  T, Before : string;
begin
  Diverge(False);
  Before := Head;
  T := Tool('git_merge', '"ref":"feature","ff":"only"');
  CheckTrue(IsError(T), 'git refuses: ' + T);
  CheckEquals('error', ResultStr(T, 'status'), T);
  CheckEquals(Before, Head, 'and nothing moved');
  CheckTrue(Pos('--ff-only', ResultStr(T, 'command')) > 0, 'the command shows what was asked: ' + T);
end;

procedure TTestGitHistory.TestMergeSquashStagesOnly;
var
  T, Before : string;
begin
  Diverge(False);
  Before := Head;
  T := Tool('git_merge', '"ref":"feature","squash":true');
  CheckEquals('ok', ResultStr(T, 'status'), T);
  CheckEquals(Before, Head, 'nothing is committed');
  CheckTrue(Pos('f.txt', Git(['diff', '--cached', '--name-only'])) > 0, 'the change is staged');
  CheckTrue(Pos('git_commit', ResultStr(T, 'warning')) > 0, 'says what to do: ' + T);
end;

procedure TTestGitHistory.TestMergeConflictAbort;
var
  T, Before : string;
begin
  Diverge(True);
  Before := Head;
  T := Tool('git_merge', '"ref":"feature"');
  CheckFalse(IsError(T), 'a conflict is an outcome, not a failure: ' + T);
  CheckEquals('conflict', ResultStr(T, 'status'), T);
  CheckTrue(Pos('a.txt', T) > 0, 'names the file: ' + T);
  CheckTrue(Pos('git_merge_abort', ResultStr(T, 'next')) > 0, 'and the way out: ' + T);
  CheckTrue(Pos('|||||||', ReadFile('a.txt')) > 0, 'diff3 markers: the base is in them');

  T := Tool('git_merge_abort', '');
  CheckFalse(IsError(T), T);
  CheckEquals(Before, Head, 'back where it was');
  CheckEquals('trunk', ReadFile('a.txt'), 'the file too');
  T := Tool('git_merge_abort', '');
  CheckTrue(IsError(T), 'nothing left to abort: ' + T);
end;

procedure TTestGitHistory.TestMergeConflictResolveAndCommit;
var
  T : string;
begin
  Diverge(True);
  T := Tool('git_merge', '"ref":"feature"');
  CheckEquals('conflict', ResultStr(T, 'status'), T);

  T := Tool('git_resolve', '"file":"a.txt","side":"theirs"');
  CheckFalse(IsError(T), T);
  CheckEquals('feature', ReadFile('a.txt'), 'theirs is the merged branch');
  CheckEquals('', Git(['diff', '--name-only', '--diff-filter=U']), 'nothing is unmerged any more');

  T := Tool('git_commit', '"message":"merge feature"');
  CheckFalse(IsError(T), T);
  CheckEquals(2, Parents('HEAD'), 'the merge is finished');
end;

procedure TTestGitHistory.TestDirtyTreeRefusedButUntrackedIsNot;
var
  T : string;
  SL : TStringList;
begin
  Diverge(False);
  SL := TStringList.Create;
  try
    SL.Text := 'untracked';
    SL.SaveToFile(FDir + PathDelim + 'new.txt');
    SL.Text := 'changed';
    SL.SaveToFile(FDir + PathDelim + 'a.txt');
  finally
    SL.Free;
  end;
  T := Tool('git_merge', '"ref":"feature"');
  CheckTrue(IsError(T), T);
  CheckTrue(Pos('a.txt', T) > 0, 'names the dirty file: ' + T);
  CheckFalse(Pos('new.txt', T) > 0, 'an untracked file is not in the way: ' + T);
  CheckEquals('', Git(['for-each-ref', 'refs/mcp-backup']), 'refused before the backup');

  Git(['checkout', '-q', '--', 'a.txt']);
  T := Tool('git_merge', '"ref":"feature","ff":"never"');
  CheckEquals('ok', ResultStr(T, 'status'), 'with the untracked file still there: ' + T);
end;

procedure TTestGitHistory.TestOperationInProgressRefused;
var
  T : string;
begin
  Diverge(True);
  T := Tool('git_merge', '"ref":"feature"');
  CheckEquals('conflict', ResultStr(T, 'status'), T);

  T := Tool('git_squash', '"count":2,"message":"x"');
  CheckTrue(IsError(T) and (Pos('git_merge_abort', T) > 0), 'names the way out: ' + T);
  T := Tool('git_rebase', '"upstream":"trunk"');
  CheckTrue(IsError(T), T);
  T := Tool('git_rebase_continue', '');
  CheckTrue(IsError(T) and (Pos('No rebase', T) > 0), 'no rebase to continue: ' + T);
  Tool('git_merge_abort', '');
end;

procedure TTestGitHistory.TestRebaseKeepsOtherBranchesAndWarns;
var
  T, Mid, Before : string;
begin
  Diverge(False);
  Git(['checkout', '-q', 'feature']);
  Commit('f2.txt', 'second');
  { a branch inside the range: rebase.updateRefs=true would move it }
  Git(['branch', 'mid', 'HEAD~1']);
  Mid := Git(['rev-parse', 'mid']);
  Before := Head;
  { feature is published }
  Git(['update-ref', 'refs/remotes/hub/feature', 'HEAD']);

  T := Tool('git_rebase', '"upstream":"trunk"');
  NeedsRebase(T);
  CheckFalse(IsError(T), T);
  CheckEquals('ok', ResultStr(T, 'status'), T);
  CheckTrue(Before <> Head, 'the branch moved');
  CheckEquals(1, Parents('HEAD'), 'linear');
  CheckFalse(GitFails(['merge-base', '--is-ancestor', 'trunk', 'HEAD']), 'on top of trunk');
  CheckEquals(Mid, Git(['rev-parse', 'mid']), 'mid stayed: --no-update-refs');
  CheckTrue(Pos('hub/feature', ResultStr(T, 'warning')) > 0, 'warned that commits were published: ' + T);
  CheckTrue(Pos('--no-update-refs', ResultStr(T, 'command')) > 0, 'pinned: ' + T);
  CheckEquals(Before, Git(['rev-parse', ResultStr(T, 'backup')]), 'the backup is where the branch was');
end;

procedure TTestGitHistory.TestRebaseConflictContinue;
var
  T : string;
begin
  Diverge(True);
  Git(['checkout', '-q', 'feature']);
  T := Tool('git_rebase', '"upstream":"trunk"');
  NeedsRebase(T);
  CheckEquals('conflict', ResultStr(T, 'status'), T);
  CheckTrue(Pos('a.txt', T) > 0, T);
  CheckTrue(Pos('git_rebase_continue', ResultStr(T, 'next')) > 0, T);

  T := Tool('git_rebase_continue', '');
  CheckTrue(IsError(T) and (Pos('a.txt', T) > 0), 'refused while a file is unmerged: ' + T);

  { git swaps the sides in a rebase: ours and theirs would mislead }
  T := Tool('git_resolve', '"file":"a.txt","side":"ours"');
  CheckTrue(IsError(T), T);
  { the commit's own side, so the replayed commit still has a change to make }
  T := Tool('git_resolve', '"file":"a.txt","side":"commit"');
  CheckFalse(IsError(T), T);
  CheckEquals('feature', ReadFile('a.txt'), 'commit is the one being replayed');

  T := Tool('git_rebase_continue', '');
  CheckEquals('ok', ResultStr(T, 'status'), T);
  CheckEquals('feature', Git(['rev-parse', '--abbrev-ref', 'HEAD']), 'back on the branch');
  CheckFalse(GitFails(['merge-base', '--is-ancestor', 'trunk', 'HEAD']), 'on top of trunk');
end;

procedure TTestGitHistory.TestRebaseConflictAbort;
var
  T, Before : string;
begin
  Diverge(True);
  Git(['checkout', '-q', 'feature']);
  Before := Head;
  T := Tool('git_rebase', '"upstream":"trunk"');
  NeedsRebase(T);
  CheckEquals('conflict', ResultStr(T, 'status'), T);

  T := Tool('git_resolve', '"file":"a.txt","side":"upstream"');
  CheckFalse(IsError(T), 'upstream is what is rebased onto: ' + T);
  CheckEquals('trunk', ReadFile('a.txt'));

  T := Tool('git_rebase_abort', '');
  CheckFalse(IsError(T), T);
  CheckEquals(Before, Head, 'the branch is as it was');
  CheckEquals('feature', Git(['rev-parse', '--abbrev-ref', 'HEAD']));
end;

procedure TTestGitHistory.TestSquashByCountAndSince;
var
  T, Old, Tree : string;
begin
  Commit('b.txt', 'one');
  Commit('b.txt', 'two');
  Commit('b.txt', 'three');
  Old  := Head;
  Tree := Git(['rev-parse', 'HEAD^{tree}']);

  T := Tool('git_squash', '"count":3,"message":"all three\nin one"');
  CheckFalse(IsError(T), T);
  CheckEquals('ok', ResultStr(T, 'status'), T);
  CheckEquals(Tree, Git(['rev-parse', 'HEAD^{tree}']), 'the files are as they were');
  CheckEquals('2', Git(['rev-list', '--count', 'HEAD']), 'base and the squashed commit');
  CheckTrue(Pos('in one', Git(['log', '-1', '--format=%B'])) > 0, 'the message');
  CheckEquals(Old, Git(['rev-parse', ResultStr(T, 'backup')]), 'one git_reset to the backup undoes it');

  Commit('c.txt', 'one');
  Commit('c.txt', 'two');
  T := Tool('git_squash', '"since":"HEAD~2","message":"two as one"');
  CheckEquals('ok', ResultStr(T, 'status'), T);
  CheckEquals('3', Git(['rev-list', '--count', 'HEAD']), 'since stays, what follows is one');
end;

procedure TTestGitHistory.TestSquashRefusals;
var
  T : string;
begin
  Commit('b.txt', 'one');
  T := Tool('git_squash', '"message":"x"');
  CheckTrue(IsError(T) and (Pos('count', T) > 0), 'needs count or since: ' + T);
  T := Tool('git_squash', '"count":1,"message":"x"');
  CheckTrue(IsError(T), 'one commit is nothing to squash: ' + T);
  T := Tool('git_squash', '"count":9,"message":"x"');
  CheckTrue(IsError(T) and (Pos('fewer', T) > 0), 'not that many commits: ' + T);
  T := Tool('git_squash', '"count":2');
  CheckTrue(IsError(T) and (Pos('message', T) > 0), 'needs a message: ' + T);

  Git(['checkout', '-q', '-b', 'side']);
  Commit('s.txt', 'side');
  Git(['checkout', '-q', 'trunk']);
  Commit('b.txt', 'two');
  Git(['merge', '-q', '--no-ff', '-m', 'merge', 'side']);
  T := Tool('git_squash', '"count":2,"message":"x"');
  CheckTrue(IsError(T) and (Pos('merge commit', T) > 0), 'a merge in the range: ' + T);
  CheckEquals('', Git(['for-each-ref', 'refs/mcp-backup']), 'no backup for a refusal');
end;

procedure TTestGitHistory.TestBackupsListedAndDeleted;
var
  T : string;
begin
  Commit('b.txt', 'one');
  Commit('b.txt', 'two');
  T := Tool('git_squash', '"count":2,"message":"x"');
  CheckEquals('ok', ResultStr(T, 'status'), T);

  T := Tool('git_branches', '"backups":true');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('refs/mcp-backup/trunk/', T) > 0, 'listed: ' + T);
  T := Tool('git_branches', '');
  CheckFalse(Pos('mcp-backup', T) > 0, 'the plain listing has none of them: ' + T);

  T := Tool('git_branches', '"delete_backups":30');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('refs/mcp-backup/trunk/', T) > 0, 'a new one is not older than 30 days: ' + T);
  T := Tool('git_branches', '"delete_backups":0');
  CheckFalse(IsError(T), T);
  CheckEquals('', Git(['for-each-ref', 'refs/mcp-backup']), 'all deleted');
end;

procedure TTestGitHistory.TestResetWarnsAboutPublishedCommits;
var
  T : string;
begin
  Commit('b.txt', 'one');
  Commit('b.txt', 'two');
  Git(['update-ref', 'refs/remotes/hub/trunk', 'HEAD']);

  T := Tool('git_reset', '"target":"HEAD~1","mode":"soft"');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('hub/trunk', ResultStr(T, 'warning')) > 0, 'warned: ' + T);
  { a commit nobody has: dropping it is nothing to warn about }
  Git(['commit', '-q', '-m', 'three']);
  T := Tool('git_reset', '"target":"HEAD~1","mode":"soft"');
  CheckFalse(IsError(T), T);
  CheckEquals('', ResultStr(T, 'warning'), 'this commit was never pushed: ' + T);
end;

procedure TTestGitHistory.TestResolveRefusals;
var
  T : string;
begin
  Diverge(True);
  T := Tool('git_resolve', '"file":"a.txt","side":"ours"');
  CheckTrue(IsError(T) and (Pos('Not a conflicted file', T) > 0), 'nothing is in conflict: ' + T);

  Tool('git_merge', '"ref":"feature"');
  T := Tool('git_resolve', '"file":"../outside.txt","side":"ours"');
  CheckTrue(IsError(T), 'only what git lists as conflicted: ' + T);
  T := Tool('git_resolve', '"file":"a.txt","side":"upstream"');
  CheckTrue(IsError(T), 'upstream is for a rebase: ' + T);
  T := Tool('git_resolve', '"file":"a.txt","side":"whatever"');
  CheckTrue(IsError(T), T);
  Tool('git_merge_abort', '');
end;

{ The result of a conflict says which files wait in the Review window and which are not a
  text merge (ADR-028).  The window is opened in the IDE; nobody presses its buttons here. }
procedure TTestGitHistory.TestConflictOpensReviewPages;
var
  T, Before : string;
  Obj, Review : TJSONObject;
  Files, Undecided : TJSONArray;
begin
  Commit('d.txt', 'base');
  Git(['checkout', '-q', '-b', 'feature']);
  Commit('a.txt', 'feature');
  Commit('d.txt', 'changed by feature');
  Git(['checkout', '-q', 'trunk']);
  Commit('a.txt', 'trunk');
  Git(['rm', '-q', 'd.txt']);
  Git(['commit', '-q', '-m', 'remove d.txt']);
  Before := Head;

  T := Tool('git_merge', '"ref":"feature"');
  CheckEquals('conflict', ResultStr(T, 'status'), T);
  Obj := ResultObject(T);
  try
    Review := Obj.Objects['review'];
    Files := Review.Arrays['files'];
    Undecided := Review.Arrays['needs_decision'];
    CheckEquals(1, Files.Count, 'the text file is in the window: ' + T);
    CheckEquals('a.txt', Files.Strings[0]);
    CheckEquals(1, Undecided.Count, 'the file one side deleted is not: ' + T);
    CheckEquals('d.txt', Undecided.Objects[0].Strings['file']);
    CheckTrue(Pos('deleted', Undecided.Objects[0].Strings['reason']) > 0, T);
    CheckTrue(Pos('Review window', Obj.Strings['next']) > 0, 'the next steps name it: ' + T);
  finally
    Obj.Free;
  end;

  { the page of a file git_resolve settled leaves the window; nothing here can tell,
    but the tool must still answer }
  T := Tool('git_resolve', '"file":"a.txt","side":"ours"');
  CheckFalse(IsError(T), T);
  T := Tool('git_merge_abort', '');
  CheckFalse(IsError(T), T);
  CheckEquals(Before, Head, 'aborted');
end;

procedure TTestGitHistory.TestRebaseConflictOpensReviewPages;
var
  T : string;
  Obj : TJSONObject;
begin
  Diverge(True);
  Git(['checkout', '-q', 'feature']);
  T := Tool('git_rebase', '"upstream":"trunk"');
  NeedsRebase(T);
  CheckEquals('conflict', ResultStr(T, 'status'), T);
  Obj := ResultObject(T);
  try
    CheckEquals(1, Obj.Objects['review'].Arrays['files'].Count, T);
  finally
    Obj.Free;
  end;
  T := Tool('git_rebase_abort', '');
  CheckFalse(IsError(T), T);
end;

initialization
  RegisterTest(TTestGitHistory);

end.
