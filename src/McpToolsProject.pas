{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsProject;

{ Project lifecycle tools: ide_ping, project_get_directory, project_get_settings,
  project_set_settings, get_lazarus_reference, project_add_file,
  project_remove_file, form_create, project_list_templates, project_create.
  Also owns KnowledgeText and IsDescriptorInteractive. }

{$mode objfpc}{$H+}

interface

uses McpDebugLease;

function GetSystemPromptText: string;

implementation

uses
  Classes, SysUtils,
  LazIDEIntf, ProjectIntf, PackageIntf, SrcEditorIntf, LazFileUtils, FileUtil, CompOptsIntf,
  MacroIntf, Controls, Forms, IDEDialogs, LCLPlatformDef, StrUtils,
  Project, ModeMatrixOpts, TransferMacros,   { IdeProject/IdeConfig, linked via IdeDebugger }
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
    '"custom_options":{"type":"string","description":"Custom compiler options string (REPLACES existing value; read project_get_settings first to preserve existing flags)"},' +
    '"debug_info":{"type":"string","description":"Debug information (-g): none, dwarf3, dwarf2, dwarf2set, stabs or auto. The FpDebug debugger (debug_run) needs a dwarf format; rebuild afterwards"},' +
    '"widgetset":{"type":"string","description":"LCL widgetset of the active build mode (win32, qt5, qt6, gtk2, gtk3, cocoa, ...); \"default\" or empty string = the platform''s default. Packages using the LCL are rebuilt for it at the next build"}}}';

  SCHEMA_ADD_FILE_TO_PROJECT =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path to the existing .pas (or other source) file to add"}},' +
    '"required":["file"]}';

  SCHEMA_REMOVE_FILE_FROM_PROJECT =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path to the file to remove from the project (file is NOT deleted from disk)"}},' +
    '"required":["file"]}';

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
    '"file":{"type":"string","description":"Absolute path of the project''s .lpi, or of a program''s .lpr: without an .lpi next to it one is written (debug info on; LCL required when it uses Forms or Interfaces)"},' +
    '"unit_paths":{"type":"string","description":"Only when an .lpi is written from an .lpr: other unit search paths, '';''-separated, relative to the .lpr"}},' +
    '"required":["file"]}';

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

{ ── Widgetset ────────────────────────────────────────────────────────────── }

{ A project chooses its widgetset per build mode with an IDE-macro option
  LCLWidgetType:=<ws> in its build-mode matrix, as Project Options >
  Compiler Options > Additions and Overrides > Set "LCLWidgetType" adds it.
  Session options (.lps) are applied after the shared ones (.lpi). }

type
  TMatrixLists = array[0..1] of TBuildMatrixOptions;

function MatrixLists(Proj: TProject): TMatrixLists;
begin
  Result[0] := Proj.BuildModes.SharedMatrixOptions;
  Result[1] := Proj.BuildModes.SessionMatrixOptions;
end;

{ M without its option at AIndex.  Not M.Delete: an option's destructor
  removes it from the list, which owns it and frees it a second time
  (an access violation, Lazarus 4.6).  Assign rebuilds the list, as the
  Project Options dialog does. }
procedure DeleteMatrixOption(M: TBuildMatrixOptions; AIndex: Integer);
var
  Rest : TBuildMatrixOptions;
  I    : Integer;
begin
  Rest := TBuildMatrixOptions.Create;
  try
    for I := 0 to M.Count - 1 do
      if I <> AIndex then
        TBuildMatrixOption.Create(Rest).Assign(M[I]);
    M.Assign(Rest);
  finally
    Rest.Free;
  end;
end;

function IsWidgetsetOption(Opt: TBuildMatrixOption; const ModeId: string): Boolean;
begin
  Result := (Opt.Typ = bmotIDEMacro) and SameText(Opt.MacroName, 'LCLWidgetType') and
            Opt.FitsMode(ModeId);
end;

{ The active build mode's own widgetset, '' for the platform's default. }
function WidgetsetOverride(Proj: TProject): string;
var
  M   : TBuildMatrixOptions;
  I   : Integer;
  Mode: string;
begin
  Result := '';
  Mode := Proj.ActiveBuildMode.Identifier;
  for M in MatrixLists(Proj) do
    for I := 0 to M.Count - 1 do
      if IsWidgetsetOption(M[I], Mode) then
        Result := M[I].Value;
end;

{ The widgetset the next build uses. }
function EffectiveWidgetset: string;
begin
  Result := '$(LCLWidgetType)';
  if not Assigned(IDEMacros) or not IDEMacros.SubstituteMacros(Result) then
    Result := '';
end;

{ Sets the active build mode's widgetset, '' or 'default' to drop it.  Other
  build modes keep theirs.  Returns '' or why not. }
function SetWidgetset(Proj: TProject; AValue: string): string;
var
  P    : TLCLPlatform;
  M    : TBuildMatrixOptions;
  Opt  : TBuildMatrixOption;
  SL   : TStringList;
  I, J : Integer;
  Mode : string;
  Known: string;
  Found: Boolean;
begin
  Result := '';
  AValue := LowerCase(Trim(AValue));
  if AValue = 'default' then AValue := '';
  if AValue <> '' then
  begin
    Known := '';
    Found := False;
    for P := Low(TLCLPlatform) to High(TLCLPlatform) do
    begin
      Found := Found or (LCLPlatformDirNames[P] = AValue);
      Known := Known + IfThen(Known <> '', ', ') + LCLPlatformDirNames[P];
    end;
    if not Found then
      Exit('Unknown widgetset "' + AValue + '"; one of: ' + Known + ', or "default"');
  end;
  Mode := Proj.ActiveBuildMode.Identifier;
  { take this mode out of every option that sets it }
  SL := TStringList.Create;
  try
    for M in MatrixLists(Proj) do
      for I := M.Count - 1 downto 0 do
        if IsWidgetsetOption(M[I], Mode) then
        begin
          SL.Text := M[I].Modes;
          for J := SL.Count - 1 downto 0 do
            if SameText(Trim(SL[J]), Mode) then SL.Delete(J);
          if SL.Count = 0 then
            DeleteMatrixOption(M, I)
          else
            M[I].Modes := TrimRight(SL.Text);
        end;
  finally
    SL.Free;
  end;
  if AValue <> '' then
  begin
    Opt := Proj.BuildModes.SharedMatrixOptions.Add(bmotIDEMacro, '*');
    Opt.MacroName := 'LCLWidgetType';
    Opt.Value     := AValue;
    Opt.Modes     := Mode;
  end;
  Proj.Modified := True;
  IncreaseBuildMacroChangeStamp;
  LazarusIDE.PrepareBuildTarget(True);
end;

{ debug_info of project_get/set_settings: none, or the -g format }
function DebugInfoName(AOpts: TLazCompilerOptions): string;
begin
  if not AOpts.GenerateDebugInfo then Exit('none');
  case AOpts.DebugInfoType of
    dsStabs     : Result := 'stabs';
    dsDwarf2    : Result := 'dwarf2';
    dsDwarf2Set : Result := 'dwarf2set';
    dsDwarf3    : Result := 'dwarf3';
  else            Result := 'auto';
  end;
end;

function ParseDebugInfo(const S: string; out AGen: Boolean;
  out AType: TCompilerDbgSymbolType): Boolean;
begin
  Result := True;
  AGen   := True;
  AType  := dsAuto;
  case LowerCase(Trim(S)) of
    'none'      : AGen := False;
    'auto'      : AType := dsAuto;
    'stabs'     : AType := dsStabs;
    'dwarf2'    : AType := dsDwarf2;
    'dwarf2set' : AType := dsDwarf2Set;
    'dwarf3'    : AType := dsDwarf3;
  else
    Result := False;
  end;
end;

const
  MacroNames : array[0..3] of string = ('CompPath', 'FPCVer', 'TargetOS', 'TargetCPU');
  MacroKeys  : array[0..3] of string =
    ('compiler', 'fpc_version', 'default_target_os', 'default_target_cpu');

function XmlAttr(const S: string): string;
begin
  Result := StringReplace(StringReplace(StringReplace(StringReplace(S,
    '&', '&amp;', [rfReplaceAll]), '<', '&lt;', [rfReplaceAll]),
    '>', '&gt;', [rfReplaceAll]), '"', '&quot;', [rfReplaceAll]);
end;

{ The .lpi the IDE's "create project for program" would write next to a
  program's .lpr (its own function needs a dialog and lives in the IDE
  executable, out of reach of a package).  Debug info on (DWARF 3), as
  project_create gives; LCL is required when the program uses Forms or
  Interfaces.  AUnitPaths: ';'-separated, relative to the .lpr. }
