{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsProject;

{ Project lifecycle tools: ping, get_project_directory, get_project_settings,
  set_project_settings, get_lazarus_reference, add_file_to_project,
  remove_file_from_project, create_form, list_project_templates, create_project.
  Also owns KnowledgeText and IsDescriptorInteractive. }

{$mode objfpc}{$H+}

interface

implementation

uses
  Classes, SysUtils,
  LazIDEIntf, ProjectIntf, PackageIntf, LazFileUtils, FileUtil,
  Controls, Forms,
  fpjson,
  McpToolContext;

{ ── Compiled-in reference knowledge ─────────────────────────────────────── }

const
  KnowledgeText: string = {$I lazarus_knowledge.inc};

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
    '"custom_options":{"type":"string","description":"Custom compiler options string (REPLACES existing value; read get_project_settings first to preserve existing flags)"}}}';

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
    '"form_class":{"type":"string","description":"Form class name (e.g. TFormSettings); the IDE generates a name if omitted"},' +
    '"directory":{"type":"string","description":"Directory for the new files; defaults to the active project directory"}},' +
    '"required":["unit_name"]}';

  SCHEMA_LIST_PROJECT_TEMPLATES =
    '{"type":"object","properties":{' +
    '"visible_only":{"type":"boolean","description":"If true (default), return only templates shown in the New Project dialog. Pass false to include hidden/internal templates."}}}';

  SCHEMA_CREATE_PROJECT =
    '{"type":"object","properties":{' +
    '"project_type":{"type":"string","description":"Template name from list_project_templates (case-insensitive). Default: ''Application'' (GUI app with Form1)."},' +
    '"project_dir":{"type":"string","description":"Absolute path for the project directory; created if absent"},' +
    '"project_name":{"type":"string","description":"Project name (becomes the .lpi filename without extension)"}},' +
    '"required":["project_dir","project_name"]}';

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

{ ── Resource accessor ───────────────────────────────────────────────────── }

function GetKnowledgeText: string;
begin
  Result := KnowledgeText;
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
  ProjType   : string;
  VisibleOnly: Boolean;
  I, J       : Integer;
begin
  Result := False;

  if Name = 'ping' then
  begin
    Result := True;
    Obj := TJSONObject.Create;
    try
      Obj.Add('status', 'ok');
      IDEPkg := PackageEditingInterface.FindPackageWithName('LazMcpAssistant');
      if Assigned(IDEPkg) then
        Obj.Add('version', IDEPkg.Version.AsString);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'get_project_directory' then
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

  else if Name = 'get_project_settings' then
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

  else if Name = 'set_project_settings' then
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

  else if Name = 'add_file_to_project' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('file_path', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'file_path required'; Exit;
    end;
    FilePath := Ctx.Params.Get('file_path', '');
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

  else if Name = 'remove_file_from_project' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('file_path', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'file_path required'; Exit;
    end;
    FilePath := Ctx.Params.Get('file_path', '');
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

  else if Name = 'create_form' then
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
    LazarusIDE.DoNewEditorFile(
      FileDescriptorForm,
      FilePath,
      '',
      [nfIsPartOfProject, nfOpenInEditor, nfSave]);
    Obj := TJSONObject.Create;
    try
      Obj.Add('unit_file', FilePath);
      Obj.Add('form_file', ChangeFileExt(FilePath, '.lfm'));
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'list_project_templates' then
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

  else if Name = 'create_project' then
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
        '". Call list_project_templates to see valid names.';
      Exit;
    end;
    if IsDescriptorInteractive(Descriptor) then
    begin
      Ctx.Error  := True;
      Ctx.Result := 'Template "' + Descriptor.Name + '" requires user input ' +
        'before the project is created (its DoInitDescriptor shows a dialog). ' +
        'Use a template where interactive=false in list_project_templates.';
      Exit;
    end;
    ForceDirectories(FilePath);
    if LazarusIDE.DoNewProject(Descriptor) <> mrOK then
    begin
      Ctx.Error := True; Ctx.Result := 'DoNewProject failed or was cancelled'; Exit;
    end;
    Proj := LazarusIDE.ActiveProject;
    Proj.ProjectInfoFile := IncludeTrailingPathDelimiter(FilePath) + NewName + '.lpi';
    Proj.Title           := NewName;
    LazarusIDE.DoSaveProject([]);
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
  Tools.Add(MakeTool('ping',
    'Returns {"status":"ok","version":"x.y"} immediately. Use this to poll for the ' +
    'MCP server coming back after rebuild_ide — retry until it succeeds.',
    SCHEMA_PING, MCP_ANN_RO));
  Tools.Add(MakeTool('get_project_directory',
    'Return the root directory of the active project (directory containing the .lpi file).',
    SCHEMA_GET_PROJECT_DIRECTORY, MCP_ANN_RO));
  Tools.Add(MakeTool('get_project_settings',
    'Return active project compiler options: target OS/CPU, output directory, ' +
    'custom options, and project file path.',
    SCHEMA_GET_PROJECT_SETTINGS, MCP_ANN_RO));
  Tools.Add(MakeTool('set_project_settings',
    'Write compiler options to the active project. All parameters are optional; ' +
    'only supplied keys are changed. Returns the new settings in the same shape ' +
    'as get_project_settings. custom_options REPLACES the existing string.',
    SCHEMA_SET_PROJECT_SETTINGS, MCP_ANN_WRITE));
  Tools.Add(MakeTool('add_file_to_project',
    'Add an existing source file to the active project (.lpi). ' +
    'Saves the project afterwards.',
    SCHEMA_ADD_FILE_TO_PROJECT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('remove_file_from_project',
    'Remove a source file from the active project without deleting it from disk. ' +
    'Saves the project afterwards.',
    SCHEMA_REMOVE_FILE_FROM_PROJECT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('create_form',
    'Create a new LCL form: a .pas unit and paired .lfm file, both added to the ' +
    'active project and opened in the editor.',
    SCHEMA_CREATE_FORM, MCP_ANN_WRITE));
  Tools.Add(MakeTool('list_project_templates',
    'List all registered Lazarus project templates (descriptors). Returns an array ' +
    'of {name, localized_name, description}. Pass the name to create_project as ' +
    'project_type.',
    SCHEMA_LIST_PROJECT_TEMPLATES, MCP_ANN_RO));
  Tools.Add(MakeTool('create_project',
    'Create a new Lazarus project from a template. Call list_project_templates to ' +
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

end.
