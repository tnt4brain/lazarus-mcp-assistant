{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TStatus;

{ TTestStatus — FPCUnit tests for ide_get_status.
  Requires a running MCP server (GServerAvail = True).  Read-only calls only:
  the answer's shape, its agreement with project_get_directory, and the
  include_git flag.  Whatever project is open in the IDE stays untouched.

  TTestStatusClosedProject closes the project to see the no-project answer
  and reopens it (TearDown restores whatever project was open); the suite is
  registered only with MCP_DEBUG_TESTS=1, so a plain run never disturbs the
  IDE's project. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, fpjson, THttpHelper;

type
  TStatusTestBase = class(TTestCase)
  protected
    procedure CheckEditorsSection(const Editors: TJSONObject);
    procedure CheckDebuggerSection(const Debugger: TJSONObject);
    procedure CheckServerSection(const Server: TJSONObject);
    procedure CheckStatusWithoutProject(const Status: TJSONObject);
  end;

  TTestStatus = class(TStatusTestBase)
  published
    procedure TestStatusInToolsList;
    procedure TestStatusSchemaHasIncludeGit;
    procedure TestOutputSchemaIsListedAndAnswered;
    procedure TestStatusStructure;
    procedure TestStatusProjectMatchesProjectOpen;
    procedure TestStatusWithoutGitSection;
    procedure TestStatusWithGitSection;
  end;

  { opt-in: it switches the IDE's project (project_close, then project_open) }
  TTestStatusClosedProject = class(TStatusTestBase)
  protected
    procedure TearDown; override;
  published
    procedure TestClosedProjectOmitsProjectSection;
  end;

implementation

uses
  SysUtils, jsonparser;

var
  { the project TTestStatusClosedProject must restore in TearDown }
  GProjectFileToReopen: string = '';

{ ── Helpers ──────────────────────────────────────────────────────────────── }

function ParseJSONObj(const S: string): TJSONObject;
var
  D : TJSONData;
begin
  D := GetJSON(S);
  if not (D is TJSONObject) then
  begin
    D.Free;
    raise EAssertionFailedError.Create('Response is not a JSON object: ' + S);
  end;
  Result := TJSONObject(D);
end;

function CallStatus(const ArgsJSON: string): TJSONObject;
begin
  Result := ParseJSONObj(CallToolText('ide_get_status', ArgsJSON, []));
end;

function GetToolsArray: TJSONArray;
var
  R   : THttpResult;
  Obj : TJSONObject;
begin
  R := McpPost('{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
  Obj := ParseJSONObj(R.Body);
  try
    Result := TJSONArray(TJSONObject(Obj.Find('result')).Find('tools').Clone);
  finally
    Obj.Free;
  end;
end;

function FindTool(const Tools: TJSONArray; const AName: string): TJSONObject;
var
  I : Integer;
begin
  Result := nil;
  for I := 0 to Tools.Count - 1 do
    if TJSONObject(Tools[I]).Get('name', '') = AName then
      Exit(TJSONObject(Tools[I]));
end;

{ ── TStatusTestBase ──────────────────────────────────────────────────────── }

procedure TStatusTestBase.CheckEditorsSection(const Editors: TJSONObject);
var
  Unsaved : TJSONArray;
  I       : Integer;
begin
  CheckTrue(Editors.Get('unsaved_count', -1) >= 0,
    'editors must have unsaved_count');
  if Editors.Find('unsaved') = nil then Exit;
  Unsaved := Editors.Arrays['unsaved'];
  CheckTrue(Unsaved.Count <= 10, 'the unsaved list is capped at 10');
  CheckTrue(Unsaved.Count <= Editors.Get('unsaved_count', -1),
    'the unsaved list cannot be longer than unsaved_count');
  for I := 0 to Unsaved.Count - 1 do
    CheckTrue(Trim(Unsaved.Strings[I]) <> '', 'unsaved entries are file names');
  if Editors.Find('truncated') <> nil then
    CheckTrue(Editors.Get('truncated', False) and
              (Editors.Get('unsaved_count', 0) > Unsaved.Count),
      'truncated=true implies more unsaved files than listed');
end;

procedure TStatusTestBase.CheckDebuggerSection(const Debugger: TJSONObject);
var
  State : string;
begin
  CheckTrue(Assigned(Debugger.Find('state')), 'debugger must have a state');
  State := Debugger.Get('state', '');
  CheckTrue((State = 'idle') or (State = 'running') or (State = 'paused') or
            (State = 'stopped') or (State = 'error'),
    'debugger state must be one of the known words, got "' + State + '"');
  if Debugger.Find('lease') <> nil then
    CheckTrue(TJSONObject(Debugger.Find('lease')).Get('owner', '') <> '',
      'a lease must name its owner');
end;

procedure TStatusTestBase.CheckServerSection(const Server: TJSONObject);
begin
  CheckTrue(Trim(Server.Get('version', '')) <> '', 'server must report a version');
end;

procedure TStatusTestBase.CheckStatusWithoutProject(const Status: TJSONObject);
begin
  CheckTrue(Status.Find('project') = nil,
    'with no project open the project section is omitted');
  CheckTrue(Status.Find('git') = nil,
    'with no project open there is no git section');
  CheckEditorsSection(TJSONObject(Status.Find('editors')));
  CheckDebuggerSection(TJSONObject(Status.Find('debugger')));
  CheckServerSection(TJSONObject(Status.Find('server')));
end;

{ ── TTestStatus ──────────────────────────────────────────────────────────── }

procedure TTestStatus.TestStatusInToolsList;
var
  Tools   : TJSONArray;
  ToolObj : TJSONObject;
  Ann     : TJSONObject;
begin
  Tools := GetToolsArray;
  try
    ToolObj := FindTool(Tools, 'ide_get_status');
    CheckTrue(Assigned(ToolObj), 'ide_get_status must be in tools/list');
    CheckTrue(Assigned(ToolObj.Find('inputSchema')),
      'ide_get_status must have inputSchema');
    Ann := TJSONObject(ToolObj.Find('annotations'));
    CheckTrue(Assigned(Ann) and Ann.Get('readOnlyHint', False),
      'ide_get_status is a read-only tool');
  finally
    Tools.Free;
  end;
end;

{ outputSchema: only ide_get_status has one, and its answer comes twice, as text and as
  structuredContent (the same object); a tool without one has no structuredContent }
procedure TTestStatus.TestOutputSchemaIsListedAndAnswered;
var
  Tools   : TJSONArray;
  ToolObj : TJSONObject;
  Schema  : TJSONObject;
  I, N    : Integer;
  R       : THttpResult;
  Resp    : TJSONObject;
  Res     : TJSONObject;
  Text    : string;
  FromText: TJSONObject;
begin
  Tools := GetToolsArray;
  try
    N := 0;
    for I := 0 to Tools.Count - 1 do
      if TJSONObject(Tools[I]).Find('outputSchema') <> nil then Inc(N);
    CheckEquals(1, N, 'one tool has an outputSchema (ide_get_status): the diet of ADR-029');
    ToolObj := FindTool(Tools, 'ide_get_status');
    Schema := TJSONObject(ToolObj.Find('outputSchema'));
    CheckTrue(Assigned(Schema), 'ide_get_status has an outputSchema');
    CheckEquals('object', Schema.Get('type', ''), 'the root of an outputSchema is an object');
    CheckTrue(Assigned(TJSONObject(Schema.Find('properties')).Find('debugger')), 'the schema names the debugger section');
  finally
    Tools.Free;
  end;

  R := McpPost('{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"ide_get_status","arguments":{}}}');
  Resp := ParseJSONObj(R.Body);
  try
    Res := TJSONObject(Resp.Find('result'));
    CheckTrue(Assigned(Res.Find('structuredContent')), 'the answer carries structuredContent');
    Text := TJSONObject(TJSONArray(Res.Find('content'))[0]).Get('text', '');
    FromText := ParseJSONObj(Text);
    try
      CheckEquals(FromText.AsJSON, Res.Find('structuredContent').AsJSON,
        'structuredContent is the object of the text content');
    finally
      FromText.Free;
    end;
    CheckTrue(Assigned(TJSONObject(Res.Find('structuredContent')).Find('debugger')), 'with its debugger section');
  finally
    Resp.Free;
  end;

  R := McpPost('{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"ide_ping","arguments":{}}}');
  Resp := ParseJSONObj(R.Body);
  try
    CheckTrue(TJSONObject(Resp.Find('result')).Find('structuredContent') = nil,
      'a tool without an outputSchema has no structuredContent');
  finally
    Resp.Free;
  end;
end;

procedure TTestStatus.TestStatusSchemaHasIncludeGit;
var
  Tools   : TJSONArray;
  ToolObj : TJSONObject;
  Props   : TJSONObject;
begin
  Tools := GetToolsArray;
  try
    ToolObj := FindTool(Tools, 'ide_get_status');
    CheckTrue(Assigned(ToolObj), 'ide_get_status must be in tools/list');
    Props := TJSONObject(TJSONObject(ToolObj.Find('inputSchema')).Find('properties'));
    CheckTrue(Assigned(Props) and Assigned(Props.Find('include_git')),
      'ide_get_status schema must contain include_git');
  finally
    Tools.Free;
  end;
end;

procedure TTestStatus.TestStatusStructure;
var
  Status : TJSONObject;
  Proj   : TJSONObject;
begin
  Status := CallStatus('{}');
  try
    if Status.Find('project') <> nil then
    begin
      Proj := TJSONObject(Status.Find('project'));
      CheckTrue(Trim(Proj.Get('name', '')) <> '',
        'an open project must have a name');
      CheckTrue(Trim(Proj.Get('project_file', '')) <> '',
        'an open project must have project_file');
      CheckTrue(Trim(Proj.Get('directory', '')) <> '',
        'an open project must have a directory');
    end;
    CheckTrue(Status.Find('editors') <> nil, 'editors section is always there');
    CheckEditorsSection(TJSONObject(Status.Find('editors')));
    CheckTrue(Status.Find('debugger') <> nil, 'debugger section is always there');
    CheckDebuggerSection(TJSONObject(Status.Find('debugger')));
    CheckTrue(Status.Find('server') <> nil, 'server section is always there');
    CheckServerSection(TJSONObject(Status.Find('server')));
    CheckTrue(Status.Find('git') = nil,
      'without include_git there is no git section');
  finally
    Status.Free;
  end;
end;

procedure TTestStatus.TestStatusProjectMatchesProjectOpen;
var
  DirObj : TJSONObject;
  Status : TJSONObject;
  Proj   : TJSONObject;
  Open   : Boolean;
begin
  DirObj := ParseJSONObj(CallToolText('project_get_directory', '{}', []));
  try
    Open := DirObj.Get('project_open', False);
  finally
    DirObj.Free;
  end;
  Status := CallStatus('{}');
  try
    CheckTrue((Status.Find('project') <> nil) = Open,
      'the project section is present exactly when a project is open');
    if Open then
    begin
      Proj := TJSONObject(Status.Find('project'));
      CheckTrue(Trim(Proj.Get('directory', '')) <> '',
        'an open project must have a directory');
    end;
  finally
    Status.Free;
  end;
end;

procedure TTestStatus.TestStatusWithoutGitSection;
var
  Status : TJSONObject;
begin
  Status := CallStatus('{"include_git":false}');
  try
    CheckTrue(Status.Find('git') = nil,
      'include_git=false (default) must not add the git section');
  finally
    Status.Free;
  end;
end;

procedure TTestStatus.TestStatusWithGitSection;
var
  Status  : TJSONObject;
  Tmp     : TJSONObject;
  Git     : TJSONObject;
  HasProj : Boolean;
begin
  { git is reported for the open project's directory only }
  Tmp := CallStatus('{}');
  try
    HasProj := Tmp.Find('project') <> nil;
  finally
    Tmp.Free;
  end;
  if not HasProj then Exit;
  Status := CallStatus('{"include_git":true}');
  try
    Git := TJSONObject(Status.Find('git'));
    CheckTrue(Assigned(Git) and Assigned(Git.Find('in_repo')),
      'git section must have in_repo');
    if Git.Get('in_repo', False) then
    begin
      CheckTrue(Trim(Git.Get('branch', '')) <> '',
        'inside a repository there is a branch');
      CheckTrue(Git.Get('changed', -1) >= 0, 'git section has a changed count');
    end
    else
      CheckTrue(Git.Find('branch') = nil,
        'outside a repository there is no branch');
  finally
    Status.Free;
  end;
end;

{ ── TTestStatusClosedProject ─────────────────────────────────────────────── }

procedure TTestStatusClosedProject.TearDown;
begin
  if GProjectFileToReopen <> '' then
  begin
    CallToolText('project_open',
      '{"file":' + JsonStr(GProjectFileToReopen) + '}', []);
    GProjectFileToReopen := '';
  end;
end;

procedure TTestStatusClosedProject.TestClosedProjectOmitsProjectSection;
var
  Settings : TJSONObject;
  Status   : TJSONObject;
  WaitedMs : Integer;
begin
  Settings := ParseJSONObj(CallToolText('project_get_settings', '{}', []));
  try
    GProjectFileToReopen := Settings.Get('project_file', '');
  finally
    Settings.Free;
  end;
  CheckTrue(GProjectFileToReopen <> '', 'a project must be open for this test');
  CheckTrue(Pos('TOOL ERROR', CallToolText('project_close', '{}', [])) = 0,
    'project_close must succeed (no unsaved changes, no debug session)');
  { the close is a menu click from a 200 ms timer, so the answer is polled
    until the project is really gone (the IDE shows its Project Wizard then;
    ide_get_status still answers) }
  Status := nil;
  WaitedMs := 0;
  repeat
    Sleep(200);
    Inc(WaitedMs, 200);
    FreeAndNil(Status);
    Status := CallStatus('{"include_git":true}');
  until (Status.Find('project') = nil) or (WaitedMs >= 5000);
  try
    CheckTrue(Status.Find('project') = nil,
      'with no project open the project section is omitted (waited ' +
      IntToStr(WaitedMs) + ' ms)');
    CheckStatusWithoutProject(Status);
  finally
    Status.Free;
  end;
  { TearDown reopens the project, whatever happened above }
end;

end.
