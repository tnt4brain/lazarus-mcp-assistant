{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolContext;

{ Shared context record and group-level dispatch/schema registry.
  Tool group units self-register via initialization blocks — McpIdeServer
  has no compile-time dependency on individual group units. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpjson, jsonparser;

type
  { Context record passed into every tool dispatch function.
    Params is a borrowed reference — do not free it. }
  TMcpStopServerProc = procedure of object;

  TMcpToolCall = record
    Params          : TJSONObject;
    Result          : string;
    Error           : Boolean;
    ConnectionClose : Boolean;      { IDE-restart tools: ide_rebuild, install/package_uninstall }
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

{ Called by SyncCallTool and HandleToolsList respectively. }
procedure McpDispatch(const Name: string; var Ctx: TMcpToolCall; out Handled: Boolean);
procedure McpRegisterSchemas(Tools: TJSONArray);

{ Blocking group registry — dispatchers run on the MCP worker thread. }
procedure RegisterMcpBlockingGroup(Fn: TMcpGroupDispatch);
procedure McpBlockingDispatch(const Name: string; var Ctx: TMcpToolCall; out Handled: Boolean);

{ MCP tool annotation presets — pass as AAnnotations to MakeTool.
  Everything works on the local IDE/project only, hence openWorldHint=false.
  RO is also used for tools that only move the editor cursor or open a tab. }
const
  MCP_ANN_RO    = '{"readOnlyHint":true,"openWorldHint":false}';
  MCP_ANN_WRITE = '{"readOnlyHint":false,"destructiveHint":false,"openWorldHint":false}';
  MCP_ANN_DEST  = '{"readOnlyHint":false,"destructiveHint":true,"openWorldHint":false}';

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

procedure McpDispatch(const Name: string; var Ctx: TMcpToolCall; out Handled: Boolean);
var
  I : Integer;
begin
  Handled := False;
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

end.
