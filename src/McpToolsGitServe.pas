{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsGitServe;

{ git_serve (ADR-035, the local part): let one other machine fetch this repository over HTTP.

  Two ways in:
    link   once, with the user's yes: remembers the machine (address, port, key) and gives the
           setup for it; after that start and stop need no dialog, because the link is the
           consent;
    start  for a machine without a link: asks the user every time and gives a ready command
           with a code of about a minute.

  Runs on the MCP worker thread (a socket server is started there); only the dialog, the
  settings and the IDE queries go to the main thread, as in McpToolsGitRemote. }

{$mode objfpc}{$H+}

interface

uses
  McpToolContext;

implementation

uses
  Classes, SysUtils, StrUtils, SyncObjs, fpjson, base64, McpIdeState, McpGitRun,
  McpToolsGitRemote, McpGitServe, McpTokens;

const
  MCP_ANN_SERVE = '{"readOnlyHint":false,"destructiveHint":false,"openWorldHint":true}';

  SCHEMA_GIT_SERVE =
    '{"type":"object","properties":{' +
    '"action":{"type":"string","enum":["link","unlink","links","start","stop","status","code"],"description":"link: ask the user once to link a machine (then start/stop need no dialog) and return its setup; start: open the listener; stop; status; unlink; links; code: a fresh code for a machine without a link"},' +
    '"peer":{"type":"string","description":"link, unlink, start: the IPv4 address of the other machine (the only one that can connect). start may leave it out when exactly one machine is linked"},' +
    '"minutes":{"type":"integer","description":"start: how long to serve (default 15, at most 60)"},' +
    '"fetches":{"type":"integer","description":"start, linked machine: close after this many fetches (default 1; 0 = until minutes run out)"},' +
    '"snapshot":{"type":"boolean","description":"start: serve the tracked files as they are on disk, uncommitted changes included (default true); false serves the checked-out commit"},' +
    '"include":{"type":"array","items":{"type":"string"},"description":"start: untracked files to send as well, as paths or patterns relative to the repository root (e.g. src/NewUnit.pas, tests/*.pas); ignored files and everything not named stay home"},' +
    '"port":{"type":"integer","description":"link: the port to keep (default: a free one is chosen)"},' +
    '"remote_dir":{"type":"string","description":"link, start without a link: the folder on the other machine the commands use (default mcp-code)"},' +
    '"work_dir":{"type":"string","description":"A directory inside the repository (default: the project''s directory)"}},' +
    '"required":[]}';

  REMOTE_NAME = 'mcp';
  SNAPSHOT_REF = 'refs/mcp/snapshot';

  { the credential helper for the other machine: scripts/git-credential-mcp, line for line }
  HELPER_LINES : array[0..15] of string = (
    '#!/bin/sh',
    '[ "$2" = get ] || exit 0',
    'key=$1',
    'cat > /dev/null',
    't=$(( $(date +%s) / 30 ))',
    'msg=',
    'i=7',
    'while [ $i -ge 0 ]; do',
    '  msg="$msg$(printf "\\\\%03o" $(( (t >> (8 * i)) & 255 )))"',
    '  i=$(( i - 1 ))',
    'done',
    'mac=$(printf "$msg" | openssl dgst -sha1 -mac HMAC -macopt "hexkey:$key" -hex | cut -d= -f2 | tr -d " ")',
    'off=$(( 0x$(printf %s "$mac" | cut -c40) ))',
    'h=$(printf %s "$mac" | cut -c$(( off * 2 + 1 ))-$(( off * 2 + 8 )))',
    'code=$(( (0x$h & 0x7fffffff) % 1000000 ))',
    'printf "username=mcp\npassword=%06d\n" $code');

  { the same helper as an instantfpc script: scripts/git-credential-mcp.pas, without its comment }
  HELPER_PAS : array[0..45] of string = (
    '{$mode objfpc}{$H+}',
    'uses SysUtils, DateUtils, sha1;',
    'function Raw(const D: TSHA1Digest): string;',
    'begin',
    '  SetLength(Result, 20);',
    '  Move(D, Result[1], 20);',
    'end;',
    'function Hmac(const AKey, AMsg: string): string;',
    'var',
    '  K, Ip, Op : string;',
    '  I : Integer;',
    'begin',
    '  K := AKey + StringOfChar(#0, 64 - Length(AKey));',
    '  SetLength(Ip, 64);',
    '  SetLength(Op, 64);',
    '  for I := 1 to 64 do',
    '  begin',
    '    Ip[I] := Chr(Ord(K[I]) xor $36);',
    '    Op[I] := Chr(Ord(K[I]) xor $5C);',
    '  end;',
    '  Result := Raw(SHA1String(Op + Raw(SHA1String(Ip + AMsg))));',
    'end;',
    'var',
    '  Key, Msg, H, Line : string;',
    '  I, Off : Integer;',
    '  T : Int64;',
    '  Bin : LongWord;',
    'begin',
    '  if (ParamCount < 2) or (ParamStr(2) <> ''get'') then Halt(0);',
    '  while not EOF(Input) do ReadLn(Input, Line);',
    '  Key := '''';',
    '  for I := 0 to (Length(ParamStr(1)) div 2) - 1 do',
    '    Key := Key + Chr(StrToIntDef(''$'' + Copy(ParamStr(1), I * 2 + 1, 2), 0));',
    '  T := DateTimeToUnix(Now, False) div 30;',
    '  SetLength(Msg, 8);',
    '  for I := 8 downto 1 do',
    '  begin',
    '    Msg[I] := Chr(T and $FF);',
    '    T := T shr 8;',
    '  end;',
    '  H := Hmac(Key, Msg);',
    '  Off := Ord(H[20]) and $0F;',
    '  Bin := ((LongWord(Ord(H[Off + 1])) and $7F) shl 24) or (LongWord(Ord(H[Off + 2])) shl 16) or',
    '         (LongWord(Ord(H[Off + 3])) shl 8) or LongWord(Ord(H[Off + 4]));',
    '  Write(''username=mcp''#10, ''password='', Format(''%.6d'', [Bin mod 1000000]), #10);',
    'end.');

type
  TLink = record
    Peer : string;
    Host : string;
    Port : Word;
    Key  : string;       { raw bytes }
  end;

var
  GServer : TGitServe = nil;
  GLock   : TCriticalSection = nil;

{ ── the links, in the settings (main thread) ─────────────────────────────── }

function ToHex(const S: string): string;
var
  I : Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    Result := Result + LowerCase(IntToHex(Ord(S[I]), 2));
end;

function FromHex(const H: string): string;
var
  I : Integer;
begin
  Result := '';
  I := 1;
  while I < Length(H) do
  begin
    Result := Result + Chr(StrToIntDef('$' + Copy(H, I, 2), 0));
    Inc(I, 2);
  end;
end;

function LinkText(const L: TLink): string;
begin
  Result := L.Peer + '|' + L.Host + '|' + IntToStr(L.Port) + '|' + ToHex(L.Key);
end;

function ParseLink(const S: string; out L: TLink): Boolean;
var
  P : TStringList;
begin
  Result := False;
  P := TStringList.Create;
  try
    P.Delimiter := '|';
    P.StrictDelimiter := True;
    P.DelimitedText := S;
    if P.Count <> 4 then Exit;
    L.Peer := P[0];
    L.Host := P[1];
    L.Port := StrToIntDef(P[2], 0);
    L.Key  := FromHex(P[3]);
    Result := (L.Peer <> '') and (L.Port > 0) and (Length(L.Key) = 20);
  finally
    P.Free;
  end;
end;

type
  TLinkOp = (loFind, loSave, loDrop, loList, loOnlyOne);

  { One job for the IDE's thread: the settings are used there only. }
  TLinkJob = class
  public
    Op     : TLinkOp;
    Link   : TLink;
    Found  : Boolean;
    Names  : string;       { loList: peer|host|port per line }
    procedure Run;
  end;

procedure TLinkJob.Run;
var
  I : Integer;
  L : TLink;
begin
  Found := False;
  Names := '';
  try
    if not Assigned(McpSettings) then Exit;
    case Op of
      loFind:
        for I := 0 to McpSettings.GitLinks.Count - 1 do
          if ParseLink(McpSettings.GitLinks[I], L) and (L.Peer = Link.Peer) then
          begin
            Link  := L;
            Found := True;
            Break;
          end;
      loOnlyOne:
        if McpSettings.GitLinks.Count = 1 then
          Found := ParseLink(McpSettings.GitLinks[0], Link);
      loSave:
        begin
          for I := McpSettings.GitLinks.Count - 1 downto 0 do
            if ParseLink(McpSettings.GitLinks[I], L) and (L.Peer = Link.Peer) then
              McpSettings.GitLinks.Delete(I);
          McpSettings.GitLinks.Add(LinkText(Link));
          McpSettings.SaveSettings;
          Found := True;
        end;
      loDrop:
        for I := McpSettings.GitLinks.Count - 1 downto 0 do
          if ParseLink(McpSettings.GitLinks[I], L) and (L.Peer = Link.Peer) then
          begin
            McpSettings.GitLinks.Delete(I);
            McpSettings.SaveSettings;
            Found := True;
          end;
      loList:
        for I := 0 to McpSettings.GitLinks.Count - 1 do
          if ParseLink(McpSettings.GitLinks[I], L) then
          begin
            Names := Names + L.Peer + '|' + L.Host + '|' + IntToStr(L.Port) + #10;
            Found := True;
          end;
    end;
  except
    Found := False;
  end;
end;

function LinkJob(AOp: TLinkOp; var ALink: TLink): Boolean;
var
  J : TLinkJob;
begin
  J := TLinkJob.Create;
  try
    J.Op   := AOp;
    J.Link := ALink;
    TThread.Synchronize(nil, @J.Run);
    ALink  := J.Link;
    Result := J.Found;
  finally
    J.Free;
  end;
end;

{ ── small helpers ────────────────────────────────────────────────────────── }

{ Counts the editors with unsaved changes; the IDE's thread. }
type
  TUnsaved = class
  public
    Count : Integer;
    procedure Run;
  end;

procedure TUnsaved.Run;
var
  L : TStringList;
begin
  Count := 0;
  L := TStringList.Create;
  try
    try
      McpUnsavedEditors(L);
      Count := L.Count;
    except
      Count := 0;
    end;
  finally
    L.Free;
  end;
end;

function UrlFor(const AHost: string; APort: Word): string;
begin
  Result := 'http://' + AHost + ':' + IntToStr(APort) + '/repo.git';
end;

function BasicHeader(const ACode: string): string;
begin
  Result := 'Authorization: Basic ' + EncodeStringBase64('mcp:' + ACode);
end;

{ For a machine without a link: the whole pull step in one line, with a code of about a minute. }
function BashCommand(const AUrl, ATarget, ACode: string): string;
begin
  Result :=
    'd=' + ATarget + '; mkdir -p "$d" && cd "$d" && { [ -d .git ] || git init -q; } && ' +
    'git -c "http.extraHeader=' + BasicHeader(ACode) + '" fetch -q ' + AUrl + ' ' +
    '+' + SNAPSHOT_REF + ':' + SNAPSHOT_REF + ' && git reset -q --hard ' + SNAPSHOT_REF +
    ' && git rev-parse HEAD';
end;

function PowerShellCommand(const AUrl, ATarget, ACode: string): string;
begin
  Result :=
    '$d=''' + ATarget + '''; New-Item -ItemType Directory -Force $d | Out-Null; Set-Location $d; ' +
    'if (-not (Test-Path .git)) { git init -q }; ' +
    'git -c "http.extraHeader=' + BasicHeader(ACode) + '" fetch -q ' + AUrl + ' ' +
    '+' + SNAPSHOT_REF + ':' + SNAPSHOT_REF + '; if ($?) { git reset -q --hard ' + SNAPSHOT_REF +
    '; git rev-parse HEAD }';
end;

{ For a linked machine, once: make the folder and the remote, install the helper. }
function SetupCommand(const L: TLink; const ATarget: string): string;
var
  I : Integer;
begin
  { two helpers are installed; the one git uses is chosen here, on the box: the instantfpc
    script (one implementation of the code, no openssl) when instantfpc is there, else the
    shell script }
  Result := 'd=' + ATarget + '; mkdir -p "$d" && cd "$d" && { [ -d .git ] || git init -q; }' +
    ' && cat > ~/.git-credential-mcp.pas <<''MCPEOF''' + #10;
  for I := Low(HELPER_PAS) to High(HELPER_PAS) do
    Result := Result + HELPER_PAS[I] + #10;
  Result := Result + 'MCPEOF' + #10 + 'cat > ~/.git-credential-mcp <<''MCPEOF''' + #10;
  for I := Low(HELPER_LINES) to High(HELPER_LINES) do
    Result := Result + HELPER_LINES[I] + #10;
  Result := Result + 'MCPEOF' + #10 +
    'chmod 700 ~/.git-credential-mcp ~/.git-credential-mcp.pas' +
    ' && { git remote remove ' + REMOTE_NAME + ' 2>/dev/null; true; }' +
    ' && git remote add ' + REMOTE_NAME + ' ' + UrlFor(L.Host, L.Port) +
    ' && git config remote.' + REMOTE_NAME + '.fetch ''+' + SNAPSHOT_REF +
    ':refs/remotes/' + REMOTE_NAME + '/snapshot''' +
    { an empty entry first: it clears the helpers the system or the user configured (Git for
      Windows lists Git Credential Manager, which would open a window and ask for a password) }
    ' && git config --unset-all credential.helper; git config credential.helper ""' +
    ' && if command -v instantfpc >/dev/null 2>&1; then' +
    ' git config --add credential.helper "!instantfpc ~/.git-credential-mcp.pas ' + ToHex(L.Key) + '";' +
    ' else git config --add credential.helper "!sh ~/.git-credential-mcp ' + ToHex(L.Key) + '"; fi';
end;

const
  { what the assistant does on the box for every test run once the link is set up }
  PULL_STEPS = 'On the other machine: git_fetch (remote mcp), then git_reset (mode hard, target ' +
    'refs/remotes/mcp/snapshot), or in a shell: cd <folder> && git fetch -q mcp && git reset ' +
    '-q --hard refs/remotes/mcp/snapshot';

function StatusObject(AServer: TGitServe): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('serving', Assigned(AServer) and AServer.Running);
  if Assigned(AServer) and AServer.Running then
  begin
    Result.Add('url', UrlFor(AServer.Host, AServer.Port));
    Result.Add('peer', AServer.Peer);
    Result.Add('seconds_left', AServer.SecondsLeft);
    Result.Add('fetches_served', AServer.Served);
    Result.Add('wrong_codes', AServer.Wrong);
  end;
end;

function IntParam(const Ctx: TMcpToolCall; const AName: string; ADefault: Integer): Integer;
begin
  Result := ADefault;
  if Assigned(Ctx.Params) then
    Result := Ctx.Params.Get(AName, ADefault);
end;

{ The repository root of the call, or '' with the reason in Ctx. }
function PrepareRepo(var Ctx: TMcpToolCall; out G: TGit; out Root: string;
  out Main: TMainPart): Boolean;
begin
  Result := False;
  Root := '';
  Main := TMainPart.Create(Ctx, 'git_serve', False);
  TThread.Synchronize(nil, @Main.Prepare);
  if Refused(Ctx, Main.Why) then Exit;
  G := Main.Git;
  Root := QueryText(G, ['rev-parse', '--show-toplevel']);
  if Root = '' then
  begin
    Refused(Ctx, 'Not inside a git repository (pass work_dir).');
    Exit;
  end;
  Root  := StringReplace(Root, '/', PathDelim, [rfReplaceAll]);
  G.Dir := Root;
  Result := True;
end;

{ ── link ─────────────────────────────────────────────────────────────────── }

procedure DoLink(var Ctx: TMcpToolCall);
var
  Main : TMainPart;
  G    : TGit;
  Root, Peer, Why, Target : string;
  L    : TLink;
  Raw  : array[0..19] of Byte;
  Port : Integer;
  Obj  : TJSONObject;
begin
  Peer := StrParam(Ctx, 'peer');
  if Peer = '' then
  begin
    Refused(Ctx, 'link needs peer: the IPv4 address of the machine to link.');
    Exit;
  end;
  Target := StrParam(Ctx, 'remote_dir', 'mcp-code');
  if not McpLocalAddressFor(Peer, L.Host, Why) then
  begin
    Refused(Ctx, Why);
    Exit;
  end;
  Main := nil;
  try
    if not PrepareRepo(Ctx, G, Root, Main) then Exit;
    Port := IntParam(Ctx, 'port', 0);
    if (Port < 0) or (Port > 65535) then
    begin
      Refused(Ctx, 'port must be between 1 and 65535.');
      Exit;
    end;
    if Port = 0 then Port := McpPickPort(L.Host);
    if Port = 0 then
    begin
      Refused(Ctx, 'No free port on ' + L.Host + '.');
      Exit;
    end;
    L.Peer := Peer;
    L.Port := Port;

    Main.Verb       := 'link another machine to this repository';
    Main.YesCaption := '&Link';
    Main.Url        := Root;
    Main.Details    :=
      'Repository: ' + Root + LineEnding +
      'Machine: ' + Peer + '  (this machine: ' + L.Host + ', port ' + IntToStr(L.Port) + ')' +
      LineEnding + LineEnding +
      'From now on an assistant may open a read-only server for that machine and close it ' +
      'again without asking you each time. While it is open that machine, and only that ' +
      'one, can fetch the tracked files of this repository as they are on disk, with a code ' +
      'that changes every 30 seconds. The connection is plain HTTP.' + LineEnding +
      'Linking again replaces the key; unlinking (git_serve unlink) removes it.' + LineEnding;
    TThread.Synchronize(nil, @Main.Ask);
    if not Main.Approved then
    begin
      Refused(Ctx, Main.Reason);
      Exit;
    end;
  finally
    Main.Free;
  end;

  McpRandomBytes(Raw, SizeOf(Raw));
  SetString(L.Key, PChar(@Raw[0]), SizeOf(Raw));
  if not LinkJob(loSave, L) then
  begin
    Refused(Ctx, 'The link could not be saved.');
    Exit;
  end;
  GLock.Enter;
  try
    if Assigned(GServer) and (GServer.Peer = L.Peer) then GServer.Stop;
  finally
    GLock.Leave;
  end;

  Obj := TJSONObject.Create;
  Obj.Add('linked', Peer);
  Obj.Add('url', UrlFor(L.Host, L.Port));
  Obj.Add('setup_bash', SetupCommand(L, Target));
  Obj.Add('note', 'Run setup_bash once on ' + Peer + ' (it makes the folder and the remote "' +
    REMOTE_NAME + '", and installs a credential helper that holds the key). ' + PULL_STEPS +
    '. Before each run: git_serve start; it closes itself after the fetch.');
  Reply(Ctx, True, Obj);
end;

{ ── start ────────────────────────────────────────────────────────────────── }

const
  MAX_INCLUDE   = 100;
  QUERY_TIMEOUT = 60 * 1000;

{ The include parameter: pathspecs of untracked files to send as well (a single string counts as
  a list of one).  '' when it is fine, else why not. }
function ReadIncludes(const Ctx: TMcpToolCall; AList: TStrings): string;
var
  D : TJSONData;
  I : Integer;
  S : string;
begin
  Result := '';
  if not Assigned(Ctx.Params) then Exit;
  D := Ctx.Params.Find('include');
  if (D = nil) or D.IsNull then Exit;
  if D is TJSONArray then
    for I := 0 to TJSONArray(D).Count - 1 do
      AList.Add(Trim(TJSONArray(D).Items[I].AsString))
  else if D.JSONType = jtString then
    AList.Add(Trim(D.AsString))
  else
    Exit('include is a list of paths or patterns, relative to the repository root.');
  if AList.Count > MAX_INCLUDE then
    Exit('include takes at most ' + IntToStr(MAX_INCLUDE) + ' entries.');
  for I := 0 to AList.Count - 1 do
  begin
    S := AList[I];
    if (S = '') or (S[1] = '-') or (Pos(#10, S) > 0) or (Pos(#13, S) > 0) then
      Exit('include: "' + S + '" is not a path or a pattern.');
  end;
end;

function JoinList(AList: TStrings; AMax: Integer): string;
var
  I : Integer;
begin
  Result := '';
  for I := 0 to AList.Count - 1 do
  begin
    if I >= AMax then
    begin
      Result := Result + ', ... (' + IntToStr(AList.Count - AMax) + ' more)';
      Break;
    end;
    if I > 0 then Result := Result + ', ';
    Result := Result + AList[I];
  end;
end;

{ A commit on top of AHead whose tree is ABase (the tracked files as on disk) plus the untracked
  files that match ASpecs.  Made in a throwaway index, so the real index, the working tree and
  the branches stay as they are.  AAdded gets the files that were new. }
function SnapshotWithFiles(const G: TGit; const ABase, AHead: string; ASpecs: TStrings;
  out ASha: string; AAdded: TStrings; out AWhy: string): Boolean;
var
  Idx, Env, Text, Tree : string;
  AddArgs : array of string;
  I : Integer;

  function Run(const Args: array of string; AUseIndex: Boolean): Boolean;
  begin
    if AUseIndex then
      Result := RunGitTimed(G.Exe, Args, G.Dir, QUERY_TIMEOUT, Text, '', Env)
    else
      Result := RunGitTimed(G.Exe, Args, G.Dir, QUERY_TIMEOUT, Text);
  end;

begin
  Result := False;
  ASha   := '';
  AWhy   := '';
  Idx := GetTempFileName(GetTempDir, 'mcpidx');
  DeleteFile(Idx);   { git wants an index that does not exist yet, not an empty file }
  Env := 'GIT_INDEX_FILE=' + Idx;
  try
    if not Run(['read-tree', ABase], True) then
    begin
      AWhy := 'read-tree: ' + Trim(Text);
      Exit;
    end;
    AddArgs := nil;
    SetLength(AddArgs, ASpecs.Count + 2);
    AddArgs[0] := 'add';
    AddArgs[1] := '--';
    for I := 0 to ASpecs.Count - 1 do
      AddArgs[I + 2] := ASpecs[I];
    if not Run(AddArgs, True) then
    begin
      AWhy := 'include: ' + Trim(Text);
      Exit;
    end;
    if Run(['diff', '--cached', '--name-only', '--no-renames', ABase], True) then
      AAdded.Text := Trim(Text);
    if not Run(['write-tree'], True) then
    begin
      AWhy := 'write-tree: ' + Trim(Text);
      Exit;
    end;
    Tree := Trim(Text);
    { the commit only carries the tree: no signing, an identity of its own }
    if not Run(['-c', 'user.name=mcp', '-c', 'user.email=mcp@localhost',
        '-c', 'commit.gpgsign=false', 'commit-tree', Tree, '-p', AHead, '-m', 'mcp snapshot'],
        False) then
    begin
      AWhy := 'commit-tree: ' + Trim(Text);
      Exit;
    end;
    ASha   := Trim(Text);
    Result := True;
  finally
    DeleteFile(Idx);
  end;
end;

{ Untracked files git does not ignore and the snapshot does not carry. }
procedure UntrackedLeftOut(const G: TGit; AAdded, ALeft: TStrings);
var
  Text : string;
  L    : TStringList;
  I    : Integer;
begin
  ALeft.Clear;
  if not RunGitTimed(G.Exe, ['-c', 'core.quotepath=false', 'ls-files', '--others',
      '--exclude-standard'], G.Dir, QUERY_TIMEOUT, Text) then Exit;
  L := TStringList.Create;
  try
    L.Text := Trim(Text);
    for I := 0 to L.Count - 1 do
      if (L[I] <> '') and (AAdded.IndexOf(L[I]) < 0) then ALeft.Add(L[I]);
  finally
    L.Free;
  end;
end;

procedure DoStartWith(var Ctx: TMcpToolCall; ASpecs, AAdded: TStringList);
var
  Main    : TMainPart;
  Unsaved : TUnsaved;
  G       : TGit;
  Head, NewSha : string;
  Left_   : TStringList;
  Names   : TJSONArray;
  I       : Integer;
  Peer, Why, Root, Sha, Snap, Note, Code, Target, Key : string;
  Minutes, Left, Fetches : Integer;
  Snapshot, Linked : Boolean;
  Srv     : TGitServe;
  L       : TLink;
  Obj, Cmds : TJSONObject;
begin
  L := Default(TLink);
  Peer := StrParam(Ctx, 'peer');
  Linked := False;
  if Peer = '' then
  begin
    if LinkJob(loOnlyOne, L) then
    begin
      Peer   := L.Peer;
      Linked := True;
    end
    else
    begin
      Refused(Ctx, 'start needs peer: the IPv4 address of the machine that will fetch ' +
        '(it may be left out only when exactly one machine is linked).');
      Exit;
    end;
  end
  else
  begin
    L.Peer := Peer;
    Linked := LinkJob(loFind, L);
  end;
  if (not Linked) and (Ctx.Bearer = '') then
  begin
    Refused(Ctx, 'This call carries no bearer token to make the code from.');
    Exit;
  end;
  Minutes := IntParam(Ctx, 'minutes', 15);
  if Minutes < 1 then Minutes := 1;
  if Minutes > 60 then Minutes := 60;
  Fetches := IntParam(Ctx, 'fetches', 1);
  if not Linked then Fetches := 0;
  Snapshot := (not Assigned(Ctx.Params)) or Ctx.Params.Get('snapshot', True);
  Target := StrParam(Ctx, 'remote_dir', 'mcp-code');
  if (ASpecs.Count > 0) and not Snapshot then
  begin
    Refused(Ctx, 'include needs snapshot (the default): it adds files to the snapshot.');
    Exit;
  end;

  GLock.Enter;
  try
    if Assigned(GServer) and GServer.Running then
    begin
      Refused(Ctx, 'Already serving ' + GServer.Peer + ' (git_serve status); stop it first.');
      Exit;
    end;
  finally
    GLock.Leave;
  end;

  Unsaved := TUnsaved.Create;
  Main    := nil;
  try
    if not PrepareRepo(Ctx, G, Root, Main) then Exit;
    TThread.Synchronize(nil, @Unsaved.Run);
    Sha := QueryText(G, ['rev-parse', '--verify', 'HEAD']);
    if Sha = '' then
    begin
      Refused(Ctx, 'The repository has no commit yet; nothing can be fetched.');
      Exit;
    end;
    if Snapshot then
      Snap := 'tracked files as on disk' + IfThen(Unsaved.Count > 0,
        ', ' + IntToStr(Unsaved.Count) + ' unsaved editor buffer(s) NOT included', '')
    else
      Snap := 'the checked-out commit ' + Copy(Sha, 1, 10);
    if ASpecs.Count > 0 then
      Snap := Snap + '; plus the untracked files matching: ' + JoinList(ASpecs, 10);

    if not Linked then
    begin
      { no link: the user decides, before anything is made or opened }
      Main.Verb       := 'serve this repository to another machine';
      Main.YesCaption := '&Serve';
      Main.Url        := Root;
      Main.Details    :=
        'Repository: ' + Root + LineEnding +
        'Machine allowed to fetch: ' + Peer + LineEnding +
        'For: ' + IntToStr(Minutes) + ' minutes' + LineEnding +
        'What it gets: ' + Snap + LineEnding +
        'Read-only; the connection is plain HTTP, protected by a code that changes every 30 ' +
        'seconds and by the address above.' + LineEnding;
      TThread.Synchronize(nil, @Main.Ask);
      if not Main.Approved then
      begin
        Refused(Ctx, Main.Reason);
        Exit;
      end;
    end;
  finally
    Unsaved.Free;
    Main.Free;
  end;

  { the commit to serve: the files as they are, or HEAD; always under one name }
  Sha  := QueryText(G, ['rev-parse', '--verify', 'HEAD']);
  Head := Sha;
  if Snapshot then
  begin
    Key := QueryText(G, ['stash', 'create']);
    if Key <> '' then Sha := Key;
    if ASpecs.Count > 0 then
    begin
      if not SnapshotWithFiles(G, Sha, Head, ASpecs, NewSha, AAdded, Why) then
      begin
        Refused(Ctx, 'Could not add the untracked files to the snapshot: ' + Why);
        Exit;
      end;
      Sha := NewSha;
    end;
  end;
  if not Query(G, ['update-ref', SNAPSHOT_REF, Sha], Note) then
  begin
    Refused(Ctx, 'Could not make the snapshot: ' + Note);
    Exit;
  end;

  if Linked then
    Key := L.Key
  else
    Key := McpServeKey(Ctx.Bearer);
  Srv := TGitServe.Create(G.Exe, Root, Peer, Key);
  Srv.FetchLimit := Fetches;
  if Linked then Left := L.Port else Left := 0;
  if not Srv.Start(Minutes, Why, Left) then
  begin
    Srv.Free;
    Refused(Ctx, Why);
    Exit;
  end;
  GLock.Enter;
  try
    FreeAndNil(GServer);
    GServer := Srv;
  finally
    GLock.Leave;
  end;

  Obj := StatusObject(Srv);
  Obj.Add('commit', Sha);
  Obj.Add('content', Snap);
  if ASpecs.Count > 0 then
  begin
    Names := TJSONArray.Create;
    for I := 0 to AAdded.Count - 1 do Names.Add(AAdded[I]);
    Obj.Add('included', Names);
  end;
  if Snapshot then
  begin
    { untracked files stay home unless named: say how many, so a missing unit on the other
      machine is not a mystery }
    Left_ := TStringList.Create;
    try
      UntrackedLeftOut(G, AAdded, Left_);
      if Left_.Count > 0 then
      begin
        Obj.Add('untracked_left_out', Left_.Count);
        Names := TJSONArray.Create;
        for I := 0 to Left_.Count - 1 do
        begin
          if I >= 10 then Break;
          Names.Add(Left_[I]);
        end;
        Obj.Add('untracked_names', Names);
        Obj.Add('untracked_hint', 'These are not sent. A new source file the build needs: ' +
          'start again with include set to its path or a pattern.');
      end;
    finally
      Left_.Free;
    end;
  end;
  if Linked then
  begin
    Obj.Add('fetches_left', Fetches);
    if Srv.Host <> L.Host then
    begin
      Obj.Add('address_changed', 'This machine is now ' + Srv.Host + ' for ' + Peer +
        ', not ' + L.Host + ': on the other machine run git remote set-url ' + REMOTE_NAME +
        ' ' + UrlFor(Srv.Host, Srv.Port));
      L.Host := Srv.Host;
      LinkJob(loSave, L);
    end;
    Obj.Add('next', PULL_STEPS);
  end
  else
  begin
    Code := Srv.Code(Left);
    Obj.Add('code', Code);
    Obj.Add('code_seconds_left', Left);
    Cmds := TJSONObject.Create;
    Cmds.Add('bash', BashCommand(UrlFor(Srv.Host, Srv.Port), Target, Code));
    Cmds.Add('powershell', PowerShellCommand(UrlFor(Srv.Host, Srv.Port), Target, Code));
    Obj.Add('commands', Cmds);
    Obj.Add('note', 'Run one of the commands on ' + Peer + '. The code lives about a minute: ' +
      'git_serve action=code makes a fresh command. For a machine you test on often, ' +
      'git_serve link once saves all this.');
  end;
  Reply(Ctx, True, Obj);
end;

procedure DoStart(var Ctx: TMcpToolCall);
var
  Specs, Added : TStringList;
  Why : string;
begin
  Specs := TStringList.Create;
  Added := TStringList.Create;
  try
    Why := ReadIncludes(Ctx, Specs);
    if Why <> '' then
      Refused(Ctx, Why)
    else
      DoStartWith(Ctx, Specs, Added);
  finally
    Added.Free;
    Specs.Free;
  end;
end;

procedure DoCode(var Ctx: TMcpToolCall);
var
  Code : string;
  Left : Integer;
  Obj, Cmds : TJSONObject;
begin
  GLock.Enter;
  try
    if not (Assigned(GServer) and GServer.Running) then
    begin
      Refused(Ctx, 'Not serving (git_serve start).');
      Exit;
    end;
    if McpServeKey(Ctx.Bearer) <> GServer.Key then
    begin
      Refused(Ctx, 'This server is for a linked machine (its box makes the codes itself), or ' +
        'was started by another client.');
      Exit;
    end;
    Code := GServer.Code(Left);
    Obj  := StatusObject(GServer);
    Obj.Add('code', Code);
    Obj.Add('code_seconds_left', Left);
    Cmds := TJSONObject.Create;
    Cmds.Add('bash', BashCommand(UrlFor(GServer.Host, GServer.Port),
      StrParam(Ctx, 'remote_dir', 'mcp-code'), Code));
    Cmds.Add('powershell', PowerShellCommand(UrlFor(GServer.Host, GServer.Port),
      StrParam(Ctx, 'remote_dir', 'mcp-code'), Code));
    Obj.Add('commands', Cmds);
  finally
    GLock.Leave;
  end;
  Reply(Ctx, True, Obj);
end;

procedure DoUnlink(var Ctx: TMcpToolCall);
var
  L   : TLink;
  Obj : TJSONObject;
begin
  L.Peer := StrParam(Ctx, 'peer');
  if L.Peer = '' then
  begin
    Refused(Ctx, 'unlink needs peer.');
    Exit;
  end;
  GLock.Enter;
  try
    if Assigned(GServer) and (GServer.Peer = L.Peer) then GServer.Stop;
  finally
    GLock.Leave;
  end;
  Obj := TJSONObject.Create;
  Obj.Add('unlinked', LinkJob(loDrop, L));
  Reply(Ctx, True, Obj);
end;

procedure DoLinks(var Ctx: TMcpToolCall);
var
  J   : TLinkJob;
  Obj : TJSONObject;
  Arr : TJSONArray;
  Lines, F : TStringList;
  I   : Integer;
  Item : TJSONObject;
begin
  J := TLinkJob.Create;
  Lines := TStringList.Create;
  F := TStringList.Create;
  try
    J.Op := loList;
    TThread.Synchronize(nil, @J.Run);
    Lines.Text := J.Names;
    Arr := TJSONArray.Create;
    for I := 0 to Lines.Count - 1 do
    begin
      F.Delimiter := '|';
      F.StrictDelimiter := True;
      F.DelimitedText := Lines[I];
      if F.Count = 3 then
      begin
        Item := TJSONObject.Create;
        Item.Add('peer', F[0]);
        Item.Add('this_machine', F[1]);
        Item.Add('port', StrToIntDef(F[2], 0));
        Arr.Add(Item);
      end;
    end;
  finally
    F.Free;
    Lines.Free;
    J.Free;
  end;
  Obj := TJSONObject.Create;
  Obj.Add('links', Arr);
  Reply(Ctx, True, Obj);
end;

procedure GitServe(var Ctx: TMcpToolCall);
var
  Action : string;
  Obj    : TJSONObject;
begin
  Action := StrParam(Ctx, 'action', 'status');
  case Action of
    'link':   DoLink(Ctx);
    'unlink': DoUnlink(Ctx);
    'links':  DoLinks(Ctx);
    'start':  DoStart(Ctx);
    'code':   DoCode(Ctx);
    'stop':
      begin
        GLock.Enter;
        try
          if Assigned(GServer) then GServer.Stop;
          Obj := StatusObject(GServer);
        finally
          GLock.Leave;
        end;
        Reply(Ctx, True, Obj);
      end;
    'status':
      begin
        GLock.Enter;
        try
          Obj := StatusObject(GServer);
        finally
          GLock.Leave;
        end;
        Reply(Ctx, True, Obj);
      end;
  else
    Refused(Ctx, 'action must be link, unlink, links, start, stop, status or code.');
  end;
end;

function DispatchGitServe(const Name: string; var Ctx: TMcpToolCall): Boolean;
begin
  Result := Name = 'git_serve';
  if not Result then Exit;
  try
    GitServe(Ctx);
  except
    on E: Exception do
      Refused(Ctx, 'git_serve failed: ' + E.ClassName + ': ' + E.Message);
  end;
end;

procedure RegisterGitServeSchema(Tools: TJSONArray);
begin
  Tools.Add(MakeTool('git_serve',
    'Let one other machine fetch this repository (read-only, HTTP) to test code there. link ' +
    'asks the user once and returns a setup to run once on that machine; after that start ' +
    'and stop need no dialog: start opens the listener (snapshot, the default, includes ' +
    'uncommitted changes of tracked files), it closes itself after the fetch, and the assistant ' +
    'runs git_fetch and git_reset on the other machine. Without a link, start asks the user ' +
    'every time and returns a ready command with a code good for about a minute. The user may ' +
    'say no; do not retry then.',
    SCHEMA_GIT_SERVE, MCP_ANN_SERVE));
end;

initialization
  GLock := TCriticalSection.Create;
  RegisterMcpBlockingGroup(@DispatchGitServe);
  RegisterMcpSchemas(@RegisterGitServeSchema);

finalization
  if Assigned(GServer) then GServer.Stop;
  FreeAndNil(GServer);
  FreeAndNil(GLock);

end.
