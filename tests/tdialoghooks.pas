{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TDialogHooks;

{ TTestDialogHooks — exercises ide_get_open_dialogs/ide_answer_dialog against
  a real, live modal dialog, raised on demand by McpTestHooks's
  __test_show_dialog__ (plugin-side test fixture code, not a tool: it has no
  schema and never appears in tools/list). Deterministic and disk-free: no
  ambiguous unit, no real build, no file left behind to clean up.

  Opt-in via MCP_TEST_HOOKS=1, set for both the IDE and this test process:
  the hook itself refuses inside the IDE unless its own environment has it,
  so this suite would otherwise just see every call refused. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, THttpHelper;

type
  TTestDialogHooks = class(TTestCase)
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestShowGetAnswerRoundTrip;
    procedure TestAnswerDialogSeesTestDialog;
  end;

implementation

uses
  SysUtils;

procedure TTestDialogHooks.SetUp;
begin
  if GetEnvironmentVariable('MCP_TEST_HOOKS') <> '1' then
    Ignore('set MCP_TEST_HOOKS=1 for both the IDE and this test process to run this suite');
end;

{ Independent of ide_answer_dialog, whose whole job here is to be exercised
  (and, right now, to fail): __test_close_last_dialog__ tracks the form it
  created directly, not through Screen, so a test failure never leaves the
  IDE stuck behind a dialog nobody can close. }
procedure TTestDialogHooks.TearDown;
begin
  CallToolText('__test_close_last_dialog__', '{}', []);
end;

{ The hook blocks inside IDEMessageDialog until answered, so this call itself
  returns only once CallOnMain's own abandon-after-grace-period kicks in
  (mcpideserver.pas, DialogGraceMs) -- same as any tool call stuck behind a
  dialog. The dialog stays open; ide_get_open_dialogs confirms it. }
procedure TTestDialogHooks.TestShowGetAnswerRoundTrip;
var
  T : string;
begin
  T := CallToolText('__test_show_dialog__',
    '{"caption":"MCP test dialog","text":"round trip","buttons":["OK","Cancel"]}', []);
  CheckTrue((Pos('pending', T) > 0) or (Pos('modal result', T) > 0),
    'either abandoned behind the dialog or (unlikely, fast) already answered: ' + T);

  T := CallToolText('ide_get_open_dialogs', '{}', []);
  CheckTrue(Pos('MCP test dialog', T) > 0, 'the test dialog is open: ' + T);
  CheckTrue(Pos('"count":1', T) > 0, 'exactly one dialog open: ' + T);

  T := CallToolText('ide_answer_dialog',
    '{"button":"Cancel","caption":"MCP test dialog"}', []);
  CheckTrue(Pos('TOOL ERROR', T) <> 1, 'ide_answer_dialog answered it: ' + T);

  T := CallToolText('ide_get_open_dialogs', '{}', []);
  CheckTrue(Pos('"count":0', T) > 0, 'the dialog is gone: ' + T);
end;

{ Regression guard for the bug this suite was built to catch: a dialog that
  ide_get_open_dialogs sees but Screen.GetCurrentModalForm misses, because
  IDEMessageDialog raises it as a native Windows TaskDialog, not an LCL
  form (see McpNativeDialog.pas). ide_answer_dialog now falls back to
  clicking the native dialog's button directly when no LCL form is modal. }
procedure TTestDialogHooks.TestAnswerDialogSeesTestDialog;
var
  T : string;
begin
  CallToolText('__test_show_dialog__',
    '{"caption":"MCP test dialog 2","text":"regression guard","buttons":["OK"]}', []);

  T := CallToolText('ide_answer_dialog', '{"button":"OK"}', []);
  CheckTrue(Pos('No LCL dialog is currently modal', T) = 0,
    'ide_answer_dialog must find the dialog Screen tracks as modal: ' + T);
  CheckTrue(Pos('TOOL ERROR', T) <> 1, 'ide_answer_dialog answered it: ' + T);
end;

end.
