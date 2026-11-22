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
  SysUtils, Process, LazFileUtils, LazIDEIntf, SrcEditorIntf, McpIdeState;

{ The child gets the parent's environment with these set by key (a value the user
  has set is replaced, never doubled): git must never wait for a terminal or an
  editor, whatever the user's configuration says (ADR-028, "every call"). }
procedure SetGitEnvironment(AProc: TProcess);
var
  I : Integer;
begin
  for I := 1 to GetEnvironmentVariableCount do
    AProc.Environment.Add(GetEnvironmentString(I));
  AProc.Environment.Values['GIT_TERMINAL_PROMPT'] := '0';
  AProc.Environment.Values['GIT_EDITOR']          := 'true';
  AProc.Environment.Values['GIT_MERGE_AUTOEDIT']  := 'no';
end;

function RunGit(const Args: array of string; const WorkDir: string;
  out Output: string; const AInput: string): Boolean;
var
  GitExe    : string;
  Proc      : TProcess;
  Chunk     : string;
  BytesRead : LongInt;
  Arg       : string;
const
  BufSize = 4096;
begin
  GitExe := McpGitExecutable;
  if GitExe = '' then
  begin
    Output := 'git executable not found on PATH; the user can set its path in ' +
              'Tools > Options > MCP Assistant';
    Exit(False);
  end;
  Output := '';
  Proc   := TProcess.Create(nil);
  try
    Proc.Executable := GitExe;
    for Arg in Args do
      Proc.Parameters.Add(Arg);
    Proc.Options := [poUsePipes, poStdErrToOutput, poNoConsole];
    Proc.ShowWindow := swoHide;
    if WorkDir <> '' then
      Proc.CurrentDirectory := WorkDir;
    SetGitEnvironment(Proc);
    Proc.Execute;
    if AInput <> '' then
      Proc.Input.Write(AInput[1], Length(AInput));
    Proc.CloseInput;
    Chunk := '';
    repeat
      SetLength(Chunk, BufSize);
      BytesRead := Proc.Output.Read(Chunk[1], BufSize);
      if BytesRead > 0 then
      begin
        SetLength(Chunk, BytesRead);
        Output := Output + Chunk;
      end;
    until (BytesRead = 0) and not Proc.Running;
    Proc.WaitOnExit;
    Result := Proc.ExitCode = 0;
    if not Result and (Pos('not a git repository', Output) > 0) then
      Output := Trim(Output) + LineEnding + '(pass work_dir: a directory inside the repository; ' +
        'without it the saved project''s directory, then the active editor''s file directory is used)';
  finally
    Proc.Free;
  end;
end;

function RunGitTimed(const AExe: string; const Args: array of string;
  const WorkDir: string; ATimeoutMs: QWord; out Output: string;
  const AInput: string; const AEnv: string): Boolean;
var
  Proc     : TProcess;
  Buf      : string;
  N        : LongInt;
  Arg      : string;
  Started  : QWord;
  TimedOut : Boolean;

  procedure Drain;
  begin
    while Proc.Output.NumBytesAvailable > 0 do
    begin
      SetLength(Buf, 4096);
      N := Proc.Output.Read(Buf[1], 4096);
      if N <= 0 then Break;
      SetLength(Buf, N);
      Output := Output + Buf;
    end;
  end;

begin
  Output   := '';
  TimedOut := False;
  Proc     := TProcess.Create(nil);
  try
    Proc.Executable := AExe;
    for Arg in Args do
      Proc.Parameters.Add(Arg);
    Proc.Options := [poUsePipes, poStdErrToOutput, poNoConsole];
    if WorkDir <> '' then
      Proc.CurrentDirectory := WorkDir;
    SetGitEnvironment(Proc);
    if (AEnv <> '') and (Pos('=', AEnv) > 1) then
      Proc.Environment.Values[Copy(AEnv, 1, Pos('=', AEnv) - 1)] :=
        Copy(AEnv, Pos('=', AEnv) + 1, MaxInt);
    Proc.Execute;
    if AInput <> '' then
      Proc.Input.Write(AInput[1], Length(AInput));
    Proc.CloseInput;
    Started := GetTickCount64;
    while Proc.Running do
    begin
      Drain;
      if GetTickCount64 - Started > ATimeoutMs then
      begin
        TimedOut := True;
        Proc.Terminate(1);
        Break;
      end;
      Sleep(30);
    end;
    Proc.WaitOnExit;
    Drain;
    Result := (Proc.ExitCode = 0) and not TimedOut;
    if TimedOut then
      Output := Output + LineEnding + 'git was stopped after ' +
        IntToStr(ATimeoutMs div 60000) + ' minutes.';
  finally
    Proc.Free;
  end;
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
