{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TGitRemote;

{ TTestGitRemote — git_remote, git_fetch, git_pull, git_push and git_tag (ADR-028).

  Each test works in a throwaway folder in the temp directory: a bare repository as
  the remote, named "hub" and not "origin", a working repository with two commits on
  a branch called "trunk", and a hostile configuration in that working repository
  (push.default=matching, pull.rebase=true, merge.ff=only, rebase.updateRefs=true,
  rebase.autoSquash=true, init.defaultBranch=trunk) to show that what the tools pin
  on the command line wins over it.

  push, pull and the changes of a remote ask the user in the IDE.  The tests answer
  through the consent test hook, which exists only when the IDE was started with
  MCP_TEST_HOOKS=1; without it the tests that need an answer are ignored.  The
  hook honours a "yes" only for a folder under the temp directory, which is where
  the bare repository is.  A test must never call a tool that asks without having
  armed the hook first: the dialog would wait for a human for 180 s.

  Requires a running MCP server and git. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, THttpHelper, McpUtils;

type
  TTestGitRemote = class(TTestCase)
  private
    FBase  : string;
    FHub   : string;     { the bare repository }
    FWork  : string;     { the repository under test }
    FOther : string;     { a second clone, to make the remote move }
    function Git(const ADir: string; const AArgs: array of string): string;
    function GitFails(const ADir: string; const AArgs: array of string): Boolean;
    function Tool(const ATool, AArgs: string): string;
    procedure Arm(const AAnswer: string; ADialogs: Integer = 1);
    function ConsentCount: Integer;
    function ConsentDetails: string;
    procedure Seed;
    procedure MoveRemote(const AFile: string);
    procedure Commit(const ADir, AFile, AText: string);
    function Head: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestRemoteList;
    procedure TestRemoteAddDeclined;
    procedure TestRemoteChangesApproved;
    procedure TestRemoteBadArgumentsRefusedBeforeAsking;
    procedure TestFetchPinsItsFlags;
    procedure TestFetchUnknownRemote;
    procedure TestSeveralRemotesAreNotGuessed;
    procedure TestPushDeclined;
    procedure TestPushOnlyTheNamedBranch;
    procedure TestPushForceAsksTwice;
    procedure TestForceNeedsAFetchedBranch;
    procedure TestPushNamedTagsOnly;
    procedure TestPullFastForward;
    procedure TestPullDivergedFfOnlyThenMerge;
    procedure TestPullRebase;
    procedure TestPullDeclined;
    procedure TestTagCreateListDelete;
  end;

implementation

uses
  Classes, SysUtils, FileUtil, Process, fpjson, jsonparser;

function IsError(const T: string): Boolean;
begin
  Result := (Pos('TOOL ERROR', T) = 1) or (Pos('RPC ERROR', T) = 1) or (Pos('HTTP ', T) = 1);
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

function TTestGitRemote.Git(const ADir: string; const AArgs: array of string): string;
var
  O : string;
begin
  if not RunCommandInDir(ADir, 'git', AArgs, O, [poNoConsole], swoHide) then
    Fail('git ' + AArgs[0] + ' failed in ' + ADir + ': ' + O);
  Result := Trim(O);
end;

function TTestGitRemote.GitFails(const ADir: string; const AArgs: array of string): Boolean;
var
  O : string;
begin
  Result := not RunCommandInDir(ADir, 'git', AArgs, O, [poNoConsole], swoHide);
end;

function TTestGitRemote.Tool(const ATool, AArgs: string): string;
var
  Extra : string;
begin
  Extra := '"work_dir":' + JsonStr(FWork);
  if AArgs = '' then
    Result := CallToolText(ATool, '{' + Extra + '}', [])
  else
    Result := CallToolText(ATool, '{' + AArgs + ',' + Extra + '}', []);
end;

procedure TTestGitRemote.Arm(const AAnswer: string; ADialogs: Integer);
var
  T : string;
begin
  T := CallToolText('__test_arm_consent__',
    '{"answer":"' + AAnswer + '","dialogs":' + IntToStr(ADialogs) + '}', []);
  if Pos('disabled', T) > 0 then
    Ignore('the IDE was not started with MCP_TEST_HOOKS=1');
  CheckFalse(IsError(T), T);
end;

function TTestGitRemote.ConsentCount: Integer;
var
  T : string;
begin
  T := CallToolText('__test_get_consent__', '{}', []);
  Result := StrToIntDef(Trim(Copy(T, 1, Pos(#10, T + #10) - 1)), -1);
end;

function TTestGitRemote.ConsentDetails: string;
var
  T : string;
begin
  T := CallToolText('__test_get_consent__', '{}', []);
  Result := Copy(T, Pos(#10, T + #10) + 1, MaxInt);
end;

procedure TTestGitRemote.Commit(const ADir, AFile, AText: string);
var
  SL : TStringList;
begin
  SL := TStringList.Create;
  try
    SL.Text := AText;
    SL.SaveToFile(IncludeTrailingPathDelimiter(ADir) + AFile);
  finally
    SL.Free;
  end;
  Git(ADir, ['add', AFile]);
  Git(ADir, ['commit', '-q', '-m', 'edit ' + AFile + ' ' + AText]);
end;

function TTestGitRemote.Head: string;
begin
  Result := Git(FWork, ['rev-parse', 'HEAD']);
end;

procedure TTestGitRemote.SetUp;
var
  O : string;
begin
  { a folder per test, new each run: git's read-only object files can outlive
    DeleteDirectory on Windows }
  FBase := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'mcpgitremote' + PathDelim +
           TestName + IntToStr(GetTickCount64) + PathDelim;
  FHub   := FBase + 'hub.git';
  FWork  := FBase + 'work';
  FOther := FBase + 'other';
  ForceDirectories(FWork);
  if not RunCommandInDir(FBase, 'git', ['init', '--bare', '-q', 'hub.git'], O, [poNoConsole], swoHide) then
    Ignore('git not usable here: ' + O);
  Git(FHub, ['symbolic-ref', 'HEAD', 'refs/heads/trunk']);

  Git(FWork, ['init', '-q']);
  Git(FWork, ['symbolic-ref', 'HEAD', 'refs/heads/trunk']);
  Git(FWork, ['config', 'user.name', 'MCP Test']);
  Git(FWork, ['config', 'user.email', 'mcp@test.invalid']);
  Git(FWork, ['config', 'core.autocrlf', 'false']);
  { the hostile configuration: none of it may change what the tools do }
  Git(FWork, ['config', 'push.default', 'matching']);
  Git(FWork, ['config', 'pull.rebase', 'true']);
  Git(FWork, ['config', 'merge.ff', 'only']);
  Git(FWork, ['config', 'rebase.updateRefs', 'true']);
  Git(FWork, ['config', 'rebase.autoSquash', 'true']);
  Git(FWork, ['config', 'init.defaultBranch', 'trunk']);
  Commit(FWork, 'a.txt', 'one');
  Commit(FWork, 'a.txt', 'two');
  Git(FWork, ['remote', 'add', 'hub', FHub]);
end;

procedure TTestGitRemote.TearDown;
begin
  McpDeleteTree(FBase);
end;

{ The remote has trunk, as the working repository has it. }
procedure TTestGitRemote.Seed;
begin
  Git(FWork, ['push', '-q', 'hub', 'trunk']);
end;

{ Somebody else adds a commit on the remote's trunk. }
procedure TTestGitRemote.MoveRemote(const AFile: string);
begin
  Git(FBase, ['clone', '-q', FHub, 'other']);
  Git(FOther, ['config', 'user.name', 'Somebody Else']);
  Git(FOther, ['config', 'user.email', 'else@test.invalid']);
  Commit(FOther, AFile, 'theirs');
  Git(FOther, ['push', '-q', 'origin', 'HEAD:trunk']);
end;

procedure TTestGitRemote.TestRemoteList;
var
  T : string;
begin
  T := Tool('git_remote', '"action":"list"');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"hub"', T) > 0, 'the remote is named hub: ' + T);
  CheckTrue(Pos('hub.git', T) > 0, 'with its address: ' + T);
end;

procedure TTestGitRemote.TestRemoteAddDeclined;
var
  T : string;
begin
  Arm('no');
  T := Tool('git_remote', '"action":"add","name":"second","url":' + JsonStr(FBase + 'second.git'));
  CheckTrue(IsError(T), 'refused: ' + T);
  CheckTrue(Pos('declined', T) > 0, 'says the user declined: ' + T);
  CheckFalse(Pos('second', Git(FWork, ['remote'])) > 0, 'the remote was not added');
  CheckTrue(Pos('second.git', ConsentDetails) > 0, 'the dialog named the address: ' + ConsentDetails);
end;

procedure TTestGitRemote.TestRemoteChangesApproved;
var
  T : string;
begin
  Git(FBase, ['init', '--bare', '-q', 'second.git']);

  Arm('yes');
  T := Tool('git_remote', '"action":"add","name":"second","url":' + JsonStr(FBase + 'second.git'));
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('second', Git(FWork, ['remote'])) > 0, 'added');

  Arm('yes');
  T := Tool('git_remote', '"action":"set_url","name":"second","url":' + JsonStr(FHub));
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('hub.git', Git(FWork, ['remote', 'get-url', 'second'])) > 0, 'address changed');

  Arm('yes');
  T := Tool('git_remote', '"action":"rename","name":"second","new_name":"third"');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('third', Git(FWork, ['remote'])) > 0, 'renamed');

  Arm('yes');
  T := Tool('git_remote', '"action":"remove","name":"third"');
  CheckFalse(IsError(T), T);
  CheckFalse(Pos('third', Git(FWork, ['remote'])) > 0, 'removed');
end;

{ None of these may reach the dialog: it would wait for a human. }
procedure TTestGitRemote.TestRemoteBadArgumentsRefusedBeforeAsking;
var
  T : string;
begin
  T := Tool('git_remote', '"action":"add","name":"x","url":"-oProxyCommand=x"');
  CheckTrue(IsError(T), 'an option as address: ' + T);
  T := Tool('git_remote', '"action":"add","name":"x","url":"ext::sh -c id"');
  CheckTrue(IsError(T), 'ext:: as address: ' + T);
  T := Tool('git_remote', '"action":"add","name":"--x","url":' + JsonStr(FHub));
  CheckTrue(IsError(T), 'an option as name: ' + T);
  T := Tool('git_remote', '"action":"remove","name":"nope"');
  CheckTrue(IsError(T) and (Pos('hub', T) > 0), 'unknown remote, the known ones listed: ' + T);
  T := Tool('git_remote', '"action":"set_url","name":"hub"');
  CheckTrue(IsError(T), 'set_url without an address: ' + T);
  T := Tool('git_remote', '"action":"explode"');
  CheckTrue(IsError(T), 'unknown action: ' + T);
end;

procedure TTestGitRemote.TestFetchPinsItsFlags;
var
  T : string;
begin
  Seed;
  MoveRemote('b.txt');
  T := Tool('git_fetch', '');
  CheckFalse(IsError(T), T);
  CheckEquals(Git(FHub, ['rev-parse', 'trunk']), Git(FWork, ['rev-parse', 'refs/remotes/hub/trunk']),
    'the remote-tracking branch moved');
  CheckTrue(Pos('--no-tags', ResultStr(T, 'command')) > 0, 'no tags unless asked: ' + T);
  CheckTrue(Pos('--recurse-submodules=no', ResultStr(T, 'command')) > 0, 'pinned: ' + T);
  CheckTrue(Pos('only remote', ResultStr(T, 'note')) > 0, 'says it used the only remote: ' + T);
  CheckEquals(Git(FWork, ['rev-parse', 'trunk']), Head, 'the branch itself did not move');
end;

procedure TTestGitRemote.TestFetchUnknownRemote;
var
  T : string;
begin
  T := Tool('git_fetch', '"remote":"nope"');
  CheckTrue(IsError(T), T);
  CheckTrue(Pos('hub', T) > 0, 'lists the remotes: ' + T);
end;

procedure TTestGitRemote.TestSeveralRemotesAreNotGuessed;
var
  T : string;
begin
  Git(FWork, ['remote', 'add', 'spare', FBase + 'spare.git']);
  T := Tool('git_fetch', '');
  CheckTrue(IsError(T), 'refused: ' + T);
  CheckTrue(Pos('pass remote', T) > 0, 'says what to do: ' + T);
  CheckTrue((Pos('hub', T) > 0) and (Pos('spare', T) > 0), 'lists them: ' + T);
end;

procedure TTestGitRemote.TestPushDeclined;
var
  T : string;
begin
  Arm('no');
  T := Tool('git_push', '');
  CheckTrue(IsError(T), 'refused: ' + T);
  CheckTrue(GitFails(FHub, ['rev-parse', '-q', '--verify', 'trunk']), 'nothing arrived');
  CheckTrue(Pos('hub', ConsentDetails) > 0, 'the dialog named the remote: ' + ConsentDetails);
  CheckTrue(Pos('2 commit(s)', ConsentDetails) > 0, 'and the commits: ' + ConsentDetails);
  CheckTrue(Pos('hub.git', ConsentDetails) > 0, 'and the address: ' + ConsentDetails);
end;

procedure TTestGitRemote.TestPushOnlyTheNamedBranch;
var
  T, SideBefore : string;
begin
  { push.default=matching would send every branch both sides have }
  Git(FWork, ['branch', 'side']);
  Git(FWork, ['push', '-q', 'hub', 'trunk', 'side']);
  SideBefore := Git(FHub, ['rev-parse', 'side']);
  Git(FWork, ['checkout', '-q', 'side']);
  Commit(FWork, 'side.txt', 'side');
  Git(FWork, ['checkout', '-q', 'trunk']);
  Commit(FWork, 'a.txt', 'three');

  Arm('yes');
  T := Tool('git_push', '');
  CheckFalse(IsError(T), T);
  CheckEquals(Head, Git(FHub, ['rev-parse', 'trunk']), 'trunk arrived');
  CheckEquals(SideBefore, Git(FHub, ['rev-parse', 'side']), 'side did not');
  CheckTrue(Pos('refs/heads/trunk:refs/heads/trunk', ResultStr(T, 'command')) > 0,
    'written out in full: ' + T);
  CheckTrue(Pos('--no-follow-tags', ResultStr(T, 'command')) > 0, 'pinned: ' + T);
  CheckTrue(Pos('1 commit(s)', ConsentDetails) > 0, 'the dialog counted: ' + ConsentDetails);
end;

procedure TTestGitRemote.TestPushForceAsksTwice;
var
  T : string;
  Before : Integer;
begin
  Seed;
  MoveRemote('b.txt');
  Git(FWork, ['fetch', '-q', 'hub']);
  Commit(FWork, 'a.txt', 'mine');

  Arm('yes');
  T := Tool('git_push', '');
  CheckTrue(IsError(T), 'git refuses a push that is not a fast-forward: ' + T);
  CheckTrue(Pos('--force', ResultStr(T, 'command')) = 0, 'and the tool did not force it: ' + T);

  Before := ConsentCount;
  Arm('yes', 2);
  T := Tool('git_push', '"force":true');
  CheckFalse(IsError(T), T);
  CheckEquals(Head, Git(FHub, ['rev-parse', 'trunk']), 'the remote branch was overwritten');
  CheckEquals(Before + 2, ConsentCount, 'two questions were asked');
  CheckTrue(Pos('Discards', ConsentDetails) > 0, 'the second one named what goes: ' + ConsentDetails);
  CheckTrue(Pos('theirs', ConsentDetails) > 0, 'with their commit: ' + ConsentDetails);
  CheckTrue(Pos('--force-with-lease=refs/heads/trunk:', ResultStr(T, 'command')) > 0,
    'never a plain --force: ' + T);
end;

procedure TTestGitRemote.TestForceNeedsAFetchedBranch;
var
  T : string;
begin
  T := Tool('git_push', '"force":true');
  CheckTrue(IsError(T), T);
  CheckTrue(Pos('git_fetch', T) > 0, 'says to fetch first: ' + T);
end;

procedure TTestGitRemote.TestPushNamedTagsOnly;
var
  T : string;
begin
  Git(FWork, ['tag', '-a', 'v1', '-m', 'one']);
  Git(FWork, ['tag', 'v2']);
  T := Tool('git_push', '"tag_names":["nope"]');
  CheckTrue(IsError(T) and (Pos('Not a tag', T) > 0), 'refused before asking: ' + T);

  Arm('yes');
  T := Tool('git_push', '"tags":["v1"]');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('v1', Git(FHub, ['tag', '--list'])) > 0, 'v1 arrived');
  CheckFalse(Pos('v2', Git(FHub, ['tag', '--list'])) > 0, 'v2 did not: never all tags');
  CheckTrue(Pos('v1', ConsentDetails) > 0, 'the dialog named the tag: ' + ConsentDetails);
end;

procedure TTestGitRemote.TestPullFastForward;
var
  T, Before : string;
begin
  Seed;
  MoveRemote('b.txt');
  Before := Head;
  Arm('yes');
  T := Tool('git_pull', '"branch":"trunk"');
  CheckFalse(IsError(T), T);
  CheckEquals(Git(FHub, ['rev-parse', 'trunk']), Head, 'fast-forwarded');
  CheckTrue(Before <> Head, 'the head moved');
  CheckTrue(FileExists(FWork + PathDelim + 'b.txt'), 'their file is here');
  CheckTrue(Pos('--ff-only', ResultStr(T, 'command')) > 0, 'ff-only is the default: ' + T);
end;

procedure TTestGitRemote.TestPullDivergedFfOnlyThenMerge;
var
  T, Before : string;
begin
  Seed;
  MoveRemote('b.txt');
  Commit(FWork, 'a.txt', 'mine');
  Before := Head;

  { merge.ff=only and pull.rebase=true in the configuration: the tool says ff-only }
  Arm('yes');
  T := Tool('git_pull', '"branch":"trunk"');
  CheckTrue(IsError(T), 'ff-only fails on a diverged branch: ' + T);
  CheckEquals(Before, Head, 'and changed nothing');

  Arm('yes');
  T := Tool('git_pull', '"branch":"trunk","mode":"merge"');
  CheckFalse(IsError(T), T);
  CheckEquals(3, WordCount(Git(FWork, ['rev-list', '--parents', '-n', '1', 'HEAD'])),
    'a merge commit: the commit and two parents');
end;

procedure TTestGitRemote.TestPullRebase;
var
  T, Theirs : string;
begin
  Seed;
  MoveRemote('b.txt');
  Theirs := Git(FHub, ['rev-parse', 'trunk']);
  Commit(FWork, 'a.txt', 'mine');

  Arm('yes');
  T := Tool('git_pull', '"branch":"trunk","mode":"rebase"');
  CheckFalse(IsError(T), T);
  CheckEquals(2, WordCount(Git(FWork, ['rev-list', '--parents', '-n', '1', 'HEAD'])),
    'a linear history: the commit and one parent');
  CheckFalse(GitFails(FWork, ['merge-base', '--is-ancestor', Theirs, 'HEAD']), 'their commit is below mine');
end;

procedure TTestGitRemote.TestPullDeclined;
var
  T, Before : string;
begin
  Seed;
  MoveRemote('b.txt');
  Before := Head;
  Arm('no');
  T := Tool('git_pull', '"branch":"trunk"');
  CheckTrue(IsError(T), T);
  CheckEquals(Before, Head, 'nothing came in');
  CheckFalse(FileExists(FWork + PathDelim + 'b.txt'), 'no new file');
end;

procedure TTestGitRemote.TestTagCreateListDelete;
var
  T : string;
begin
  T := Tool('git_tag', '"action":"create","name":"v1","message":"line one\nsay \"hi\""');
  CheckFalse(IsError(T), T);
  CheckEquals('tag', Git(FWork, ['cat-file', '-t', 'v1']), 'annotated');
  CheckTrue(Pos('say "hi"', Git(FWork, ['for-each-ref', 'refs/tags/v1', '--format=%(contents)'])) > 0,
    'the message arrived whole, quotes included');

  T := Tool('git_tag', '"action":"create","name":"v2","lightweight":true');
  CheckFalse(IsError(T), T);
  CheckEquals('commit', Git(FWork, ['cat-file', '-t', 'v2']), 'lightweight');

  T := Tool('git_tag', '"action":"list"');
  CheckFalse(IsError(T), T);
  CheckTrue((Pos('"v1"', T) > 0) and (Pos('"v2"', T) > 0), 'both listed: ' + T);

  T := Tool('git_tag', '"action":"create","name":"v1","message":"again"');
  CheckTrue(IsError(T) and (Pos('exists', T) > 0), 'a tag is not moved: ' + T);
  T := Tool('git_tag', '"action":"create","name":"v3"');
  CheckTrue(IsError(T) and (Pos('message', T) > 0), 'annotated needs a message: ' + T);

  T := Tool('git_tag', '"action":"delete","name":"v2"');
  CheckFalse(IsError(T), T);
  CheckFalse(Pos('v2', Git(FWork, ['tag', '--list'])) > 0, 'deleted');
  T := Tool('git_tag', '"action":"delete","name":"v2"');
  CheckTrue(IsError(T), 'deleting what is not there: ' + T);
end;

initialization
  RegisterTest(TTestGitRemote);

end.
