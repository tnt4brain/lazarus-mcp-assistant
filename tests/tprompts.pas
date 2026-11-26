{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TPrompts;

{ TTestPrompts: McpPrompts on its own (no server), and prompts/list and prompts/get through the
  running server (needs one). }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TTestPrompts = class(TTestCase)
  published
    procedure TestEveryPromptIsListedWithItsArguments;
    procedure TestTextsNameTheTools;
    procedure TestRequiredArgumentIsChecked;
    procedure TestTheTwoIdePromptsAreNotBuiltHere;
    procedure TestServerListsAndGetsThem;
  end;

implementation

uses
  Classes, SysUtils, fpjson, jsonparser, McpPrompts, THttpHelper;

procedure TTestPrompts.TestEveryPromptIsListedWithItsArguments;
var
  L : TJSONArray;
  I : Integer;
  P : TJSONObject;
begin
  L := TJSONArray.Create;
  try
    McpPromptsList(L);
    CheckEquals(7, L.Count, 'seven prompts: ' + McpPromptNames);
    for I := 0 to L.Count - 1 do
    begin
      P := TJSONObject(L[I]);
      CheckTrue(P.Get('name', '') <> '', 'a name');
      CheckTrue(Length(P.Get('description', '')) > 20, 'a description of ' + P.Get('name', ''));
    end;
    P := TJSONObject(L[5]);
    CheckEquals('write_adr', P.Get('name', ''));
    CheckTrue(TJSONObject(TJSONArray(P.Find('arguments'))[0]).Get('required', False), 'topic is required');
  finally
    L.Free;
  end;
end;

procedure TTestPrompts.TestTextsNameTheTools;
var
  A : TJSONObject;
  T, E : string;
begin
  CheckTrue(McpPromptText('review_diff', nil, T, E), 'review_diff is built here');
  CheckTrue((Pos('git_diff', T) > 0) and (Pos('git_status', T) > 0), 'names the git tools: ' + T);
  A := TJSONObject(GetJSON('{"ref":"feature/x"}'));
  try
    CheckTrue(McpPromptText('review_diff', A, T, E));
    CheckTrue(Pos('feature/x', T) > 0, 'with the ref: ' + T);
    CheckTrue(Pos('git_status', T) = 0, 'and no status of the working tree: ' + T);
  finally
    A.Free;
  end;
  McpPromptText('explain_exception', nil, T, E);
  CheckTrue(Pos('ide_get_exceptions', T) > 0, T);
  A := TJSONObject(GetJSON('{"suite":"TTestFoo.TestBar"}'));
  try
    McpPromptText('fix_failing_test', A, T, E);
    CheckTrue((Pos('ide_run_tests', T) > 0) and (Pos('TTestFoo.TestBar', T) > 0), T);
  finally
    A.Free;
  end;
  McpPromptText('release_checklist', nil, T, E);
  CheckTrue(Pos('git_status', T) > 0, T);
  CheckTrue(Pos('Do not tag, push or publish', T) > 0, 'it reads only: ' + T);
end;

procedure TTestPrompts.TestRequiredArgumentIsChecked;
var
  A : TJSONObject;
  T, E : string;
begin
  CheckTrue(McpPromptText('write_adr', nil, T, E), 'handled');
  CheckTrue(E <> '', 'topic missing: an error');
  CheckEquals('', T, 'and no text');
  A := TJSONObject(GetJSON('{"topic":"  how settings are stored  "}'));
  try
    CheckTrue(McpPromptText('write_adr', A, T, E));
    CheckEquals('', E);
    CheckTrue(Pos('how settings are stored', T) > 0, 'the topic, trimmed: ' + T);
  finally
    A.Free;
  end;
end;

procedure TTestPrompts.TestTheTwoIdePromptsAreNotBuiltHere;
var
  T, E : string;
begin
  CheckFalse(McpPromptText('explain_compiler_errors', nil, T, E), 'the server builds it');
  CheckFalse(McpPromptText('review_active_file', nil, T, E), 'the server builds it');
  CheckFalse(McpPromptText('no_such_prompt', nil, T, E), 'unknown');
end;

procedure TTestPrompts.TestServerListsAndGetsThem;
var
  R    : THttpResult;
  Root : TJSONObject;
begin
  R := McpPost('{"jsonrpc":"2.0","id":3,"method":"prompts/list"}');
  CheckEquals(200, R.Code);
  Root := TJSONObject(GetJSON(R.Body));
  try
    CheckEquals(7, TJSONArray(TJSONObject(Root.Find('result')).Find('prompts')).Count, 'seven over HTTP: ' + R.Body);
  finally
    Root.Free;
  end;
  R := McpPost('{"jsonrpc":"2.0","id":4,"method":"prompts/get","params":{"name":"review_diff","arguments":{"ref":"main"}}}');
  CheckTrue(Pos('git_diff', R.Body) > 0, 'prompts/get answers: ' + R.Body);
  R := McpPost('{"jsonrpc":"2.0","id":5,"method":"prompts/get","params":{"name":"write_adr"}}');
  CheckTrue(Pos('"error"', R.Body) > 0, 'a missing required argument is a JSON-RPC error: ' + R.Body);
  R := McpPost('{"jsonrpc":"2.0","id":6,"method":"prompts/get","params":{"name":"nope"}}');
  CheckTrue(Pos('Unknown prompt', R.Body) > 0, 'an unknown prompt: ' + R.Body);
end;

initialization
  RegisterTest(TTestPrompts);
end.
