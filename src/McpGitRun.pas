{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpGitRun;

{ Running git for the git tools: the short call on the main thread (RunGit), the
  long one on the MCP worker thread (RunGitTimed), and the directory a call
  works in (GetGitWorkDir). }

{$mode objfpc}{$H+}

interface

uses
  Classes, McpToolContext;

{ AInput, if any, is written to git's standard input (git commit -F -): on
  Windows TProcess joins the arguments into one command line without escaping
  double quotes, so free text must not be an argument.  Main thread only
  (McpGitExecutable). }
function RunGit(const Args: array of string; const WorkDir: string;
  out Output: string; const AInput: string = ''): Boolean;

{ Like RunGit, for a command that may take minutes and talks to a remote:
  runs on the MCP worker thread (so AExe is passed in, McpGitExecutable is for
  the main thread), never asks for credentials (stdin is closed, so a prompt
  would hang), and is stopped after ATimeoutMs.  AEnv, if not empty, is one more
  environment entry NAME=value for this child only (git_serve: GIT_INDEX_FILE). }
function RunGitTimed(const AExe: string; const Args: array of string;
  const WorkDir: string; ATimeoutMs: QWord; out Output: string;
  const AInput: string = ''; const AEnv: string = ''): Boolean;

{ Files whose open editor holds unsaved changes.  Main thread only. }
procedure McpUnsavedEditors(AFiles: TStrings);

{ work_dir of the call, else the saved project's directory, else the directory of
  the active editor's file. }
function GetGitWorkDir(const Ctx: TMcpToolCall): string;

implementation

uses
  SysUtils, LazFileUtils, LazIDEIntf, SrcEditorIntf, McpIdeState, McpProcess;

{ The child gets the parent's environment with these set by key (a value the user
  has set is replaced, never doubled): git must never wait for a terminal or an
  editor, whatever the user's configuration says (ADR-028, "every call"). }
function GitEnvironment(const AExtra: string): TStringArray;
begin
  Result := nil;
  SetLength(Result, 3);
  Result[0] := 'GIT_TERMINAL_PROMPT=0';
  Result[1] := 'GIT_EDITOR=true';
  Result[2] := 'GIT_MERGE_AUTOEDIT=no';
  if (AExtra <> '') and (Pos('=', AExtra) > 1) then
  begin
    SetLength(Result, 4);
    Result[3] := AExtra;
  end;
end;

function RunGit(const Args: array of string; const WorkDir: string;
  out Output: string; const AInput: string): Boolean;
var
  GitExe : string;
  Code   : Integer;
begin
  GitExe := McpGitExecutable;
  if GitExe = '' then
  begin
    Output := 'git executable not found on PATH; the user can set its path in ' +
              'Tools > Options > MCP Assistant';
    Exit(False);
  end;
  Result := (McpRunCapture(GitExe, Args, WorkDir, Output, Code, 0, AInput,
              GitEnvironment('')) = reExited) and (Code = 0);
  if not Result and (Pos('not a git repository', Output) > 0) then
    Output := Trim(Output) + LineEnding + '(pass work_dir: a directory inside the repository; ' +
      'without it the saved project''s directory, then the active editor''s file directory is used)';
end;

function RunGitTimed(const AExe: string; const Args: array of string;
  const WorkDir: string; ATimeoutMs: QWord; out Output: string;
  const AInput: string; const AEnv: string): Boolean;
var
  Code : Integer;
  Ended : TMcpRunEnd;
begin
  Ended  := McpRunCapture(AExe, Args, WorkDir, Output, Code, ATimeoutMs, AInput,
              GitEnvironment(AEnv));
  Result := (Ended = reExited) and (Code = 0);
  if Ended = reTimedOut then
    Output := Output + LineEnding + 'git was stopped after ' +
      IntToStr(ATimeoutMs div 60000) + ' minutes.';
end;

procedure McpUnsavedEditors(AFiles: TStrings);
var
  I  : Integer;
  Ed : TSourceEditorInterface;
begin
  AFiles.Clear;
  for I := 0 to SourceEditorManagerIntf.UniqueSourceEditorCount - 1 do
  begin
    Ed := SourceEditorManagerIntf.UniqueSourceEditors[I];
    if Ed.Modified then
      AFiles.Add(Ed.FileName);
  end;
end;

function GetGitWorkDir(const Ctx: TMcpToolCall): string;
begin
  if Assigned(Ctx.Params) then
    Result := Ctx.Params.Get('work_dir', '')
  else
    Result := '';
  if (Result = '') and Assigned(LazarusIDE.ActiveProject) and
     (LazarusIDE.ActiveProject.ProjectInfoFile <> '') then
    Result := ExtractFilePath(LazarusIDE.ActiveProject.ProjectInfoFile);
  if (Result = '') and Assigned(SourceEditorManagerIntf) and
     Assigned(SourceEditorManagerIntf.ActiveEditor) and
     FilenameIsAbsolute(SourceEditorManagerIntf.ActiveEditor.FileName) then
    Result := ExtractFilePath(SourceEditorManagerIntf.ActiveEditor.FileName);
end;

end.
