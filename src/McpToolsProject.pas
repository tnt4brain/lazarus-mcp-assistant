{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsProject;

{ Project lifecycle tools: ide_ping, project_get_directory, project_get_settings,
  project_set_settings, get_lazarus_reference, project_add_file,
  project_remove_file, form_create, project_list_templates, project_create.
  Also owns KnowledgeText and IsDescriptorInteractive. }

{$mode objfpc}{$H+}

interface

function GetSystemPromptText: string;

implementation

uses
  Classes, SysUtils,
  LazIDEIntf, ProjectIntf, PackageIntf, SrcEditorIntf, LazFileUtils, FileUtil,
  Controls, Forms, IDEDialogs,
  fpjson,
  McpToolContext;

{ ── Compiled-in reference knowledge & system prompt ─────────────────────── }

const
  KnowledgeText   : string = {$I lazarus_knowledge.inc};
  SystemPromptText: string = {$I system_prompt.inc};

{ ── Schema constants ─────────────────────────────────────────────────────── }

const
  SCHEMA_PING =
    '{"type":"object","properties":{}}';

  SCHEMA_GET_PROJECT_DIRECTORY =
    '{"type":"object","properties":{}}';

  SCHEMA_GET_PROJECT_SETTINGS =
    '{"type":"object","properties":{}}';

  SCHEMA_SET_PROJECT_SETTINGS =
    '{"type":"object","properties":{' +
    '"target_os":{"type":"string","description":"Target OS (e.g. win64, linux); empty string = host OS"},' +
    '"target_cpu":{"type":"string","description":"Target CPU (e.g. x86_64, aarch64); empty string = host CPU"},' +
    '"output_dir":{"type":"string","description":"Unit output directory; macros like $(TargetOS) are expanded at build time"},' +
    '"custom_options":{"type":"string","description":"Custom compiler options string (REPLACES existing value; read project_get_settings first to preserve existing flags)"}}}';

  SCHEMA_ADD_FILE_TO_PROJECT =
    '{"type":"object","properties":{' +
    '"file_path":{"type":"string","description":"Absolute path to the existing .pas (or other source) file to add"}},' +
    '"required":["file_path"]}';

  SCHEMA_REMOVE_FILE_FROM_PROJECT =
    '{"type":"object","properties":{' +
    '"file_path":{"type":"string","description":"Absolute path to the file to remove from the project (file is NOT deleted from disk)"}},' +
    '"required":["file_path"]}';

  SCHEMA_CREATE_FORM =
    '{"type":"object","properties":{' +
    '"unit_name":{"type":"string","description":"Pascal unit name for the new form (e.g. UnitSettings)"},' +
    '"kind":{"type":"string","enum":["form","datamodule","frame"],"description":"What to create (default form)"},' +
    '"directory":{"type":"string","description":"Directory for the new files; defaults to the active project directory"}},' +
    '"required":["unit_name"]}';

  SCHEMA_LIST_PROJECT_TEMPLATES =
    '{"type":"object","properties":{' +
    '"visible_only":{"type":"boolean","description":"If true (default), return only templates shown in the New Project dialog. Pass false to include hidden/internal templates."}}}';

  SCHEMA_CREATE_PROJECT =
    '{"type":"object","properties":{' +
    '"project_type":{"type":"string","description":"Template name from project_list_templates (case-insensitive). Default: ''Application'' (GUI app with Form1)."},' +
    '"project_dir":{"type":"string","description":"Absolute path for the project directory; created if absent"},' +
    '"project_name":{"type":"string","description":"Project name (becomes the .lpi filename without extension)"}},' +
    '"required":["project_dir","project_name"]}';

  SCHEMA_OPEN_PROJECT =
    '{"type":"object","properties":{' +
    '"file_path":{"type":"string","description":"Absolute path of the project''s .lpi"}},' +
    '"required":["file_path"]}';

{ ── IsDescriptorInteractive helper ──────────────────────────────────────── }

type
  TProjectDescHack = class(TProjectDescriptor)
  public
    function DoInitDescriptorCode: Pointer;
  end;


function TProjectDescHack.DoInitDescriptorCode: Pointer;
type TInitFunc = function: TModalResult of object;
var F: TInitFunc;
begin
  F      := @DoInitDescriptor;    { protected — accessible from subclass }
  Result := TMethod(F).Code;      { FPC reads Self's actual VMT entry }
end;

var GBaseDoInitCode: Pointer = nil;

function IsDescriptorInteractive(Desc: TProjectDescriptor): Boolean;
var Probe: TProjectDescHack;
begin
  if GBaseDoInitCode = nil then
  begin
    Probe := TProjectDescHack.Create;
    try
      GBaseDoInitCode := Probe.DoInitDescriptorCode;
    finally
      Probe.Free;
    end;
  end;
  if GBaseDoInitCode = nil then
    Exit(True);   { couldn't determine base — assume interactive to be safe }
  Result := TProjectDescHack(Desc).DoInitDescriptorCode <> GBaseDoInitCode;
end;

{ ── Resource accessors ──────────────────────────────────────────────────── }

function GetKnowledgeText: string;
begin
  Result := KnowledgeText;
end;

function GetSystemPromptText: string;
begin
  Result := SystemPromptText;
end;

{ A Save As dialog that shows nothing: it answers with a file in
  GMcpSaveDir, under the name the IDE suggests (GMcpSaveProjectName for the
  project file).  Installed as IDESaveDialogClass only while project_create
  saves a new project. }
type
  TMcpSaveDialog = class(TIDESaveDialog)
  protected
    function DoExecute: boolean; override;
  public
    class function NeedOverwritePrompt: boolean; override;
  end;

var
  GMcpSaveDir         : string = '';
  GMcpSaveProjectName : string = '';

function TMcpSaveDialog.DoExecute: boolean;
begin
  if SameText(ExtractFileExt(FileName), '.lpi') then
    FileName := GMcpSaveDir + GMcpSaveProjectName + '.lpi'
  else
    FileName := GMcpSaveDir + ExtractFileName(FileName);
  Result := True;
end;

class function TMcpSaveDialog.NeedOverwritePrompt: boolean;
begin
  Result := False;  { project_create only saves into an empty folder }
end;

{ Why the current project cannot be closed for AAction ('' when it can):
  closing it would otherwise ask the user about unsaved changes in a dialog,
  and the tool call would wait for it. }
function ProjectCloseRefusal(const AAction: string): string;
var
  I : Integer;
begin
  Result := '';
  if LazarusIDE.ToolStatus <> itNone then
    Exit('The IDE is busy (debugging or building). Stop that first (debug_stop), ' +
         'then try ' + AAction + ' again.');
  if Assigned(LazarusIDE.ActiveProject) and LazarusIDE.ActiveProject.Modified then
    Exit('The current project ' + LazarusIDE.ActiveProject.ProjectInfoFile +
         ' has unsaved changes. Ask the user to save or discard them first.');
  for I := 0 to SourceEditorManagerIntf.SourceEditorCount - 1 do
    if SourceEditorManagerIntf.SourceEditors[I].Modified then
      Exit('Unsaved changes in ' + SourceEditorManagerIntf.SourceEditors[I].FileName +
           '. Save them (editor_save) or ask the user before ' + AAction + '.');
end;

{ ── Dispatch ─────────────────────────────────────────────────────────────── }

function DispatchProjectTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  Obj        : TJSONObject;
  Arr        : TJSONArray;
  DescObj    : TJSONObject;
  Proj       : TLazProject;
  PF         : TLazProjectFile;
  IDEPkg     : TIDEPackage;
  Descriptor : TProjectDescriptor;
  FilePath   : string;
  NewName    : string;
  Kind       : string;
  Desc       : TProjectFileDescriptor;
  ProjType   : string;
  VisibleOnly: Boolean;
  I, J       : Integer;
  OldSaveDialogClass : TIDESaveDialogClass;
  SaveRes    : TModalResult;
  Existing   : TStringList;
begin
  Result := False;

  if Name = 'project_open' then
  begin
    { Opening closes the current project.  The IDE would ask about a running
      debugger or build and about unsaved changes, so those cases are refused
      here instead; ofRevert skips the last question, which then concerns
      session data only (cursor positions, open tabs), and discards it. }
    Result := True;
    FilePath := '';
    if Assigned(Ctx.Params) then
      FilePath := Ctx.Params.Get('file_path', '');
    if FilePath = '' then
    begin
      Ctx.Error := True; Ctx.Result := 'file_path required'; Exit;
    end;
    FilePath := CleanAndExpandFilename(FilePath);
    if not SameText(ExtractFileExt(FilePath), '.lpi') then
    begin
      Ctx.Error := True; Ctx.Result := 'Pass the project''s .lpi file: ' + FilePath; Exit;
    end;
    if not FileExists(FilePath) then
    begin
      Ctx.Error := True; Ctx.Result := 'File not found: ' + FilePath; Exit;
    end;
    Proj := LazarusIDE.ActiveProject;
    NewName := '';
    if Assigned(Proj) then
    begin
      NewName := Proj.ProjectInfoFile;
      if CompareFilenames(NewName, FilePath) = 0 then
      begin
        Ctx.Result := '{"project_file":"' + StringToJSONString(FilePath) +
                      '","already_open":true}';
        Exit;
      end;
    end;
    Ctx.Result := ProjectCloseRefusal('opening another project');
    if Ctx.Result <> '' then
    begin
      Ctx.Error := True; Exit;
    end;
    if LazarusIDE.DoOpenProjectFile(FilePath, [ofAddToRecent, ofRevert]) <> mrOK then
    begin
      Ctx.Error := True; Ctx.Result := 'Could not open ' + FilePath; Exit;
    end;
    Obj := TJSONObject.Create;
    try
      if Assigned(LazarusIDE.ActiveProject) then
        Obj.Add('project_file', LazarusIDE.ActiveProject.ProjectInfoFile)
      else
        Obj.Add('project_file', FilePath);
      Obj.Add('previous_project', NewName);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'ide_ping' then
  begin
    Result := True;
    Obj := TJSONObject.Create;
    try
      Obj.Add('status', 'ok');
      IDEPkg := PackageEditingInterface.FindPackageWithName('LazMcpAssistant');
      if Assigned(IDEPkg) then
        Obj.Add('version', IDEPkg.Version.AsString);
      { who the server thinks is calling: the session id the client sent
        back, or 'anonymous' (ADR-012) }
      if Ctx.ClientId <> '' then
        Obj.Add('client', Ctx.ClientId);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'project_get_directory' then
  begin
    Result := True;
    Obj := TJSONObject.Create;
    try
      if Assigned(LazarusIDE) and Assigned(LazarusIDE.ActiveProject) then
        Obj.Add('directory', ExtractFilePath(LazarusIDE.ActiveProject.ProjectInfoFile))
      else
        Obj.Add('error', 'No active project');
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'project_get_settings' then
  begin
    Result := True;
    Obj := TJSONObject.Create;
    try
      if Assigned(LazarusIDE) and Assigned(LazarusIDE.ActiveProject) then
      begin
        Proj := LazarusIDE.ActiveProject;
        Obj.Add('project_file',  Proj.ProjectInfoFile);
        Obj.Add('target_os_cpu', LazarusIDE.GetFPCFrontEndOptions);
        if Assigned(Proj.LazCompilerOptions) then
        begin
          Obj.Add('custom_options', Proj.LazCompilerOptions.CustomOptions);
          Obj.Add('output_dir',     Proj.LazCompilerOptions.UnitOutputDirectory);
          Obj.Add('target_os',      Proj.LazCompilerOptions.TargetOS);
        end;
      end
      else
        Obj.Add('error', 'No active project');
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'project_set_settings' then
  begin
    Result := True;
    Proj := LazarusIDE.ActiveProject;
    if not Assigned(Proj) or not Assigned(Proj.LazCompilerOptions) then
    begin
      Ctx.Error := True; Ctx.Result := 'No active project'; Exit;
    end;
    if Assigned(Ctx.Params) then
    begin
      if Ctx.Params.Find('target_os')      <> nil then
        Proj.LazCompilerOptions.TargetOS            := Ctx.Params.Get('target_os',      '');
      if Ctx.Params.Find('target_cpu')     <> nil then
        Proj.LazCompilerOptions.TargetCPU           := Ctx.Params.Get('target_cpu',     '');
      if Ctx.Params.Find('output_dir')     <> nil then
        Proj.LazCompilerOptions.UnitOutputDirectory := Ctx.Params.Get('output_dir',     '');
      if Ctx.Params.Find('custom_options') <> nil then
        Proj.LazCompilerOptions.CustomOptions       := Ctx.Params.Get('custom_options', '');
    end;
    LazarusIDE.DoSaveProject([]);
    Obj := TJSONObject.Create;
    try
      Obj.Add('project_file',   Proj.ProjectInfoFile);
      Obj.Add('target_os',      Proj.LazCompilerOptions.TargetOS);
      Obj.Add('target_cpu',     Proj.LazCompilerOptions.TargetCPU);
      Obj.Add('output_dir',     Proj.LazCompilerOptions.UnitOutputDirectory);
      Obj.Add('custom_options', Proj.LazCompilerOptions.CustomOptions);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'project_add_file' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('file_path', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'file_path required'; Exit;
    end;
    FilePath := CleanAndExpandFilename(Ctx.Params.Get('file_path', ''));
    if not FileExists(FilePath) then
    begin
      Ctx.Error := True; Ctx.Result := 'File not found: ' + FilePath; Exit;
    end;
    Proj := LazarusIDE.ActiveProject;
    if not Assigned(Proj) then
    begin
      Ctx.Error := True; Ctx.Result := 'No active project'; Exit;
    end;
    PF := Proj.CreateProjectFile(FilePath);
    Proj.AddFile(PF, False);
    LazarusIDE.DoSaveProject([]);
    Obj := TJSONObject.Create;
    try
      Obj.Add('file',    FilePath);
      Obj.Add('project', Proj.ProjectInfoFile);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'project_remove_file' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('file_path', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'file_path required'; Exit;
    end;
    FilePath := CleanAndExpandFilename(Ctx.Params.Get('file_path', ''));
    Proj := LazarusIDE.ActiveProject;
    if not Assigned(Proj) then
    begin
      Ctx.Error := True; Ctx.Result := 'No active project'; Exit;
    end;
    J := -1;
    for I := 0 to Proj.FileCount - 1 do
      if SameFileName(Proj.Files[I].Filename, FilePath) then
      begin
        J := I;
        Break;
      end;
    if J < 0 then
    begin
      Ctx.Error := True; Ctx.Result := 'File not in project: ' + FilePath; Exit;
    end;
    Proj.RemoveUnit(J);
    LazarusIDE.DoSaveProject([]);
    Obj := TJSONObject.Create;
    try
      Obj.Add('removed', True);
      Obj.Add('file',    FilePath);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'form_create' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('unit_name', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'unit_name required'; Exit;
    end;
    NewName  := Ctx.Params.Get('unit_name', '');
    FilePath := Ctx.Params.Get('directory', '');
    if FilePath = '' then
    begin
      Proj := LazarusIDE.ActiveProject;
      if Assigned(Proj) then
        FilePath := ExtractFilePath(Proj.ProjectInfoFile)
      else
      begin
        Ctx.Error  := True;
        Ctx.Result := 'directory required when no project is open';
        Exit;
      end;
    end;
    FilePath := IncludeTrailingPathDelimiter(FilePath) + NewName + '.pas';
    Kind := LowerCase(Ctx.Params.Get('kind', 'form'));
    if Kind = 'form' then
      Desc := FileDescriptorForm
    else if Kind = 'datamodule' then
      Desc := FileDescriptorDatamodule
    else if Kind = 'frame' then
      Desc := ProjectFileDescriptors.FindByName(FileDescNameFrame)
    else
      Desc := nil;
    if Desc = nil then
    begin
      Ctx.Error  := True;
      Ctx.Result := 'kind must be form, datamodule or frame';
      Exit;
    end;
    { nfCreateDefaultSrc: without it NewFile leaves the unit empty and the
      designer root nameless (class "T") }
    if LazarusIDE.DoNewEditorFile(Desc, FilePath, '',
         [nfCreateDefaultSrc, nfIsPartOfProject, nfOpenInEditor, nfSave]) <> mrOK then
    begin
      Ctx.Error  := True;
      Ctx.Result := 'Could not create ' + FilePath;
      Exit;
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('kind',      Kind);
      Obj.Add('unit_file', FilePath);
      Obj.Add('form_file', ChangeFileExt(FilePath, '.lfm'));
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'project_list_templates' then
  begin
    Result := True;
    VisibleOnly := True;
    if Assigned(Ctx.Params) then
      VisibleOnly := Ctx.Params.Get('visible_only', True);
    Arr := TJSONArray.Create;
    try
      for I := 0 to ProjectDescriptors.Count - 1 do
      begin
        Descriptor := ProjectDescriptors.Items[I];
        if VisibleOnly and not Descriptor.VisibleInNewDialog then
          Continue;
        DescObj := TJSONObject.Create;
        DescObj.Add('name',           Descriptor.Name);
        DescObj.Add('localized_name', Descriptor.GetLocalizedName);
        DescObj.Add('description',    Descriptor.GetLocalizedDescription);
        DescObj.Add('interactive',    IsDescriptorInteractive(Descriptor));
        Arr.Add(DescObj);
      end;
      Ctx.Result := Arr.AsJSON;
    finally
      Arr.Free;
    end;
  end

  else if Name = 'project_create' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('project_dir', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'project_dir required'; Exit;
    end;
    if Ctx.Params.Get('project_name', '') = '' then
    begin
      Ctx.Error := True; Ctx.Result := 'project_name required'; Exit;
    end;
    FilePath := Ctx.Params.Get('project_dir',  '');
    NewName  := Ctx.Params.Get('project_name', '');
    ProjType := Ctx.Params.Get('project_type', 'Application');
    Descriptor := ProjectDescriptors.FindByName(ProjType);
    if not Assigned(Descriptor) then
    begin
      Ctx.Error  := True;
      Ctx.Result := 'Unknown project_type "' + ProjType +
        '". Call project_list_templates to see valid names.';
      Exit;
    end;
    if IsDescriptorInteractive(Descriptor) then
    begin
      Ctx.Error  := True;
      Ctx.Result := 'Template "' + Descriptor.Name + '" requires user input ' +
        'before the project is created (its DoInitDescriptor shows a dialog). ' +
        'Use a template where interactive=false in project_list_templates.';
      Exit;
    end;
    if not IsValidIdent(NewName) then
    begin
      Ctx.Error := True;
      Ctx.Result := 'project_name must be a Pascal identifier: ' + NewName; Exit;
    end;
    { new files only: the IDE would ask before overwriting }
    FilePath := IncludeTrailingPathDelimiter(CleanAndExpandDirectory(FilePath));
    if DirectoryExists(FilePath) then
    begin
      Existing := FindAllFiles(FilePath, AllFilesMask, False);
      try
        if Existing.Count > 0 then
        begin
          Ctx.Error := True;
          Ctx.Result := 'project_dir is not empty: ' + FilePath; Exit;
        end;
      finally
        Existing.Free;
      end;
    end;
    { DoNewProject closes the current project first, asking about unsaved
      changes in a dialog that would block this call }
    Ctx.Result := ProjectCloseRefusal('creating a project');
    if Ctx.Result <> '' then
    begin
      Ctx.Error := True; Exit;
    end;
    ForceDirectories(FilePath);
    if LazarusIDE.DoNewProject(Descriptor) <> mrOK then
    begin
      Ctx.Error := True; Ctx.Result := 'DoNewProject failed or was cancelled'; Exit;
    end;
    Proj := LazarusIDE.ActiveProject;
    { A new project is unsaved (virtual).  If closing the old one was answered
      otherwise, it can still be active here, and saving it would save the
      user's project under the new name. }
    if (Proj = nil) or not Proj.IsVirtual then
    begin
      Ctx.Error := True;
      Ctx.Result := 'No new project was created; the current project is unchanged.';
      Exit;
    end;
    Proj.Title := NewName;
    { A new project's files are unsaved: saving asks for each name in a Save
      As dialog.  Answered here, through the IDE's dialog class, with
      project_dir and the names the IDE suggests (project_name for the .lpi). }
    GMcpSaveDir         := FilePath;
    GMcpSaveProjectName := NewName;
    OldSaveDialogClass  := IDESaveDialogClass;
    IDESaveDialogClass  := TMcpSaveDialog;
    try
      SaveRes := LazarusIDE.DoSaveProject([]);
    finally
      IDESaveDialogClass := OldSaveDialogClass;
    end;
    Proj := LazarusIDE.ActiveProject;
    if (SaveRes <> mrOK) or (Proj = nil) or Proj.IsVirtual then
    begin
      Ctx.Error := True;
      Ctx.Result := 'The project was created but not saved; it is open in the IDE as an ' +
                    'unsaved project.';
      Exit;
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('project_file', Proj.ProjectInfoFile);
      Obj.Add('project_type', Descriptor.Name);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end;
end;

{ ── Schema registration ──────────────────────────────────────────────────── }

procedure RegisterProjectSchemas(Tools: TJSONArray);
begin
  Tools.Add(MakeTool('ide_ping',
    'Returns {"status":"ok","version":"x.y","client":"<id>"} immediately: client ' +
    'is the identity the server sees for this caller (its session id, or ' +
    '"anonymous"). After ide_rebuild, wait with the returned poll_command; ' +
    'this then confirms the server is back.',
    SCHEMA_PING, MCP_ANN_RO));
  Tools.Add(MakeTool('project_get_directory',
    'Return the root directory of the active project (directory containing the .lpi file).',
    SCHEMA_GET_PROJECT_DIRECTORY, MCP_ANN_RO));
  Tools.Add(MakeTool('project_get_settings',
    'Return active project compiler options: target OS/CPU, output directory, ' +
    'custom options, and project file path.',
    SCHEMA_GET_PROJECT_SETTINGS, MCP_ANN_RO));
  Tools.Add(MakeTool('project_set_settings',
    'Write compiler options to the active project. All parameters are optional; ' +
    'only supplied keys are changed. Returns the new settings in the same shape ' +
    'as project_get_settings. custom_options REPLACES the existing string.',
    SCHEMA_SET_PROJECT_SETTINGS, MCP_ANN_WRITE));
  Tools.Add(MakeTool('project_add_file',
    'Add an existing source file to the active project (.lpi). ' +
    'Saves the project afterwards.',
    SCHEMA_ADD_FILE_TO_PROJECT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('project_remove_file',
    'Remove a source file from the active project without deleting it from disk. ' +
    'Saves the project afterwards.',
    SCHEMA_REMOVE_FILE_FROM_PROJECT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('form_create',
    'Create a new form, data module or frame: a .pas unit and paired .lfm file, ' +
    'both added to the active project and opened in the editor. The IDE names ' +
    'it (Form2, DataModule1, Frame1); rename it with form_set_properties Name.',
    SCHEMA_CREATE_FORM, MCP_ANN_WRITE));
  Tools.Add(MakeTool('project_open',
    'Open an existing project (.lpi), closing the current one. Refused while ' +
    'debugging or building, or with unsaved changes. Clears the Messages window.',
    SCHEMA_OPEN_PROJECT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('project_list_templates',
    'List all registered Lazarus project templates (descriptors). Returns an array ' +
    'of {name, localized_name, description}. Pass the name to project_create as ' +
    'project_type.',
    SCHEMA_LIST_PROJECT_TEMPLATES, MCP_ANN_RO));
  Tools.Add(MakeTool('project_create',
    'Create a new Lazarus project from a template. Call project_list_templates to ' +
    'discover available templates. Returns ' +
    '{"project_file":"<path>","project_type":"<name>"}.',
    SCHEMA_CREATE_PROJECT, MCP_ANN_WRITE));
end;

initialization
  RegisterMcpGroup(@DispatchProjectTool);
  RegisterMcpSchemas(@RegisterProjectSchemas);
  RegisterMcpResource(
    'lazarus-ide://reference',
    'Lazarus IDE Reference',
    'Lazarus/FPC component library reference: available packages, install ' +
    'instructions, and key API gotchas. Read this before answering questions ' +
    'about LCL controls, package installation, or component libraries.',
    'text/plain',
    @GetKnowledgeText);
  RegisterMcpResource(
    'lazarus-ide://system-prompt',
    'MCP Assistant System Prompt',
    'Behavioral instructions injected into Claude when launched from the IDE. ' +
    'Describes available tools, recommended workflows, and common gotchas.',
    'text/plain',
    @GetSystemPromptText);

end.
