{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolContext;

{ Shared context record and group-level dispatch/schema registry.
  Tool group units self-register via initialization blocks — McpIdeServer
  has no compile-time dependency on individual group units. }

{$mode objfpc}{$H+}

interface

uses
  fpjson, jsonparser;

type
  { Context record passed into every tool dispatch function.
    Params is a borrowed reference — do not free it. }
  TMcpStopServerProc = procedure of object;

  TMcpToolCall = record
    Params          : TJSONObject;
    Result          : string;
    Error           : Boolean;
    ConnectionClose : Boolean;      { IDE-restart tools: rebuild_ide, install/uninstall_package }
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

{ MCP tool annotation presets — pass as AAnnotations to MakeTool. }
const
  MCP_ANN_RO    = '{"readOnlyHint":true}';
  MCP_ANN_WRITE = '{"destructiveHint":false}';
  MCP_ANN_DEST  = '{"destructiveHint":true}';

(* Build a tool descriptor object from a JSON string schema.
   AName and ADesc are plain Pascal strings (auto-escaped).
   InputSchemaJSON is the full inputSchema value, e.g.:
     '{"type":"object","properties":{...},"required":[...]}' *)
function MakeTool(const AName, ADesc, InputSchemaJSON: string;
  const AAnnotations: string = ''): TJSONObject;

procedure RegisterMcpResource(const AUri, AName, ADesc, AMimeType: string;
                               AGetText: TMcpGetResourceText);
procedure McpListResources(Resources: TJSONArray);
function  McpReadResource(const AUri: string; out Content: string): Boolean;

implementation

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

function MakeTool(const AName, ADesc, InputSchemaJSON: string;
  const AAnnotations: string = ''): TJSONObject;
var
  Schema : TJSONData;
begin
  Schema := GetJSON(InputSchemaJSON);
  Result := TJSONObject.Create;
  Result.Add('name',        AName);
  Result.Add('description', ADesc);
  Result.Add('inputSchema', Schema);
  if AAnnotations <> '' then
    Result.Add('annotations', GetJSON(AAnnotations));
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
