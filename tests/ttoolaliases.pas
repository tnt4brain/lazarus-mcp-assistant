{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TToolAliases;

{ TTestToolAliases: McpTranslateCall (ADR-031) on its own, no server.
  TTestToolAliasTable: the table against the live tools/list: every old name is gone from the list,
  every new name is in it, and the argument a fusion adds exists in the new tool's schema.
  The second one requires a running MCP server. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, fpjson, jsonparser, McpToolAliases, THttpHelper;

type
  TTestToolAliases = class(TTestCase)
  protected
    procedure SetUp; override;
  private
    function Call(const AJson, ASession: string; out ANotice, AError: string): TJSONObject;
  published
    procedure TestParamIsRenamed;
    procedure TestOneNamePerIdea;
    procedure TestNoticeOncePerSessionAndName;
    procedure TestBothNamesEqualOrDifferent;
    procedure TestOtherToolsAndNilAreLeftAlone;
    procedure TestNothingToTranslate;
    procedure TestFusedToolGetsItsFixedArgument;
    procedure TestStrictModeRefusesOldNames;
    procedure TestShippedDocumentsTeachCurrentNames;
    procedure TestRenamedToolsDocListsEveryEntry;
  end;

  TTestToolAliasTable = class(TTestCase)
  published
    procedure TestTableMatchesToolList;
    procedure TestOldCallsAnswerLikeNewOnes;
  end;

implementation

uses
  Classes, SysUtils;

procedure TTestToolAliases.SetUp;
begin
  McpAliasForgetSessions;
end;

function TTestToolAliases.Call(const AJson, ASession: string;
  out ANotice, AError: string): TJSONObject;
begin
  Result := TJSONObject(GetJSON(AJson));
  McpTranslateCall(Result, ASession, ANotice, AError);
end;

procedure TTestToolAliases.TestParamIsRenamed;
var
  P : TJSONObject;
  N, E : string;
begin
  P := Call('{"name":"editor_read_file","arguments":{"path":"a.pas"}}', 's1', N, E);
  try
    CheckEquals('', E);
    CheckEquals('editor_read_file', P.Get('name', ''));
    CheckEquals('a.pas', TJSONObject(P.Find('arguments')).Get('file', ''));
    CheckEquals(-1, TJSONObject(P.Find('arguments')).IndexOfName('path'), 'old name gone');
    CheckTrue(Pos('"path"', N) > 0, 'says which parameter: ' + N);
    CheckTrue(Pos('"file"', N) > 0, 'and what it is now: ' + N);
  finally
    P.Free;
  end;
  { one entry for every form tool }
  P := Call('{"name":"form_get_lfm","arguments":{"form_file":"f.pas","component_name":"B"}}', 's1', N, E);
  try
    CheckEquals('f.pas', TJSONObject(P.Find('arguments')).Get('file', ''));
    CheckEquals('B', TJSONObject(P.Find('arguments')).Get('component_name', ''));
    CheckEquals(-1, TJSONObject(P.Find('arguments')).IndexOfName('form_file'));
  finally
    P.Free;
  end;
  { the other arguments stay }
  P := Call('{"name":"debug_set_breakpoint","arguments":{"file_path":"a.pas","line":3}}', 's1', N, E);
  try
    CheckEquals('a.pas', TJSONObject(P.Find('arguments')).Get('file', ''));
    CheckEquals(3, TJSONObject(P.Find('arguments')).Get('line', 0));
  finally
    P.Free;
  end;
end;

procedure TTestToolAliases.TestOneNamePerIdea;
const
  CASES : array[0..6, 0..2] of string = (
    ('project_run',        'wait_seconds', 'timeout_s'),
    ('project_run_output', 'wait_seconds', 'timeout_s'),
    ('project_run_input',  'wait_seconds', 'timeout_s'),
    ('project_run_input',  'text',         'stdin'),
    ('debug_set_variable', 'name',         'variable_name'),
    ('code_edit_statement', 'op',           'action'),
    ('package_create',     'type',         'package_type'));
var
  I    : Integer;
  P    : TJSONObject;
  N, E : string;
begin
  for I := 0 to High(CASES) do
  begin
    P := Call('{"name":"' + CASES[I, 0] + '","arguments":{"' + CASES[I, 1] + '":"v","other":1}}', 'x', N, E);
    try
      CheckEquals('', E, CASES[I, 0]);
      CheckEquals('v', TJSONObject(P.Find('arguments')).Get(CASES[I, 2], ''), CASES[I, 0] + ' ' + CASES[I, 1]);
      CheckEquals(-1, TJSONObject(P.Find('arguments')).IndexOfName(CASES[I, 1]), 'old name gone');
      CheckEquals(1, TJSONObject(P.Find('arguments')).Get('other', 0), 'the rest stays');
    finally
      P.Free;
    end;
  end;
  { the same word in a tool that does not use the old name is not touched; neither is the new
    component's name in form_add_component, which stays "name" (component_name addresses an
    existing component in every form tool) }
  P := Call('{"name":"project_create","arguments":{"name":"p"}}', 'x', N, E);
  try
    CheckEquals('p', TJSONObject(P.Find('arguments')).Get('name', ''));
  finally
    P.Free;
  end;
end;

procedure TTestToolAliases.TestNoticeOncePerSessionAndName;
var
  P : TJSONObject;
  N, E : string;
begin
  P := Call('{"name":"editor_read_file","arguments":{"path":"a.pas"}}', 'one', N, E);
  P.Free;
  CheckTrue(N <> '', 'first time: told');
  P := Call('{"name":"editor_read_file","arguments":{"path":"b.pas"}}', 'one', N, E);
  try
    CheckEquals('', N, 'second time in the session: not told again');
    CheckEquals('b.pas', TJSONObject(P.Find('arguments')).Get('file', ''), 'still translated');
  finally
    P.Free;
  end;
  P := Call('{"name":"editor_read_file","arguments":{"path":"b.pas"}}', 'two', N, E);
  P.Free;
  CheckTrue(N <> '', 'another session: told');
  P := Call('{"name":"project_create_unit","arguments":{"filename":"u.pas"}}', 'one', N, E);
  P.Free;
  CheckTrue(N <> '', 'another old name in the same session: told');
end;

procedure TTestToolAliases.TestBothNamesEqualOrDifferent;
var
  P : TJSONObject;
  N, E : string;
begin
  P := Call('{"name":"project_create_unit","arguments":{"file":"u.pas","filename":"u.pas"}}', 's', N, E);
  try
    CheckEquals('', E, 'equal values are fine');
    CheckEquals(-1, TJSONObject(P.Find('arguments')).IndexOfName('filename'), 'the old one is dropped');
  finally
    P.Free;
  end;
  P := Call('{"name":"project_create_unit","arguments":{"file":"u.pas","filename":"v.pas"}}', 's', N, E);
  try
    CheckTrue(E <> '', 'different values are an error');
    CheckTrue((Pos('filename', E) > 0) and (Pos('file', E) > 0), 'naming both: ' + E);
    CheckEquals('v.pas', TJSONObject(P.Find('arguments')).Get('filename', ''), 'the request is left as it was');
  finally
    P.Free;
  end;
end;

procedure TTestToolAliases.TestOtherToolsAndNilAreLeftAlone;
var
  P : TJSONObject;
  N, E : string;
begin
  { git_diff's path may be a directory: it is not an alias there }
  P := Call('{"name":"git_diff","arguments":{"path":"src"}}', 's', N, E);
  try
    CheckEquals('src', TJSONObject(P.Find('arguments')).Get('path', ''));
    CheckEquals(-1, TJSONObject(P.Find('arguments')).IndexOfName('file'));
    CheckEquals('', N);
  finally
    P.Free;
  end;
  McpTranslateCall(nil, 's', N, E);
  CheckEquals('', N);
  CheckEquals('', E);
end;

procedure TTestToolAliases.TestNothingToTranslate;
var
  P : TJSONObject;
  N, E : string;
begin
  P := Call('{"name":"editor_open"}', 's', N, E);   { no arguments at all }
  try
    CheckEquals('', N);
    CheckEquals('', E);
    CheckEquals('editor_open', P.Get('name', ''));
  finally
    P.Free;
  end;
  P := Call('{"name":"editor_open","arguments":{"file":"a.pas"}}', 's', N, E);
  try
    CheckEquals('', N, 'the current name needs no notice');
  finally
    P.Free;
  end;
end;

{ strict mode (1.9): an old name is refused with the new one, the current names pass untouched }
procedure TTestToolAliases.TestStrictModeRefusesOldNames;
var
  P : TJSONObject;
  N, E : string;
begin
  McpAliasSetStrict(True);
  try
    P := Call('{"name":"editor_open","arguments":{"file_path":"x.pas"}}', 's', N, E);
    try
      CheckTrue(Pos('"file_path"', E) > 0, 'names the old parameter: ' + E);
      CheckTrue(Pos('"file"', E) > 0, 'names the new one: ' + E);
    finally
      P.Free;
    end;
    P := Call('{"name":"debug_step_into"}', 's', N, E);
    try
      CheckTrue(Pos('debug_step_into', E) > 0, 'names the old tool: ' + E);
      CheckTrue(Pos('kind=', E) > 0, 'and what it became: ' + E);
      CheckEquals('debug_step_into', P.Get('name', ''), 'the request is left as it was');
    finally
      P.Free;
    end;
    P := Call('{"name":"editor_open","arguments":{"file":"x.pas"}}', 's', N, E);
    try
      CheckEquals('', E, 'current names pass');
      CheckEquals('', N, 'with no notice');
    finally
      P.Free;
    end;
  finally
    McpAliasSetStrict(False);
  end;
  P := Call('{"name":"editor_open","arguments":{"file_path":"x.pas"}}', 's', N, E);
  try
    CheckEquals('', E, 'off again: translated');
  finally
    P.Free;
  end;
end;

procedure TTestToolAliases.TestFusedToolGetsItsFixedArgument;
var
  P : TJSONObject;
  N, E : string;
begin
  { no arguments at all: the object is made }
  P := Call('{"name":"debug_step_into"}', 'f', N, E);
  try
    CheckEquals('', E);
    CheckEquals('debug_step', P.Get('name', ''));
    CheckEquals('into', TJSONObject(P.Find('arguments')).Get('kind', ''));
    CheckTrue(Pos('debug_step_into', N) > 0, 'tells the old name: ' + N);
  finally
    P.Free;
  end;
  { the caller's other arguments stay }
  P := Call('{"name":"debug_step_out","arguments":{"timeout_s":5}}', 'f', N, E);
  try
    CheckEquals('out', TJSONObject(P.Find('arguments')).Get('kind', ''));
    CheckEquals(5, TJSONObject(P.Find('arguments')).Get('timeout_s', 0));
  finally
    P.Free;
  end;
  { a boolean fixed argument stays a boolean }
  P := Call('{"name":"code_goto_declaration","arguments":{"symbol":"X","file":"a.pas"}}', 'f', N, E);
  try
    CheckEquals('code_find_declaration', P.Get('name', ''));
    CheckTrue(TJSONObject(P.Find('arguments')).Find('show').JSONType = jtBoolean, 'show is a boolean');
    CheckTrue(TJSONObject(P.Find('arguments')).Get('show', False));
    CheckTrue(Pos('show=true', N) > 0, 'says it plainly: ' + N);
  finally
    P.Free;
  end;
  P := Call('{"name":"code_goto_declaration","arguments":{"show":false}}', 'f', N, E);
  try
    CheckTrue(E <> '', 'show=false contradicts the old name');
  finally
    P.Free;
  end;
  { the same kind is harmless, another one contradicts the old name }
  P := Call('{"name":"debug_step_over","arguments":{"kind":"over"}}', 'f', N, E);
  try
    CheckEquals('', E);
  finally
    P.Free;
  end;
  P := Call('{"name":"debug_step_over","arguments":{"kind":"out"}}', 'f', N, E);
  try
    CheckTrue(E <> '', 'contradiction is refused');
    CheckEquals('debug_step_over', P.Get('name', ''), 'left as it was');
  finally
    P.Free;
  end;
end;

procedure TTestToolAliases.TestShippedDocumentsTeachCurrentNames;
const
  DOCS : array[0..8] of string = ('README.md', 'docs/tools.md', 'docs/write-scope.md', 'docs/testing.md',
                                  'docs/self-hosted-development.md', 'docs/system-prompt.md', 'docs/lazarus-knowledge.md',
                                  'src/system_prompt.inc', 'src/lazarus_knowledge.inc');
var
  Root, Text : string;
  I, K       : Integer;
  A          : TMcpAlias;
  L          : TStringList;
  Checked    : Integer;
begin
  { only the ADRs and the release notes may name a retired tool (ADR-031) }
  Root := ExtractFilePath(ParamStr(0)) + '..' + PathDelim;
  Checked := 0;
  L := TStringList.Create;
  try
    for I := Low(DOCS) to High(DOCS) do
    begin
      if not FileExists(Root + DOCS[I]) then Continue;
      L.LoadFromFile(Root + DOCS[I]);
      Text := L.Text;
      Inc(Checked);
      for K := 0 to McpAliasCount - 1 do
      begin
        A := McpAliasAt(K);
        if A.Kind <> akTool then Continue;
        CheckEquals(0, Pos(A.Tool, Text), DOCS[I] + ' teaches the retired tool ' + A.Tool);
      end;
    end;
  finally
    L.Free;
  end;
  if Checked = 0 then Ignore('the shipped documents are not next to the test program');
end;

procedure TTestToolAliases.TestRenamedToolsDocListsEveryEntry;
var
  Root, Text, Tool : string;
  K                : Integer;
  A                : TMcpAlias;
  L                : TStringList;
begin
  { docs/renamed-tools.md is the announcement of the 2.0 refusal: it must name every old
    tool, and every old parameter with its tool (ADR-031) }
  Root := ExtractFilePath(ParamStr(0)) + '..' + PathDelim + 'docs' + PathDelim + 'renamed-tools.md';
  if not FileExists(Root) then
  begin
    Ignore('docs/renamed-tools.md is not next to the test program');
    Exit;
  end;
  L := TStringList.Create;
  try
    L.LoadFromFile(Root);
    Text := L.Text;
  finally
    L.Free;
  end;
  for K := 0 to McpAliasCount - 1 do
  begin
    A := McpAliasAt(K);
    if A.Kind = akTool then
      CheckTrue(Pos('`' + A.Tool + '`', Text) > 0, 'renamed-tools.md lacks the tool ' + A.Tool)
    else
    begin
      CheckTrue(Pos('`' + A.Old + '`', Text) > 0, 'renamed-tools.md lacks the parameter ' + A.Old);
      Tool := A.Tool;
      if Tool[Length(Tool)] = '*' then Tool := Copy(Tool, 1, Length(Tool) - 1) + '*';
      CheckTrue(Pos('`' + Tool, Text) > 0,
        'renamed-tools.md lacks the tool ' + Tool + ' of the parameter ' + A.Old);
    end;
  end;
end;

{ ---- the table against the live tools/list ---------------------------------------------------- }

procedure TTestToolAliasTable.TestTableMatchesToolList;
var
  R     : THttpResult;
  Root  : TJSONObject;
  Tools : TJSONArray;
  I, K  : Integer;
  A     : TMcpAlias;
  Tool  : TJSONObject;
  Names : TStringList;

  function Find(const AName: string): TJSONObject;
  var
    J : Integer;
  begin
    Result := nil;
    J := Names.IndexOf(AName);
    if J >= 0 then Result := TJSONObject(Names.Objects[J]);
  end;

  function Props(ATool: TJSONObject): TJSONObject;
  begin
    Result := TJSONObject(TJSONObject(ATool.Find('inputSchema')).Find('properties'));
  end;

begin
  R := McpPost('{"jsonrpc":"2.0","id":9,"method":"tools/list"}');
  CheckEquals(200, R.Code);
  Root := TJSONObject(GetJSON(R.Body));
  Names := TStringList.Create;
  try
    Tools := TJSONArray(TJSONObject(Root.Find('result')).Find('tools'));
    for I := 0 to Tools.Count - 1 do
      Names.AddObject(TJSONObject(Tools[I]).Get('name', ''), Tools[I]);
    CheckTrue(McpAliasCount > 0, 'a table');
    for I := 0 to McpAliasCount - 1 do
    begin
      A := McpAliasAt(I);
      if A.Kind = akTool then
      begin
        CheckTrue(Find(A.Tool) = nil, 'old tool is not in the list: ' + A.Tool);
        Tool := Find(A.New);
        CheckTrue(Tool <> nil, 'new tool exists: ' + A.New);
        if (Tool <> nil) and (A.FixedKey <> '') then
          CheckTrue(Props(Tool).Find(A.FixedKey) <> nil,
            A.New + ' has the argument ' + A.FixedKey + ' the old name sets');
      end
      else
      begin
        { every tool the entry covers: no longer declares the old name, and has the new one when
          it had the parameter }
        for K := 0 to Names.Count - 1 do
        begin
          if (Copy(A.Tool, Length(A.Tool), 1) = '*') then
          begin
            if Copy(Names[K], 1, Length(A.Tool) - 1) <> Copy(A.Tool, 1, Length(A.Tool) - 1) then Continue;
          end
          else if Names[K] <> A.Tool then Continue;
          Tool := TJSONObject(Names.Objects[K]);
          CheckTrue(Props(Tool).Find(A.Old) = nil,
            Names[K] + ' still declares the old name ' + A.Old);
          if A.Tool = Names[K] then
            CheckTrue(Props(Tool).Find(A.New) <> nil,
              Names[K] + ' has the new parameter ' + A.New);
        end;
        if Copy(A.Tool, Length(A.Tool), 1) <> '*' then
          CheckTrue(Find(A.Tool) <> nil, 'tool of the entry exists: ' + A.Tool);
      end;
    end;
  finally
    Names.Free;
    Root.Free;
  end;
end;

procedure TTestToolAliasTable.TestOldCallsAnswerLikeNewOnes;
begin
  { the same request through the old name and the new call: the same answer (ADR-031) }
  CheckEquals(CallToolText('editor_get_active', '{"what":"cursor"}', []),
              CallToolText('editor_get_cursor', '{}', []), 'cursor');
  CheckEquals(CallToolText('editor_get_active', '{"what":"selection"}', []),
              CallToolText('editor_get_selection', '{}', []), 'selection');
  CheckEquals(CallToolText('git_stash', '{"action":"pop","index":99}', []),
              CallToolText('git_stash_pop', '{"index":99}', []), 'stash pop of a stash that is not there');
end;

initialization
  RegisterTest(TTestToolAliases);
end.
