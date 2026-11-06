{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TProjectTools;

{ TTestProjectTools — FPCUnit tests for FR-006 project lifecycle tools.
  Requires a running MCP server (GServerAvail = True).

  Only read-only or side-effect-free calls are made here:
    - tools/list presence check for all 8 FR-006 tools
    - ide_run_tests schema regression (not RTProps / editor_replace_range schema)
    - form_search_palette with a known component name
    - ide_get_messages structure check
  Mutating tools (add/remove_file, form_create, project_set_settings,
  project_run) are not called from automated tests to avoid touching
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
    procedure TestGetMessagesSkipOwn;
    procedure TestCreateProjectSchema;
    procedure TestListProjectTemplatesReturnsArray;
    procedure TestProjectCleanSchema;
    procedure TestProjectCleanDryRunIsSafe;
    procedure TestGetOpenDialogsSchema;
    procedure TestGetOpenDialogsReturnsCount;
    procedure TestAnswerDialogSchema;
    procedure TestAnswerDialogRefusesWithoutButton;
    procedure TestAnswerDialogNoDialogOpen;
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
    'project_add_file', 'project_remove_file', 'form_create',
    'project_set_settings', 'editor_open', 'form_search_palette',
    'project_run', 'ide_get_messages', 'project_create', 'project_list_templates');
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
  Verifies ide_run_tests exposes test_project in its schema, not start_line
  (which would indicate it was accidentally given editor_replace_range''s schema). }
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
      if TJSONObject(Tools[I]).Get('name', '') = 'ide_run_tests' then
      begin
        ToolObj := TJSONObject(Tools[I]);
        Break;
      end;
    CheckTrue(Assigned(ToolObj), 'ide_run_tests must be in tools/list');
    Schema := TJSONObject(ToolObj.Find('inputSchema'));
    CheckTrue(Assigned(Schema), 'ide_run_tests must have inputSchema');
    Props := TJSONObject(Schema.Find('properties'));
    CheckTrue(Assigned(Props), 'ide_run_tests inputSchema must have properties');
    CheckTrue(Assigned(Props.Find('test_project')),
      'ide_run_tests schema must contain test_project (not editor_replace_range schema)');
    CheckTrue(Props.Find('start_line') = nil,
      'ide_run_tests schema must NOT contain start_line (editor_replace_range field)');
  finally
    Tools.Free;
  end;
end;

procedure TTestProjectTools.TestSearchComponentsReturnsArray;
{ Calls form_search_palette with 'TButton' — always registered in the LCL.
  Only runs when server is available; safe (read-only). }
var
  R       : THttpResult;
  Obj     : TJSONObject;
  Res     : TJSONObject;
  Content : TJSONArray;
  Item0   : TJSONObject;
  Results : TJSONArray;
begin
  R := CallTool('form_search_palette', '{"query":"TButton"}');
  CheckEquals(200, R.Code, 'form_search_palette must return HTTP 200');
  Obj := ParseJSON(R.Body);
  try
    Res := TJSONObject(Obj.Find('result'));
    CheckTrue(Assigned(Res), 'form_search_palette must return a result');
    Content := TJSONArray(Res.Find('content'));
    CheckTrue(Assigned(Content) and (Content.Count > 0),
      'form_search_palette result must have content');
    // The text payload is JSON itself — parse it
    Results := TJSONArray(GetJSON(TJSONObject(Content[0]).Get('text', '[]')));
    try
      CheckTrue(Results.Count > 0,
        'form_search_palette("TButton") must return at least one match');
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
  R := CallTool('ide_get_messages', '{}');
  CheckEquals(200, R.Code, 'ide_get_messages must return HTTP 200');
  Obj := ParseJSON(R.Body);
  try
    Res := TJSONObject(Obj.Find('result'));
    CheckTrue(Assigned(Res), 'ide_get_messages must return a result');
    Content := TJSONArray(Res.Find('content'));
    CheckTrue(Assigned(Content) and (Content.Count > 0),
      'ide_get_messages must have content');
    Payload := TJSONObject(GetJSON(TJSONObject(Content[0]).Get('text', '{}')));
    try
      CheckTrue(Assigned(Payload.Find('messages')),
        'ide_get_messages payload must contain "messages" array');
      CheckTrue(Assigned(Payload.Find('line_count')),
        'ide_get_messages payload must contain "line_count"');
    finally
      Payload.Free;
    end;
  finally
    Obj.Free;
  end;
end;

{ skip_own leaves out the lines the server adds itself: never more than all of them }
procedure TTestProjectTools.TestGetMessagesSkipOwn;
var
  All, Skipped : TJSONObject;
