{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolContext;

{ Shared context record and group-level dispatch/schema registry.
  Tool group units self-register via initialization blocks — McpIdeServer
  has no compile-time dependency on individual group units. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, fpjson, jsonparser;

type
  { Context record passed into every tool dispatch function.
    Params is a borrowed reference — do not free it. }
  TMcpStopServerProc = procedure of object;

  TMcpToolCall = record
    Params          : TJSONObject;
    Result          : string;
    Error           : Boolean;
    Images          : TStringArray; { base64 PNGs, sent as image content after Result }
    ClientId        : string;       { Mcp-Session-Id / cookie, or 'anonymous' (ADR-012) }
    StopServer      : TMcpStopServerProc;  { set by SyncCallTool before dispatch }
  end;

  TMcpGroupDispatch = function(const Name: string; var Ctx: TMcpToolCall): Boolean;
  TMcpSchemaReg     = procedure(Tools: TJSONArray);

  TMcpGetResourceText = function: string;

  TMcpResourceEntry = record
    Uri         : string;
    Name        : string;
    Description : string;
    MimeType    : string;
    GetText     : TMcpGetResourceText;
  end;

{ Called once per group unit from its initialization block. }
procedure RegisterMcpGroup(Fn: TMcpGroupDispatch);
procedure RegisterMcpSchemas(Fn: TMcpSchemaReg);

{ True when a tool must be refused while no project is open.  With none, the
  IDE sits in its modal Project Wizard (File > Close Project), which offers
  exactly: New project, Open project, Open recent project.  The same goes for
  tools: only project_create and project_open (which also covers "recent")
  pass, plus ide_ping, the liveness probe that the restart poll relies on and
  that never touches the IDE, and ide_report, which looks for a project itself.
  Everything else is refused, so a tool added
  later is safe by default instead of raising an access violation inside the
  IDE (TProject.GetMainFilename, PrepareForCompile, ... all dereference the
  missing project). }
function McpToolNeedsProject(const AToolName: string): Boolean;

const
  { Parameters of ide_rebuild, package_install and package_uninstall besides their own }
  MCP_REBUILD_FLAGS =
    '"save_unsaved":{"type":"boolean","description":"Save the editors and the packages that hold ' +
    'unsaved changes first. Default false: the call is refused (nothing changed) and names them, ' +
    'because the rebuild closes every editor without asking and stops on a question about an ' +
    'unsaved package. A package that was never saved, or has a file missing on disk, is never ' +
    'saved this way and still stops the call"},' +
    '"skip_compile":{"type":"boolean","description":"Do not compile the package first. Default false: ' +
    'a package that does not compile stops the call before anything is changed"}';

var
  { Set by mcpideserver: stop and start the server again (main thread).  A rebuild
    that ends without restarting the IDE uses it to bring the server back. }
  GMcpRestartServer : TProcedure = nil;

type
  TMcpWriteCheck = function(const AFileName: string; out AWhy: string): Boolean;

var
  { Set by McpToolsEditor to McpCheckWritable (this unit has no IDE dependency, so the test
    project can build it); nil allows everything. }
  GMcpWriteCheck : TMcpWriteCheck = nil;

type
  { A package by name or by .lpk path (one of them is ''): may its .lpk be changed? }
  TMcpPackageWriteCheck = function(const AName, ALpk: string; out AWhy: string): Boolean;

var
  GMcpPackageCheck : TMcpPackageWriteCheck = nil;

{ False, with AWhy, when AName is a tool that changes a file or a form outside the folders
  GMcpWriteCheck allows.  McpDispatch applies it before any tool runs. }
function McpWriteAllowed(const AName: string; AParams: TJSONObject; out AWhy: string): Boolean;

{ Called by SyncCallTool and HandleToolsList respectively. }
procedure McpDispatch(const Name: string; var Ctx: TMcpToolCall; out Handled: Boolean);
procedure McpRegisterSchemas(Tools: TJSONArray);

{ Check a tools/call's arguments against the tool's inputSchema: every name in
  "required" present, no name outside "properties".  False with a message that
  lists the accepted names.  Unknown tools pass (the dispatcher reports them). }
function McpValidateArgs(const ToolName: string; Args: TJSONObject;
  out Msg: string): Boolean;

{ The accepted name closest to AWanted (case-insensitive edit distance, at most a
  third of its length and never more than 3), '' if none is near.  For the
  "did you mean" of the unknown-parameter error. }
function McpClosestName(const AWanted: string; ANames: TStrings): string;

{ Blocking group registry — dispatchers run on the MCP worker thread. }
procedure RegisterMcpBlockingGroup(Fn: TMcpGroupDispatch);
procedure McpBlockingDispatch(const Name: string; var Ctx: TMcpToolCall; out Handled: Boolean);

{ MCP tool annotation presets — pass as AAnnotations to MakeTool.
  Everything works on the local IDE/project only, hence openWorldHint=false.
  RO is also used for tools that only move the editor cursor or open a tab.
  DEST is for changes Ctrl+Z or form_undo can't take back: deletes that
  form_undo restores are WRITE, as are deletes of editor text.
  _IDEM: a second call with the same arguments changes nothing more (it may
  report "already" or "not found"); not for relative targets such as HEAD~1. }
const
  MCP_ANN_RO         = '{"readOnlyHint":true,"openWorldHint":false}';
  MCP_ANN_WRITE      = '{"readOnlyHint":false,"destructiveHint":false,"openWorldHint":false}';
  MCP_ANN_WRITE_IDEM = '{"readOnlyHint":false,"destructiveHint":false,"idempotentHint":true,' +
                       '"openWorldHint":false}';
  MCP_ANN_DEST       = '{"readOnlyHint":false,"destructiveHint":true,"openWorldHint":false}';
  MCP_ANN_DEST_IDEM  = '{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":true,' +
                       '"openWorldHint":false}';

(* Build a tool descriptor object from a JSON string schema.
   AName and ADesc are plain Pascal strings (auto-escaped).
   InputSchemaJSON is the full inputSchema value, e.g.:
     '{"type":"object","properties":{...},"required":[...]}'
   Tool names are <category>_<action> (debug_, editor_, code_, form_,
   project_, package_, ide_, git_); MakeTool derives the human-readable title
   from that, e.g. debug_get_call_stack -> "Debugger: get call stack". *)
function MakeTool(const AName, ADesc, InputSchemaJSON: string;
  const AAnnotations: string = ''): TJSONObject;

procedure RegisterMcpResource(const AUri, AName, ADesc, AMimeType: string;
                               AGetText: TMcpGetResourceText);
procedure McpListResources(Resources: TJSONArray);
function  McpReadResource(const AUri: string; out Content: string): Boolean;

implementation

procedure SortToolsByName(Tools: TJSONArray); forward;

var
  GDispatchGroups  : array of TMcpGroupDispatch;
  GSchemaGroups    : array of TMcpSchemaReg;
  GBlockingGroups  : array of TMcpGroupDispatch;
  GResourceEntries : array of TMcpResourceEntry;

function McpToolNeedsProject(const AToolName: string): Boolean;
begin
  Result := not ((AToolName = 'project_create') or (AToolName = 'project_open') or
                 (AToolName = 'ide_ping') or (AToolName = 'ide_report'));
end;

procedure RegisterMcpGroup(Fn: TMcpGroupDispatch);
begin
  SetLength(GDispatchGroups, Length(GDispatchGroups) + 1);
  GDispatchGroups[High(GDispatchGroups)] := Fn;
end;

procedure RegisterMcpSchemas(Fn: TMcpSchemaReg);
begin
  SetLength(GSchemaGroups, Length(GSchemaGroups) + 1);
  GSchemaGroups[High(GSchemaGroups)] := Fn;
end;

const
  { Tools that change the file their `file` argument names (a dry run only reads) }
  { these change an existing package's .lpk (package_move_unit two of them) }
  PACKAGE_WRITERS : array[0..7] of string = (
    'package_add_file', 'package_remove_file', 'package_add_dependency',
    'package_remove_dependency', 'package_set_info', 'package_set_settings',
    'package_move_unit', 'package_save');

  FILE_WRITERS : array[0..8] of string = (
    'code_add_uses', 'code_add_to_class', 'code_insert_in_procedure',
    'code_replace_procedure_body', 'code_edit_statement', 'code_complete', 'code_format',
    'code_rename_identifier', 'code_extract_method');
  { Tools that change the form their `form_file` argument names }
  FORM_WRITERS : array[0..11] of string = (
    'form_set_properties', 'form_add_component', 'form_delete_component', 'form_arrange',
    'form_create_event_handler', 'form_add_collection_item', 'form_delete_collection_item',
    'form_move_collection_item', 'form_add_menu_item', 'form_move_menu_item', 'form_undo',
    'form_redo');

function PackageArgAllowed(const AArg: string; out AWhy: string): Boolean;
begin
  Result := True;
  AWhy := '';
  if (AArg = '') or not Assigned(GMcpPackageCheck) then Exit;
  if LowerCase(ExtractFileExt(AArg)) = '.lpk' then
    Result := GMcpPackageCheck('', AArg, AWhy)
  else
    Result := GMcpPackageCheck(AArg, '', AWhy);
end;

function McpWriteAllowed(const AName: string; AParams: TJSONObject; out AWhy: string): Boolean;
var
  Arg, F : string;
  I      : Integer;
begin
  Result := True;
  AWhy := '';
  if AParams = nil then Exit;
  for I := Low(PACKAGE_WRITERS) to High(PACKAGE_WRITERS) do
    if AName = PACKAGE_WRITERS[I] then
    begin
      if AParams.Get('dry_run', False) then Exit;
      if AName = 'package_move_unit' then
      begin
        Result := PackageArgAllowed(AParams.Get('from_package', ''), AWhy) and
                  PackageArgAllowed(AParams.Get('to_package', ''), AWhy);
        Exit;
      end;
      F := AParams.Get('lpk_path', '');
      if (F <> '') and Assigned(GMcpPackageCheck) then
        Result := GMcpPackageCheck('', F, AWhy)
      else if Assigned(GMcpPackageCheck) then
        Result := GMcpPackageCheck(AParams.Get('package_name', ''), '', AWhy);
      Exit;
    end;
  if AName = 'git_archive' then
  begin
    { an absolute output path; '' is left to the tool, which refuses it }
    F := AParams.Get('output', '');
    if (F <> '') and Assigned(GMcpWriteCheck) then
      Result := GMcpWriteCheck(F, AWhy);
    Exit;
  end;
  Arg := '';
  for I := Low(FILE_WRITERS) to High(FILE_WRITERS) do
    if AName = FILE_WRITERS[I] then Arg := 'file';
  for I := Low(FORM_WRITERS) to High(FORM_WRITERS) do
    if AName = FORM_WRITERS[I] then Arg := 'form_file';
  if Arg = '' then Exit;
  if AParams.Get('dry_run', False) then Exit;
  F := AParams.Get(Arg, '');                 { '' = the active editor; the hook resolves it }
  if Assigned(GMcpWriteCheck) then
    Result := GMcpWriteCheck(F, AWhy);
end;

procedure McpDispatch(const Name: string; var Ctx: TMcpToolCall; out Handled: Boolean);
var
  I   : Integer;
  Why : string;
begin
  Handled := False;
  if not McpWriteAllowed(Name, Ctx.Params, Why) then
  begin
    Ctx.Error := True;
    Ctx.Result := Why;
    Handled := True;
    Exit;
  end;
  for I := 0 to High(GDispatchGroups) do
    if GDispatchGroups[I](Name, Ctx) then
    begin
      Handled := True;
      Exit;
    end;
end;

procedure McpRegisterSchemas(Tools: TJSONArray);
var
  I : Integer;
begin
  for I := 0 to High(GSchemaGroups) do
    GSchemaGroups[I](Tools);
  SortToolsByName(Tools);
end;

procedure RegisterMcpBlockingGroup(Fn: TMcpGroupDispatch);
begin
  SetLength(GBlockingGroups, Length(GBlockingGroups) + 1);
  GBlockingGroups[High(GBlockingGroups)] := Fn;
end;

procedure McpBlockingDispatch(const Name: string; var Ctx: TMcpToolCall; out Handled: Boolean);
var
  I : Integer;
begin
  Handled := False;
  for I := 0 to High(GBlockingGroups) do
    if GBlockingGroups[I](Name, Ctx) then
    begin
      Handled := True;
      Exit;
    end;
end;

var
  GSchemaLock  : TCriticalSection;
  GSchemaCache : TJSONArray;

function EditDistance(const A, B: string): Integer;
var
  Prev, Cur : array of Integer;
  I, J, Cost : Integer;
begin
  SetLength(Prev, Length(B) + 1);
  SetLength(Cur, Length(B) + 1);
  for J := 0 to Length(B) do Prev[J] := J;
  for I := 1 to Length(A) do
  begin
    Cur[0] := I;
    for J := 1 to Length(B) do
    begin
      if A[I] = B[J] then Cost := 0 else Cost := 1;
      Cur[J] := Prev[J] + 1;
      if Cur[J - 1] + 1 < Cur[J] then Cur[J] := Cur[J - 1] + 1;
      if Prev[J - 1] + Cost < Cur[J] then Cur[J] := Prev[J - 1] + Cost;
    end;
    Prev := Copy(Cur);
  end;
  Result := Prev[Length(B)];
end;

function McpClosestName(const AWanted: string; ANames: TStrings): string;
var
  D, Best, Limit : Integer;
  W, N, Cand : string;
begin
  Result := '';
  W := LowerCase(AWanted);
  Limit := Length(W) div 3;
  if Limit > 3 then Limit := 3;
  if Limit < 1 then Limit := 1;
  Best := MaxInt;
  for Cand in ANames do
  begin
    N := LowerCase(Cand);
    D := EditDistance(W, N);
    { "file" for "form_file", "max_results" for "results": one name inside the other }
    if (D > Limit) and (Length(W) >= 4) and (Length(N) >= 4) and
       ((Pos(W, N) > 0) or (Pos(N, W) > 0)) then
      D := Limit;
    if (D <= Limit) and (D < Best) then
    begin
      Best := D;
      Result := Cand;
    end;
  end;
end;

function McpValidateArgs(const ToolName: string; Args: TJSONObject;
  out Msg: string): Boolean;
var
  I, J     : Integer;
  En       : TJSONEnum;
  Names    : TStringList;
  Hint     : string;
  Schema   : TJSONObject;
  Props    : TJSONObject;
  Req      : TJSONArray;
  Missing  : string;
  Unknown  : string;
  Accepted : string;
begin
  Result := True;
  Msg := '';
  GSchemaLock.Enter;
  try
    if GSchemaCache = nil then
    begin
      GSchemaCache := TJSONArray.Create;
      for I := 0 to High(GSchemaGroups) do
        GSchemaGroups[I](GSchemaCache);
    end;
    Schema := nil;
    for En in GSchemaCache do
      if TJSONObject(En.Value).Get('name', '') = ToolName then
      begin
        Schema := TJSONObject(En.Value).Find('inputSchema') as TJSONObject;
        Break;
      end;
    if Schema = nil then Exit;
    Props := Schema.Find('properties') as TJSONObject;
    Req   := Schema.Find('required') as TJSONArray;
    Missing := '';
    if Assigned(Req) then
      for En in Req do
        if (Args = nil) or (Args.IndexOfName(En.Value.AsString) < 0) then
        begin
          if Missing <> '' then Missing := Missing + ', ';
          Missing := Missing + En.Value.AsString;
        end;
    Unknown := '';
    Names := TStringList.Create;
    try
      if Assigned(Props) then
        for En in Props do
          Names.Add(En.Key);
      if Assigned(Args) then
        for En in Args do
          if (Props = nil) or (Props.IndexOfName(En.Key) < 0) then
          begin
            if Unknown <> '' then Unknown := Unknown + ', ';
            Unknown := Unknown + En.Key;
            Hint := McpClosestName(En.Key, Names);
            if Hint <> '' then
              Unknown := Unknown + ' (did you mean ' + Hint + '?)';
          end;
    finally
      Names.Free;
    end;
    if (Missing = '') and (Unknown = '') then Exit;
    Accepted := '';
    if Assigned(Props) then
      for J := 0 to Props.Count - 1 do
      begin
        if Accepted <> '' then Accepted := Accepted + ', ';
        Accepted := Accepted + Props.Names[J];
        if Assigned(Req) then
          for En in Req do
            if En.Value.AsString = Props.Names[J] then
              Accepted := Accepted + ' (required)';
      end;
    if Accepted = '' then Accepted := 'none';
    Result := False;
    if Missing <> '' then Msg := 'Missing required parameter(s): ' + Missing + '. ';
    if Unknown <> '' then Msg := Msg + 'Unknown parameter(s): ' + Unknown + '. ';
    Msg := Msg + 'Accepted by ' + ToolName + ': ' + Accepted + '.';
  finally
    GSchemaLock.Leave;
  end;
end;

function ToolTitle(const AName: string): string;
const
  Prefixes : array[0..7] of string =
    ('debug_', 'editor_', 'code_', 'form_', 'project_', 'package_', 'ide_', 'git_');
  Categories : array[0..7] of string =
    ('Debugger', 'Editor', 'CodeTools', 'Form designer', 'Project', 'Packages', 'IDE', 'Git');
var
  I    : Integer;
  Rest : string;
begin
  Result := StringReplace(AName, '_', ' ', [rfReplaceAll]);
  for I := Low(Prefixes) to High(Prefixes) do
    if Copy(AName, 1, Length(Prefixes[I])) = Prefixes[I] then
    begin
      Rest := Copy(AName, Length(Prefixes[I]) + 1, MaxInt);
      if Prefixes[I] = 'git_' then Rest := 'git ' + Rest;  { "Git: git stash pop" }
      Result := Categories[I] + ': ' + StringReplace(Rest, '_', ' ', [rfReplaceAll]);
      Exit;
    end;
end;

function MakeTool(const AName, ADesc, InputSchemaJSON: string;
  const AAnnotations: string = ''): TJSONObject;
var
  Schema : TJSONData;
  Ann    : TJSONObject;
  Title  : string;
begin
  Title  := ToolTitle(AName);
  Schema := GetJSON(InputSchemaJSON);
  Result := TJSONObject.Create;
  Result.Add('name',        AName);
  Result.Add('title',       Title);   { MCP 2025-06-18 }
  Result.Add('description', ADesc);
  Result.Add('inputSchema', Schema);
  if AAnnotations <> '' then
    Ann := TJSONObject(GetJSON(AAnnotations))
  else
    Ann := TJSONObject.Create;
  Ann.Add('title', Title);            { older clients read it here }
  Result.Add('annotations', Ann);
end;

{ Sort the tool list by name so each category's tools are adjacent. }
procedure SortToolsByName(Tools: TJSONArray);
var
  I, J : Integer;
  A, B : TJSONObject;
begin
  for I := 1 to Tools.Count - 1 do
  begin
    J := I;
    while (J > 0) and
          (TJSONObject(Tools[J - 1]).Get('name', '') > TJSONObject(Tools[J]).Get('name', '')) do
    begin
      A := TJSONObject(Tools.Extract(J - 1));  { shifts J to J-1 }
      B := TJSONObject(Tools.Extract(J - 1));
      Tools.Insert(J - 1, A);
      Tools.Insert(J - 1, B);
      Dec(J);
    end;
  end;
end;

procedure RegisterMcpResource(const AUri, AName, ADesc, AMimeType: string;
                               AGetText: TMcpGetResourceText);
var
  E : TMcpResourceEntry;
begin
  E.Uri         := AUri;
  E.Name        := AName;
  E.Description := ADesc;
  E.MimeType    := AMimeType;
  E.GetText     := AGetText;
  SetLength(GResourceEntries, Length(GResourceEntries) + 1);
  GResourceEntries[High(GResourceEntries)] := E;
end;

procedure McpListResources(Resources: TJSONArray);
var
  I   : Integer;
  Obj : TJSONObject;
begin
  for I := 0 to High(GResourceEntries) do
  begin
    Obj := TJSONObject.Create;
    Obj.Add('uri',         GResourceEntries[I].Uri);
    Obj.Add('name',        GResourceEntries[I].Name);
    Obj.Add('description', GResourceEntries[I].Description);
    Obj.Add('mimeType',    GResourceEntries[I].MimeType);
    Resources.Add(Obj);
  end;
end;

function McpReadResource(const AUri: string; out Content: string): Boolean;
var
  I : Integer;
begin
  Result := False;
  for I := 0 to High(GResourceEntries) do
    if GResourceEntries[I].Uri = AUri then
    begin
      Content := GResourceEntries[I].GetText();
      Result  := True;
      Exit;
    end;
end;

initialization
  GSchemaLock := TCriticalSection.Create;

finalization
  GSchemaCache.Free;
  GSchemaLock.Free;

end.
