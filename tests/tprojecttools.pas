{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TProjectTools;

{ TTestProjectTools — FPCUnit tests for FR-006 project lifecycle tools.
  Requires a running MCP server (GServerAvail = True).

  Only read-only or side-effect-free calls are made here:
    - tools/list presence check for all 8 FR-006 tools
    - run_tests schema regression (not RTProps / replace_text schema)
    - search_components with a known component name
    - get_messages structure check
  Mutating tools (add/remove_file, create_form, set_project_settings,
  run_with_args) are not called from automated tests to avoid touching
  whatever project is open in the IDE. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, THttpHelper;

type
  TTestProjectTools = class(TTestCase)
  published
    procedure TestFR006ToolsInList;
    procedure TestRunTestsSchemaNotReplaceText;
    procedure TestSearchComponentsReturnsArray;
    procedure TestGetMessagesReturnsStructure;
    procedure TestCreateProjectSchema;
    procedure TestListProjectTemplatesReturnsArray;
  end;

implementation

uses
  SysUtils, fpjson, jsonparser;

function ParseJSON(const S: string): TJSONObject;
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

{ ── Helpers ──────────────────────────────────────────────────────────────── }

function CallTool(const ToolName, ArgsJSON: string): THttpResult;
begin
  Result := McpPost(
    '{"jsonrpc":"2.0","id":99,"method":"tools/call",' +
    '"params":{"name":"' + ToolName + '","arguments":' + ArgsJSON + '}}');
end;

function GetToolsArray: TJSONArray;
var
  R   : THttpResult;
  Obj : TJSONObject;
  Res : TJSONObject;
begin
  R := McpPost('{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
  Obj := ParseJSON(R.Body);
  Res := TJSONObject(Obj.Find('result'));
  Result := TJSONArray(Res.Find('tools').Clone);
  Obj.Free;
end;

{ ── Tests ─────────────────────────────────────────────────────────────────── }

procedure TTestProjectTools.TestFR006ToolsInList;
const
  N_Tools = 10;
  Expected: array[0..N_Tools - 1] of string = (
    'add_file_to_project', 'remove_file_from_project', 'create_form',
    'set_project_settings', 'open_file', 'search_components',
    'run_with_args', 'get_messages', 'create_project', 'list_project_templates');
var
  Tools   : TJSONArray;
  Found   : array[0..N_Tools - 1] of Boolean;
  I, K    : Integer;
  Missing : string;
  AllOK   : Boolean;
begin
  Tools := GetToolsArray;
  try
    FillChar(Found, SizeOf(Found), 0);
    for I := 0 to Tools.Count - 1 do
      for K := 0 to N_Tools - 1 do
        if TJSONObject(Tools[I]).Get('name', '') = Expected[K] then
          Found[K] := True;
  finally
    Tools.Free;
  end;
  AllOK   := True;
  Missing := '';
  for K := 0 to N_Tools - 1 do
    if not Found[K] then
    begin
      AllOK := False;
      if Missing <> '' then Missing := Missing + ', ';
      Missing := Missing + Expected[K];
    end;
  CheckTrue(AllOK, 'FR-006 tools missing from tools/list: ' + Missing);
end;

procedure TTestProjectTools.TestRunTestsSchemaNotReplaceText;
{ Regression for the RTProps/RunTProps double-free bug (line 731 fix).
  Verifies run_tests exposes test_project in its schema, not start_line
  (which would indicate it was accidentally given replace_text''s schema). }
var
  Tools    : TJSONArray;
  I        : Integer;
  ToolObj  : TJSONObject;
  Schema   : TJSONObject;
  Props    : TJSONObject;
begin
  Tools := GetToolsArray;
  try
    ToolObj := nil;
    for I := 0 to Tools.Count - 1 do
      if TJSONObject(Tools[I]).Get('name', '') = 'run_tests' then
      begin
        ToolObj := TJSONObject(Tools[I]);
        Break;
      end;
    CheckTrue(Assigned(ToolObj), 'run_tests must be in tools/list');
    Schema := TJSONObject(ToolObj.Find('inputSchema'));
    CheckTrue(Assigned(Schema), 'run_tests must have inputSchema');
    Props := TJSONObject(Schema.Find('properties'));
    CheckTrue(Assigned(Props), 'run_tests inputSchema must have properties');
    CheckTrue(Assigned(Props.Find('test_project')),
      'run_tests schema must contain test_project (not replace_text schema)');
    CheckTrue(Props.Find('start_line') = nil,
      'run_tests schema must NOT contain start_line (replace_text field)');
  finally
    Tools.Free;
  end;
end;

procedure TTestProjectTools.TestSearchComponentsReturnsArray;
{ Calls search_components with 'TButton' — always registered in the LCL.
  Only runs when server is available; safe (read-only). }
var
  R       : THttpResult;
  Obj     : TJSONObject;
  Res     : TJSONObject;
  Content : TJSONArray;
  Item0   : TJSONObject;
  Results : TJSONArray;
begin
  R := CallTool('search_components', '{"query":"TButton"}');
  CheckEquals(200, R.Code, 'search_components must return HTTP 200');
  Obj := ParseJSON(R.Body);
  try
    Res := TJSONObject(Obj.Find('result'));
    CheckTrue(Assigned(Res), 'search_components must return a result');
    Content := TJSONArray(Res.Find('content'));
    CheckTrue(Assigned(Content) and (Content.Count > 0),
      'search_components result must have content');
    // The text payload is JSON itself — parse it
    Results := TJSONArray(GetJSON(TJSONObject(Content[0]).Get('text', '[]')));
    try
      CheckTrue(Results.Count > 0,
        'search_components("TButton") must return at least one match');
      Item0 := TJSONObject(Results[0]);
      CheckTrue(Assigned(Item0.Find('class_name')),
        'Each result must have class_name');
      CheckTrue(Assigned(Item0.Find('unit_name')),
        'Each result must have unit_name');
      CheckTrue(Assigned(Item0.Find('palette_page')),
        'Each result must have palette_page');
    finally
      Results.Free;
    end;
  finally
    Obj.Free;
  end;
end;

procedure TTestProjectTools.TestGetMessagesReturnsStructure;
var
  R       : THttpResult;
  Obj     : TJSONObject;
  Res     : TJSONObject;
  Content : TJSONArray;
  Payload : TJSONObject;
begin
  R := CallTool('get_messages', '{}');
  CheckEquals(200, R.Code, 'get_messages must return HTTP 200');
  Obj := ParseJSON(R.Body);
  try
    Res := TJSONObject(Obj.Find('result'));
    CheckTrue(Assigned(Res), 'get_messages must return a result');
    Content := TJSONArray(Res.Find('content'));
    CheckTrue(Assigned(Content) and (Content.Count > 0),
      'get_messages must have content');
    Payload := TJSONObject(GetJSON(TJSONObject(Content[0]).Get('text', '{}')));
    try
      CheckTrue(Assigned(Payload.Find('messages')),
        'get_messages payload must contain "messages" array');
      CheckTrue(Assigned(Payload.Find('line_count')),
        'get_messages payload must contain "line_count"');
    finally
      Payload.Free;
    end;
  finally
    Obj.Free;
  end;
end;

procedure TTestProjectTools.TestListProjectTemplatesReturnsArray;
{ Live call — read-only, returns registered project descriptors. }
var
  R       : THttpResult;
  Obj     : TJSONObject;
  Res     : TJSONObject;
  Content : TJSONArray;
  Items   : TJSONArray;
  Item0   : TJSONObject;
  HasApp  : Boolean;
  I       : Integer;
begin
  R := CallTool('list_project_templates', '{}');
  CheckEquals(200, R.Code, 'list_project_templates must return HTTP 200');
  Obj := ParseJSON(R.Body);
  try
    Res := TJSONObject(Obj.Find('result'));
    CheckTrue(Assigned(Res), 'list_project_templates must return a result');
    Content := TJSONArray(Res.Find('content'));
    CheckTrue(Assigned(Content) and (Content.Count > 0),
      'list_project_templates result must have content');
    Items := TJSONArray(GetJSON(TJSONObject(Content[0]).Get('text', '[]')));
    try
      CheckTrue(Items.Count > 0,
        'list_project_templates must return at least one template');
      Item0 := TJSONObject(Items[0]);
      CheckTrue(Assigned(Item0.Find('name')),
        'Each template must have a name field');
      CheckTrue(Assigned(Item0.Find('localized_name')),
        'Each template must have a localized_name field');
      // 'Application' must be present — it is always registered
      HasApp := False;
      for I := 0 to Items.Count - 1 do
        if SameText(TJSONObject(Items[I]).Get('name', ''), 'Application') then
        begin
          HasApp := True; Break;
        end;
      CheckTrue(HasApp, 'list_project_templates must include ''Application'' template');
    finally
      Items.Free;
    end;
  finally
    Obj.Free;
  end;
end;

procedure TTestProjectTools.TestCreateProjectSchema;
{ Schema presence test only — create_project is mutating so no live call. }
var
  Tools   : TJSONArray;
  I       : Integer;
  ToolObj : TJSONObject;
  Schema  : TJSONObject;
  Props   : TJSONObject;
begin
  Tools := GetToolsArray;
  try
    ToolObj := nil;
    for I := 0 to Tools.Count - 1 do
      if TJSONObject(Tools[I]).Get('name', '') = 'create_project' then
      begin
        ToolObj := TJSONObject(Tools[I]);
        Break;
      end;
    CheckTrue(Assigned(ToolObj), 'create_project must be in tools/list');
    Schema := TJSONObject(ToolObj.Find('inputSchema'));
    CheckTrue(Assigned(Schema), 'create_project must have inputSchema');
    Props := TJSONObject(Schema.Find('properties'));
    CheckTrue(Assigned(Props), 'create_project inputSchema must have properties');
    CheckTrue(Assigned(Props.Find('project_dir')),
      'create_project schema must contain project_dir');
    CheckTrue(Assigned(Props.Find('project_name')),
      'create_project schema must contain project_name');
    CheckTrue(Assigned(Props.Find('project_type')),
      'create_project schema must contain project_type');
  finally
    Tools.Free;
  end;
end;

end.
