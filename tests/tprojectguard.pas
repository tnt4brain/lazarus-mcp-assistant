{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TProjectGuard;

{ The no-project rule: with no project open the IDE shows its modal Project
  Wizard, and only the wizard's own actions are served.  Standalone, no IDE. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, McpToolContext;

type
  TTestProjectGuard = class(TTestCase)
  published
    procedure TestWizardActionsPass;
    procedure TestLivenessProbePasses;
    procedure TestEverythingElseIsRefused;
    procedure TestUnknownAndFutureToolsAreRefused;
  end;

implementation

procedure TTestProjectGuard.TestWizardActionsPass;
begin
  { New project; Open project and Open recent project (one tool) }
  CheckFalse(McpToolNeedsProject('project_create'), 'project_create');
  CheckFalse(McpToolNeedsProject('project_open'), 'project_open');
end;

procedure TTestProjectGuard.TestLivenessProbePasses;
begin
  { wait_for_restart polls it; refusing it would hang a restart into a
    no-project IDE }
  CheckFalse(McpToolNeedsProject('ide_ping'), 'ide_ping');
  CheckFalse(McpToolNeedsProject('ide_report'), 'ide_report');
end;

procedure TTestProjectGuard.TestEverythingElseIsRefused;
const
  Names : array[0..21] of string = (
    'project_close', 'project_build', 'project_run', 'project_get_settings',
    'project_create_unit', 'editor_open', 'editor_read_file', 'editor_save',
    'code_complete', 'code_get_outline', 'form_get_lfm', 'form_create',
    'form_search_palette', 'debug_set_breakpoint', 'debug_run', 'debug_get_state',
    'git_status', 'package_compile', 'package_list', 'ide_rebuild',
    'ide_get_messages', 'ide_answer_dialog');
var
  I : Integer;
begin
  for I := Low(Names) to High(Names) do
    CheckTrue(McpToolNeedsProject(Names[I]), Names[I] + ' must be refused');
end;

procedure TTestProjectGuard.TestUnknownAndFutureToolsAreRefused;
begin
  { safe by default: a tool nobody classified is refused, not left to raise
    an access violation in the IDE }
  CheckTrue(McpToolNeedsProject('some_tool_added_next_year'), 'unknown tool');
  CheckTrue(McpToolNeedsProject(''), 'empty name');
  CheckTrue(McpToolNeedsProject('project_open_all'), 'prefix of an allowed name');
  CheckTrue(McpToolNeedsProject('PROJECT_OPEN'), 'tool names are case-sensitive');
end;

initialization
  RegisterTest(TTestProjectGuard);
end.
