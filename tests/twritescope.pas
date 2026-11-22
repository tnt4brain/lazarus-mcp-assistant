{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TWriteScope;

{ ADR-034: which tools are asked whether a path may be changed (McpWriteAllowed), and whether a
  path that goes through a link leaves its root (McpRealPath).  No IDE and no server. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, fpjson, jsonparser, McpToolContext, McpUtils,
  McpToolScope, THttpHelper;

type
  TTestWriteScope = class(TTestCase)
  private
    function Allowed(const ATool, AArgs: string): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestFileWritersAreAsked;
    procedure TestPackageCreateAndJunitOutAreAsked;
    procedure TestGitWritersAreAskedForTheirFolder;
    procedure TestGitReadsAndNewFoldersAreNotAsked;
    procedure TestGitActionsListOrChange;
    procedure TestGuardedToolList;
  end;

  { ADR-034 decision 6: the live tools/list against McpToolScope, both directions. A tool that
    changes something, or takes a path, and is in no table fails here. }
  TTestToolScope = class(TTestCase)
  published
    procedure TestEveryToolIsClassified;
    procedure TestTablesNameLiveToolsAndArguments;
    procedure TestTableAgreesWithTheGuard;
  end;

  { The same through the running server: every route of a tools/call is checked, not only the
    tools McpDispatch runs (ide_run_tests and the blocking git tools have routes of their own).
    Requires a running MCP server. }
  TTestWriteScopeLive = class(TTestCase)
  private
    function Outside: string;
  published
    procedure TestRunTestsJunitOutOutsideRefused;
    procedure TestBlockingGitToolRefusedOutside;
    procedure TestGitWritersRefusedOutside;
  end;

  TTestRealPath = class(TTestCase)
  private
    FBase, FRoot, FOutside, FLink : string;
    FLinked : Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestPlainPathsStayWhereTheyAre;
    procedure TestLinkOutOfTheRootIsRefused;
    procedure TestLexicalCheckIsFooledByTheLink;
    procedure TestNewFileBehindTheLinkIsJudgedByItsParent;
  end;

implementation

uses
  Process
  {$IFDEF UNIX}, BaseUnix{$ENDIF};

const
  IN_DIR  = 'D:/proj/inside';        { the stubs only look at the word "outside" }
  OUT_DIR = 'D:/proj/outside';

var
  GFileAsked, GFolderAsked : Integer;
  GLastFolder              : string;

function StubFile(const AFile: string; out AWhy: string): Boolean;
begin
  Inc(GFileAsked);
  Result := Pos('outside', AFile) = 0;
  if Result then AWhy := '' else AWhy := 'Refused: ' + AFile;
end;

function StubFolder(const ADir: string; out AWhy: string): Boolean;
begin
  Inc(GFolderAsked);
  GLastFolder := ADir;
  Result := Pos('outside', ADir) = 0;
  if Result then AWhy := '' else AWhy := 'Refused: ' + ADir;
end;

{ ---- TTestWriteScope -------------------------------------------------------------------------- }

procedure TTestWriteScope.SetUp;
begin
  GFileAsked := 0;
  GFolderAsked := 0;
  GLastFolder := '';
  GMcpWriteCheck  := @StubFile;
  GMcpFolderCheck := @StubFolder;
end;

procedure TTestWriteScope.TearDown;
begin
  GMcpWriteCheck  := nil;
  GMcpFolderCheck := nil;
end;

function TTestWriteScope.Allowed(const ATool, AArgs: string): Boolean;
var
  P : TJSONObject;
  W : string;
begin
  P := TJSONObject(GetJSON(AArgs));
  try
    Result := McpWriteAllowed(ATool, P, W);
    CheckEquals(Result, W = '', ATool + ': a refusal says why, a pass says nothing: ' + W);
  finally
    P.Free;
  end;
end;

procedure TTestWriteScope.TestFileWritersAreAsked;
const
  TOOLS : array[0..8] of string = (
    'code_add_uses', 'code_add_to_class', 'code_insert_in_procedure',
    'code_replace_procedure_body', 'code_edit_statement', 'code_complete', 'code_format',
    'code_rename_identifier', 'code_extract_method');
var
  T : string;
begin
  for T in TOOLS do
  begin
    CheckFalse(Allowed(T, '{"file":"' + OUT_DIR + '/a.pas"}'), T + ' outside');
    CheckTrue(Allowed(T, '{"file":"' + IN_DIR + '/a.pas"}'), T + ' inside');
    CheckTrue(Allowed(T, '{"file":"' + OUT_DIR + '/a.pas","dry_run":true}'), T + ' dry run');
  end;
  CheckFalse(Allowed('form_set_properties', '{"file":"' + OUT_DIR + '/f.pas"}'), 'a form tool');
  CheckFalse(Allowed('git_archive', '{"output":"' + OUT_DIR + '/a.zip"}'), 'git_archive output');
  CheckTrue(Allowed('git_archive', '{"output":"' + IN_DIR + '/a.zip"}'), 'git_archive output inside');
end;

procedure TTestWriteScope.TestPackageCreateAndJunitOutAreAsked;
begin
  CheckFalse(Allowed('package_create', '{"directory":"' + OUT_DIR + '/pkg"}'), 'package_create outside');
  CheckTrue(Allowed('package_create', '{"directory":"' + IN_DIR + '/pkg"}'), 'package_create inside');
  CheckTrue(Allowed('package_create', '{"name":"X"}'), 'no directory: the tool reports it');
  CheckFalse(Allowed('ide_run_tests', '{"junit_out":"' + OUT_DIR + '/r.xml"}'), 'junit_out outside');
  CheckTrue(Allowed('ide_run_tests', '{"junit_out":"' + IN_DIR + '/r.xml"}'), 'junit_out inside');
  CheckTrue(Allowed('ide_run_tests', '{"suite":"X"}'), 'no junit_out: nothing is written');
end;

procedure TTestWriteScope.TestGitWritersAreAskedForTheirFolder;
const
  TOOLS : array[0..16] of string = (
    'git_add', 'git_branch_delete', 'git_checkout', 'git_cherry_pick', 'git_commit', 'git_fetch',
    'git_merge', 'git_merge_abort', 'git_pull', 'git_push', 'git_rebase', 'git_rebase_abort',
    'git_rebase_continue', 'git_reset', 'git_resolve', 'git_squash', 'git_stash');
var
  T : string;
begin
  for T in TOOLS do
  begin
    CheckFalse(Allowed(T, '{"work_dir":"' + OUT_DIR + '"}'), T + ' outside');
    CheckTrue(Allowed(T, '{"work_dir":"' + IN_DIR + '"}'), T + ' inside');
  end;
  GFolderAsked := 0;
  CheckTrue(Allowed('git_commit', '{"message":"x"}'), 'no work_dir: the default folder is asked');
  CheckEquals(1, GFolderAsked, 'asked once');
  CheckEquals('', GLastFolder, 'with the empty name, which the hook resolves');
end;

procedure TTestWriteScope.TestGitReadsAndNewFoldersAreNotAsked;
const
  TOOLS : array[0..8] of string = (
    'git_status', 'git_log', 'git_diff', 'git_blame', 'git_branches', 'git_init', 'git_clone',
    'project_create', 'editor_read_file');
var
  T : string;
begin
  for T in TOOLS do
    CheckTrue(Allowed(T, '{"work_dir":"' + OUT_DIR + '","target_dir":"' + OUT_DIR + '/n"}'),
      T + ' is not asked');
  CheckEquals(0, GFolderAsked, 'no folder asked');
  CheckEquals(0, GFileAsked, 'no file asked');
end;

procedure TTestWriteScope.TestGitActionsListOrChange;
begin
  CheckTrue(Allowed('git_remote', '{"action":"list","work_dir":"' + OUT_DIR + '"}'), 'remote list');
  CheckFalse(Allowed('git_remote', '{"action":"add","work_dir":"' + OUT_DIR + '"}'), 'remote add');
  CheckTrue(Allowed('git_remote', '{"action":"add","work_dir":"' + IN_DIR + '"}'), 'remote add inside');
  CheckTrue(Allowed('git_tag', '{"action":"list","work_dir":"' + OUT_DIR + '"}'), 'tag list');
  CheckFalse(Allowed('git_tag', '{"action":"create","work_dir":"' + OUT_DIR + '"}'), 'tag create');
  CheckFalse(Allowed('git_tag', '{"action":"delete","work_dir":"' + OUT_DIR + '"}'), 'tag delete');
end;

procedure TTestWriteScope.TestGuardedToolList;
const
  GUARDED : array[0..10] of string = (
    'code_format', 'form_arrange', 'package_save', 'git_archive', 'ide_run_tests',
    'package_create', 'git_fetch', 'git_push', 'git_remote', 'git_tag', 'git_serve');
  UNGUARDED : array[0..6] of string = (
    'git_status', 'git_log', 'git_init', 'git_clone', 'editor_read_file', 'project_create',
    'ide_ping');
var
  T : string;
begin
  for T in GUARDED do CheckTrue(McpToolIsWriteGuarded(T), T + ' is guarded');
  for T in UNGUARDED do CheckFalse(McpToolIsWriteGuarded(T), T + ' is not');
end;

{ ---- TTestToolScope --------------------------------------------------------------------------- }

const
  { arguments that name a place in the file system, or look like one }
  PATHY : array[0..21] of string = (
    'file', 'directory', 'lpk_path', 'work_dir', 'search_dir', 'project_dir', 'target_dir',
    'output', 'junit_out', 'test_project', 'unit_paths', 'output_dir', 'unit_output_dir',
    'unit_search_path', 'include_path', 'usage_unit_path', 'usage_include_path', 'path', 'paths',
    'files', 'active_file', 'target');

function LiveTools: TJSONArray;
var
  R : THttpResult;
begin
  R := McpPost('{"jsonrpc":"2.0","id":9,"method":"tools/list"}');
  Result := TJSONArray(TJSONObject(TJSONObject(GetJSON(R.Body)).Find('result')).Find('tools'));
end;

function IsPathy(const AArg: string): Boolean;
var
  I : Integer;
begin
  for I := 0 to High(PATHY) do
    if PATHY[I] = AArg then Exit(True);
  Result := False;
end;

function InPathTable(const ATool, AArg: string; out AUse: TMcpPathUse): Boolean;
var
  I : Integer;
  P : TMcpToolPath;
begin
  Result := False;
  AUse := puRead;
  for I := 0 to McpToolPathCount - 1 do
  begin
    P := McpToolPathAt(I);
    if (P.Tool = ATool) and (P.Arg = AArg) then
    begin
      AUse := P.Use;
      Exit(True);
    end;
  end;
end;

function InNoPath(const ATool: string): Boolean;
var
  I : Integer;
begin
  for I := 0 to McpNoPathCount - 1 do
    if McpNoPathTool(I) = ATool then Exit(True);
  Result := False;
end;

function HasWritingPath(const ATool: string): Boolean;
var
  I : Integer;
  P : TMcpToolPath;
begin
  Result := False;
  for I := 0 to McpToolPathCount - 1 do
  begin
    P := McpToolPathAt(I);
    if (P.Tool = ATool) and (P.Use <> puRead) then Exit(True);
  end;
end;

procedure TTestToolScope.TestEveryToolIsClassified;
var
  Tools : TJSONArray;
  I     : Integer;
  T     : TJSONObject;
  Name  : string;
  Props : TJSONObject;
  K     : Integer;
  Arg   : string;
  U     : TMcpPathUse;
  RO    : Boolean;
  Ann   : TJSONData;
begin
  Tools := LiveTools;
  CheckTrue(Tools.Count > 100, 'the live list');
  for I := 0 to Tools.Count - 1 do
  begin
    T := TJSONObject(Tools[I]);
    Name := T.Get('name', '');
    RO := False;
    Ann := T.Find('annotations');
    if Ann is TJSONObject then RO := TJSONObject(Ann).Get('readOnlyHint', False);
    Props := TJSONObject(TJSONObject(T.Find('inputSchema')).Find('properties'));
    { every argument that looks like a path is classified }
    if Assigned(Props) then
      for K := 0 to Props.Count - 1 do
      begin
        Arg := Props.Names[K];
        if IsPathy(Arg) and not InPathTable(Name, Arg, U) and not McpIsNotAPath(Name, Arg) then
          Fail(Name + ' takes ' + Arg + ', which is in no table of McpToolScope');
      end;
    { a tool that changes something has a writing path or a reason }
    if not RO then
      CheckTrue(HasWritingPath(Name) or InNoPath(Name),
        Name + ' changes something and is in no table of McpToolScope');
  end;
end;

procedure TTestToolScope.TestTablesNameLiveToolsAndArguments;
var
  Tools : TJSONArray;
  I, K  : Integer;
  P     : TMcpToolPath;
  T     : TJSONObject;
  Names : TStringList;
  Props : TJSONObject;
begin
  Tools := LiveTools;
  Names := TStringList.Create;
  try
    for I := 0 to Tools.Count - 1 do
      Names.AddObject(TJSONObject(Tools[I]).Get('name', ''), Tools[I]);
    for I := 0 to McpToolPathCount - 1 do
    begin
      P := McpToolPathAt(I);
      K := Names.IndexOf(P.Tool);
      CheckTrue(K >= 0, 'the table names a tool that is not there: ' + P.Tool);
      if K < 0 then Continue;
      T := TJSONObject(Names.Objects[K]);
      Props := TJSONObject(TJSONObject(T.Find('inputSchema')).Find('properties'));
      CheckTrue(Assigned(Props) and (Props.Find(P.Arg) <> nil),
        P.Tool + ' has no argument ' + P.Arg);
    end;
    for I := 0 to McpNoPathCount - 1 do
      CheckTrue(Names.IndexOf(McpNoPathTool(I)) >= 0,
        'no-path table names a tool that is not there: ' + McpNoPathTool(I));
  finally
    Names.Free;
  end;
end;

procedure TTestToolScope.TestTableAgreesWithTheGuard;
var
  I : Integer;
  P : TMcpToolPath;
begin
  for I := 0 to McpToolPathCount - 1 do
  begin
    P := McpToolPathAt(I);
    case P.Use of
      puWrite, puFolder:
        CheckTrue(McpToolIsWriteGuarded(P.Tool),
          P.Tool + ' (' + P.Arg + ') is asked before it runs, but McpToolIsWriteGuarded says no');
      puWriteInTool, puFolderInTool, puNewPlace, puRead:
        { a guarded tool whose argument is only read, or whose tool asks itself, is allowed }
        ;
    end;
  end;
  for I := 0 to McpNoPathCount - 1 do
    if McpNoPathCategory(I) = 'p' then
      CheckTrue(McpToolIsWriteGuarded(McpNoPathTool(I)), McpNoPathTool(I) + ' is not guarded');
end;

{ ---- TTestWriteScopeLive ---------------------------------------------------------------------- }

function TTestWriteScopeLive.Outside: string;
begin
  { the user's home: never a root (a project could sit there, but not the test's) }
  Result := ExcludeTrailingPathDelimiter(GetUserDir);
end;

procedure TTestWriteScopeLive.TestRunTestsJunitOutOutsideRefused;
var
  F, T : string;
begin
  F := Outside + PathDelim + 'mcp_scope_probe_' + IntToStr(GetProcessID) + '.xml';
  try
    T := CallToolText('ide_run_tests', '{"suite":"TTestUtils","junit_out":' + JsonStr(F) + '}', []);
    CheckTrue(Pos('Refused', T) > 0, 'refused: ' + T);
    CheckFalse(FileExists(F), 'nothing was written');
  finally
    if FileExists(F) then DeleteFile(F);
  end;
end;

procedure TTestWriteScopeLive.TestBlockingGitToolRefusedOutside;
var
  T : string;
begin
  { git_fetch runs on the worker thread (RunGitTimed), not through McpDispatch }
  T := CallToolText('git_fetch', '{"work_dir":' + JsonStr(Outside) + '}', []);
  CheckTrue(Pos('Refused', T) > 0, 'refused: ' + T);
end;

procedure TTestWriteScopeLive.TestGitWritersRefusedOutside;
const
  { each with the arguments it needs to get past the argument check, which comes first }
  TOOLS : array[0..3] of string = ('git_add', 'git_commit', 'git_checkout', 'git_reset');
  ARGS  : array[0..3] of string = ('"paths":["x"]', '"message":"x"', '"target":"x"', '"target":"HEAD"');
var
  T : string;
  I : Integer;
begin
  for I := Low(TOOLS) to High(TOOLS) do
  begin
    T := CallToolText(TOOLS[I], '{' + ARGS[I] + ',"work_dir":' + JsonStr(Outside) + '}', []);
    CheckTrue(Pos('Refused', T) > 0, TOOLS[I] + ' refused: ' + Copy(T, 1, 200));
  end;
end;

{ ---- TTestRealPath ---------------------------------------------------------------------------- }

procedure TTestRealPath.SetUp;
var
  S : string;
begin
  FBase    := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'mcpreal' + IntToStr(GetProcessID);
  FRoot    := FBase + PathDelim + 'root';
  FOutside := FBase + PathDelim + 'outside';
  FLink    := FRoot + PathDelim + 'link';
  ForceDirectories(FRoot + PathDelim + 'inside');
  ForceDirectories(FOutside);
  FLinked := False;
  {$IFDEF UNIX}
  FLinked := fpSymlink(PChar(FOutside), PChar(FLink)) = 0;
  {$ELSE}
  FLinked := RunCommand('cmd', ['/c', 'mklink', '/J', FLink, FOutside], S) and DirectoryExists(FLink);
  {$ENDIF}
end;

procedure TTestRealPath.TearDown;
begin
  if FLinked then
  begin
    {$IFDEF UNIX}
    DeleteFile(FLink);
    {$ELSE}
    RemoveDir(FLink);   { removes the junction, not what it points at }
    {$ENDIF}
  end;
  RemoveDir(FRoot + PathDelim + 'inside');
  RemoveDir(FRoot);
  RemoveDir(FOutside);
  RemoveDir(FBase);
end;

procedure TTestRealPath.TestPlainPathsStayWhereTheyAre;
begin
  CheckTrue(McpPathIsUnderReal(FRoot + PathDelim + 'inside' + PathDelim + 'a.pas', FRoot), 'a new file inside');
  CheckTrue(McpPathIsUnderReal(FRoot + PathDelim + 'x' + PathDelim + 'y' + PathDelim + 'a.pas', FRoot),
    'a new file in a folder that does not exist yet');
  CheckFalse(McpPathIsUnderReal(FOutside + PathDelim + 'a.pas', FRoot), 'a sibling folder');
  CheckFalse(McpPathIsUnderReal(FRoot, FRoot), 'the root itself, as before');
  CheckFalse(McpPathIsUnderReal('mcproot', FRoot), 'a relative path');
end;

procedure TTestRealPath.TestLinkOutOfTheRootIsRefused;
begin
  if not FLinked then begin Ignore('could not make a link here'); Exit; end;
  CheckFalse(McpPathIsUnderReal(FLink + PathDelim + 'a.pas', FRoot), 'a new file behind the link');
  CheckTrue(SameText(McpRealPath(FLink), McpRealPath(FOutside)), 'the link is where it points: ' + McpRealPath(FLink));
  { a root that is a link counts as where it points }
  CheckTrue(McpPathIsUnderReal(FOutside + PathDelim + 'a.pas', FLink), 'the root is a link');
end;

procedure TTestRealPath.TestLexicalCheckIsFooledByTheLink;
begin
  if not FLinked then begin Ignore('could not make a link here'); Exit; end;
  { why the real path is needed: the text of the path says "inside the root" }
  CheckTrue(McpPathIsUnder(FLink + PathDelim + 'a.pas', FRoot), 'McpPathIsUnder looks at the text only');
end;

procedure TTestRealPath.TestNewFileBehindTheLinkIsJudgedByItsParent;
var
  F : TextFile;
  P : string;
begin
  if not FLinked then begin Ignore('could not make a link here'); Exit; end;
  P := FOutside + PathDelim + 'there.pas';
  AssignFile(F, P);
  Rewrite(F);
  CloseFile(F);
  try
    CheckFalse(McpPathIsUnderReal(FLink + PathDelim + 'there.pas', FRoot), 'an existing file behind the link');
    CheckFalse(McpPathIsUnderReal(FLink + PathDelim + 'sub' + PathDelim + 'new.pas', FRoot),
      'a file in a folder behind the link that does not exist');
  finally
    DeleteFile(P);
  end;
end;

initialization
  RegisterTest(TTestWriteScope);
  RegisterTest(TTestWriteScopeLive);
  RegisterTest(TTestToolScope);
  RegisterTest(TTestRealPath);

end.
