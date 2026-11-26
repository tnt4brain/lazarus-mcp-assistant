{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsStatus;

{ ide_get_status — the IDE's aggregated one-call status: project, unsaved
  editors, debugger and server version, so a client starts a task with one
  call instead of several.  Read-only, and it never dereferences the project,
  so it works with none open (the project section is omitted then); that is
  why it is on the short list in McpToolNeedsProject.

  Every section comes from a state source another tool already reads:
  LazarusIDE.ActiveProject (project_get_directory), McpUnsavedEditors from
  McpGitRun (editor_list_open), DebugBoss.State with McpLeaseJSON
  (McpDebugLease), the package version (ide_ping), and git in the project
  directory through RunGit (git_status) — the last only when the caller asks
  for it, because git status can be slow on big repositories. }

{$mode objfpc}{$H+}

interface

implementation

uses
  SysUtils, Classes,
  LazIDEIntf, SrcEditorIntf, PackageIntf, ProjectIntf, BaseDebugManager,
  fpjson,
  McpToolContext, McpDebugLease, McpIdeState, McpGitRun;

{ ── Schema constants ─────────────────────────────────────────────────────── }

const
  SCHEMA_GET_STATUS =
    '{"type":"object","properties":{' +
    '"include_git":{"type":"boolean","description":"Also the git state of the open ' +
    'project''s directory (in_repo, branch, changed files count); default false, ' +
    'because git status can be slow on big repositories"}}}';

  { What the answer looks like.  Only "debugger" is always there: the project section is left out
    when no project is open, editors when the IDE has no source editor manager, git unless asked. }
  OUTPUT_GET_STATUS =
    '{"type":"object","properties":{' +
    '"project":{"type":"object","properties":{"name":{"type":"string"},"project_file":{"type":"string"},' +
    '"directory":{"type":"string"}}},' +
    '"git":{"type":"object"},' +
    '"editors":{"type":"object","properties":{"unsaved_count":{"type":"integer"},' +
    '"unsaved":{"type":"array","items":{"type":"string"}},"truncated":{"type":"boolean"}},' +
    '"required":["unsaved_count"]},' +
    '"debugger":{"type":"object","properties":{"state":{"type":"string"},"lease":{"type":"object"}},' +
    '"required":["state"]},' +
    '"server":{"type":"object","properties":{"version":{"type":"string"}}}},' +
    '"required":["debugger"]}';

  { at most this many unsaved file names in the answer }
  UNSAVED_CAP = 10;

{ ── Helpers ──────────────────────────────────────────────────────────────── }

{ The git state of ADir: in_repo, the branch and the count of changed files,
  from one `git status --porcelain=v1 --branch`.  RunGit hides the console
  window and stops git from waiting for a terminal; False leaves the reason
  in Output, and not being in a repository is the expected case here. }
procedure FillGitSection(const ADir: string; Obj: TJSONObject);
var
  Output  : string;
  Line    : string;
  Changed : Integer;
  SepPos  : Integer;
begin
  if not RunGit(['status', '--porcelain=v1', '--branch'], ADir, Output) then
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
  UnsavedNames : TStringList;
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

    { editors: how many buffers have unsaved changes, capped file names;
      McpUnsavedEditors walks the unique editors, one entry per file even
      when it is open in a split view or a second window }
    if Assigned(SourceEditorManagerIntf) then
    begin
      Editors := TJSONObject.Create;
      Unsaved := TJSONArray.Create;
      UnsavedNames := TStringList.Create;
      try
        McpUnsavedEditors(UnsavedNames);
        Total := UnsavedNames.Count;
        for I := 0 to Total - 1 do
          if I < UNSAVED_CAP then
            Unsaved.Add(UnsavedNames[I]);
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
        UnsavedNames.Free;
        Unsaved.Free;
        Editors.Free;
      end;
    end;

    { debugger }
    DbgSec := TJSONObject.Create;
    try
      if Assigned(DebugBoss) then
        DbgSec.Add('state', McpDbgStateStr(DebugBoss.State))
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
var
  T : TJSONObject;
begin
  T := MakeTool('ide_get_status',
    'Overview, several tools in one call: the open project as ' +
    'project_get_directory reports it (name, project_file, directory; the ' +
    'section is omitted when no project is open), unsaved editors as ' +
    'editor_list_open (count and at most 10 file names), the debugger state ' +
    'with the session lease as debug_get_state reports it, and the server ' +
    'version. include_git=true adds the git section of git_status (in_repo, ' +
    'branch, changed files count) for the project''s directory; it is off by ' +
    'default because git status can be slow.',
    SCHEMA_GET_STATUS, MCP_ANN_RO);
  McpSetOutputSchema(T, OUTPUT_GET_STATUS);
  Tools.Add(T);
end;

initialization
  RegisterMcpGroup(@DispatchStatusTool);
  RegisterMcpSchemas(@RegisterStatusSchemas);

end.
