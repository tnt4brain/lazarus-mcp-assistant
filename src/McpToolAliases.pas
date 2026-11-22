{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolAliases;

{ Old tool and parameter names that still work (ADR-031).

  One table.  McpTranslateCall rewrites a tools/call request in place, before anything looks at
  the name or the arguments, so the guards, the argument check and the tools only ever see
  current names:

    parameter  tool (or "prefix*") + old name  ->  new name
    tool       old tool                        ->  new tool, with one fixed argument

  Old names work through the whole of 1.x and are refused from 2.0 on (the entries then become
  retirements).  Each old name is announced once per session; every use is counted.

  RTL and fpjson only, so the test program links it. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson;

type
  TMcpAliasKind = (akParam, akTool);

  TMcpAlias = record
    Kind     : TMcpAliasKind;
    Tool     : string;   { akParam: the tool, or "prefix*"; akTool: the old tool }
    Old      : string;   { akParam: the old parameter; akTool: ''. }
    New      : string;   { akParam: the new parameter; akTool: the new tool }
    FixedKey : string;   { akTool: the argument the new tool is given, with }
    FixedVal : string;   {   this string value ('bool:true' = the boolean true); '' = none }
  end;

{ Rewrites AParams (the "params" of a tools/call: name, arguments) in place.  ANotice is the
  sentence to tell the client when this session has not been told about this old name yet, or
  ''.  AError is '' unless the call cannot be translated (old and new given with different
  values); the request is then left as it was. }
procedure McpTranslateCall(AParams: TJSONObject; const ASession: string;
  out ANotice, AError: string);

{ For tests and the report: the table, and how often each old name was used since the start. }
function McpAliasCount: Integer;
function McpAliasAt(AIndex: Integer): TMcpAlias;
procedure McpAliasUsage(AInto: TStrings);   { 'old name=count' }
procedure McpAliasForgetSessions;           { tests: tell everything again }

implementation

const
  ALIASES : array[0..34] of TMcpAlias = (
    { one name for each idea (1.7.0): seconds to wait, text for stdin, the variable }
    (Kind: akParam; Tool: 'project_run';        Old: 'wait_seconds'; New: 'timeout_s'; FixedKey: ''; FixedVal: ''),
    (Kind: akParam; Tool: 'project_run_output'; Old: 'wait_seconds'; New: 'timeout_s'; FixedKey: ''; FixedVal: ''),
    (Kind: akParam; Tool: 'project_run_input';  Old: 'wait_seconds'; New: 'timeout_s'; FixedKey: ''; FixedVal: ''),
    (Kind: akParam; Tool: 'project_run_input';  Old: 'text'; New: 'stdin'; FixedKey: ''; FixedVal: ''),
    (Kind: akParam; Tool: 'debug_set_variable'; Old: 'name'; New: 'variable_name'; FixedKey: ''; FixedVal: ''),
    { every form tool took its file as form_file; "file" like all the others (1.7.0) }
    (Kind: akParam; Tool: 'form_*'; Old: 'form_file'; New: 'file'; FixedKey: ''; FixedVal: ''),
    { the cursor and the selection are views of the active editor (1.7.0) }
    (Kind: akTool; Tool: 'editor_get_cursor';    Old: ''; New: 'editor_get_active'; FixedKey: 'what'; FixedVal: 'cursor'),
    (Kind: akTool; Tool: 'editor_get_selection'; Old: ''; New: 'editor_get_active'; FixedKey: 'what'; FixedVal: 'selection'),
    { jumping to a declaration is a flag of the lookup (1.7.0) }
    (Kind: akTool; Tool: 'code_goto_declaration'; Old: ''; New: 'code_find_declaration'; FixedKey: 'show'; FixedVal: 'bool:true'),
    (Kind: akTool; Tool: 'git_stash_pop'; Old: ''; New: 'git_stash'; FixedKey: 'action'; FixedVal: 'pop'),
    { undo and redo of the designer became one tool (1.7.0) }
    (Kind: akTool; Tool: 'form_undo'; Old: ''; New: 'form_history'; FixedKey: 'action'; FixedVal: 'undo'),
    (Kind: akTool; Tool: 'form_redo'; Old: ''; New: 'form_history'; FixedKey: 'action'; FixedVal: 'redo'),
    { three step tools became one (1.7.0) }
    (Kind: akTool; Tool: 'debug_step_over'; Old: ''; New: 'debug_step'; FixedKey: 'kind'; FixedVal: 'over'),
    (Kind: akTool; Tool: 'debug_step_into'; Old: ''; New: 'debug_step'; FixedKey: 'kind'; FixedVal: 'into'),
    (Kind: akTool; Tool: 'debug_step_out';  Old: ''; New: 'debug_step'; FixedKey: 'kind'; FixedVal: 'out'),
    { the file argument was file_path, path or filename in some tools; "file" since v1.0 }
    (Kind: akParam; Tool: 'debug_set_breakpoint';    Old: 'file_path'; New: 'file'; FixedKey: ''; FixedVal: ''),
    (Kind: akParam; Tool: 'debug_remove_breakpoint'; Old: 'file_path'; New: 'file'; FixedKey: ''; FixedVal: ''),
    (Kind: akParam; Tool: 'debug_run_to_line';       Old: 'file_path'; New: 'file'; FixedKey: ''; FixedVal: ''),
    (Kind: akParam; Tool: 'editor_open';             Old: 'file_path'; New: 'file'; FixedKey: ''; FixedVal: ''),
    (Kind: akParam; Tool: 'project_add_file';        Old: 'file_path'; New: 'file'; FixedKey: ''; FixedVal: ''),
    (Kind: akParam; Tool: 'project_remove_file';     Old: 'file_path'; New: 'file'; FixedKey: ''; FixedVal: ''),
    (Kind: akParam; Tool: 'project_open';            Old: 'file_path'; New: 'file'; FixedKey: ''; FixedVal: ''),
    (Kind: akParam; Tool: 'editor_read_file';        Old: 'path';      New: 'file'; FixedKey: ''; FixedVal: ''),
    (Kind: akParam; Tool: 'project_create_unit';     Old: 'filename';  New: 'file'; FixedKey: ''; FixedVal: ''),
    { 1.8.1: one name for the same idea }
    (Kind: akParam; Tool: 'editor_edit_text';        Old: 'old_string'; New: 'old_text'; FixedKey: ''; FixedVal: ''),
    (Kind: akParam; Tool: 'editor_edit_text';        Old: 'new_string'; New: 'new_text'; FixedKey: ''; FixedVal: ''),
    (Kind: akParam; Tool: 'git_log';                 Old: 'max_count';  New: 'limit'; FixedKey: ''; FixedVal: ''),
    (Kind: akParam; Tool: 'package_search_online';   Old: 'max_results'; New: 'limit'; FixedKey: ''; FixedVal: ''),
    (Kind: akParam; Tool: 'code_find_descendants';   Old: 'max_results'; New: 'limit'; FixedKey: ''; FixedVal: ''),
    (Kind: akParam; Tool: 'code_find_overrides';     Old: 'max_results'; New: 'limit'; FixedKey: ''; FixedVal: ''),
    (Kind: akParam; Tool: 'debug_set_breakpoint';    Old: 'data';       New: 'watch_expression'; FixedKey: ''; FixedVal: ''),
    (Kind: akParam; Tool: 'git_cherry_pick';         Old: 'commit';     New: 'ref'; FixedKey: ''; FixedVal: ''),
    (Kind: akParam; Tool: 'git_tag';                 Old: 'commit';     New: 'ref'; FixedKey: ''; FixedVal: ''),
    (Kind: akParam; Tool: 'git_log';                 Old: 'branch';     New: 'ref'; FixedKey: ''; FixedVal: ''),
    (Kind: akParam; Tool: 'git_push';                Old: 'tags';       New: 'tag_names'; FixedKey: ''; FixedVal: ''));

var
  GLock     : TRTLCriticalSection;
  GTold     : TStringList;   { 'session|old name' already announced }
  GUsage    : TStringList;   { old name=count }

function McpAliasCount: Integer;
begin
  Result := Length(ALIASES);
end;

function McpAliasAt(AIndex: Integer): TMcpAlias;
begin
  Result := ALIASES[AIndex];
end;

function ToolMatches(const APattern, ATool: string): Boolean;
begin
  if (APattern <> '') and (APattern[Length(APattern)] = '*') then
    Result := Copy(ATool, 1, Length(APattern) - 1) = Copy(APattern, 1, Length(APattern) - 1)
  else
    Result := APattern = ATool;
end;

procedure Count(const AOld: string);
var
  I : Integer;
begin
  I := GUsage.IndexOfName(AOld);
  if I < 0 then GUsage.Add(AOld + '=1')
  else GUsage.ValueFromIndex[I] := IntToStr(StrToIntDef(GUsage.ValueFromIndex[I], 0) + 1);
end;

{ True the first time this session meets this old name }
function FirstTime(const ASession, AOld: string): Boolean;
var
  Key : string;
begin
  Key := ASession + '|' + AOld;
  EnterCriticalSection(GLock);
  try
    Count(AOld);
    Result := GTold.IndexOf(Key) < 0;
    if Result then
    begin
      if GTold.Count >= 4096 then GTold.Clear;   { sessions come and go; this is only a courtesy }
      GTold.Add(Key);
    end;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

{ a fixed value as the client writes it }
function FixedText(const AFixed: string): string;
begin
  if AFixed = 'bool:true' then Result := 'true' else Result := '"' + AFixed + '"';
end;

{ does the caller's value say what the old tool's fixed value says }
function FixedMatches(AData: TJSONData; const AFixed: string): Boolean;
begin
  if AFixed = 'bool:true' then
    Result := (AData.JSONType = jtBoolean) and AData.AsBoolean
  else
    Result := (AData.JSONType = jtString) and (AData.AsString = AFixed);
end;

procedure McpTranslateCall(AParams: TJSONObject; const ASession: string;
  out ANotice, AError: string);
var
  Name, Note : string;
  Args       : TJSONObject;
  I          : Integer;
  A          : TMcpAlias;
  OldIdx     : Integer;
  Pending    : string;   { notices collected during one call }

  procedure Tell(const AOld, AText: string);
  begin
    if FirstTime(ASession, AOld) then
    begin
      if Pending <> '' then Pending := Pending + ' ';
      Pending := Pending + AText;
    end;
  end;

begin
  ANotice := '';
  AError  := '';
  Pending := '';
  if not Assigned(AParams) then Exit;
  Name := AParams.Get('name', '');
  if Name = '' then Exit;
  Args := nil;
  if AParams.Find('arguments', jtObject) <> nil then
    Args := TJSONObject(AParams.Find('arguments', jtObject));

  { 1. an old tool: its new name, and the one argument that says which of the merged tools it was }
  for I := 0 to McpAliasCount - 1 do
  begin
    A := McpAliasAt(I);
    if (A.Kind <> akTool) or (A.Tool <> Name) then Continue;
    if (A.FixedKey <> '') and Assigned(Args) then
    begin
      OldIdx := Args.IndexOfName(A.FixedKey);
      if (OldIdx >= 0) and not FixedMatches(Args.Items[OldIdx], A.FixedVal) then
      begin
        AError := Format('"%s" is "%s" with %s=%s; do not pass %s (or call "%s" yourself).',
          [A.Tool, A.New, A.FixedKey, FixedText(A.FixedVal), A.FixedKey, A.New]);
        Exit;
      end;
    end;
    if A.FixedKey <> '' then
    begin
      if Args = nil then
      begin
        Args := TJSONObject.Create;
        AParams.Add('arguments', Args);
      end;
      if Args.IndexOfName(A.FixedKey) < 0 then
      begin
        if A.FixedVal = 'bool:true' then Args.Add(A.FixedKey, True)
        else Args.Add(A.FixedKey, A.FixedVal);
      end;
    end;
    Note := Format('deprecated: tool "%s" is now "%s"', [A.Tool, A.New]);
    if A.FixedKey <> '' then Note := Note + Format(' with %s=%s', [A.FixedKey, FixedText(A.FixedVal)]);
    Tell(A.Tool, Note + '; the old name works through 1.x and is refused from 2.0.');
    AParams.Strings['name'] := A.New;
    Name := A.New;
    Break;
  end;

  { 2. old parameter names of that tool }
  if Args <> nil then
    for I := 0 to McpAliasCount - 1 do
    begin
      A := McpAliasAt(I);
      if (A.Kind <> akParam) or not ToolMatches(A.Tool, Name) then Continue;
      OldIdx := Args.IndexOfName(A.Old);
      if OldIdx < 0 then Continue;
      if Args.IndexOfName(A.New) >= 0 then
      begin
        if Args.Items[OldIdx].AsJSON <> Args.Find(A.New).AsJSON then
        begin
          AError := Format('"%s" and "%s" are the same parameter (old and new name) and differ; ' +
                           'pass only "%s".', [A.Old, A.New, A.New]);
          Exit;
        end;
        Args.Delete(OldIdx);
      end else
      begin
        Args.Add(A.New, Args.Items[OldIdx].Clone);
        Args.Delete(OldIdx);
      end;
      Tell(Name + '.' + A.Old,
        Format('deprecated: parameter "%s" of "%s" is now "%s"; the old name works through 1.x and is refused from 2.0.',
          [A.Old, Name, A.New]));
    end;
  ANotice := Pending;
end;

procedure McpAliasUsage(AInto: TStrings);
begin
  EnterCriticalSection(GLock);
  try
    AInto.AddStrings(GUsage);
  finally
    LeaveCriticalSection(GLock);
  end;
end;

procedure McpAliasForgetSessions;
begin
  EnterCriticalSection(GLock);
  try
    GTold.Clear;
    GUsage.Clear;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

initialization
  InitCriticalSection(GLock);
  GTold  := TStringList.Create;
  GTold.Sorted := False;
  GUsage := TStringList.Create;
finalization
  GTold.Free;
  GUsage.Free;
  DoneCriticalSection(GLock);
end.
