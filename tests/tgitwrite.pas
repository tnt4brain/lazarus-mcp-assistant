{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TGitWrite;

{ TTestGitWrite — the git tools that change a repository: git_checkout, git_reset,
  git_stash, git_stash_pop, with git_branches and git_log.  Each test works in a throwaway
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
    procedure TestResetMixedUnstages;
    procedure TestResetSoftKeepsStaged;
    procedure TestStashAndPop;
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
  if not RunCommandInDir(FDir, 'git', AArgs, O) then
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
  if not RunCommandInDir(FDir, 'git', ['init', '-q'], O) then
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
  T := Tool('git_stash_pop', '');
  CheckFalse(IsError(T), T);
  CheckEquals('dirty', ReadA, 'and back');
  CheckEquals('', Trim(Git(['stash', 'list'])), 'the stash is used up');
end;

procedure TTestGitWrite.TestLog;
var
  T : string;
begin
  T := Tool('git_log', '"max_count":1');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('second', T) > 0, T);
  CheckEquals(0, Pos('first', T), 'max_count honoured: ' + T);
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
  CheckTrue(RunCommandInDir(D, 'git', ['symbolic-ref', '--short', 'HEAD'], O), O);
  CheckEquals('trunk', Trim(O), 'the first branch is named');
  CheckFalse(RunCommandInDir(D, 'git', ['rev-parse', '--verify', '-q', 'HEAD'], O),
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