function WriteProgramProject(const ALpr, AUnitPaths: string): string;
var
  Src    : TStringList;
  Name   : string;
  Text   : string;
  NeedLcl: Boolean;
begin
  Result := ChangeFileExt(ALpr, '.lpi');
  Name   := ExtractFileNameOnly(ALpr);
  Src := TStringList.Create;
  try
    Src.LoadFromFile(ALpr);
    Text := LowerCase(Src.Text);
  finally
    Src.Free;
  end;
  NeedLcl := (Pos('interfaces', Text) > 0) or (Pos(' forms', Text) > 0) or
             (Pos(',forms', Text) > 0) or (Pos(', forms', Text) > 0);
  Text :=
    '<?xml version="1.0" encoding="UTF-8"?>' + LineEnding +
    '<CONFIG>' + LineEnding +
    '  <ProjectOptions>' + LineEnding +
    '    <Version Value="12"/>' + LineEnding +
    '    <General>' + LineEnding +
    '      <Flags>' + LineEnding +
    '        <MainUnitHasCreateFormStatements Value="False"/>' + LineEnding +
    '        <MainUnitHasTitleStatement Value="False"/>' + LineEnding +
    '        <MainUnitHasScaledStatement Value="False"/>' + LineEnding +
    '      </Flags>' + LineEnding +
    '      <SessionStorage Value="InIDEConfig"/>' + LineEnding +
    '      <Title Value="' + Name + '"/>' + LineEnding +
    '      <UseAppBundle Value="False"/>' + LineEnding +
    '    </General>' + LineEnding +
    '    <BuildModes>' + LineEnding +
    '      <Item Name="Default" Default="True"/>' + LineEnding +
    '    </BuildModes>' + LineEnding +
    '    <PublishOptions>' + LineEnding +
    '      <Version Value="2"/>' + LineEnding +
    '    </PublishOptions>' + LineEnding +
    '    <RunParams>' + LineEnding +
    '      <FormatVersion Value="2"/>' + LineEnding +
    '    </RunParams>' + LineEnding;
  if NeedLcl then
    Text := Text +
      '    <RequiredPackages>' + LineEnding +
      '      <Item>' + LineEnding +
      '        <PackageName Value="LCL"/>' + LineEnding +
      '      </Item>' + LineEnding +
      '    </RequiredPackages>' + LineEnding;
  Text := Text +
    '    <Units>' + LineEnding +
    '      <Unit>' + LineEnding +
    '        <Filename Value="' + ExtractFileName(ALpr) + '"/>' + LineEnding +
    '        <IsPartOfProject Value="True"/>' + LineEnding +
    '      </Unit>' + LineEnding +
    '    </Units>' + LineEnding +
    '  </ProjectOptions>' + LineEnding +
    '  <CompilerOptions>' + LineEnding +
    '    <Version Value="11"/>' + LineEnding +
    '    <Target>' + LineEnding +
    '      <Filename Value="' + Name + '"/>' + LineEnding +
    '    </Target>' + LineEnding +
    '    <SearchPaths>' + LineEnding;
  if AUnitPaths <> '' then
    Text := Text +
      '      <OtherUnitFiles Value="' + XmlAttr(AUnitPaths) + '"/>' + LineEnding;
  Text := Text +
    '      <UnitOutputDirectory Value="lib/$(TargetCPU)-$(TargetOS)"/>' + LineEnding +
    '    </SearchPaths>' + LineEnding +
    '    <Linking>' + LineEnding +
    '      <Debugging>' + LineEnding +
    '        <DebugInfoType Value="dsDwarf3"/>' + LineEnding +
    '      </Debugging>' + LineEnding +
    '    </Linking>' + LineEnding +
    '  </CompilerOptions>' + LineEnding +
    '</CONFIG>' + LineEnding;
  Src := TStringList.Create;
  try
    Src.Text := Text;
    Src.SaveToFile(Result);
  finally
    Src.Free;
  end;
