{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsIdeWindows;

{ ide_list_windows and ide_get_window: the windows of the IDE as things an assistant can name and read
  (1.9.0, read-only first).  They run on the main thread and only look: nothing is shown, hidden,
  moved or focused.  The id is the form's address in hex, checked against the live forms on every
  call, so an id of a closed window answers "not found" and never reaches another object. }

{$mode objfpc}{$H+}

interface

implementation

uses
  Classes, SysUtils, StrUtils, Forms, Controls, StdCtrls, fpjson, SynEdit,
  McpToolContext;

const
  DEFAULT_MAX_CHARS = 20000;
  LIMIT_MAX_CHARS   = 100000;

  SCHEMA_LIST_WINDOWS =
    '{"type":"object","properties":{' +
    '"visible_only":{"type":"boolean","description":"Only windows that are shown (default true)"}}}';

  SCHEMA_GET_WINDOW =
    '{"type":"object","properties":{' +
    '"id":{"type":"string","description":"The id from ide_list_windows"},' +
    '"max_chars":{"type":"integer","description":"At most this many characters of text in all (default 20000, at most 100000)"}},' +
    '"required":["id"]}';

function WindowId(AForm: TCustomForm): string;
begin
  Result := 'w' + IntToHex(PtrUInt(AForm), 1);
end;

function FindWindow(const AId: string): TCustomForm;
var
  I : Integer;
begin
  Result := nil;
  for I := 0 to Screen.CustomFormCount - 1 do
    if WindowId(Screen.CustomForms[I]) = AId then
      Exit(Screen.CustomForms[I]);
end;

{ what kind of window it is, by the class names the IDE and the plugin use; "window" when not known }
function WindowKind(AForm: TCustomForm): string;
var
  C : string;
begin
  C := AForm.ClassName;
  if fsModal in AForm.FormState then Exit('dialog');
  if C = 'TMessagesView' then Exit('messages');
  if (C = 'TSearchResultsView') or (C = 'TSearchResultsViewForm') then Exit('search_results');
  if C = 'TSourceNotebook' then Exit('editor');
  if C = 'TMainIDEBar' then Exit('ide');
  if C = 'TAnchorDockHostSite' then Exit('dock_site');   { the frame that holds docked windows }
  if Pos('Review', C) > 0 then Exit('review');
  if (Pos('Markdown', C) > 0) or (Pos('MdForm', C) > 0) then Exit('markdown');
  if Pos('Designer', C) > 0 then Exit('designer');
  Result := 'window';
end;

function DescribeWindow(AForm: TCustomForm): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('id',      WindowId(AForm));
  Result.Add('kind',    WindowKind(AForm));
  Result.Add('class',   AForm.ClassName);
  Result.Add('name',    AForm.Name);
  Result.Add('title',   AForm.Caption);
  Result.Add('visible', AForm.Visible);
  Result.Add('modal',   fsModal in AForm.FormState);
  Result.Add('docked',  (AForm.HostDockSite <> nil) or (AForm.Parent <> nil));
  Result.Add('focused', Screen.ActiveCustomForm = AForm);
end;

{ the text of one control, '' when it shows none we read }
function ControlText(AControl: TControl): string;
begin
  Result := '';
  if AControl is TCustomMemo then
    Result := TCustomMemo(AControl).Lines.Text
  else if AControl is TCustomListBox then
    Result := TCustomListBox(AControl).Items.Text
  else if AControl is TCustomSynEdit then
    Result := TCustomSynEdit(AControl).Lines.Text
  else if AControl is TCustomEdit then
    Result := TCustomEdit(AControl).Text
  else if AControl is TCustomLabel then
    Result := TCustomLabel(AControl).Caption;
end;

procedure CollectText(AParent: TWinControl; AParts: TJSONArray; var ALeft: Integer; var ACut: Boolean);
var
  I    : Integer;
  C    : TControl;
  T    : string;
  Part : TJSONObject;
begin
  for I := 0 to AParent.ControlCount - 1 do
  begin
    C := AParent.Controls[I];
    T := ControlText(C);
    if T <> '' then
    begin
      Part := TJSONObject.Create;
      Part.Add('control', C.ClassName + IfThen(C.Name <> '', ' ' + C.Name, ''));
      if Length(T) > ALeft then
      begin
        T := Copy(T, 1, ALeft);
        ACut := True;
      end;
      Part.Add('text', T);
      AParts.Add(Part);
      Dec(ALeft, Length(T));
      if ALeft <= 0 then
      begin
        ACut := True;
        Exit;
      end;
    end;
    if C is TWinControl then
    begin
      CollectText(TWinControl(C), AParts, ALeft, ACut);
      if ALeft <= 0 then Exit;
    end;
  end;
end;

function DispatchIdeWindowTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  I, Max, Left : Integer;
  Only, Cut    : Boolean;
  Arr          : TJSONArray;
  Obj          : TJSONObject;
  Parts        : TJSONArray;
  F            : TCustomForm;
  Id           : string;
begin
  Result := (Name = 'ide_list_windows') or (Name = 'ide_get_window');
  if not Result then Exit;
  if Name = 'ide_list_windows' then
  begin
    Only := True;
    if Assigned(Ctx.Params) then Only := Ctx.Params.Get('visible_only', True);
    Arr := TJSONArray.Create;
    for I := 0 to Screen.CustomFormCount - 1 do
    begin
      F := Screen.CustomForms[I];
      if Only and not F.Visible then Continue;
      Arr.Add(DescribeWindow(F));
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('count', Arr.Count);
      Obj.Add('windows', Arr);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
    Exit;
  end;
  { ide_get_window }
  Id := '';
  Max := DEFAULT_MAX_CHARS;
  if Assigned(Ctx.Params) then
  begin
    Id  := Ctx.Params.Get('id', '');
    Max := Ctx.Params.Get('max_chars', DEFAULT_MAX_CHARS);
  end;
  if (Max < 1) or (Max > LIMIT_MAX_CHARS) then Max := DEFAULT_MAX_CHARS;
  F := FindWindow(Id);
  if F = nil then
  begin
    Ctx.Error := True;
    Ctx.Result := 'No window with the id "' + Id + '": it may have been closed. ide_list_windows lists the open ones.';
    Exit;
  end;
  Left := Max;
  Cut := False;
  Parts := TJSONArray.Create;
  CollectText(F, Parts, Left, Cut);
  Obj := DescribeWindow(F);
  try
    Obj.Add('text_parts', Parts);
    Obj.Add('truncated', Cut);
    Ctx.Result := Obj.AsJSON;
  finally
    Obj.Free;
  end;
end;

procedure RegisterIdeWindowSchemas(Tools: TJSONArray);
begin
  Tools.Add(MakeTool('ide_list_windows',
    'The windows of the IDE: id, kind (ide, editor, messages, search_results, markdown, review, designer, ' +
    'dialog, dock_site (the frame holding docked windows), window), class, title, visible, modal, docked, focused. Shows nothing and moves nothing. ' +
    'Hidden windows only with visible_only=false. ide_get_open_dialogs says more about dialogs.',
    SCHEMA_LIST_WINDOWS, MCP_ANN_RO));
  Tools.Add(MakeTool('ide_get_window',
    'The text a window shows: the memos, lists, edit boxes, labels and source editors in it, one part ' +
    'per control (control, text). id from ide_list_windows; max_chars limits the text (default 20000). ' +
    'Read only: nothing is shown, hidden or focused. A closed window answers "No window".',
    SCHEMA_GET_WINDOW, MCP_ANN_RO));
end;

initialization
  RegisterMcpGroup(@DispatchIdeWindowTool);
  RegisterMcpSchemas(@RegisterIdeWindowSchemas);

end.
