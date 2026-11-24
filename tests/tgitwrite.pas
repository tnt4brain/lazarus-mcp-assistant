{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TGitWrite;

{ TTestGitWrite — the git tools that change a repository: git_checkout, git_reset,
  git_stash (push, pop), with git_branches and git_log.  Each test works in a throwaway
  repository in the temp folder (two commits, a.txt "one" then "two"); the results are
  checked with git itself.  Requires a running MCP server and git.
  Needs nothing from the IDE's project. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, THttpHelper;

type
  TTestGitWrite = class(TTestCase)
  private
    FDir : string;
    function Git(const AArgs: array of string): string;
    function Tool(const ATool, AArgs: string): string;
    function ReadA: string;
    procedure WriteA(const AText: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestCheckoutFileRestores;
    procedure TestCheckoutBranchAndBranches;
    procedure TestCheckoutCreatesBranch;
    procedure TestResetMixedUnstages;
    procedure TestResetSoftKeepsStaged;
    procedure TestStashAndPop;
    procedure TestStashPaths;
    procedure TestCommitAmend;
    procedure TestBranchDelete;
    procedure TestCherryPick;
    procedure TestArchive;
    procedure TestLog;
    procedure TestInitCreatesRepository;
    procedure TestInitKeepsExistingGitignore;
    procedure TestInitRefusedInsideRepository;
    procedure TestCloneRefusesBadArguments;
  end;

implementation

uses
  Classes, SysUtils, FileUtil, Process;

function IsError(const T: string): Boolean;
begin
  Result := (Pos('TOOL ERROR', T) = 1) or (Pos('RPC ERROR', T) = 1) or (Pos('HTTP ', T) = 1);
end;

function TTestGitWrite.Git(const AArgs: array of string): string;
var
  O : string;
begin
  if not RunCommandInDir(FDir, 'git', AArgs, O, [poNoConsole], swoHide) then
    Fail('git ' + AArgs[0] + ' failed: ' + O);
  Result := O;
end;

function TTestGitWrite.Tool(const ATool, AArgs: string): string;
var
  Extra : string;
begin
  Extra := '"work_dir":' + JsonStr(FDir);
  if AArgs = '' then
    Result := CallToolText(ATool, '{' + Extra + '}', [])
  else
    Result := CallToolText(ATool, '{' + AArgs + ',' + Extra + '}', []);
end;

function TTestGitWrite.ReadA: string;
var
  SL : TStringList;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(FDir + PathDelim + 'a.txt');
    Result := Trim(SL.Text);
  finally
    SL.Free;
  end;
end;

procedure TTestGitWrite.WriteA(const AText: string);
var
  SL : TStringList;
begin
  SL := TStringList.Create;
  try
    SL.Text := AText;
    SL.SaveToFile(FDir + PathDelim + 'a.txt');
  finally
    SL.Free;
  end;
end;

procedure TTestGitWrite.SetUp;
var
  O : string;
begin
  { a folder per test, new each run: git's read-only object files can outlive
    DeleteDirectory on Windows }
  FDir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'mcpgitwrite' + PathDelim +
          TestName + IntToStr(GetTickCount64) + PathDelim;
  ForceDirectories(FDir);
  if not RunCommandInDir(FDir, 'git', ['init', '-q'], O, [poNoConsole], swoHide) then
    Ignore('git not usable here: ' + O);
  Git(['config', 'user.name', 'MCP Test']);
  Git(['config', 'user.email', 'mcp@test.invalid']);
  Git(['config', 'core.autocrlf', 'false']);
  WriteA('one');
  Git(['add', 'a.txt']);
  Git(['commit', '-q', '-m', 'first']);
  WriteA('two');
  Git(['commit', '-q', '-a', '-m', 'second']);
end;

procedure TTestGitWrite.TearDown;
begin
  DeleteDirectory(FDir, False);
end;

procedure TTestGitWrite.TestCheckoutFileRestores;
var
  T : string;
begin
  WriteA('dirty');
  T := Tool('git_checkout', '"target":"a.txt"');
  CheckFalse(IsError(T), T);
  CheckEquals('two', ReadA, 'the file is back as committed');
end;

procedure TTestGitWrite.TestCheckoutBranchAndBranches;
var
  T : string;
begin
  Git(['branch', 'feature']);
  T := Tool('git_branches', '');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('feature', T) > 0, 'lists the branch: ' + T);
  T := Tool('git_checkout', '"target":"feature"');
  CheckFalse(IsError(T), T);
  CheckEquals('feature', Trim(Git(['rev-parse', '--abbrev-ref', 'HEAD'])), 'on the branch');
  T := Tool('git_checkout', '"target":"no-such-branch"');
  CheckTrue(IsError(T) or (Pos('error', LowerCase(T)) > 0) or (Pos('did not match', T) > 0),
    'an unknown target is reported: ' + T);
end;

procedure TTestGitWrite.TestCheckoutCreatesBranch;
var
  T : string;
begin
  T := Tool('git_checkout', '"target":"topic","create":true');
  CheckFalse(IsError(T), T);
  CheckEquals('topic', Trim(Git(['rev-parse', '--abbrev-ref', 'HEAD'])), 'on the new branch');
  { from a start point: HEAD~1 holds the first version of the file }
  T := Tool('git_checkout', '"target":"old","create":true,"start_point":"HEAD~1"');
  CheckFalse(IsError(T), T);
  CheckEquals('one', ReadA, 'the branch starts at the start point');
  { an existing name is refused, the branch stays }
  T := Tool('git_checkout', '"target":"topic","create":true');
  CheckTrue(IsError(T) or (Pos('already exists', T) > 0), 'existing name refused: ' + T);
  CheckEquals('old', Trim(Git(['rev-parse', '--abbrev-ref', 'HEAD'])), 'still on old');
  { names that would be read as options or hold spaces never reach git }
  T := Tool('git_checkout', '"target":"-f","create":true');
  CheckTrue(Pos('Invalid', T) > 0, T);
  T := Tool('git_checkout', '"target":"a b","create":true');
  CheckTrue(Pos('Invalid', T) > 0, T);
end;

procedure TTestGitWrite.TestResetMixedUnstages;
var
  T : string;
begin
  WriteA('three');
  Git(['add', 'a.txt']);
  CheckTrue(Pos('M  a.txt', Git(['status', '--short'])) > 0, 'staged first');
  T := Tool('git_reset', '"target":"HEAD"');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos(' M a.txt', Git(['status', '--short'])) > 0, 'unstaged, change kept');
  CheckEquals('three', ReadA, 'working tree untouched');
end;

procedure TTestGitWrite.TestResetSoftKeepsStaged;
var
  T : string;
begin
  T := Tool('git_reset', '"target":"HEAD~1","mode":"soft"');
  CheckFalse(IsError(T), T);
  CheckEquals('first', Trim(Git(['log', '-1', '--format=%s'])), 'HEAD moved back');
  CheckTrue(Pos('M  a.txt', Git(['status', '--short'])) > 0, 'the second commit''s change is staged');
  CheckEquals('two', ReadA, 'working tree untouched');
end;

procedure TTestGitWrite.TestStashAndPop;
var
  T : string;
begin
  WriteA('dirty');
  T := Tool('git_stash', '"message":"wip"');
  CheckFalse(IsError(T), T);
  CheckEquals('two', ReadA, 'the change is stashed away');
  CheckTrue(Pos('wip', Git(['stash', 'list'])) > 0, 'with its message');
  T := Tool('git_stash', '"action":"pop","message":"x"');
  CheckTrue(IsError(T), 'push-only argument with pop is refused: ' + T);
  T := Tool('git_stash', '"action":"pop"');
  CheckFalse(IsError(T), T);
  CheckEquals('dirty', ReadA, 'and back');
  CheckEquals('', Trim(Git(['stash', 'list'])), 'the stash is used up');
  { the old name works through 1.x (ADR-031) }
  T := Tool('git_stash', '"message":"again"');
  CheckFalse(IsError(T), T);
  T := Tool('git_stash', '"action":"push","index":1');
  CheckTrue(IsError(T), 'pop-only argument with push is refused: ' + T);
  T := Tool('git_stash_pop', '');
  CheckFalse(IsError(T), T);
  CheckEquals('dirty', ReadA, 'old git_stash_pop');
end;

procedure TTestGitWrite.TestStashPaths;
var
  T  : string;
  SL : TStringList;
  B  : string;
begin
  B := FDir + 'b.txt';
  SL := TStringList.Create;
  try
    SL.Text := 'b1';
    SL.SaveToFile(B);
    Git(['add', 'b.txt']);
    Git(['commit', '-q', '-m', 'add b']);
    SL.Text := 'b2';
    SL.SaveToFile(B);
    WriteA('dirty');
    T := Tool('git_stash', '"paths":["a.txt"]');
    CheckFalse(IsError(T), T);
    CheckEquals('two', ReadA, 'a.txt is stashed away');
    SL.LoadFromFile(B);
    CheckEquals('b2', Trim(SL.Text), 'b.txt keeps its change');
    Git(['stash', 'pop', '-q']);
    CheckEquals('dirty', ReadA, 'the stash holds a.txt only');
    { a path that starts with - is a path, never an option }
    T := Tool('git_stash', '"paths":["--all"]');
    CheckTrue(IsError(T) or (Pos('pathspec', T) > 0) or (Pos('error', LowerCase(T)) > 0), T);
  finally
    SL.Free;
  end;
end;

procedure TTestGitWrite.TestCommitAmend;
var
  T, Before : string;
begin
  Before := Trim(Git(['rev-list', '--count', 'HEAD']));
  WriteA('three');
  Git(['add', 'a.txt']);
  T := Tool('git_commit', '"amend":true,"message":"two, reworded"');
  CheckFalse(IsError(T), T);
  CheckEquals(Before, Trim(Git(['rev-list', '--count', 'HEAD'])), 'no new commit');
  CheckEquals('two, reworded', Trim(Git(['log', '-1', '--format=%s'])), 'new message');
  CheckEquals('three', Trim(Git(['show', 'HEAD:a.txt'])), 'the staged change is in it');
  { no message: the old one stays }
  WriteA('four');
  Git(['add', 'a.txt']);
  T := Tool('git_commit', '"amend":true');
  CheckFalse(IsError(T), T);
  CheckEquals('two, reworded', Trim(Git(['log', '-1', '--format=%s'])), 'message kept');
  CheckEquals('four', Trim(Git(['show', 'HEAD:a.txt'])), 'with the second change');
  { without amend a message is still needed }
  T := Tool('git_commit', '');
  CheckTrue(IsError(T), 'a plain commit needs a message: ' + T);
  { a commit a remote branch holds is not rewritten }
  Git(['update-ref', 'refs/remotes/origin/main', 'HEAD']);
  WriteA('five');
  Git(['add', 'a.txt']);
  T := Tool('git_commit', '"amend":true,"message":"nope"');
  CheckTrue(IsError(T) and (Pos('remote branch', T) > 0), 'refused: ' + T);
  CheckEquals('two, reworded', Trim(Git(['log', '-1', '--format=%s'])), 'history untouched');
end;

procedure TTestGitWrite.TestBranchDelete;
var
  T, Main : string;
begin
  Main := Trim(Git(['rev-parse', '--abbrev-ref', 'HEAD']));
  { merged: gone }
  Git(['branch', 'done']);
  T := Tool('git_branch_delete', '"branch":"done"');
  CheckFalse(IsError(T), T);
  CheckEquals('', Trim(Git(['branch', '--list', 'done'])), 'the merged branch is deleted');
  { not merged: kept, and no force option }
  Git(['checkout', '-q', '-b', 'work']);
  WriteA('work');
  Git(['commit', '-q', '-am', 'only on work']);
  Git(['checkout', '-q', Main]);
  T := Tool('git_branch_delete', '"branch":"work"');
  CheckTrue(IsError(T), 'refused: ' + T);
  CheckTrue(Trim(Git(['branch', '--list', 'work'])) <> '', 'the unmerged branch stays');
  { the checked-out branch stays too }
  T := Tool('git_branch_delete', '"branch":' + JsonStr(Main));
  CheckTrue(IsError(T), 'current branch refused: ' + T);
  { a name that is an option is no name }
  T := Tool('git_branch_delete', '"branch":"-D"');
  CheckTrue(IsError(T), 'option refused: ' + T);
  CheckTrue(Trim(Git(['branch', '--list', 'work'])) <> '', 'still there');
end;

procedure TTestGitWrite.TestCherryPick;
var
  T, Main, Hash : string;
  SL : TStringList;
begin
  Main := Trim(Git(['rev-parse', '--abbrev-ref', 'HEAD']));
  { a commit on another branch that touches a new file: applied here }
  Git(['checkout', '-q', '-b', 'side', 'HEAD~1']);
  SL := TStringList.Create;
  try
    SL.Text := 'extra';
    SL.SaveToFile(FDir + 'b.txt');
  finally
    SL.Free;
  end;
  Git(['add', 'b.txt']);
  Git(['commit', '-q', '-m', 'add b']);
  Hash := Trim(Git(['rev-parse', 'HEAD']));
  Git(['checkout', '-q', Main]);
  T := Tool('git_cherry_pick', '"ref":' + JsonStr(Hash));
  CheckFalse(IsError(T), T);
  CheckTrue(FileExists(FDir + 'b.txt'), 'the file arrived');
  CheckEquals('add b', Trim(Git(['log', '-1', '--format=%s'])), 'one new commit on top');
  { a conflict stops; abort puts everything back }
  Git(['checkout', '-q', '-b', 'clash', 'HEAD~2']);
  WriteA('clash');
  Git(['commit', '-q', '-am', 'clash on a']);
  Hash := Trim(Git(['rev-parse', 'HEAD']));
  Git(['checkout', '-q', Main]);
  T := Tool('git_cherry_pick', '"ref":' + JsonStr(Hash));
  CheckTrue(IsError(T) and (Pos('abort=true', T) > 0), 'stopped on the conflict: ' + T);
  T := Tool('git_cherry_pick', '"abort":true');
  CheckFalse(IsError(T), T);
  CheckEquals('two', ReadA, 'the file is back');
  CheckEquals('', Trim(Git(['status', '--porcelain', '--untracked-files=no'])), 'clean again');
  { an option is no commit }
  T := Tool('git_cherry_pick', '"ref":"--abort"');
  CheckTrue(IsError(T), 'option refused: ' + T);
  T := Tool('git_cherry_pick', '');
  CheckTrue(IsError(T), 'nothing to pick: ' + T);
end;

procedure TTestGitWrite.TestArchive;
var
  T, Out_, Listing : string;
begin
  Out_ := FDir + 'out.tar';
  T := Tool('git_archive', '"output":' + JsonStr(Out_) + ',"prefix":"pkg"');
  CheckFalse(IsError(T), T);
  CheckTrue(FileExists(Out_), 'archive written');
  if RunCommandInDir(FDir, 'tar', ['-tf', Out_], Listing, [poNoConsole], swoHide) then
    CheckTrue(Pos('pkg/a.txt', StringReplace(Listing, '\', '/', [rfReplaceAll])) > 0,
      'prefix and file in the archive: ' + Listing);
  { never overwritten }
  T := Tool('git_archive', '"output":' + JsonStr(Out_));
  CheckTrue(IsError(T) and (Pos('exists', T) > 0), 'refused: ' + T);
  { a relative path is no output; neither is a ref that is an option }
  T := Tool('git_archive', '"output":"rel.tar"');
  CheckTrue(IsError(T), 'relative refused: ' + T);
  T := Tool('git_archive', '"output":' + JsonStr(FDir + 'x.tar') + ',"ref":"--help"');
  CheckTrue(IsError(T), 'option as ref refused: ' + T);
  CheckFalse(FileExists(FDir + 'x.tar'), 'nothing written');
  { an unknown ref fails and leaves no file }
  T := Tool('git_archive', '"output":' + JsonStr(FDir + 'y.tar') + ',"ref":"nosuchref"');
  CheckTrue(IsError(T), 'unknown ref: ' + T);
end;

procedure TTestGitWrite.TestLog;
var
  T : string;
begin
  T := Tool('git_log', '"limit":1');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('second', T) > 0, T);
  CheckEquals(0, Pos('first', T), 'limit honoured: ' + T);
end;

{ A directory with a file in it, outside the repository of SetUp. }
function PlainDir(const ATest: string; const AFile, AText: string): string;
var
  SL : TStringList;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'mcpgitinit' + PathDelim +
            ATest + IntToStr(GetTickCount64) + PathDelim;
  ForceDirectories(Result);
  SL := TStringList.Create;
  try
    SL.Text := AText;
    SL.SaveToFile(Result + AFile);
  finally
    SL.Free;
  end;
end;

procedure TTestGitWrite.TestInitCreatesRepository;
var
  D, T, O : string;
begin
  D := PlainDir(TestName, 'x.txt', 'keep me');
  T := CallToolText('git_init', '{"work_dir":' + JsonStr(D) +
    ',"initial_branch":"trunk","gitignore":true}', []);
  CheckFalse(IsError(T), T);
  CheckTrue(DirectoryExists(D + '.git'), 'a repository now');
  CheckTrue(RunCommandInDir(D, 'git', ['symbolic-ref', '--short', 'HEAD'], O, [poNoConsole], swoHide), O);
  CheckEquals('trunk', Trim(O), 'the first branch is named');
  CheckFalse(RunCommandInDir(D, 'git', ['rev-parse', '--verify', '-q', 'HEAD'], O, [poNoConsole], swoHide),
    'nothing is committed');
  CheckTrue(FileExists(D + 'x.txt'), 'the files are kept');
  CheckTrue(FileExists(D + '.gitignore'), 'the .gitignore is written');
end;

procedure TTestGitWrite.TestInitKeepsExistingGitignore;
var
  D, T : string;
  SL : TStringList;
begin
  D := PlainDir(TestName, '.gitignore', 'mine');
  T := CallToolText('git_init', '{"work_dir":' + JsonStr(D) + ',"gitignore":true}', []);
  CheckFalse(IsError(T), T);
  SL := TStringList.Create;
  try
    SL.LoadFromFile(D + '.gitignore');
    CheckEquals('mine', Trim(SL.Text), 'an existing .gitignore is not overwritten');
  finally
    SL.Free;
  end;
end;

procedure TTestGitWrite.TestInitRefusedInsideRepository;
var
  T : string;
begin
  T := Tool('git_init', '');
  CheckTrue(IsError(T), 'refused in a repository: ' + T);
  CheckTrue(Pos('already inside', T) > 0, T);
end;

{ Everything git_clone refuses before it asks the user.  A clone that gets as
  far as the consent dialog needs a human, so it is not tested here. }
procedure TTestGitWrite.TestCloneRefusesBadArguments;
var
  Fresh, T : string;
begin
  Fresh := FDir + 'new-clone';
  T := CallToolText('git_clone', '{"url":"-oProxyCommand=x","target_dir":' + JsonStr(Fresh) + '}', []);
  CheckTrue(IsError(T) and (Pos('Not a repository address', T) > 0), 'option as address: ' + T);
  T := CallToolText('git_clone', '{"url":"ext::sh -c id","target_dir":' + JsonStr(Fresh) + '}', []);
  CheckTrue(IsError(T) and (Pos('Not a repository address', T) > 0), 'ext transport: ' + T);
  T := CallToolText('git_clone', '{"url":' + JsonStr(FDir) + ',"target_dir":"relative/dir"}', []);
  CheckTrue(IsError(T) and (Pos('absolute', T) > 0), 'relative target: ' + T);
  T := CallToolText('git_clone', '{"url":' + JsonStr(FDir) + ',"target_dir":' + JsonStr(FDir) + '}', []);
  CheckTrue(IsError(T) and (Pos('not an empty folder', T) > 0), 'target with files: ' + T);
  T := CallToolText('git_clone', '{"url":' + JsonStr(FDir) + ',"target_dir":' + JsonStr(Fresh) +
    ',"branch":"--upload-pack=x"}', []);
  CheckTrue(IsError(T) and (Pos('Invalid branch', T) > 0), 'option as branch: ' + T);
  T := CallToolText('git_clone', '{"url":' + JsonStr(FDir) + '}', []);
  CheckTrue(IsError(T), 'target_dir is required: ' + T);
  CheckFalse(DirectoryExists(Fresh), 'nothing was cloned');
end;

end.