end;

{ ── Dispatch ─────────────────────────────────────────────────────────────── }

function DispatchProjectTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  Obj        : TJSONObject;
  Arr        : TJSONArray;
  DescObj    : TJSONObject;
  Proj       : TLazProject;
  PF         : TLazProjectFile;
  AlreadyIn  : Boolean;
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
  MacroIdx   : Integer;
  LprPath    : string;
  CreatedLpi : Boolean;
  MacroText  : string;
  DbgGen     : Boolean;
  DbgType    : TCompilerDbgSymbolType;
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
      FilePath := Ctx.Params.Get('file', '');
    if FilePath = '' then
    begin
      Ctx.Error := True; Ctx.Result := 'file required'; Exit;
    end;
    FilePath := CleanAndExpandFilename(FilePath);
    LprPath := '';
    if SameText(ExtractFileExt(FilePath), '.lpr') then
    begin
      { a program without a project: the .lpi is written next to it, as the
        IDE does when it is asked to open one }
      if not FileExists(FilePath) then
      begin
        Ctx.Error := True; Ctx.Result := 'File not found: ' + FilePath; Exit;
      end;
      LprPath  := FilePath;
      FilePath := ChangeFileExt(LprPath, '.lpi');
    end
    else if not SameText(ExtractFileExt(FilePath), '.lpi') then
    begin
      Ctx.Error := True;
      Ctx.Result := 'project_open takes a project .lpi (or a program .lpr, for which it ' +
        'writes the .lpi); parameter file; got: ' + FilePath;
      Exit;
    end;
    if (LprPath = '') and not FileExists(FilePath) then
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
    CreatedLpi := False;
    if (LprPath <> '') and not FileExists(FilePath) then
    begin
      WriteProgramProject(LprPath, Ctx.Params.Get('unit_paths', ''));
      CreatedLpi := True;
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
      if CreatedLpi then Obj.Add('created_project_file', True);
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
      { and which token it came with (ADR-021) }
      if McpSessionTokenName(Ctx.ClientId) <> '' then
        Obj.Add('token', McpSessionTokenName(Ctx.ClientId));
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
      if Assigned(LazarusIDE) and Assigned(LazarusIDE.ActiveProject) and
         (LazarusIDE.ActiveProject.ProjectInfoFile <> '') then
      begin
        Obj.Add('project_open', True);
        Obj.Add('directory', ExtractFilePath(LazarusIDE.ActiveProject.ProjectInfoFile));
      end
      else if Assigned(LazarusIDE) and Assigned(LazarusIDE.ActiveProject) then
      begin
        Obj.Add('project_open', True);
        Obj.Add('error', 'The open project is not saved yet, so it has no directory; ' +
          'save it in the IDE first (File > Save All)');
      end
      else
      begin
        Obj.Add('project_open', False);
        Obj.Add('error', 'No active project; project_open a .lpi first');
      end;
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
        Obj.Add('widgetset',          EffectiveWidgetset);
        Obj.Add('widgetset_override', WidgetsetOverride(TProject(Proj)));
        if Assigned(Proj.LazCompilerOptions) then
          Obj.Add('debug_info', DebugInfoName(Proj.LazCompilerOptions));
      end
      else
        Obj.Add('error', 'No active project');
      { the compiler the IDE builds with, whether or not a project is saved }
      for MacroIdx := 0 to 3 do
      begin
        MacroText := '$(' + MacroNames[MacroIdx] + ')';
        if IDEMacros.SubstituteMacros(MacroText) then
          Obj.Add(MacroKeys[MacroIdx], MacroText);
      end;
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
    if Assigned(Ctx.Params) and (Ctx.Params.Find('debug_info') <> nil) and
       not ParseDebugInfo(Ctx.Params.Get('debug_info', ''), DbgGen, DbgType) then
    begin
      Ctx.Error := True;
      Ctx.Result := 'debug_info must be none, dwarf3, dwarf2, dwarf2set, stabs or auto';
      Exit;
    end;
    { first, so that an unknown widgetset changes nothing }
    if Assigned(Ctx.Params) and (Ctx.Params.Find('widgetset') <> nil) then
    begin
      Ctx.Result := SetWidgetset(TProject(Proj), Ctx.Params.Get('widgetset', ''));
      if Ctx.Result <> '' then
      begin
        Ctx.Error := True; Exit;
      end;
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
      if Ctx.Params.Find('debug_info') <> nil then
      begin
        Proj.LazCompilerOptions.GenerateDebugInfo := DbgGen;
        if DbgGen then Proj.LazCompilerOptions.DebugInfoType := DbgType;
      end;
    end;
    LazarusIDE.DoSaveProject([]);
    Obj := TJSONObject.Create;
    try
      Obj.Add('project_file',   Proj.ProjectInfoFile);
      Obj.Add('target_os',      Proj.LazCompilerOptions.TargetOS);
      Obj.Add('target_cpu',     Proj.LazCompilerOptions.TargetCPU);
      Obj.Add('output_dir',     Proj.LazCompilerOptions.UnitOutputDirectory);
      Obj.Add('custom_options', Proj.LazCompilerOptions.CustomOptions);
      Obj.Add('widgetset',          EffectiveWidgetset);
      Obj.Add('widgetset_override', WidgetsetOverride(TProject(Proj)));
      Obj.Add('debug_info', DebugInfoName(Proj.LazCompilerOptions));
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'project_add_file' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('file', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'file required'; Exit;
    end;
    FilePath := CleanAndExpandFilename(Ctx.Params.Get('file', ''));
    if not FileExists(FilePath) then
    begin
      Ctx.Error := True; Ctx.Result := 'File not found: ' + FilePath; Exit;
    end;
    Proj := LazarusIDE.ActiveProject;
    if not Assigned(Proj) then
    begin
      Ctx.Error := True; Ctx.Result := 'No active project'; Exit;
    end;
    { The project also lists files only open in an editor.  TProject.AddFile
      only warns about a file listed already and adds it a second time, so a
      listed one is marked as part of the project instead, as the IDE's
      "Add editor file to project" does. }
    PF := nil;
    for I := 0 to Proj.FileCount - 1 do
      if SameFileName(Proj.Files[I].Filename, FilePath) then
      begin
        PF := Proj.Files[I]; Break;
      end;
    AlreadyIn := Assigned(PF) and PF.IsPartOfProject;
    if not AlreadyIn then
    begin
      if Assigned(PF) then
        PF.IsPartOfProject := True
      else
      begin
        PF := Proj.CreateProjectFile(FilePath);
        Proj.AddFile(PF, False);
        PF.IsPartOfProject := True;   { else it is listed but not part of the project }
      end;
      LazarusIDE.DoSaveProject([]);
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('file',    FilePath);
      Obj.Add('project', Proj.ProjectInfoFile);
      if AlreadyIn then Obj.Add('already_in_project', True);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'project_remove_file' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('file', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'file required'; Exit;
    end;
    FilePath := CleanAndExpandFilename(Ctx.Params.Get('file', ''));
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
    { the list also has files only open in an editor }
    if (J < 0) or not Proj.Files[J].IsPartOfProject then
    begin
      Ctx.Error := True; Ctx.Result := 'File not in project: ' + FilePath; Exit;
    end;
    { RemoveUnit frees the file's unit info, which an open editor still uses }
    if Assigned(SourceEditorManagerIntf.SourceEditorIntfWithFilename(FilePath)) then
    begin
      Ctx.Error  := True;
      Ctx.Result := FilePath + ' is open in the editor: save or revert it, close it ' +
                    'with editor_close, then remove it.';
      Exit;
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
    'custom options, the widgetset the next build uses (widgetset_override: the ' +
    'active build mode''s own choice, "" = the default), and project file path.',
    SCHEMA_GET_PROJECT_SETTINGS, MCP_ANN_RO));
  Tools.Add(MakeTool('project_set_settings',
    'Write compiler options to the active project. All parameters are optional; ' +
    'only supplied keys are changed. Returns the new settings in the same shape ' +
    'as project_get_settings. custom_options REPLACES the existing string.',
    SCHEMA_SET_PROJECT_SETTINGS, MCP_ANN_WRITE_IDEM));
  Tools.Add(MakeTool('project_add_file',
    'Add an existing source file to the active project (.lpi). ' +
    'Saves the project afterwards.',
    SCHEMA_ADD_FILE_TO_PROJECT, MCP_ANN_WRITE_IDEM));
  Tools.Add(MakeTool('project_remove_file',
    'Remove a source file from the active project without deleting it from disk. ' +
    'Saves the project afterwards.',
    SCHEMA_REMOVE_FILE_FROM_PROJECT, MCP_ANN_WRITE_IDEM));
  Tools.Add(MakeTool('form_create',
    'Create a new form, data module or frame: a .pas unit and paired .lfm file, ' +
    'both added to the active project and opened in the editor. The IDE names ' +
    'it (Form2, DataModule1, Frame1); rename it with form_set_properties Name.',
    SCHEMA_CREATE_FORM, MCP_ANN_WRITE));
  Tools.Add(MakeTool('project_open',
    'Open a project (.lpi), closing the current one. Given a program''s .lpr ' +
    'with no .lpi, writes one next to it first (the IDE otherwise has only an unsaved ' +
    'default project open), so build, run and debug work on it. Refused while ' +
    'debugging or building, or with unsaved changes. Clears the Messages window.',
    SCHEMA_OPEN_PROJECT, MCP_ANN_WRITE_IDEM));
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
    'Behavioral instructions sent to every client as the server''s instructions. ' +
    'Describes available tools, recommended workflows, and common gotchas.',
    'text/plain',
    @GetSystemPromptText);

end.
