{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpPrompts;

{ The prompts of prompts/list (1.9.0), as slash commands in the clients that show them.  Each is a
  short instruction that names the tools to use; none needs the IDE to be built, so this unit is RTL
  and fpjson only and the test program links it.  explain_compiler_errors and review_active_file fetch
  IDE state when they are asked for; the server builds those two, this unit only lists them. }

{$mode objfpc}{$H+}

interface

uses
  fpjson;

{ All prompts, with their arguments, for prompts/list. }
procedure McpPromptsList(APrompts: TJSONArray);

{ True when AName is one of the prompts this unit builds (not the two that need the IDE).  AText is
  the instruction; AErr is '' unless a required argument is missing, then AText is ''. }
function McpPromptText(const AName: string; AArgs: TJSONObject; out AText, AErr: string): Boolean;

function McpPromptNames: string;   { for tests and error messages, comma separated }

implementation

uses
  SysUtils, StrUtils;

type
  TPromptDef = record
    Name     : string;
    Desc     : string;
    ArgName  : string;   { '' = no argument }
    ArgDesc  : string;
    Required : Boolean;
  end;

const
  PROMPTS : array[0..6] of TPromptDef = (
    (Name: 'explain_compiler_errors';
     Desc: 'Fetch current compiler output and ask Claude to explain errors and suggest fixes';
     ArgName: ''; ArgDesc: ''; Required: False),
    (Name: 'review_active_file';
     Desc: 'Review the currently active editor file for code quality and improvements';
     ArgName: ''; ArgDesc: ''; Required: False),
    (Name: 'review_diff';
     Desc: 'Review the uncommitted changes, or the changes of a commit or branch, for bugs and style';
     ArgName: 'ref'; ArgDesc: 'A commit, branch or range to review instead of the uncommitted changes'; Required: False),
    (Name: 'explain_exception';
     Desc: 'Find out why the program or the IDE raised its last exception, and say how to fix it';
     ArgName: ''; ArgDesc: ''; Required: False),
    (Name: 'fix_failing_test';
     Desc: 'Run a test project, take the failing tests one at a time and fix the code or the test';
     ArgName: 'suite'; ArgDesc: 'A test class or Class.Test to run first; default: the whole project'; Required: False),
    (Name: 'write_adr';
     Desc: 'Write an architecture decision record about a topic, in the format of the project''s docs/adr folder';
     ArgName: 'topic'; ArgDesc: 'What was decided, or has to be'; Required: True),
    (Name: 'release_checklist';
     Desc: 'Walk through the checks before a release of the open project and report what is not ready';
     ArgName: 'version'; ArgDesc: 'The version about to be released'; Required: False));

function McpPromptNames: string;
var
  I : Integer;
begin
  Result := '';
  for I := Low(PROMPTS) to High(PROMPTS) do
  begin
    if Result <> '' then Result := Result + ', ';
    Result := Result + PROMPTS[I].Name;
  end;
end;

procedure McpPromptsList(APrompts: TJSONArray);
var
  I    : Integer;
  P, A : TJSONObject;
  Args : TJSONArray;
begin
  for I := Low(PROMPTS) to High(PROMPTS) do
  begin
    P := TJSONObject.Create;
    P.Add('name',        PROMPTS[I].Name);
    P.Add('description', PROMPTS[I].Desc);
    if PROMPTS[I].ArgName <> '' then
    begin
      A := TJSONObject.Create;
      A.Add('name',        PROMPTS[I].ArgName);
      A.Add('description', PROMPTS[I].ArgDesc);
      A.Add('required',    PROMPTS[I].Required);
      Args := TJSONArray.Create;
      Args.Add(A);
      P.Add('arguments', Args);
    end;
    APrompts.Add(P);
  end;
end;

function ArgOf(AArgs: TJSONObject; const AName: string): string;
begin
  Result := '';
  if Assigned(AArgs) then
    Result := Trim(AArgs.Get(AName, ''));
end;

function McpPromptText(const AName: string; AArgs: TJSONObject; out AText, AErr: string): Boolean;
var
  Ref, Suite, Topic, Version : string;
begin
  AText := '';
  AErr  := '';
  Result := True;
  case AName of
    'review_diff':
    begin
      Ref := ArgOf(AArgs, 'ref');
      if Ref = '' then
        AText := 'Review the uncommitted changes of the open project. Call git_status, then git_diff for ' +
          'the changed files. '
      else
        AText := 'Review the changes of "' + Ref + '". Call git_log with ref="' + Ref + '" and git_diff ' +
          'with ref="' + Ref + '". ';
      AText := AText + 'Look for bugs first (wrong conditions, unfreed objects, missing checks at the ' +
        'edges), then for what a reader would trip over. For every finding give the file and line and ' +
        'say what you would change. Do not change any file; end with the three findings that matter most.';
    end;
    'explain_exception':
      AText := 'Find out why the last exception happened. Call ide_get_exceptions for what the IDE caught; ' +
        'if the debugger is paused on an exception call debug_get_exception, debug_get_call_stack and ' +
        'debug_get_locals. Read the code at the top frame of the project''s own units (editor_read_file). ' +
        'Say what raised it, why, and the smallest change that fixes the cause (not one that hides the ' +
        'message). If no exception is on record, say so.';
    'fix_failing_test':
    begin
      Suite := ArgOf(AArgs, 'suite');
      AText := 'Run the tests and fix what fails. Call ide_run_tests with the project''s test_project';
      if Suite <> '' then AText := AText + ' and suite="' + Suite + '"';
      AText := AText + '. Take the failures one at a time: read the test and the code it checks, decide ' +
        'whether the code or the test is wrong (say which and why), make the smallest change with ' +
        'editor_edit_text, save, and run that test again before the next one. At the end run everything ' +
        'once more and report the counts. Never delete or loosen a test just to make it pass.';
    end;
    'write_adr':
    begin
      Topic := ArgOf(AArgs, 'topic');
      if Topic = '' then
      begin
        AErr := 'topic is required: what the decision is about';
        Exit;
      end;
      AText := 'Write an architecture decision record about: ' + Topic + '. First look at the project''s ' +
        'docs/adr folder (project_list_directory) and read the newest record or two, to copy their format, ' +
        'headings and numbering. State the problem, the decision, the alternatives that were rejected and ' +
        'why, and the consequences, including what gets worse. Create the next number with ' +
        'editor_create_file. Mark it Proposed unless the person has said it is decided.';
    end;
    'release_checklist':
    begin
      Version := ArgOf(AArgs, 'version');
      AText := 'Check that the open project is ready to release';
      if Version <> '' then AText := AText + ' as version ' + Version;
      AText := AText + '. Report each item as ready, not ready or not checkable, with the evidence: ' +
        '1) git_status is clean and the branch is the one meant to be released; 2) project_build ' +
        'succeeds with no warnings that are new; 3) ide_run_tests passes (state the counts and what was ' +
        'skipped); 4) the version in the project or package matches' +
        IfThen(Version <> '', ' ' + Version, ' the release') + ' and the README, changelog and ' +
        'documents say the same; 5) nothing is left marked TODO or FIXME that was meant for this release ' +
        '(project_list_todos). Do not tag, push or publish anything: end with what is left to do.';
    end;
  else
    Result := False;
  end;
end;

end.
