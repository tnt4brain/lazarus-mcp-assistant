{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsGitRemote;

{ Git tools for remotes (ADR-028): git_remote, git_fetch, git_pull, git_push, git_tag.

  The rule about consent is about what crosses the boundary of the machine:
    push, pull and any change of a remote's address ask the user, every call;
    fetch from a remote that is already configured, tags and listing do not.
  Nothing is left to git's defaults: every behavior the result depends on is named
  on the command line, and the result carries the exact command that ran.

  fetch, pull and push run on the MCP worker thread (a transfer can take minutes);
  only the dialog and the IDE queries go to the main thread, through a per-call
  object.  git_remote and git_tag run on the main thread. }

{$mode objfpc}{$H+}

interface

uses
  Classes, fpjson, McpToolContext;

{ What the history tools (McpToolsGitHistory) share with these: where git runs, the
  per-call object for the IDE's thread, short queries, the parameters of a call and the
  shape of an answer. }
type
  { where and with what git runs; safe to use on any thread }
  TGit = record
    Exe : string;
    Dir : string;
  end;

  { One per call: the IDE's thread is needed for the executable, the work directory,
    the editors and the dialog.  Per call, not global: two clients can push at once. }
  TMainPart = class
  public
    Call         : TMcpToolCall;
    ToolName     : string;
    CheckEditors : Boolean;
    Git          : TGit;
    Why          : string;
    { the question for Ask }
    Verb, YesCaption, Url, Details : string;
    Approved     : Boolean;
    Reason       : string;
    constructor Create(const ACall: TMcpToolCall; const AToolName: string; ACheckEditors: Boolean);
    procedure Prepare;
    procedure Ask;
  end;

{ A short query (a minute at most); any thread. }
function Query(const G: TGit; const Args: array of string; out AOutput: string): Boolean;
{ The trimmed output of a query, '' when git failed. }
function QueryText(const G: TGit; const Args: array of string): string;
function RefOk(const G: TGit; const ARef: string): Boolean;       { a valid ref name }
function RefExists(const G: TGit; const ARef: string): Boolean;   { a ref that resolves }
function CurrentBranch(const G: TGit): string;                    { '' when HEAD is detached }

function StrParam(const Ctx: TMcpToolCall; const AName: string; const ADefault: string = ''): string;
function BoolParam(const Ctx: TMcpToolCall; const AName: string): Boolean;
{ Sets the refusal when AWhy is not empty. }
function Refused(var Ctx: TMcpToolCall; const AWhy: string): Boolean;
{ Answers with AObj as JSON, an error when not AOk, and frees it. }
procedure Reply(var Ctx: TMcpToolCall; AOk: Boolean; AObj: TJSONObject);
function CommandText(const Args: array of string): string;

implementation

uses
  SysUtils, McpIdeState, McpGitRun, McpConsent;

const
  SCHEMA_GIT_FETCH =
    '{"type":"object","properties":{' +
    '"remote":{"type":"string","description":"Name of a configured remote. Default: the current branch''s remote, or the only remote"},' +
    '"tags":{"type":"boolean","description":"Also fetch all tags (default false: no tags are fetched)"},' +
    '"prune":{"type":"boolean","description":"Delete remote-tracking branches that no longer exist on the remote (default false)"},' +
    '"work_dir":{"type":"string","description":"A directory inside the repository (default: the project''s directory)"}},' +
    '"required":[]}';

  SCHEMA_GIT_PULL =
    '{"type":"object","properties":{' +
    '"remote":{"type":"string","description":"Name of a configured remote. Default: the current branch''s remote, or the only remote"},' +
    '"branch":{"type":"string","description":"The remote branch to take in. Default: the one the current branch tracks"},' +
    '"mode":{"type":"string","enum":["ff-only","merge","rebase"],"description":"ff-only (default): fast-forward or fail. merge: always make a merge commit. rebase: replay your commits on top"},' +
    '"work_dir":{"type":"string","description":"A directory inside the repository (default: the project''s directory)"}},' +
    '"required":[]}';

  SCHEMA_GIT_PUSH =
    '{"type":"object","properties":{' +
    '"remote":{"type":"string","description":"Name of a configured remote. Default: the branch''s remote, or the only remote"},' +
    '"branch":{"type":"string","description":"Local branch to push, to the branch of the same name. Default: the current branch"},' +
    '"force":{"type":"boolean","description":"Overwrite the remote branch (--force-with-lease against what you last fetched). The user is asked a second question that names the commits it would discard"},' +
    '"set_upstream":{"type":"boolean","description":"Make the remote branch the branch''s upstream (default false)"},' +
    '"tags":{"type":"array","items":{"type":"string"},"description":"Names of tags to push as well, one by one (never all tags)"},' +
    '"work_dir":{"type":"string","description":"A directory inside the repository (default: the project''s directory)"}},' +
    '"required":[]}';

  SCHEMA_GIT_REMOTE =
    '{"type":"object","properties":{' +
    '"action":{"type":"string","enum":["list","add","set_url","rename","remove"],"description":"list shows the remotes with the addresses git will use; the others change them and ask the user"},' +
    '"name":{"type":"string","description":"The remote (add, set_url, rename, remove)"},' +
    '"url":{"type":"string","description":"The address (add, set_url): https://, ssh (git@host:path) or a local path"},' +
    '"new_name":{"type":"string","description":"The new name (rename)"},' +
    '"push":{"type":"boolean","description":"set_url: change the address pushes go to, not the one fetches come from"},' +
    '"work_dir":{"type":"string","description":"A directory inside the repository (default: the project''s directory)"}},' +
    '"required":["action"]}';

  SCHEMA_GIT_TAG =
    '{"type":"object","properties":{' +
    '"action":{"type":"string","enum":["list","create","delete"],"description":"Local tags only; pushing one is git_push with tags"},' +
    '"name":{"type":"string","description":"Tag name (create, delete)"},' +
    '"message":{"type":"string","description":"create: the message of the annotated tag (required unless lightweight)"},' +
    '"ref":{"type":"string","description":"create: what to tag (default HEAD)"},' +
    '"lightweight":{"type":"boolean","description":"create: a plain pointer without message or tagger (default false: annotated)"},' +
    '"work_dir":{"type":"string","description":"A directory inside the repository (default: the project''s directory)"}},' +
    '"required":["action"]}';

  { these reach out to the network: openWorldHint }
  MCP_ANN_NET  = '{"readOnlyHint":false,"destructiveHint":false,"openWorldHint":true}';
  MCP_ANN_PUSH = '{"readOnlyHint":false,"destructiveHint":true,"openWorldHint":true}';

  NET_TIMEOUT_MS   = 30 * 60 * 1000;
  QUERY_TIMEOUT_MS = 60 * 1000;
  LISTED_COMMITS   = 10;

{ ── Helpers ──────────────────────────────────────────────────────────────── }

function Query(const G: TGit; const Args: array of string; out AOutput: string): Boolean;
begin
  Result := RunGitTimed(G.Exe, Args, G.Dir, QUERY_TIMEOUT_MS, AOutput);
end;

{ The trimmed output of a query, '' when git failed. }
function QueryText(const G: TGit; const Args: array of string): string;
var
  Output : string;
begin
  if Query(G, Args, Output) then
    Result := Trim(Output)
  else
    Result := '';
end;

function StrParam(const Ctx: TMcpToolCall; const AName: string; const ADefault: string): string;
begin
  if Assigned(Ctx.Params) then
    Result := Trim(Ctx.Params.Get(AName, ADefault))
  else
    Result := ADefault;
end;

function BoolParam(const Ctx: TMcpToolCall; const AName: string): Boolean;
begin
  Result := Assigned(Ctx.Params) and Ctx.Params.Get(AName, False);
end;

{ Sets the refusal when AWhy is not empty. }
function Refused(var Ctx: TMcpToolCall; const AWhy: string): Boolean;
begin
  Result := AWhy <> '';
  if Result then
  begin
    Ctx.Error  := True;
    Ctx.Result := AWhy;
  end;
end;

{ Takes ownership of AObj. }
procedure Reply(var Ctx: TMcpToolCall; AOk: Boolean; AObj: TJSONObject);
begin
  try
    Ctx.Error  := not AOk;
    Ctx.Result := AObj.AsJSON;
  finally
    AObj.Free;
  end;
end;

function CommandText(const Args: array of string): string;
var
  Arg : string;
begin
  Result := 'git';
  for Arg in Args do
    if Pos(' ', Arg) > 0 then
      Result := Result + ' "' + Arg + '"'
    else
      Result := Result + ' ' + Arg;
end;

function DetailLine(const ALabel, AValue: string): string;
begin
  Result := Format('%-14s%s%s', [ALabel + ':', AValue, LineEnding]);
end;

{ An address that starts with - would be read as an option; ext:: runs a command. }
function BadAddress(const AUrl: string): Boolean;
begin
  Result := (AUrl = '') or (AUrl[1] = '-') or (Pos('ext::', LowerCase(AUrl)) = 1) or
            (Pos(#10, AUrl) > 0) or (Pos(#13, AUrl) > 0);
end;

function ValidRemoteName(const AName: string): Boolean;
var
  C : Char;
begin
  if (AName = '') or (AName[1] in ['-', '.']) or (Pos('..', AName) > 0) then
    Exit(False);
  for C in AName do
    if not (C in ['A'..'Z', 'a'..'z', '0'..'9', '_', '-', '.', '/']) then
      Exit(False);
  Result := True;
end;

function RefOk(const G: TGit; const ARef: string): Boolean;
var
  Output : string;
begin
  Result := (ARef <> '') and Query(G, ['check-ref-format', ARef], Output);
end;

function RefExists(const G: TGit; const ARef: string): Boolean;
var
  Output : string;
begin
  Result := Query(G, ['rev-parse', '-q', '--verify', ARef], Output);
end;

function CurrentBranch(const G: TGit): string;
begin
  Result := QueryText(G, ['symbolic-ref', '-q', '--short', 'HEAD']);
end;

function EffectiveUrl(const G: TGit; const ARemote: string; APush: Boolean): string;
begin
  if APush then
    Result := QueryText(G, ['remote', 'get-url', '--push', ARemote])
  else
    Result := QueryText(G, ['remote', 'get-url', ARemote]);
end;

{ The configured remotes; False when git failed (AOutput says why). }
function RemoteNames(const G: TGit; ANames: TStrings; out AOutput: string): Boolean;
begin
  ANames.Clear;
  Result := Query(G, ['remote'], AOutput);
  if Result then
    ANames.Text := Trim(AOutput);
end;

{ Which remote a call talks to: the one asked for, else the branch's own, else the only
  one.  Nothing is assumed: with several and none configured, the call is refused and
  the remotes are listed. }
function ResolveRemote(const G: TGit; const AWanted, ABranch: string;
  out ARemote, ANote, AWhy: string): Boolean;
var
  Names  : TStringList;
  Output : string;
  Own    : string;
begin
  ARemote := '';
  ANote   := '';
  AWhy    := '';
  Names   := TStringList.Create;
  try
    if not RemoteNames(G, Names, Output) then
    begin
      AWhy := 'git could not list the remotes: ' + Trim(Output);
      Exit(False);
    end;

    if AWanted <> '' then
    begin
      if Names.IndexOf(AWanted) < 0 then
      begin
        AWhy := 'No remote named ' + AWanted + '. Remotes: ' + Names.CommaText;
        Exit(False);
      end;
      ARemote := AWanted;
      Exit(True);
    end;

    if ABranch <> '' then
    begin
      Own := QueryText(G, ['config', '--get', 'branch.' + ABranch + '.remote']);
      if Names.IndexOf(Own) >= 0 then
      begin
        ARemote := Own;
        Exit(True);
      end;
    end;

    case Names.Count of
      0: AWhy := 'This repository has no remotes. Add one with git_remote (action add).';
      1:
      begin
        ARemote := Names[0];
        ANote   := 'No remote was given and none is configured for the branch; used the only remote, ' +
                   ARemote + '.';
        Exit(True);
      end;
    else
      AWhy := 'Several remotes and none is configured for the branch: pass remote. Remotes: ' +
              Names.CommaText;
    end;
    Result := False;
  finally
    Names.Free;
  end;
end;

{ The commits a push would send: those of the branch that no remote-tracking branch of
  the remote has. }
procedure SendRange(const G: TGit; const ARemote, ABranch: string; ARange: TStrings);
var
  Tracking : string;
begin
  ARange.Clear;
  Tracking := 'refs/remotes/' + ARemote + '/' + ABranch;
  if RefExists(G, Tracking) then
    ARange.Add(Tracking + '..refs/heads/' + ABranch)
  else
  begin
    ARange.Add('refs/heads/' + ABranch);
    ARange.Add('--not');
    ARange.Add('--remotes=' + ARemote);
  end;
end;

{ "3 commit(s)", then the first lines of them, for the dialog. }
function CommitsText(const G: TGit; ARange: TStrings): string;
var
  Args   : TStringList;
  Output : string;
  Count  : Integer;
begin
  Args := TStringList.Create;
  try
    Args.Add('rev-list');
    Args.Add('--count');
    Args.AddStrings(ARange);
    if not Query(G, Args.ToStringArray, Output) then
      Exit('(git could not count them: ' + Trim(Output) + ')' + LineEnding);
    Count := StrToIntDef(Trim(Output), 0);

    Args.Clear;
    Args.AddStrings(['log', '--oneline', '-n', IntToStr(LISTED_COMMITS)]);
    Args.AddStrings(ARange);
    Query(G, Args.ToStringArray, Output);
  finally
    Args.Free;
  end;
  Result := IntToStr(Count) + ' commit(s)' + LineEnding;
  if Count > 0 then
    Result := Result + Trim(Output) + LineEnding;
  if Count > LISTED_COMMITS then
    Result := Result + '... and ' + IntToStr(Count - LISTED_COMMITS) + ' more' + LineEnding;
end;

{ ── Main-thread part of a call ───────────────────────────────────────────── }

constructor TMainPart.Create(const ACall: TMcpToolCall; const AToolName: string;
  ACheckEditors: Boolean);
begin
  inherited Create;
  Call         := ACall;
  ToolName     := AToolName;
  CheckEditors := ACheckEditors;
end;

procedure TMainPart.Prepare;
var
  Unsaved : TStringList;
begin
  Why := '';
  try
    Git.Exe := McpGitExecutable;
    if Git.Exe = '' then
    begin
      Why := 'git executable not found on PATH; the user can set its path in ' +
             'Tools > Options > MCP Assistant';
      Exit;
    end;
    Git.Dir := GetGitWorkDir(Call);
    if not CheckEditors then Exit;
    Unsaved := TStringList.Create;
    try
      McpUnsavedEditors(Unsaved);
      if Unsaved.Count > 0 then
        Why := 'These files have unsaved changes in the editor; save them first (editor_save), ' +
               'the operation changes files on disk: ' + Unsaved.CommaText;
    finally
      Unsaved.Free;
    end;
  except
    { Synchronize would re-raise this in the worker thread, which then never answers }
    on E: Exception do
      Why := 'Could not prepare: ' + E.ClassName + ': ' + E.Message;
  end;
end;

procedure TMainPart.Ask;
begin
  Approved := False;
  try
    Approved := McpConfirmGitRemote(ToolName, Verb, YesCaption, Url, Details, Reason);
  except
    on E: Exception do
    begin
      Approved := False;
      Reason   := 'Could not ask the user: ' + E.ClassName + ': ' + E.Message;
    end;
  end;
end;

{ ── git_fetch ────────────────────────────────────────────────────────────── }

procedure GitFetch(var Ctx: TMcpToolCall);
var
  Main   : TMainPart;
  G      : TGit;
  Remote, Note, Why, Output, Cmd : string;
  Args   : TStringList;
  Ok     : Boolean;
  Obj    : TJSONObject;
begin
  Main := TMainPart.Create(Ctx, 'git_fetch', False);
  try
    TThread.Synchronize(nil, @Main.Prepare);
    if Refused(Ctx, Main.Why) then Exit;
    G := Main.Git;
  finally
    Main.Free;
  end;

  if not ResolveRemote(G, StrParam(Ctx, 'remote'), CurrentBranch(G), Remote, Note, Why) then
  begin
    Refused(Ctx, Why);
    Exit;
  end;

  Args := TStringList.Create;
  try
    Args.AddStrings(['-c', 'protocol.ext.allow=never', 'fetch', '--recurse-submodules=no']);
    if BoolParam(Ctx, 'tags') then Args.Add('--tags') else Args.Add('--no-tags');
    if BoolParam(Ctx, 'prune') then Args.Add('--prune') else Args.Add('--no-prune');
    Args.AddStrings(['--', Remote]);
    Cmd := CommandText(Args.ToStringArray);
    Ok  := RunGitTimed(G.Exe, Args.ToStringArray, G.Dir, NET_TIMEOUT_MS, Output);
  finally
    Args.Free;
  end;

  Obj := TJSONObject.Create;
  Obj.Add('command', Cmd);
  Obj.Add('remote', Remote);
  if Note <> '' then
    Obj.Add('note', Note);
  Obj.Add('output', Trim(Output));
  Reply(Ctx, Ok, Obj);
end;

{ ── git_pull ─────────────────────────────────────────────────────────────── }

procedure GitPull(var Ctx: TMcpToolCall);
var
  Main     : TMainPart;
  G        : TGit;
  Branch, Remote, Note, Why, Mode, RemoteBranch, Merge, Url, Output : string;
  Before, After, Cmd : string;
  ModeArgs : TStringArray;
  Args     : TStringList;
  Ok       : Boolean;
  Obj      : TJSONObject;
begin
  Main := TMainPart.Create(Ctx, 'git_pull', True);
  try
    TThread.Synchronize(nil, @Main.Prepare);
    if Refused(Ctx, Main.Why) then Exit;
    G := Main.Git;

    Branch := CurrentBranch(G);
    if Branch = '' then
    begin
      Refused(Ctx, 'HEAD is detached: check out a branch first (git_checkout).');
      Exit;
    end;

    Mode := StrParam(Ctx, 'mode', 'ff-only');
    case Mode of
      'ff-only': ModeArgs := ['--ff-only', '--no-rebase'];
      'merge':   ModeArgs := ['--no-ff', '--no-rebase'];
      'rebase':  ModeArgs := ['--rebase=true'];
    else
      Refused(Ctx, 'mode must be ff-only, merge or rebase');
      Exit;
    end;

    if not ResolveRemote(G, StrParam(Ctx, 'remote'), Branch, Remote, Note, Why) then
    begin
      Refused(Ctx, Why);
      Exit;
    end;

    RemoteBranch := StrParam(Ctx, 'branch');
    if RemoteBranch = '' then
    begin
      Merge := QueryText(G, ['config', '--get', 'branch.' + Branch + '.merge']);
      if Pos('refs/heads/', Merge) = 1 then
        RemoteBranch := Copy(Merge, Length('refs/heads/') + 1, MaxInt);
    end;
    if RemoteBranch = '' then
    begin
      Refused(Ctx, 'The branch ' + Branch + ' tracks no remote branch: pass branch ' +
        '(the remote branch to take in).');
      Exit;
    end;
    if not RefOk(G, 'refs/heads/' + RemoteBranch) then
    begin
      Refused(Ctx, 'Not a branch name: ' + RemoteBranch);
      Exit;
    end;

    Url := EffectiveUrl(G, Remote, False);
    Main.Verb       := 'pull from a remote into your working tree';
    Main.YesCaption := '&Pull';
    Main.Url        := Url;
    Main.Details    :=
      DetailLine('Remote', Remote) +
      DetailLine('Address', Url) +
      DetailLine('Takes in', 'refs/heads/' + RemoteBranch) +
      DetailLine('Into', 'the current branch, ' + Branch + ' (' + Mode + ')') +
      LineEnding + 'Files of your working tree change.' + LineEnding;
    TThread.Synchronize(nil, @Main.Ask);
    if not Main.Approved then
    begin
      Refused(Ctx, Main.Reason);
      Exit;
    end;
  finally
    Main.Free;
  end;

  Before := QueryText(G, ['rev-parse', 'HEAD']);
  Args := TStringList.Create;
  try
    Args.AddStrings(['-c', 'protocol.ext.allow=never',
      '-c', 'rebase.updateRefs=false', '-c', 'rebase.autoSquash=false',
      '-c', 'rebase.autoStash=false', '-c', 'merge.conflictStyle=diff3',
      'pull', '--no-edit', '--no-autostash', '--recurse-submodules=no']);
    Args.AddStrings(ModeArgs);
    Args.AddStrings(['--', Remote, 'refs/heads/' + RemoteBranch]);
    Cmd := CommandText(Args.ToStringArray);
    Ok  := RunGitTimed(G.Exe, Args.ToStringArray, G.Dir, NET_TIMEOUT_MS, Output);
  finally
    Args.Free;
  end;
  After := QueryText(G, ['rev-parse', 'HEAD']);

  Obj := TJSONObject.Create;
  Obj.Add('command', Cmd);
  Obj.Add('remote', Remote);
  if Note <> '' then
    Obj.Add('note', Note);
  Obj.Add('branch', Branch);
  Obj.Add('mode', Mode);
  Obj.Add('head_before', Before);
  Obj.Add('head_after', After);
  Obj.Add('changed', Before <> After);
  Obj.Add('output', Trim(Output));
  Reply(Ctx, Ok, Obj);
end;

{ ── git_push ─────────────────────────────────────────────────────────────── }

{ The tags to push, checked; AWhy is not empty when one is not a tag. }
procedure CollectTags(const Ctx: TMcpToolCall; const G: TGit; ATags: TStrings; out AWhy: string);
var
  Data : TJSONData;
  Item : TJSONEnum;
  Tag  : string;
begin
  AWhy := '';
  if not Assigned(Ctx.Params) then Exit;
  Data := Ctx.Params.Find('tags');
  if not (Data is TJSONArray) then Exit;
  for Item in TJSONArray(Data) do
  begin
    Tag := Trim(Item.Value.AsString);
    if (Tag = '') or (Tag[1] = '-') or not RefOk(G, 'refs/tags/' + Tag) or
       not RefExists(G, 'refs/tags/' + Tag) then
    begin
      AWhy := 'Not a tag of this repository: ' + Tag;
      Exit;
    end;
    ATags.Add(Tag);
  end;
end;

procedure GitPush(var Ctx: TMcpToolCall);
var
  Main     : TMainPart;
  G        : TGit;
  Branch, Remote, Note, Why, Url, Output : string;
  Tracking, Expected, Default_, Tag : string;
  Range, Tags, Args : TStringList;
  Force, Ok : Boolean;
  Obj      : TJSONObject;
  Refs     : TJSONArray;
begin
  Force := BoolParam(Ctx, 'force');
  Main  := TMainPart.Create(Ctx, 'git_push', False);
  Range := TStringList.Create;
  Tags  := TStringList.Create;
  Args  := TStringList.Create;
  try
    TThread.Synchronize(nil, @Main.Prepare);
    if Refused(Ctx, Main.Why) then Exit;
    G := Main.Git;

    Branch := StrParam(Ctx, 'branch');
    if Branch = '' then
      Branch := CurrentBranch(G);
    if Branch = '' then
    begin
      Refused(Ctx, 'HEAD is detached: pass branch, or check out a branch first (git_checkout).');
      Exit;
    end;
    if not RefOk(G, 'refs/heads/' + Branch) or not RefExists(G, 'refs/heads/' + Branch) then
    begin
      Refused(Ctx, 'No local branch named ' + Branch + '.');
      Exit;
    end;

    if not ResolveRemote(G, StrParam(Ctx, 'remote'), Branch, Remote, Note, Why) then
    begin
      Refused(Ctx, Why);
      Exit;
    end;

    CollectTags(Ctx, G, Tags, Why);
    if Refused(Ctx, Why) then Exit;

    Tracking := 'refs/remotes/' + Remote + '/' + Branch;
    if Force then
    begin
      if not RefExists(G, Tracking) then
      begin
        Refused(Ctx, 'force needs ' + Remote + '/' + Branch + ' to compare against: ' +
          'it is not known here. git_fetch first, or push without force.');
        Exit;
      end;
      Expected := QueryText(G, ['rev-parse', Tracking]);
    end;

    Url := EffectiveUrl(G, Remote, True);
    SendRange(G, Remote, Branch, Range);
    Main.Verb       := 'push commits to a remote';
    Main.YesCaption := '&Push';
    Main.Url        := Url;
    Main.Details    :=
      DetailLine('Remote', Remote) +
      DetailLine('Address', Url) +
      DetailLine('Pushes', 'refs/heads/' + Branch + ' -> refs/heads/' + Branch) +
      DetailLine('Commits', CommitsText(G, Range));
    if Tags.Count > 0 then
      Main.Details := Main.Details + DetailLine('Tags', Tags.CommaText);
    Default_ := QueryText(G, ['symbolic-ref', '-q', '--short', 'refs/remotes/' + Remote + '/HEAD']);
    if Default_ = Remote + '/' + Branch then
      Main.Details := Main.Details + LineEnding +
        'This is the default branch of ' + Remote + ' (as last fetched).' + LineEnding;
    TThread.Synchronize(nil, @Main.Ask);
    if not Main.Approved then
    begin
      Refused(Ctx, Main.Reason);
      Exit;
    end;

    if Force then
    begin
      Range.Clear;
      Range.Add('refs/heads/' + Branch + '..' + Tracking);
      Main.Verb       := 'overwrite a branch on a remote (force push)';
      Main.YesCaption := '&Force push';
      Main.Details    :=
        DetailLine('Remote', Remote) +
        DetailLine('Address', Url) +
        DetailLine('Overwrites', 'refs/heads/' + Branch + ' on ' + Remote) +
        DetailLine('Discards', CommitsText(G, Range)) +
        LineEnding + 'These commits are on the remote and not in your branch; after the push they ' +
        'are gone from the remote branch.' + LineEnding;
      TThread.Synchronize(nil, @Main.Ask);
      if not Main.Approved then
      begin
        Refused(Ctx, Main.Reason);
        Exit;
      end;
    end;

    Args.AddStrings(['-c', 'protocol.ext.allow=never', 'push', '--no-follow-tags',
      '--recurse-submodules=no']);
    if BoolParam(Ctx, 'set_upstream') then
      Args.Add('--set-upstream');
    if Force then
      Args.Add('--force-with-lease=refs/heads/' + Branch + ':' + Expected);
    Args.AddStrings(['--', Remote, 'refs/heads/' + Branch + ':refs/heads/' + Branch]);
    Obj := TJSONObject.Create;
    Refs := TJSONArray.Create;
    Obj.Add('refs', Refs);
    Refs.Add('refs/heads/' + Branch);
    for Tag in Tags do
    begin
      Args.Add('refs/tags/' + Tag + ':refs/tags/' + Tag);
      Refs.Add('refs/tags/' + Tag);
    end;
    Ok := RunGitTimed(G.Exe, Args.ToStringArray, G.Dir, NET_TIMEOUT_MS, Output);
    Obj.Add('command', CommandText(Args.ToStringArray));
    Obj.Add('remote', Remote);
    if Note <> '' then
      Obj.Add('note', Note);
    Obj.Add('url', Url);
    Obj.Add('output', Trim(Output));
    Reply(Ctx, Ok, Obj);
  finally
    Args.Free;
    Tags.Free;
    Range.Free;
    Main.Free;
  end;
end;

{ ── git_remote ───────────────────────────────────────────────────────────── }

function RemotesJson(const G: TGit): TJSONArray;
var
  Names : TStringList;
  Output, Name : string;
  Item  : TJSONObject;
begin
  Result := TJSONArray.Create;
  Names  := TStringList.Create;
  try
    if not RemoteNames(G, Names, Output) then Exit;
    for Name in Names do
    begin
      Item := TJSONObject.Create;
      Item.Add('name', Name);
      Item.Add('fetch_url', EffectiveUrl(G, Name, False));
      Item.Add('push_url', EffectiveUrl(G, Name, True));
      Result.Add(Item);
    end;
  finally
    Names.Free;
  end;
end;

{ add, set_url, rename and remove: each changes where later pushes and pulls go, so
  each asks.  Main thread: the dialog is shown directly. }
procedure RemoteChange(var Ctx: TMcpToolCall; AMain: TMainPart; const AAction: string);
var
  G       : TGit;
  Name, NewUrl, NewName, Old, Scope, Output, Cmd : string;
  Names   : TStringList;
  Args    : TStringList;
  Exists, PushOnly, Ok : Boolean;
  Obj     : TJSONObject;
begin
  G       := AMain.Git;
  Name    := StrParam(Ctx, 'name');
  NewUrl  := StrParam(Ctx, 'url');
  NewName := StrParam(Ctx, 'new_name');
  if not ValidRemoteName(Name) then
  begin
    Refused(Ctx, 'name is required: letters, digits, _ - . / only.');
    Exit;
  end;

  Names := TStringList.Create;
  Args  := TStringList.Create;
  try
    if not RemoteNames(G, Names, Output) then
    begin
      Refused(Ctx, 'git could not list the remotes: ' + Trim(Output));
      Exit;
    end;
    Exists := Names.IndexOf(Name) >= 0;

    if (AAction <> 'add') and not Exists then
    begin
      Refused(Ctx, 'No remote named ' + Name + '. Remotes: ' + Names.CommaText);
      Exit;
    end;

    case AAction of
      'add':
      begin
        if Exists then
        begin
          Refused(Ctx, 'A remote named ' + Name + ' exists already; change it with set_url.');
          Exit;
        end;
        if BadAddress(NewUrl) then
        begin
          Refused(Ctx, 'url is required and must be a repository address, not an option or ext::');
          Exit;
        end;
        Args.AddStrings(['remote', 'add', '--', Name, NewUrl]);
        AMain.Verb       := 'add a remote';
        AMain.YesCaption := '&Add';
        AMain.Url        := NewUrl;
        AMain.Details    := DetailLine('Remote', Name) + DetailLine('New address', NewUrl) +
          LineEnding + 'Pushes and pulls to this name will go to that address.' + LineEnding;
      end;
      'set_url':
      begin
        if BadAddress(NewUrl) then
        begin
          Refused(Ctx, 'url is required and must be a repository address, not an option or ext::');
          Exit;
        end;
        PushOnly := BoolParam(Ctx, 'push');
        Old := EffectiveUrl(G, Name, PushOnly);
        Args.AddStrings(['remote', 'set-url']);
        if PushOnly then
          Args.Add('--push');
        Args.AddStrings(['--', Name, NewUrl]);
        if PushOnly then
          Scope := 'pushes only (the push address)'
        else
          Scope := 'fetches and, unless a push address is set, pushes';
        AMain.Verb       := 'change where a remote sends and receives';
        AMain.YesCaption := '&Change';
        AMain.Url        := NewUrl;
        AMain.Details    := DetailLine('Remote', Name) + DetailLine('For', Scope) +
          DetailLine('Address now', Old) + DetailLine('New address', NewUrl) + LineEnding +
          'Later pushes and pulls will go to the new address.' + LineEnding;
      end;
      'rename':
      begin
        if not ValidRemoteName(NewName) or (Names.IndexOf(NewName) >= 0) then
        begin
          Refused(Ctx, 'new_name is required, must be a valid name and must not exist yet.');
          Exit;
        end;
        Args.AddStrings(['remote', 'rename', '--', Name, NewName]);
        AMain.Verb       := 'rename a remote';
        AMain.YesCaption := '&Rename';
        AMain.Url        := EffectiveUrl(G, Name, False);
        AMain.Details    := DetailLine('Remote', Name) + DetailLine('New name', NewName) +
          DetailLine('Address', AMain.Url) + LineEnding +
          'Its remote-tracking branches are renamed with it.' + LineEnding;
      end;
      'remove':
      begin
        Args.AddStrings(['remote', 'remove', '--', Name]);
        AMain.Verb       := 'remove a remote';
        AMain.YesCaption := '&Remove';
        AMain.Url        := EffectiveUrl(G, Name, False);
        AMain.Details    := DetailLine('Remote', Name) + DetailLine('Address', AMain.Url) +
          LineEnding + 'Its remote-tracking branches and its settings are deleted here; ' +
          'nothing is changed on the remote.' + LineEnding;
      end;
    end;

    AMain.Ask;
    if not AMain.Approved then
    begin
      Refused(Ctx, AMain.Reason);
      Exit;
    end;
    Cmd := CommandText(Args.ToStringArray);
    Ok  := RunGitTimed(G.Exe, Args.ToStringArray, G.Dir, QUERY_TIMEOUT_MS, Output);
  finally
    Args.Free;
    Names.Free;
  end;

  Obj := TJSONObject.Create;
  Obj.Add('command', Cmd);
  Obj.Add('output', Trim(Output));
  Obj.Add('remotes', RemotesJson(G));
  Reply(Ctx, Ok, Obj);
end;

procedure GitRemote(var Ctx: TMcpToolCall);
var
  Main   : TMainPart;
  Action : string;
  Obj    : TJSONObject;
begin
  Main := TMainPart.Create(Ctx, 'git_remote', False);
  try
    Main.Prepare;
    if Refused(Ctx, Main.Why) then Exit;
    Action := StrParam(Ctx, 'action');
    case Action of
      'list':
      begin
        Obj := TJSONObject.Create;
        Obj.Add('remotes', RemotesJson(Main.Git));
        Reply(Ctx, True, Obj);
      end;
      'add', 'set_url', 'rename', 'remove':
        RemoteChange(Ctx, Main, Action);
    else
      Refused(Ctx, 'action must be list, add, set_url, rename or remove');
    end;
  finally
    Main.Free;
  end;
end;

{ ── git_tag ──────────────────────────────────────────────────────────────── }

function TagsJson(const G: TGit): TJSONArray;
var
  Output, Line : string;
  Lines  : TStringList;
  Fields : TStringList;
  Item   : TJSONObject;
begin
  Result := TJSONArray.Create;
  if not Query(G, ['tag', '--list',
    '--format=%(refname:short)%09%(objecttype)%09%(objectname:short)%09%(contents:subject)'],
    Output) then Exit;
  Lines  := TStringList.Create;
  Fields := TStringList.Create;
  try
    Fields.Delimiter       := #9;
    Fields.StrictDelimiter := True;
    Lines.Text := Trim(Output);
    for Line in Lines do
    begin
      Fields.DelimitedText := Line;
      if Fields.Count < 4 then Continue;
      Item := TJSONObject.Create;
      Item.Add('name', Fields[0]);
      Item.Add('annotated', Fields[1] = 'tag');
      Item.Add('object', Fields[2]);
      Item.Add('subject', Fields[3]);
      Result.Add(Item);
    end;
  finally
    Fields.Free;
    Lines.Free;
  end;
end;

procedure TagCreate(var Ctx: TMcpToolCall; const G: TGit);
var
  Name, Message, Commit, Output, Cmd : string;
  Light, Ok : Boolean;
  Args : TStringList;
  Obj  : TJSONObject;
begin
  Name    := StrParam(Ctx, 'name');
  Message := Trim(StrParam(Ctx, 'message'));
  Commit  := StrParam(Ctx, 'ref', 'HEAD');
  if Commit = '' then
    Commit := 'HEAD';
  Light   := BoolParam(Ctx, 'lightweight');
  if (Name = '') or (Name[1] = '-') or not RefOk(G, 'refs/tags/' + Name) then
  begin
    Refused(Ctx, 'name is required and must be a valid tag name.');
    Exit;
  end;
  if RefExists(G, 'refs/tags/' + Name) then
  begin
    Refused(Ctx, 'The tag ' + Name + ' exists already. Tags are not moved: delete it first if you mean to.');
    Exit;
  end;
  if (Commit[1] = '-') or not RefExists(G, Commit + '^{commit}') then
  begin
    Refused(Ctx, 'Not a commit: ' + Commit);
    Exit;
  end;
  if not Light and (Message = '') then
  begin
    Refused(Ctx, 'message is required for an annotated tag (or pass lightweight=true).');
    Exit;
  end;

  Args := TStringList.Create;
  try
    if Light then
      Args.AddStrings(['tag', Name, Commit])
    else
      Args.AddStrings(['tag', '-a', '--cleanup=whitespace', '-F', '-', Name, Commit]);
    Cmd := CommandText(Args.ToStringArray);
    { the message goes in on standard input: free text must not be an argument (Windows) }
    Ok  := RunGitTimed(G.Exe, Args.ToStringArray, G.Dir, QUERY_TIMEOUT_MS, Output, Message + LineEnding);
  finally
    Args.Free;
  end;

  Obj := TJSONObject.Create;
  Obj.Add('command', Cmd);
  Obj.Add('output', Trim(Output));
  if Ok then
    Obj.Add('commit', QueryText(G, ['rev-parse', '--short', Name + '^{commit}']));
  Reply(Ctx, Ok, Obj);
end;

procedure TagDelete(var Ctx: TMcpToolCall; const G: TGit);
var
  Name, Output, Cmd : string;
  Ok  : Boolean;
  Obj : TJSONObject;
begin
  Name := StrParam(Ctx, 'name');
  if (Name = '') or (Name[1] = '-') or not RefOk(G, 'refs/tags/' + Name) or
     not RefExists(G, 'refs/tags/' + Name) then
  begin
    Refused(Ctx, 'No tag named ' + Name + '.');
    Exit;
  end;
  Cmd := CommandText(['tag', '-d', '--', Name]);
  Ok  := RunGitTimed(G.Exe, ['tag', '-d', '--', Name], G.Dir, QUERY_TIMEOUT_MS, Output);
  Obj := TJSONObject.Create;
  Obj.Add('command', Cmd);
  Obj.Add('output', Trim(Output));
  Reply(Ctx, Ok, Obj);
end;

procedure GitTag(var Ctx: TMcpToolCall);
var
  Main : TMainPart;
  Obj  : TJSONObject;
begin
  Main := TMainPart.Create(Ctx, 'git_tag', False);
  try
    Main.Prepare;
    if Refused(Ctx, Main.Why) then Exit;
    case StrParam(Ctx, 'action') of
      'list':
      begin
        Obj := TJSONObject.Create;
        Obj.Add('tags', TagsJson(Main.Git));
        Reply(Ctx, True, Obj);
      end;
      'create': TagCreate(Ctx, Main.Git);
      'delete': TagDelete(Ctx, Main.Git);
    else
      Refused(Ctx, 'action must be list, create or delete');
    end;
  finally
    Main.Free;
  end;
end;

{ ── Dispatch and registration ────────────────────────────────────────────── }

{ Main thread. }
function DispatchGitRemoteTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
begin
  Result := True;
  case Name of
    'git_remote': GitRemote(Ctx);
    'git_tag':    GitTag(Ctx);
  else
    Result := False;
  end;
end;

{ MCP worker thread: a transfer can take minutes and must not hold the IDE. }
function DispatchGitRemoteBlocking(const Name: string; var Ctx: TMcpToolCall): Boolean;
begin
  Result := True;
  try
    case Name of
      'git_fetch': GitFetch(Ctx);
      'git_pull':  GitPull(Ctx);
      'git_push':  GitPush(Ctx);
    else
      Result := False;
    end;
  except
    on E: Exception do
      Refused(Ctx, Name + ' failed: ' + E.ClassName + ': ' + E.Message);
  end;
end;

procedure RegisterGitRemoteSchemas(Tools: TJSONArray);
begin
  Tools.Add(MakeTool('git_remote',
    'List the remotes with the addresses git will use (action list), or add one, change its ' +
    'address, rename or remove it. Changing one asks the user in the IDE every time and the ' +
    'user may say no; do not retry then. No remote name is assumed.',
    SCHEMA_GIT_REMOTE, MCP_ANN_WRITE));
  Tools.Add(MakeTool('git_fetch',
    'Download what a configured remote has (git fetch). Only remote-tracking branches change, ' +
    'never your branches or files. No tags unless tags=true. Never asks for credentials (an ' +
    'address that needs them fails). Returns the exact command that ran.',
    SCHEMA_GIT_FETCH, MCP_ANN_NET));
  Tools.Add(MakeTool('git_pull',
    'Fetch a remote branch and take it into the current branch (git pull). The user is asked in ' +
    'the IDE for every pull and may say no; do not retry then. mode ff-only (default) fails ' +
    'rather than merge; merge always makes a merge commit; rebase replays your commits. ' +
    'Refused while an editor holds unsaved changes. Never asks for credentials.',
    SCHEMA_GIT_PULL, MCP_ANN_PUSH));
  Tools.Add(MakeTool('git_push',
    'Push a branch, and optionally named tags, to a remote (git push). The user is asked in the ' +
    'IDE for every push, with the remote, its address and the commits that would go, and may ' +
    'say no; do not retry then. force=true is --force-with-lease and needs a second approval ' +
    'that names the commits it would discard. Hooks run. Never asks for credentials.',
    SCHEMA_GIT_PUSH, MCP_ANN_PUSH));
  Tools.Add(MakeTool('git_tag',
    'List, create (annotated by default) or delete local tags. A tag is never moved: delete it ' +
    'first. Pushing one is git_push with tags.',
    SCHEMA_GIT_TAG, MCP_ANN_DEST));
end;

initialization
  RegisterMcpGroup(@DispatchGitRemoteTool);
  RegisterMcpBlockingGroup(@DispatchGitRemoteBlocking);
  RegisterMcpSchemas(@RegisterGitRemoteSchemas);

end.