begin
  All := TJSONObject(GetJSON(CallToolText('ide_get_messages', '{}', [])));
  Skipped := TJSONObject(GetJSON(CallToolText('ide_get_messages', '{"skip_own":true}', [])));
  try
    CheckEquals(All.Arrays['messages'].Count, All.Get('line_count', -1), 'line_count matches');
    CheckEquals(Skipped.Arrays['messages'].Count, Skipped.Get('line_count', -1),
      'line_count matches when skipping');
    CheckTrue(Skipped.Arrays['messages'].Count <= All.Arrays['messages'].Count,
      'skip_own never adds lines');
  finally
    All.Free;
    Skipped.Free;
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
  R := CallTool('project_list_templates', '{}');
  CheckEquals(200, R.Code, 'project_list_templates must return HTTP 200');
  Obj := ParseJSON(R.Body);
  try
    Res := TJSONObject(Obj.Find('result'));
    CheckTrue(Assigned(Res), 'project_list_templates must return a result');
    Content := TJSONArray(Res.Find('content'));
    CheckTrue(Assigned(Content) and (Content.Count > 0),
      'project_list_templates result must have content');
    Items := TJSONArray(GetJSON(TJSONObject(Content[0]).Get('text', '[]')));
    try
      CheckTrue(Items.Count > 0,
        'project_list_templates must return at least one template');
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
      CheckTrue(HasApp, 'project_list_templates must include ''Application'' template');
    finally
      Items.Free;
    end;
  finally
    Obj.Free;
  end;
end;

procedure TTestProjectTools.TestCreateProjectSchema;
{ Schema presence test only — project_create is mutating so no live call. }
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
      if TJSONObject(Tools[I]).Get('name', '') = 'project_create' then
      begin
        ToolObj := TJSONObject(Tools[I]);
        Break;
      end;
    CheckTrue(Assigned(ToolObj), 'project_create must be in tools/list');
    Schema := TJSONObject(ToolObj.Find('inputSchema'));
    CheckTrue(Assigned(Schema), 'project_create must have inputSchema');
    Props := TJSONObject(Schema.Find('properties'));
    CheckTrue(Assigned(Props), 'project_create inputSchema must have properties');
    CheckTrue(Assigned(Props.Find('project_dir')),
      'project_create schema must contain project_dir');
    CheckTrue(Assigned(Props.Find('project_name')),
      'project_create schema must contain project_name');
    CheckTrue(Assigned(Props.Find('project_type')),
      'project_create schema must contain project_type');
  finally
    Tools.Free;
  end;
end;

procedure TTestProjectTools.TestProjectCleanSchema;
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
      if TJSONObject(Tools[I]).Get('name', '') = 'project_clean' then
      begin
        ToolObj := TJSONObject(Tools[I]);
        Break;
      end;
    CheckTrue(Assigned(ToolObj), 'project_clean must be in tools/list');
    Schema := TJSONObject(ToolObj.Find('inputSchema'));
    CheckTrue(Assigned(Schema), 'project_clean must have inputSchema');
    Props := TJSONObject(Schema.Find('properties'));
    CheckTrue(Assigned(Props), 'project_clean inputSchema must have properties');
    CheckTrue(Assigned(Props.Find('dry_run')),
      'project_clean schema must contain dry_run');
    CheckTrue(Assigned(Props.Find('package_name')),
      'project_clean schema must contain package_name');
    CheckTrue(Assigned(Props.Find('lpk_path')),
      'project_clean schema must contain lpk_path');
  finally
    Tools.Free;
  end;
end;

procedure TTestProjectTools.TestProjectCleanDryRunIsSafe;
{ Live call — dry_run defaults true, so this only lists, never deletes;
  safe to call against whatever project is open in the IDE. }
var
  R         : THttpResult;
  Obj       : TJSONObject;
  Res       : TJSONObject;
  Content   : TJSONArray;
  ResultObj : TJSONObject;
begin
  R := CallTool('project_clean', '{}');
  CheckEquals(200, R.Code, 'project_clean must return HTTP 200');
  Obj := ParseJSON(R.Body);
  try
    Res := TJSONObject(Obj.Find('result'));
    CheckTrue(Assigned(Res), 'project_clean must return a result');
    Content := TJSONArray(Res.Find('content'));
    CheckTrue(Assigned(Content) and (Content.Count > 0),
      'project_clean result must have content');
    ResultObj := TJSONObject(GetJSON(TJSONObject(Content[0]).Get('text', '{}')));
    try
      CheckTrue(ResultObj.Get('dry_run', False),
        'project_clean with no arguments must default to dry_run true');
      CheckTrue(Assigned(ResultObj.Find('candidates')),
        'project_clean must return a candidates array');
      CheckTrue(not Assigned(ResultObj.Find('deleted')),
        'a dry_run response must not include a deleted field');
    finally
      ResultObj.Free;
    end;
  finally
    Obj.Free;
  end;
