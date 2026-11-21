{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsStatus;

{ ide_get_status — the IDE's aggregated one-call status: project, unsaved
  editors, debugger and server version, so a client starts a task with one
  call instead of several.  Read-only, and it never dereferences the project,
  so it works with none open (the project section is omitted then); that is
  why it is on the short list in McpToolNeedsProject.

  Every section comes from a state source another tool already reads:
  LazarusIDE.ActiveProject (project_get_directory), SourceEditorManagerIntf
  with TSourceEditorInterface.Modified (editor_list_open), DebugBoss.State
  with McpLeaseJSON (McpDebugLease), the package version (ide_ping), and git
  in the project directory (git_status) — the last only when the caller asks
  for it, because git status can be slow on big repositories. }

{$mode objfpc}{$H+}

interface

implementation

uses
  SysUtils, Process,
  LazIDEIntf, SrcEditorIntf, PackageIntf, ProjectIntf,
  LazDebuggerIntfBaseTypes, BaseDebugManager,
  fpjson,
  McpToolContext, McpDebugLease, McpIdeState;

{ ── Schema constants ─────────────────────────────────────────────────────── }

const
  SCHEMA_GET_STATUS =
    '{"type":"object","properties":{' +
    '"include_git":{"type":"boolean","description":"Also the git state of the open ' +
    'project''s directory (in_repo, branch, changed files count); default false, ' +
    'because git status can be slow on big repositories"}}}';

  { at most this many unsaved file names in the answer }
  UNSAVED_CAP = 10;

{ ── Helpers ──────────────────────────────────────────────────────────────── }

{ The debugger state as a word, mapped like McpToolsDebugger's DbgStateStr. }
function DebuggerStateStr(S: TDBGState): string;
begin
  case S of
    dsNone, dsIdle           : Result := 'idle';
    dsStop                   : Result := 'stopped';
    dsPause                  : Result := 'paused';
    dsInternalPause          : Result := 'running';  { internal pause; IDE auto-continues }
    dsInit, dsRun            : Result := 'running';
    dsError                  : Result := 'error';
    dsDestroying             : Result := 'stopped';
  else
    Result := 'idle';
  end;
end;

{ The git state of ADir: in_repo, the branch and the count of changed files,
  from one `git status --porcelain=v1 --branch`. }
procedure FillGitSection(const ADir: string; Obj: TJSONObject);
var
  GitExe    : string;
  Proc      : TProcess;
  Chunk     : string;
  BytesRead : LongInt;
  Output    : string;
  Line      : string;
  Changed   : Integer;
  SepPos    : Integer;
const
  BufSize = 4096;
begin
  GitExe := McpGitExecutable;
  if GitExe = '' then
  begin
    Obj.Add('in_repo', False);
    Obj.Add('error', 'git executable not found on PATH');
    Exit;
  end;
  Proc   := TProcess.Create(nil);
  Output := '';
  Chunk  := '';
  try
    Proc.Executable := GitExe;
    Proc.Parameters.Add('status');
    Proc.Parameters.Add('--porcelain=v1');
    Proc.Parameters.Add('--branch');
    Proc.CurrentDirectory := ADir;
    Proc.Options := [poUsePipes, poStderrToOutput];
    Proc.Execute;
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
    if Proc.ExitCode <> 0 then
    begin
      Obj.Add('in_repo', False);
      { not a repository is the expected case; anything else is worth a line }
      if Pos('not a git repository', Output) = 0 then
        Obj.Add('error', Trim(Copy(Output, 1, 200)));
      Exit;
    end;
    Obj.Add('in_repo', True);
    Changed := 0;
    while Output <> '' do
    begin
      SepPos := Pos(#10, Output);
      if SepPos = 0 then
      begin
        Line := Output;
        Output := '';
      end
      else
      begin
        Line := Copy(Output, 1, SepPos - 1);
        Delete(Output, 1, SepPos);
      end;
      if Line = '' then Break;
      if Copy(Line, 1, 3) = '## ' then
      begin
        { "## <branch>[...[upstream]]" }
        SepPos := Pos('...', Line);
        if SepPos > 0 then
          Line := Copy(Line, 4, SepPos - 4)
        else
          Line := Copy(Line, 4, MaxInt);
        if Line <> '' then Obj.Add('branch', Line);
      end
      else
        Inc(Changed);
    end;
    Obj.Add('changed', Changed);
  finally
    Proc.Free;
  end;
end;

{ ── Dispatch ─────────────────────────────────────────────────────────────── }

function DispatchStatusTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  Obj          : TJSONObject;
  ProjectSec   : TJSONObject;
  Editors      : TJSONObject;
  GitSec       : TJSONObject;
  DbgSec       : TJSONObject;
  Lease        : TJSONObject;
  Unsaved      : TJSONArray;
  IDEPkg       : TIDEPackage;
  Proj         : TLazProject;
  I, Total     : Integer;
begin
  Result := Name = 'ide_get_status';
  if not Result then Exit;
  Obj := TJSONObject.Create;
  try
    { project: the section is omitted when none is open }
    if Assigned(LazarusIDE) and Assigned(LazarusIDE.ActiveProject) and
       (LazarusIDE.ActiveProject.ProjectInfoFile <> '') then
    begin
      Proj := LazarusIDE.ActiveProject;
      ProjectSec := TJSONObject.Create;
      try
        ProjectSec.Add('name', ExtractFileName(Proj.ProjectInfoFile));
        ProjectSec.Add('project_file', Proj.ProjectInfoFile);
        ProjectSec.Add('directory', ExtractFilePath(Proj.ProjectInfoFile));
        Obj.Add('project', ProjectSec);
        ProjectSec := nil;
      finally
        ProjectSec.Free;
      end;
      if Assigned(Ctx.Params) and Ctx.Params.Get('include_git', False) then
      begin
        GitSec := TJSONObject.Create;
        try
          FillGitSection(ExtractFilePath(Proj.ProjectInfoFile), GitSec);
          Obj.Add('git', GitSec);
          GitSec := nil;
        finally
          GitSec.Free;
        end;
      end;
    end;

    { editors: how many buffers have unsaved changes, capped file names }
    if Assigned(SourceEditorManagerIntf) then
    begin
      Editors := TJSONObject.Create;
      Unsaved := TJSONArray.Create;
      try
        Total := 0;
        for I := 0 to SourceEditorManagerIntf.SourceEditorCount - 1 do
          if SourceEditorManagerIntf.SourceEditors[I].Modified then
          begin
            Inc(Total);
            if Unsaved.Count < UNSAVED_CAP then
              Unsaved.Add(SourceEditorManagerIntf.SourceEditors[I].FileName);
          end;
        Editors.Add('unsaved_count', Total);
        if Unsaved.Count > 0 then
        begin
          Editors.Add('unsaved', Unsaved);
          Unsaved := nil;
          if Total > Editors.Arrays['unsaved'].Count then
            Editors.Add('truncated', True);
        end;
        Obj.Add('editors', Editors);
        Editors := nil;
      finally
        Unsaved.Free;
        Editors.Free;
      end;
    end;

    { debugger }
    DbgSec := TJSONObject.Create;
    try
      if Assigned(DebugBoss) then
        DbgSec.Add('state', DebuggerStateStr(DebugBoss.State))
      else
        DbgSec.Add('state', 'idle');
      Lease := McpLeaseJSON;
      if Assigned(Lease) then
        DbgSec.Add('lease', Lease);
      Obj.Add('debugger', DbgSec);
      DbgSec := nil;
    finally
      DbgSec.Free;
    end;

    { server version, as ide_ping reports it }
    IDEPkg := PackageEditingInterface.FindPackageWithName('LazMcpAssistant');
    if Assigned(IDEPkg) then
      Obj.Add('server', TJSONObject.Create(['version', IDEPkg.Version.AsString]));

    Ctx.Result := Obj.AsJSON;
  finally
    Obj.Free;
  end;
end;

{ ── Schema registration ──────────────────────────────────────────────────── }

procedure RegisterStatusSchemas(Tools: TJSONArray);
begin
  Tools.Add(MakeTool('ide_get_status',
    'Aggregated IDE status in one call: the open project (name, project_file, ' +
    'directory; the section is omitted when no project is open), unsaved editors ' +
    '(count and at most 10 file names), the debugger state with the session lease ' +
    'when one is held, and the server version. include_git=true adds the git state ' +
    'of the project''s directory (in_repo, branch, changed files count); it is off ' +
    'by default because git status can be slow.',
    SCHEMA_GET_STATUS, MCP_ANN_RO));
end;

initialization
  RegisterMcpGroup(@DispatchStatusTool);
  RegisterMcpSchemas(@RegisterStatusSchemas);

end.