end;

procedure TTestProjectTools.TestGetOpenDialogsSchema;
var
  Tools   : TJSONArray;
  I       : Integer;
  ToolObj : TJSONObject;
begin
  Tools := GetToolsArray;
  try
    ToolObj := nil;
    for I := 0 to Tools.Count - 1 do
      if TJSONObject(Tools[I]).Get('name', '') = 'ide_get_open_dialogs' then
      begin
        ToolObj := TJSONObject(Tools[I]);
        Break;
      end;
    CheckTrue(Assigned(ToolObj), 'ide_get_open_dialogs must be in tools/list');
    CheckTrue(Assigned(ToolObj.Find('inputSchema')),
      'ide_get_open_dialogs must have inputSchema');
  finally
    Tools.Free;
  end;
end;

procedure TTestProjectTools.TestGetOpenDialogsReturnsCount;
{ Live call — no IDE dialog should be open during an automated test run, so
  this only checks the shape: count present, dialogs an array, and no
  "summary" when count is 0 (mirroring project_clean's dry_run contract). }
var
  R         : THttpResult;
  Obj       : TJSONObject;
  Res       : TJSONObject;
  Content   : TJSONArray;
  ResultObj : TJSONObject;
begin
  R := CallTool('ide_get_open_dialogs', '{}');
  CheckEquals(200, R.Code, 'ide_get_open_dialogs must return HTTP 200');
  Obj := ParseJSON(R.Body);
  try
    Res := TJSONObject(Obj.Find('result'));
    CheckTrue(Assigned(Res), 'ide_get_open_dialogs must return a result');
    Content := TJSONArray(Res.Find('content'));
    CheckTrue(Assigned(Content) and (Content.Count > 0),
      'ide_get_open_dialogs result must have content');
    ResultObj := TJSONObject(GetJSON(TJSONObject(Content[0]).Get('text', '{}')));
    try
      CheckTrue(Assigned(ResultObj.Find('count')),
        'ide_get_open_dialogs must return a count');
      CheckTrue(Assigned(ResultObj.Find('dialogs')),
        'ide_get_open_dialogs must return a dialogs array');
      if ResultObj.Get('count', 0) = 0 then
        CheckTrue(not Assigned(ResultObj.Find('summary')),
          'no summary field when no dialog is open');
    finally
      ResultObj.Free;
    end;
  finally
    Obj.Free;
  end;
end;

procedure TTestProjectTools.TestAnswerDialogSchema;
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
      if TJSONObject(Tools[I]).Get('name', '') = 'ide_answer_dialog' then
      begin
        ToolObj := TJSONObject(Tools[I]);
        Break;
      end;
    CheckTrue(Assigned(ToolObj), 'ide_answer_dialog must be in tools/list');
    Schema := TJSONObject(ToolObj.Find('inputSchema'));
    CheckTrue(Assigned(Schema), 'ide_answer_dialog must have inputSchema');
    Props := TJSONObject(Schema.Find('properties'));
    CheckTrue(Assigned(Props) and Assigned(Props.Find('button')),
      'ide_answer_dialog schema must contain button');
    CheckTrue(Assigned(Props.Find('caption')),
      'ide_answer_dialog schema must contain caption');
  finally
    Tools.Free;
  end;
end;

procedure TTestProjectTools.TestAnswerDialogRefusesWithoutButton;
begin
  CheckTrue(Pos('TOOL ERROR', CallToolText('ide_answer_dialog', '{}', [])) = 1,
    'ide_answer_dialog without button must refuse');
end;

procedure TTestProjectTools.TestAnswerDialogNoDialogOpen;
{ No IDE dialog should be open during an automated test run, so this exercises
  the "nothing to click" refusal path without needing to raise a real one. }
var
  Text : string;
begin
  Text := CallToolText('ide_answer_dialog', '{"button":"OK"}', []);
  CheckTrue(Pos('TOOL ERROR', Text) = 1,
    'ide_answer_dialog must refuse when no dialog is open');
  CheckTrue(Pos('modal', Text) > 0,
    'the refusal should say no dialog is modal');
end;

end.
