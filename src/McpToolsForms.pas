{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsForms;

{ Form designer tools: form_list_components, form_get_properties,
  form_set_properties, form_add_component, form_delete_component,
  form_arrange, form_get_lfm, form_create_event_handler, form_search_palette,
  form_list_collection_items, form_add_collection_item,
  form_delete_collection_item, form_move_collection_item,
  form_get_menu, form_add_menu_item, form_move_menu_item, form_undo, form_redo.

  Property access goes through the Object Inspector's property editors
  (PropEdits), so values read and write exactly as in the Object Inspector:
    - nested properties by dotted path: BorderSpacing.Around, Font.Style,
      Constraints.MinWidth, AnchorSideLeft.Control, ChildSizing.Layout
    - enums and sets as text: alClient, [akLeft,akTop], [fsBold]
    - component references by name: PopupMenu1
    - events by handler name: the handler is created when it does not exist
    - Name: renames the component and its field/references in the source
    - collection items by index: Columns[0].Caption, Panels[1].Width
    - string lists (Memo.Lines, ListBox.Items) as a JSON array or as text
  "Parent" is accepted as a pseudo-property to move a control into another
  container.  Everything runs on the IDE main thread. }

{$mode objfpc}{$H+}

interface

implementation

uses
  Classes, SysUtils, Math, StrUtils,
  LazIDEIntf, SrcEditorIntf, LazFileUtils,
  Controls, Forms, Menus, LCLProc, FormEditingIntf, ComponentEditors,
  TypInfo, LResources,
  ComponentReg, PropEdits,
  fpjson,
  McpToolContext, McpToolHelpers;

{ ── Schema constants ─────────────────────────────────────────────────────── }

const
  FORM_FILE_PROP =
    '"form_file":{"type":"string","description":"Absolute path of the .lfm or its .pas"}';

  SCHEMA_FORM_LIST_COMPONENTS =
    '{"type":"object","properties":{' + FORM_FILE_PROP + '},' +
    '"required":["form_file"]}';

  SCHEMA_FORM_GET_PROPERTIES =
    '{"type":"object","properties":{' + FORM_FILE_PROP + ',' +
    '"component_name":{"type":"string","description":"Component name, or the form''s own name"},' +
    '"names":{"type":"array","items":{"type":"string"},"description":"Only these properties (dotted paths allowed, e.g. BorderSpacing). ' +
      'When given, enum/set/reference properties also list their allowed values."},' +
    '"include_events":{"type":"boolean","description":"Include OnXxx event properties (default false)"}},' +
    '"required":["form_file","component_name"]}';

  SCHEMA_FORM_SET_PROPERTIES =
    '{"type":"object","properties":{' + FORM_FILE_PROP + ',' +
    '"component_name":{"type":"string","description":"Component name, or the form''s own name"},' +
    '"properties":{"type":"object","additionalProperties":{"type":["string","number","boolean","array"]},' +
      '"description":"Map of property path to value as the Object Inspector shows it, e.g. ' +
      '{\"Caption\":\"OK\",\"Align\":\"alBottom\",\"Anchors\":\"[akRight,akBottom]\",' +
      '\"BorderSpacing.Around\":6,\"Font.Style\":\"[fsBold]\",\"OnClick\":\"btnOKClick\",' +
      '\"Parent\":\"Panel1\",\"Name\":\"btnOK\",\"Columns[0].Width\":120,\"Lines\":[\"first\",\"second\"]}. ' +
      'Collection items are addressed by index (Columns[0].Caption, Panels[2].Text); string lists ' +
      '(Lines, Items) take an array of strings or one text with line breaks. Parent moves the control ' +
      'into another container; Name renames it in the source as well; events take a handler name (created if missing). ' +
      'Applied in order Parent, others, Name. Returns one result per property."}},' +
    '"required":["form_file","component_name","properties"]}';

  SCHEMA_FORM_ADD_COMPONENT =
    '{"type":"object","properties":{' + FORM_FILE_PROP + ',' +
    '"class_name":{"type":"string","description":"Component class (e.g. TButton); must be on the IDE palette"},' +
    '"parent_name":{"type":"string","description":"Container to put it in; defaults to the form"},' +
    '"name":{"type":"string","description":"Component name; default is the IDE''s (Button1, ...)"},' +
    '"left":{"type":"integer","description":"Default 8"},' +
    '"top":{"type":"integer","description":"Default 8"},' +
    '"width":{"type":"integer","description":"Default: the class default size"},' +
    '"height":{"type":"integer","description":"Default: the class default size"},' +
    '"properties":{"type":"object","description":"Properties to set right away, same format as form_set_properties"}},' +
    '"required":["form_file","class_name"]}';

  SCHEMA_FORM_DELETE_COMPONENT =
    '{"type":"object","properties":{' + FORM_FILE_PROP + ',' +
    '"component_name":{"type":"string","description":"Component to delete (its children are deleted too)"}},' +
    '"required":["form_file","component_name"]}';

  SCHEMA_FORM_ARRANGE =
    '{"type":"object","properties":{' + FORM_FILE_PROP + ',' +
    '"components":{"type":"array","items":{"type":"string"},"description":"Controls to arrange; all must share one parent. ' +
      'The first one is the reference for size and alignment."},' +
    '"same_size":{"type":"string","enum":["width","height","both"],"description":"Copy the first control''s width/height to the others"},' +
    '"distribute":{"type":"string","enum":["horizontal","vertical"],"description":"Place the controls in the given order, ' +
      'starting at the first one, separated by spacing pixels; without spacing, spread them evenly between the first and the last"},' +
    '"spacing":{"type":"integer","description":"Gap in pixels for distribute"},' +
    '"align":{"type":"string","enum":["left","right","top","bottom","hcenter","vcenter"],"description":"Align edges or centres"},' +
    '"relative_to":{"type":"string","enum":["first","parent"],"description":"Align to the first control (default) or within the parent''s client area"}},' +
    '"required":["form_file","components"]}';

  SCHEMA_FORM_GET_LFM =
    '{"type":"object","properties":{' + FORM_FILE_PROP + ',' +
    '"component_name":{"type":"string","description":"Only this component''s object block (default: whole form)"}},' +
    '"required":["form_file"]}';

  SCHEMA_FORM_CREATE_EVENT_HANDLER =
    '{"type":"object","properties":{' + FORM_FILE_PROP + ',' +
    '"component_name":{"type":"string","description":"Component name (e.g. btnOK)"},' +
    '"event_name":{"type":"string","description":"Event property name (e.g. OnClick)"},' +
    '"handler_name":{"type":"string","description":"Optional custom handler name; defaults to FormName+CompName+EventSuffix"}},' +
    '"required":["form_file","component_name","event_name"]}';

  SCHEMA_FORM_SEARCH_PALETTE =
    '{"type":"object","properties":{' +
    '"query":{"type":"string","description":"Substring to match against component class names (case-insensitive)"}},' +
    '"required":["query"]}';

  COLLECTION_PROPS =
    FORM_FILE_PROP + ',' +
    '"component_name":{"type":"string","description":"Owner of the collection, e.g. ListView1"},' +
    '"property":{"type":"string","description":"Columns, Panels, Bands, ... or an item path such as Bands[0].Controls"}';

  SCHEMA_FORM_LIST_COLLECTION_ITEMS =
    '{"type":"object","properties":{' + COLLECTION_PROPS + ',' +
    '"include_properties":{"type":"boolean","description":"Return each item''s properties (default true)"}},' +
    '"required":["form_file","component_name","property"]}';

  SCHEMA_FORM_ADD_COLLECTION_ITEM =
    '{"type":"object","properties":{' + COLLECTION_PROPS + ',' +
    '"index":{"type":"integer","description":"Position for the new item (default: at the end)"},' +
    '"properties":{"type":"object","description":"Item properties to set, same format as form_set_properties, ' +
      'e.g. {\"Caption\":\"Name\",\"Width\":120}"}},' +
    '"required":["form_file","component_name","property"]}';

  SCHEMA_FORM_DELETE_COLLECTION_ITEM =
    '{"type":"object","properties":{' + COLLECTION_PROPS + ',' +
    '"index":{"type":"integer","description":"Index of the item to delete"}},' +
    '"required":["form_file","component_name","property","index"]}';

  SCHEMA_FORM_MOVE_COLLECTION_ITEM =
    '{"type":"object","properties":{' + COLLECTION_PROPS + ',' +
    '"index":{"type":"integer","description":"Current index of the item"},' +
    '"new_index":{"type":"integer","description":"Index it should have afterwards"}},' +
    '"required":["form_file","component_name","property","index","new_index"]}';

  SCHEMA_FORM_GET_MENU =
    '{"type":"object","properties":{' + FORM_FILE_PROP + ',' +
    '"menu_name":{"type":"string","description":"TMainMenu/TPopupMenu name, or a menu item to get only its submenu. Optional when the form has exactly one menu"}},' +
    '"required":["form_file"]}';

  SCHEMA_FORM_ADD_MENU_ITEM =
    '{"type":"object","properties":{' + FORM_FILE_PROP + ',' +
    '"parent_name":{"type":"string","description":"Menu (TMainMenu/TPopupMenu) for a top-level item, or the menu item to add a submenu entry to"},' +
    '"caption":{"type":"string","description":"Caption; \"-\" makes a separator. Use & for the accelerator key (&File)"},' +
    '"name":{"type":"string","description":"Component name (default: derived by the IDE, MenuItem1, ...)"},' +
    '"index":{"type":"integer","description":"Position among the parent''s items (default: at the end)"},' +
    '"properties":{"type":"object","description":"More properties, same format as form_set_properties, ' +
      'e.g. {\"ShortCut\":\"Ctrl+S\",\"OnClick\":\"mnuSaveClick\",\"Checked\":true}"}},' +
    '"required":["form_file","parent_name","caption"]}';

  SCHEMA_FORM_MOVE_MENU_ITEM =
    '{"type":"object","properties":{' + FORM_FILE_PROP + ',' +
    '"component_name":{"type":"string","description":"Menu item to move"},' +
    '"parent_name":{"type":"string","description":"New parent menu or menu item (default: keep the parent)"},' +
    '"index":{"type":"integer","description":"Position among the new parent''s items (default: at the end)"}},' +
    '"required":["form_file","component_name"]}';

{ ── Property-editor helpers ──────────────────────────────────────────────── }

type
  { Collects property editors.  GetPersistentProperties and
    TPropertyEditor.GetProperties hand ownership to the receiver, so the pool
    frees every editor it has seen.  Level holds the editors of the most
    recent Collect call. }
  TEditorPool = class
  private
    FAll   : TFPList;
    FLevel : TFPList;
    procedure AddEditor(Prop: TPropertyEditor);
  public
    constructor Create;
    destructor Destroy; override;
    procedure CollectTop(AItem: TPersistent; AFilter: TTypeKinds);
    procedure CollectSub(AEditor: TPropertyEditor);
    function FindInLevel(const AName: string): TPropertyEditor;
    property Level: TFPList read FLevel;
  end;

  TValueCollector = class
    Items : TJSONArray;
    procedure Add(const S: ansistring);
  end;

  TLfmMethodWriter = class
    procedure WriteMethod(Writer: TWriter; Instance: TPersistent;
      PropInfo: PPropInfo; const MethodValue, DefMethodValue: TMethod;
      var Handled: boolean);
  end;

constructor TEditorPool.Create;
begin
  inherited Create;
  FAll   := TFPList.Create;
  FLevel := TFPList.Create;
end;

destructor TEditorPool.Destroy;
var
  I : Integer;
begin
  for I := 0 to FAll.Count - 1 do
    TPropertyEditor(FAll[I]).Free;
  FAll.Free;
  FLevel.Free;
  inherited Destroy;
end;

procedure TEditorPool.AddEditor(Prop: TPropertyEditor);
begin
  FAll.Add(Prop);
  FLevel.Add(Prop);
end;

procedure TEditorPool.CollectTop(AItem: TPersistent; AFilter: TTypeKinds);
begin
  FLevel.Clear;
  GetPersistentProperties(AItem, AFilter, GlobalDesignHook, @AddEditor, nil);
end;

procedure TEditorPool.CollectSub(AEditor: TPropertyEditor);
begin
  FLevel.Clear;
  AEditor.GetProperties(@AddEditor);
end;

function TEditorPool.FindInLevel(const AName: string): TPropertyEditor;
var
  I : Integer;
begin
  for I := 0 to FLevel.Count - 1 do
    if SameText(TPropertyEditor(FLevel[I]).GetName, AName) then
      Exit(TPropertyEditor(FLevel[I]));
  Result := nil;
end;

procedure TValueCollector.Add(const S: ansistring);
begin
  if Items.Count < 200 then
    Items.Add(S);
end;

procedure TLfmMethodWriter.WriteMethod(Writer: TWriter; Instance: TPersistent;
  PropInfo: PPropInfo; const MethodValue, DefMethodValue: TMethod;
  var Handled: boolean);
var
  CurName : string;
begin
  { Same as the IDE's own LFM writer, but resolving designer (JIT) methods
    through the design hook instead of IDE-internal classes. }
  Handled := True;
  if (DefMethodValue.Data = MethodValue.Data) and
     (DefMethodValue.Code = MethodValue.Code) then
    Exit;
  CurName := GlobalDesignHook.GetMethodName(MethodValue, Instance);
  if CurName = '' then Exit;
  Writer.Driver.BeginProperty(Writer.PropertyPath + PropInfo^.Name);
  Writer.Driver.WriteMethodName(CurName);
  Writer.Driver.EndProperty;
end;

function KindName(AEditor: TPropertyEditor): string;
begin
  Result := GetEnumName(TypeInfo(TTypeKind), Ord(AEditor.GetPropType^.Kind));
  if Copy(Result, 1, 2) = 'tk' then
    Delete(Result, 1, 2);
  Result := LowerCase(Result);
end;

{ Expand class-typed sub-objects (BorderSpacing, Font, Constraints,
  AnchorSide…, ChildSizing) but not references to other components, sets or
  collections. }
function ShouldExpand(AEditor: TPropertyEditor): Boolean;
var
  TD : PTypeData;
begin
  Result := False;
  if not (paSubProperties in AEditor.GetAttributes) then Exit;
  if AEditor.GetPropType^.Kind <> tkClass then Exit;
  TD := GetTypeData(AEditor.GetPropType);
  Result := Assigned(TD) and Assigned(TD^.ClassType) and
            not TD^.ClassType.InheritsFrom(TComponent) and
            not TD^.ClassType.InheritsFrom(TCollection);
end;

function SafeValue(AEditor: TPropertyEditor): string;
begin
  try
    Result := AEditor.GetValue;
    { the Boolean editor shows "(True)"; report the value as it is set }
    if (AEditor.GetPropType^.Kind = tkBool) and (Length(Result) > 2) and
       (Result[1] = '(') and (Result[Length(Result)] = ')') then
      Result := Copy(Result, 2, Length(Result) - 2);
  except
    on E: Exception do Result := '(unreadable: ' + E.Message + ')';
  end;
end;

{ Is AEditor's property of class AClass (or a descendant)? }
function EditsClass(AEditor: TPropertyEditor; AClass: TClass): Boolean;
var
  TD : PTypeData;
begin
  Result := False;
  if AEditor.GetPropType^.Kind <> tkClass then Exit;
  TD := GetTypeData(AEditor.GetPropType);
  Result := Assigned(TD) and Assigned(TD^.ClassType) and
            TD^.ClassType.InheritsFrom(AClass);
end;

{ ── Designer undo ─────────────────────────────────────────────────────────── }

type
  { The changes of one tool call, recorded in the designer's undo list as one
    group: what one Edit > Undo (Ctrl+Z, form_undo) takes back. }
  TUndoGroup = record
    Designer : TComponentEditorDesigner;
    Started  : Boolean;
  end;
  PUndoGroup = ^TUndoGroup;

function NewUndoGroup(ADesigner: TIDesigner): TUndoGroup;
begin
  Result.Designer := nil;
  if ADesigner is TComponentEditorDesigner then
    Result.Designer := TComponentEditorDesigner(ADesigner);
  Result.Started := False;
end;

procedure AddUndo(var AGroup: TUndoGroup; APersistent: TPersistent;
  AOp: TUndoOpType; const AField, AOld, ANew: string);
begin
  if AGroup.Designer = nil then Exit;
  if (AOp = uopChange) and (AOld = ANew) then Exit;
  if AGroup.Designer.AddUndoAction(APersistent, AOp, not AGroup.Started,
                                   AField, AOld, ANew) then
    AGroup.Started := True;
end;

{ Can the designer's undo replay a change made through AEditor?  It sets a
  published property of simple type on a component it finds by name
  (TDesigner.ExecuteUndoItem); sub-objects (Font.Color), collection items,
  references, events and string lists are out of its reach.  (Menu items are
  fine: the menu tools record their deletes and moves, so an entry naming an
  item finds it again.) }
function UndoableEditor(AEditor: TPropertyEditor): Boolean;
begin
  Result := (AEditor.GetPropInfo <> nil) and (AEditor.GetComponent(0) is TComponent) and
            (AEditor.GetPropType^.Kind in [tkInteger, tkInt64, tkChar, tkWChar, tkUChar,
              tkEnumeration, tkFloat, tkBool, tkSString, tkLString, tkAString,
              tkUString, tkWString, tkSet]);
end;

{ The value as the Object Inspector records it for undo (its GetPropValue). }
function UndoValue(AEditor: TPropertyEditor): string;
begin
  case AEditor.GetPropType^.Kind of
    tkInteger, tkInt64:
      Result := IntToStr(AEditor.GetInt64ValueAt(0));
    tkChar, tkWChar, tkUChar:
      Result := Char(AEditor.GetOrdValueAt(0));
    tkEnumeration:
      Result := AEditor.GetEnumValueAt(0);
    tkFloat:
      Result := FloatToStr(AEditor.GetFloatValueAt(0));
    tkBool:
      Result := BoolToStr(Boolean(AEditor.GetOrdValueAt(0)), 'True', 'False');
    tkSet:
      Result := AEditor.GetSetValueAt(0, True);
  else
    Result := AEditor.GetStrValueAt(0);
  end;
end;

{ TStrings properties (Memo.Lines, ListBox.Items) only have a dialog editor,
  so they are read and written here directly. }
function StringsJSON(AList: TStrings): TJSONArray;
var
  I : Integer;
begin
  Result := TJSONArray.Create;
  if AList = nil then Exit;
  for I := 0 to Min(AList.Count, 500) - 1 do
    Result.Add(AList[I]);
end;

procedure SetStrings(AList: TStrings; AData: TJSONData);
var
  I : Integer;
begin
  AList.BeginUpdate;
  try
    if AData.JSONType = jtArray then
    begin
      AList.Clear;
      for I := 0 to AData.Count - 1 do
        AList.Add(AData.Items[I].AsString);
    end
    else if AData.JSONType = jtNull then
      AList.Clear
    else
      AList.Text := AData.AsString;
  finally
    AList.EndUpdate;
  end;
end;

{ Walk the part of APath up to its last collection index, e.g.
  'Columns[2].Title.Caption' -> ATarget = item 2 of Columns,
  ARest = 'Title.Caption'.  Paths without an index are returned unchanged. }
function ResolveItemPath(ARoot: TPersistent; const APath: string;
  out ATarget: TPersistent; out ARest: string; out AErr: string): Boolean;
var
  LastBr, P, Idx : Integer;
  Head, Seg, PropName : string;
  Obj : TObject;
begin
  ATarget := ARoot;
  ARest   := APath;
  AErr    := '';
  LastBr  := LastDelimiter(']', APath);
  if LastBr = 0 then Exit(True);
  Result := False;
  Head  := Copy(APath, 1, LastBr);
  ARest := Copy(APath, LastBr + 1, MaxInt);
  if ARest <> '' then
  begin
    if ARest[1] <> '.' then
    begin
      AErr := 'bad property path: ' + APath; Exit;
    end;
    Delete(ARest, 1, 1);
  end;
  while Head <> '' do
  begin
    P := Pos('.', Head);
    if P > 0 then
    begin
      Seg := Copy(Head, 1, P - 1);
      Delete(Head, 1, P);
    end
    else
    begin
      Seg  := Head;
      Head := '';
    end;
    Idx := -1;
    P := Pos('[', Seg);
    if P > 0 then
    begin
      PropName := Copy(Seg, 1, P - 1);
      if (Seg[Length(Seg)] <> ']') or
         not TryStrToInt(Copy(Seg, P + 1, Length(Seg) - P - 1), Idx) then
      begin
        AErr := 'bad index in: ' + Seg; Exit;
      end;
    end
    else
      PropName := Seg;
    if not IsPublishedProp(ATarget, PropName) or
       (PropType(ATarget, PropName) <> tkClass) then
    begin
      AErr := PropName + ' is not an object property of ' + ATarget.ClassName; Exit;
    end;
    Obj := GetObjectProp(ATarget, PropName);
    if P > 0 then
    begin
      if not (Obj is TCollection) then
      begin
        AErr := PropName + ' is not a collection'; Exit;
      end;
      if (Idx < 0) or (Idx >= TCollection(Obj).Count) then
      begin
        AErr := Format('%s[%d]: index out of range (count %d)',
                       [PropName, Idx, TCollection(Obj).Count]);
        Exit;
      end;
      ATarget := TCollection(Obj).Items[Idx];
    end
    else if Obj is TPersistent then
      ATarget := TPersistent(Obj)
    else
    begin
      AErr := PropName + ' is nil'; Exit;
    end;
  end;
  Result := True;
end;

{ The collection at APath ('Columns', 'Bands[0].Controls') of AComp. }
function FindCollection(AComp: TPersistent; const APath: string;
  out AErr: string): TCollection;
var
  Target : TPersistent;
  Rest   : string;
  Obj    : TObject;
begin
  Result := nil;
  if not ResolveItemPath(AComp, APath, Target, Rest, AErr) then Exit;
  if Rest = '' then
  begin
    AErr := APath + ' is a collection item, not a collection'; Exit;
  end;
  Obj := Target;
  while Rest <> '' do
  begin
    if Pos('.', Rest) > 0 then
    begin
      AErr := '';
      if not IsPublishedProp(Obj, Copy(Rest, 1, Pos('.', Rest) - 1)) then
      begin
        AErr := 'property not found: ' + Copy(Rest, 1, Pos('.', Rest) - 1); Exit;
      end;
      Obj := GetObjectProp(Obj, Copy(Rest, 1, Pos('.', Rest) - 1));
      Delete(Rest, 1, Pos('.', Rest));
    end
    else
    begin
      if (Obj = nil) or not IsPublishedProp(Obj, Rest) or
         (PropType(Obj, Rest) <> tkClass) then
      begin
        AErr := 'property not found: ' + Rest; Exit;
      end;
      Obj  := GetObjectProp(Obj, Rest);
      Rest := '';
    end;
    if Obj = nil then
    begin
      AErr := 'nil object in path: ' + APath; Exit;
    end;
  end;
  if not (Obj is TCollection) then
  begin
    AErr := APath + ' is not a collection (it is ' + Obj.ClassName + ')'; Exit;
  end;
  Result := TCollection(Obj);
end;

{ Resolve a dotted property path ('BorderSpacing.Around') to its editor.
  Sub-objects the Object Inspector hides (AnchorSideLeft..AnchorSideBottom
  have a THiddenPropertyEditor; it edits them in the Anchor Editor) are
  entered through RTTI, and their own properties (Control, Side) through
  their editors. }
function ResolvePath(Pool: TEditorPool; AItem: TPersistent;
  const APath: string; out AErr: string): TPropertyEditor;
var
  Rest, Part : string;
  P          : Integer;
  Cur        : TPersistent;   { the object whose properties are in the pool }
  Info       : PPropInfo;
  Sub        : TObject;
begin
  Result := nil;
  AErr   := '';
  Cur    := AItem;
  Pool.CollectTop(AItem, tkAny);
  Rest := APath;
  repeat
    P := Pos('.', Rest);
    if P > 0 then
    begin
      Part := Copy(Rest, 1, P - 1);
      Delete(Rest, 1, P);
    end
    else
    begin
      Part := Rest;
      Rest := '';
    end;
    Result := Pool.FindInLevel(Part);
    if (Result = nil) and (Rest <> '') and Assigned(Cur) then
    begin
      Info := GetPropInfo(Cur, Part);
      Sub  := nil;
      if Assigned(Info) and (Info^.PropType^.Kind = tkClass) then
        Sub := GetObjectProp(Cur, Info);
      if (Sub is TPersistent) and not (Sub is TComponent) then
      begin
        Cur := TPersistent(Sub);
        Pool.CollectTop(Cur, tkAny);
        Continue;
      end;
    end;
    if Result = nil then
    begin
      AErr := 'property not found: ' + Part;
      Exit;
    end;
    if Rest <> '' then
    begin
      if not (paSubProperties in Result.GetAttributes) then
      begin
        AErr := Part + ' has no sub-properties';
        Exit(nil);
      end;
      Cur := nil;
      if (Result.GetPropType^.Kind = tkClass) and (Result.GetObjectValue is TPersistent) then
        Cur := TPersistent(Result.GetObjectValue);
      Pool.CollectSub(Result);
    end;
  until Rest = '';
end;

{ Does property path AName pass the optional names filter?  A filter entry
  selects the property itself and everything below it; ancestors of a
  filter entry are traversed but not reported. }
function FilterMatch(AFilter: TStringList; const AName: string;
  out AReport: Boolean): Boolean;
var
  I : Integer;
  F : string;
begin
  AReport := True;
  if (AFilter = nil) or (AFilter.Count = 0) then Exit(True);
  AReport := False;
  Result  := False;
  for I := 0 to AFilter.Count - 1 do
  begin
    F := AFilter[I];
    if SameText(AName, F) or SameText(Copy(AName, 1, Length(F) + 1), F + '.') then
    begin
      AReport := True;
      Exit(True);
    end;
    if SameText(Copy(F, 1, Length(AName) + 1), AName + '.') then
      Result := True;  { an ancestor: descend }
  end;
end;

procedure ListLevel(Pool: TEditorPool; const APrefix: string; ADepth: Integer;
  AFilter: TStringList; AArr: TJSONArray);
var
  Snapshot : TFPList;
  I        : Integer;
  Ed       : TPropertyEditor;
  PName    : string;
  Obj      : TJSONObject;
  Report   : Boolean;
  Values   : TValueCollector;
begin
  Snapshot := TFPList.Create;
  try
    Snapshot.Assign(Pool.Level);
    for I := 0 to Snapshot.Count - 1 do
    begin
      Ed    := TPropertyEditor(Snapshot[I]);
      PName := APrefix + Ed.GetName;
      if not FilterMatch(AFilter, PName, Report) then Continue;
      if Report then
      begin
        Obj := TJSONObject.Create;
        Obj.Add('name',  PName);
        Obj.Add('value', SafeValue(Ed));
        Obj.Add('kind',  KindName(Ed));
        if EditsClass(Ed, TStrings) then
          Obj.Add('lines', StringsJSON(TStrings(Ed.GetObjectValue)))
        else if EditsClass(Ed, TCollection) and Assigned(Ed.GetObjectValue) then
          Obj.Add('count', TCollection(Ed.GetObjectValue).Count);
        { sets and sub-objects report paReadOnly for their text field, yet
          are settable as text / via their sub-properties; string lists are
          settable here, collections through form_*_collection_item }
        if (paReadOnly in Ed.GetAttributes) and
           not (paSubProperties in Ed.GetAttributes) and
           not EditsClass(Ed, TStrings) then
          Obj.Add('read_only', True);
        if Assigned(AFilter) and (AFilter.Count > 0) and
           (paValueList in Ed.GetAttributes) then
        begin
          Values := TValueCollector.Create;
          try
            Values.Items := TJSONArray.Create;
            try
              Ed.GetValues(@Values.Add);
            except
              { some editors need a live designer selection; skip the list }
            end;
            Obj.Add('values', Values.Items);
          finally
            Values.Free;
          end;
        end;
        AArr.Add(Obj);
      end;
      if ShouldExpand(Ed) and (ADepth < 3) then
      begin
        Pool.CollectSub(Ed);
        ListLevel(Pool, PName + '.', ADepth + 1, AFilter, AArr);
      end;
    end;
  finally
    Snapshot.Free;
  end;
end;

{ AnchorSideLeft..AnchorSideBottom have a THiddenPropertyEditor (the Anchor
  Editor edits them), so ListLevel never meets them: list their Control and
  Side from the control.  Without a names filter only the sides anchored to
  a control, to keep the listing short. }
procedure ListAnchorSides(Pool: TEditorPool; AComp: TComponent; AKinds: TTypeKinds;
  AFilter: TStringList; AArr: TJSONArray);
var
  Kind : TAnchorKind;
  Side : TAnchorSide;
begin
  if not (AComp is TControl) then Exit;
  for Kind := Low(TAnchorKind) to High(TAnchorKind) do
  begin
    Side := TControl(AComp).AnchorSide[Kind];
    if (Side = nil) or (((AFilter = nil) or (AFilter.Count = 0)) and (Side.Control = nil)) then
      Continue;
    Pool.CollectTop(Side, AKinds);
    ListLevel(Pool, 'AnchorSide' + Copy(GetEnumName(TypeInfo(TAnchorKind), Ord(Kind)), 3, MaxInt) + '.',
              1, AFilter, AArr);
  end;
end;

{ ── Designer helpers ─────────────────────────────────────────────────────── }

function FindEditorFor(const AFile: string): TSourceEditorInterface;
var
  J : Integer;
begin
  Result := nil;
  for J := 0 to SourceEditorManagerIntf.SourceEditorCount - 1 do
    if CompareFilenames(SourceEditorManagerIntf.SourceEditors[J].FileName,
                        AFile) = 0 then
      Exit(SourceEditorManagerIntf.SourceEditors[J]);
end;

{ The designer of the form whose unit or .lfm is AFormFile; opens the form
  in the designer when needed. }
function FindDesigner(const AFormFile: string; out AErr: string): TIDesigner;
var
  PasFile : string;
  Ed      : TSourceEditorInterface;
begin
  Result := nil;
  AErr   := '';
  if not Assigned(FormEditingHook) then
  begin
    AErr := 'FormEditingHook is nil';
    Exit;
  end;
  { Designers belong to the unit's source editor, so look for the .pas.
    Normalised, so D:/x/f.pas matches the editor's D:\x\f.pas. }
  PasFile := CleanAndExpandFilename(AFormFile);
  if SameText(ExtractFileExt(PasFile), '.lfm') then
  begin
    PasFile := ChangeFileExt(AFormFile, '.pas');
    if not FileExists(PasFile) and FileExists(ChangeFileExt(AFormFile, '.pp')) then
      PasFile := ChangeFileExt(AFormFile, '.pp');
  end;
  Ed := FindEditorFor(PasFile);
  if Ed = nil then
  begin
    { the IDE answers a missing file with a dialog }
    if not McpCheckFileToOpen(PasFile, AErr) then
    begin
      Exit;
    end;
    LazarusIDE.DoOpenEditorFile(PasFile, -1, -1, [ofOnlyIfExists]);
    Ed := FindEditorFor(PasFile);
  end;
  if Ed = nil then
  begin
    AErr := 'Could not open the form unit: ' + PasFile;
    Exit;
  end;
  Result := LazarusIDE.GetDesignerForProjectEditor(Ed, True);  { loads the form }
  if (Result = nil) or (Result.LookupRoot = nil) then
  begin
    Result := nil;
    AErr   := 'No form designer for: ' + AFormFile + ' (is it a form/frame/data module unit?)';
    Exit;
  end;
  GlobalDesignHook.LookupRoot := Result.LookupRoot;
end;

function FindComp(ADesigner: TIDesigner; const AName: string): TComponent;
begin
  Result := nil;
  if AName = '' then Exit;
  if SameText(ADesigner.LookupRoot.Name, AName) then
    Exit(ADesigner.LookupRoot);
  Result := ADesigner.LookupRoot.FindComponent(AName);
end;

{ The names of the menus (TMainMenu, TPopupMenu) on a form, for the messages that
  ask for a menu and for the one-menu default of form_get_menu. }
function MenuNamesOf(ARoot: TComponent): TStringList;
var
  I : Integer;
begin
  Result := TStringList.Create;
  for I := 0 to ARoot.ComponentCount - 1 do
    if ARoot.Components[I] is TMenu then
      Result.Add(ARoot.Components[I].Name);
end;

function JSONValueAsString(AData: TJSONData): string;
begin
  case AData.JSONType of
    jtString  : Result := AData.AsString;
    jtBoolean : if AData.AsBoolean then Result := 'True' else Result := 'False';
    jtNull    : Result := '';
  else          Result := AData.AsJSON;  { numbers as written }
  end;
end;

{ Move AComp into the container named ANewParent. }
function SetParentOf(ADesigner: TIDesigner; AComp: TComponent;
  const ANewParent: string; out AErr: string): Boolean;
var
  P : TComponent;
begin
  Result := False;
  AErr   := '';
  if not (AComp is TControl) then
  begin
    AErr := AComp.Name + ' is not a control';
    Exit;
  end;
  P := FindComp(ADesigner, ANewParent);
  if not (P is TWinControl) then
  begin
    AErr := 'container not found: ' + ANewParent;
    Exit;
  end;
  if not (csAcceptsControls in TWinControl(P).ControlStyle) then
  begin
    AErr := ANewParent + ' does not accept child controls';
    Exit;
  end;
  if (P = AComp) or ((AComp is TWinControl) and TWinControl(AComp).IsParentOf(TControl(P))) then
  begin
    AErr := 'cannot move a control into itself';
    Exit;
  end;
  TControl(AComp).Parent := TWinControl(P);
  Result := True;
end;

{ Apply AProps to AComp (a component or a collection item); one result entry
  per property.  Returns the number of failures.  With AGroup the changes go
  into the designer's undo list in that group, and each result tells whether
  its change can be undone there. }
function ApplyProperties(ADesigner: TIDesigner; AComp: TPersistent;
  AProps: TJSONObject; AResults: TJSONArray; AGroup: PUndoGroup): Integer;
var
  Pool    : TEditorPool;
  Pass, I : Integer;
  Key     : string;
  Val     : string;
  Ed      : TPropertyEditor;
  Err     : string;
  R       : TJSONObject;
  Target  : TPersistent;
  Rest    : string;
  List    : TStrings;
  ARecord : Boolean;
  Undoable: Boolean;
  OldVal  : string;
  OldParent : TWinControl;
begin
  Result := 0;
  if AProps = nil then Exit;
  ARecord := AGroup <> nil;
  Pool := TEditorPool.Create;
  try
    { pass 0: Parent, pass 1: everything else, pass 2: Name }
    for Pass := 0 to 2 do
      for I := 0 to AProps.Count - 1 do
      begin
        Key := AProps.Names[I];
        if (Pass = 0) <> SameText(Key, 'Parent') then Continue;
        if (Pass = 2) <> SameText(Key, 'Name') then Continue;
        Val := JSONValueAsString(AProps.Items[I]);
        R := TJSONObject.Create;
        R.Add('name', Key);
        Undoable := False;
        try
          if Pass = 0 then
          begin
            if not (AComp is TComponent) then
              Err := 'Parent applies to components only'
            else
            begin
              OldParent := nil;
              if AComp is TControl then
                OldParent := TControl(AComp).Parent;
              if SetParentOf(ADesigner, TComponent(AComp), Val, Err) then
              begin
                R.Add('value', TControl(AComp).Parent.Name);
                { as the Object Inspector and the component tree record it }
                Undoable := Assigned(OldParent);
                if ARecord and Undoable then
                  AddUndo(AGroup^, AComp, uopChange, 'Parent', OldParent.Name,
                          TControl(AComp).Parent.Name);
              end;
            end;
          end
          else if not ResolveItemPath(AComp, Key, Target, Rest, Err) then
            { Err set }
          else if Rest = '' then
            Err := 'path names a collection item, not a property'
          else
          begin
            Ed := ResolvePath(Pool, Target, Rest, Err);
            if Assigned(Ed) and EditsClass(Ed, TStrings) then
            begin
              List := TStrings(Ed.GetObjectValue);
              if List = nil then
                Err := 'string list is nil'
              else
              begin
                SetStrings(List, AProps.Items[I]);
                GlobalDesignHook.Modified(Target);
                R.Add('value', Format('(%d lines)', [List.Count]));
              end;
            end
            else if Assigned(Ed) then
            begin
              if EditsClass(Ed, TCollection) then
                Err := 'collection: set item properties as ' + Rest + '[index].Prop, ' +
                       'add/delete items with form_add_collection_item / form_delete_collection_item'
              else if (paReadOnly in Ed.GetAttributes) and not (paSubProperties in Ed.GetAttributes) then
                Err := 'read-only property'
              else
              begin
                Undoable := UndoableEditor(Ed);
                if Undoable then
                  OldVal := UndoValue(Ed);
                Ed.SetValue(Val);
                R.Add('value', SafeValue(Ed));
                if ARecord and Undoable then
                  AddUndo(AGroup^, Ed.GetComponent(0), uopChange, Ed.GetName,
                          OldVal, UndoValue(Ed));
              end;
            end;
          end;
        except
          on E: Exception do Err := E.Message;
        end;
        if Err <> '' then
        begin
          R.Add('error', Err);
          Inc(Result);
        end
        else if ARecord then
          R.Add('undoable', Undoable);
        AResults.Add(R);
      end;
  finally
    Pool.Free;
  end;
  ADesigner.Modified;
end;

{ ── Menu helpers ─────────────────────────────────────────────────────────── }

{ Name of the menu (for top-level items) or menu item AItem belongs to. }
function MenuParentName(AItem: TMenuItem): string;
begin
  Result := '';
  if AItem.Parent = nil then Exit;
  if Assigned(AItem.GetParentMenu) and (AItem.Parent = AItem.GetParentMenu.Items) then
    Result := AItem.GetParentMenu.Name
  else
    Result := AItem.Parent.Name;
end;

{ The item list of a menu, or of a menu item (its submenu). }
function MenuItemsOf(AComp: TComponent): TMenuItem;
begin
  if AComp is TMenu then
    Result := TMenu(AComp).Items
  else if AComp is TMenuItem then
    Result := TMenuItem(AComp)
  else
    Result := nil;
end;

function MenuTreeJSON(AItem: TMenuItem): TJSONArray;
var
  I   : Integer;
  MI  : TMenuItem;
  Obj : TJSONObject;
  H   : string;
begin
  Result := TJSONArray.Create;
  for I := 0 to AItem.Count - 1 do
  begin
    MI  := AItem.Items[I];
    Obj := TJSONObject.Create;
    Obj.Add('name',    MI.Name);
    Obj.Add('caption', MI.Caption);
    if MI.IsLine then Obj.Add('separator', True);
    if MI.ShortCut <> 0 then Obj.Add('shortcut', ShortCutToTextRaw(MI.ShortCut));
    if not MI.Enabled then Obj.Add('enabled', False);
    if not MI.Visible then Obj.Add('visible', False);
    if MI.Checked then Obj.Add('checked', True);
    if MI.RadioItem then Obj.Add('group_index', MI.GroupIndex);
    if Assigned(MI.Action) then Obj.Add('action', MI.Action.Name);
    H := GlobalDesignHook.GetMethodName(GetMethodProp(MI, 'OnClick'), MI);
    if H <> '' then Obj.Add('on_click', H);
    if MI.Count > 0 then Obj.Add('items', MenuTreeJSON(MI));
    Result.Add(Obj);
  end;
end;

{ The IDE's Menu Editor keeps its own view of the menu and does not notice
  items added or removed elsewhere; hiding it frees that view (it is rebuilt
  when the user opens it again). }
function HideMenuEditor: Boolean;
var
  I : Integer;
begin
  Result := False;
  for I := Screen.CustomFormCount - 1 downto 0 do
    if Screen.CustomForms[I].ClassNameIs('TMenuDesignerForm') and
       Screen.CustomForms[I].Visible then
    begin
      Screen.CustomForms[I].Hide;
      Result := True;
    end;
end;

{ Delete AItem and its submenu, as the Menu Editor does. }
procedure DeleteMenuItem(AItem: TMenuItem);
var
  I : Integer;
  P : TPersistent;
begin
  for I := AItem.Count - 1 downto 0 do
    DeleteMenuItem(AItem.Items[I]);
  if Assigned(AItem.Parent) then
    AItem.Parent.Remove(AItem);
  P := AItem;
  GlobalDesignHook.DeletePersistent(P);
end;

{ Select APersistent in the Object Inspector (and nothing else). }
procedure SelectOnly(APersistent: TPersistent);
var
  Sel : TPersistentSelectionList;
begin
  Sel := TPersistentSelectionList.Create;
  try
    if Assigned(APersistent) then
      Sel.Add(APersistent);
    GlobalDesignHook.SetSelection(Sel);
  finally
    Sel.Free;
  end;
end;

function ControlInfo(AComp: TComponent; ARoot: TComponent): TJSONObject;
var
  C    : TControl;
  L, T : Integer;
begin
  Result := TJSONObject.Create;
  Result.Add('name',  AComp.Name);
  Result.Add('class', AComp.ClassName);
  if AComp is TControl then
  begin
    C := TControl(AComp);
    if Assigned(C.Parent) then
      Result.Add('parent', C.Parent.Name)
    else
      Result.Add('parent', '');
    Result.Add('left',    C.Left);
    Result.Add('top',     C.Top);
    Result.Add('width',   C.Width);
    Result.Add('height',  C.Height);
    Result.Add('align',   GetEnumName(TypeInfo(TAlign), Ord(C.Align)));
    Result.Add('anchors', GetSetProp(C, 'Anchors', True));
    Result.Add('visible', C.Visible);
    if IsPublishedProp(C, 'Caption') then
      Result.Add('caption', GetStrProp(C, 'Caption'))
    else if IsPublishedProp(C, 'Text') then
      Result.Add('text', GetStrProp(C, 'Text'));
    if (C is TWinControl) and IsPublishedProp(C, 'TabOrder') then
      Result.Add('tab_order', TWinControl(C).TabOrder);
  end
  else if AComp is TMenuItem then
  begin
    { menu items have no position; form_get_menu shows the tree }
    Result.Add('menu_item', True);
    Result.Add('parent',  MenuParentName(TMenuItem(AComp)));
    Result.Add('caption', TMenuItem(AComp).Caption);
  end
  else
  begin
    GetComponentLeftTopOrDesignInfo(AComp, L, T);
    Result.Add('non_visual', True);
    Result.Add('left', L);
    Result.Add('top',  T);
  end;
end;

{ Text of the "object Name: TClass" block for AName inside an LFM. }
function ExtractObjectBlock(const ALfm, AName: string): string;
var
  Lines  : TStringList;
  I, J   : Integer;
  S, Ind : string;
begin
  Result := '';
  Lines := TStringList.Create;
  try
    Lines.Text := ALfm;
    for I := 0 to Lines.Count - 1 do
    begin
      S := TrimLeft(Lines[I]);
      if SameText(Copy(S, 1, Length('object ' + AName + ':')), 'object ' + AName + ':') or
         SameText(Copy(S, 1, Length('inherited ' + AName + ':')), 'inherited ' + AName + ':') or
         SameText(Copy(S, 1, Length('inline ' + AName + ':')), 'inline ' + AName + ':') then
      begin
        Ind := Copy(Lines[I], 1, Length(Lines[I]) - Length(S));
        for J := I to Lines.Count - 1 do
        begin
          Result := Result + Lines[J] + LineEnding;
          if (J > I) and (Lines[J] = Ind + 'end') then
            Exit;
        end;
        Exit;
      end;
    end;
  finally
    Lines.Free;
  end;
end;

function DesignerLfm(ADesigner: TIDesigner): string;
var
  Bin, Txt      : TMemoryStream;
  Writer        : TWriter;
  DestroyDriver : Boolean;
  MW            : TLfmMethodWriter;
begin
  Result := '';
  Bin := TMemoryStream.Create;
  Txt := TMemoryStream.Create;
  MW  := TLfmMethodWriter.Create;
  try
    DestroyDriver := False;
    Writer := CreateLRSWriter(Bin, DestroyDriver);
    try
      Writer.OnWriteMethodProperty := @MW.WriteMethod;
      Writer.WriteDescendent(ADesigner.LookupRoot, nil);
    finally
      if DestroyDriver then Writer.Driver.Free;
      Writer.Free;
    end;
    Bin.Position := 0;
    LRSObjectBinaryToText(Bin, Txt);
    SetString(Result, PChar(Txt.Memory), Txt.Size);
  finally
    MW.Free;
    Txt.Free;
    Bin.Free;
  end;
end;

{ Name of the handler assigned to event AProp of AComp, '' when none. }
function EventHandlerName(AComp: TComponent; AProp: PPropInfo): string;
var
  M : TMethod;
begin
  M := GetMethodProp(AComp, AProp);
  if (M.Code = nil) and (M.Data = nil) then
    Exit('');
  Result := GlobalDesignHook.GetMethodName(M, AComp);
end;

{ ── Undo by snapshot ─────────────────────────────────────────────────────── }

{ Changes the designer's undo cannot replay property by property are
  recorded as a replacement of the whole component: a delete entry before the
  change (it streams the component as it is) and an add entry after it.  Undo
  deletes the changed component and inserts the old one; references other
  components held to it come back through McpRefKeeper.  A menu item is
  replaced with its whole menu. }

type
  TSnapshot = record
    Group   : TUndoGroup;
    Targets : array of TComponent;
  end;

{ The component to replace for a change of AComp, or nil when there is none:
  the form itself, inherited components and components of a frame cannot be
  deleted and inserted again. }
function SnapshotTarget(ARoot, AComp: TComponent): TComponent;
begin
  Result := AComp;
  if Result is TMenuItem then
    Result := TMenuItem(Result).GetParentMenu;
  if (Result = nil) or (Result = ARoot) or (Result.Owner <> ARoot) or
     (csAncestor in Result.ComponentState) then
    Result := nil;
end;

{ Record the delete entries for AComps.  False, with nothing recorded, when
  one of them has no snapshot target. }
function SnapBegin(out ASnap: TSnapshot; ADesigner: TIDesigner;
  const AComps: array of TComponent): Boolean;
var
  I, J, N : Integer;
  T       : TComponent;
  Dup     : Boolean;
begin
  ASnap.Group := NewUndoGroup(ADesigner);
  ASnap.Targets := nil;
  Result := ASnap.Group.Designer <> nil;
  if not Result then Exit;
  N := 0;
  for I := 0 to High(AComps) do
  begin
    T := SnapshotTarget(ADesigner.LookupRoot, AComps[I]);
    if T = nil then
    begin
      ASnap.Targets := nil;
      Exit(False);
    end;
    Dup := False;
    for J := 0 to N - 1 do
      Dup := Dup or (ASnap.Targets[J] = T);
    if Dup then Continue;
    SetLength(ASnap.Targets, N + 1);
    ASnap.Targets[N] := T;
    Inc(N);
  end;
  for I := 0 to N - 1 do
    AddUndo(ASnap.Group, ASnap.Targets[I], uopDelete, 'Name', ASnap.Targets[I].Name, '');
end;

{ Record the add entries, after the change. }
procedure SnapEnd(var ASnap: TSnapshot);
var
  I : Integer;
begin
  for I := 0 to High(ASnap.Targets) do
    AddUndo(ASnap.Group, ASnap.Targets[I], uopAdd, 'Name', '', ASnap.Targets[I].Name);
end;

{ Can every property in AProps be undone entry by entry (see UndoableEditor)? }
function AllNativeUndoable(AComp: TComponent; AProps: TJSONObject): Boolean;
var
  Pool   : TEditorPool;
  I      : Integer;
  Key    : string;
  Target : TPersistent;
  Rest, Err : string;
  Ed     : TPropertyEditor;
begin
  Result := True;
  Pool := TEditorPool.Create;
  try
    for I := 0 to AProps.Count - 1 do
    begin
      Key := AProps.Names[I];
      if SameText(Key, 'Parent') then Continue;
      { paths that do not resolve fail without changing anything }
      if not ResolveItemPath(AComp, Key, Target, Rest, Err) or (Rest = '') then Continue;
      Ed := ResolvePath(Pool, Target, Rest, Err);
      if Ed = nil then Continue;
      if EditsClass(Ed, TStrings) or not UndoableEditor(Ed) then
        Exit(False);
    end;
  finally
    Pool.Free;
  end;
end;

{ ── form_arrange ─────────────────────────────────────────────────────────── }

function ArrangeControls(ADesigner: TIDesigner; AParams: TJSONObject;
  out AErr: string): TJSONArray;
var
  Names     : TJSONArray;
  Ctls      : array of TControl;
  N, I      : Integer;
  First     : TControl;
  SameSize  : string;
  Distrib   : string;
  AlignTo   : string;
  ToParent  : Boolean;
  HasGap    : Boolean;
  Gap, Pos0 : Integer;
  Total     : Integer;
  C         : TComponent;
  Obj       : TJSONObject;
  RefL, RefT, RefR, RefB, RefW, RefH : Integer;
  Old       : array of TRect;
  Group     : TUndoGroup;
begin
  Result := nil;
  AErr   := '';
  Names := AParams.Get('components', TJSONArray(nil));
  if (Names = nil) or (Names.Count = 0) then
  begin
    AErr := 'components required';
    Exit;
  end;
  N := Names.Count;
  SetLength(Ctls, N);
  for I := 0 to N - 1 do
  begin
    C := FindComp(ADesigner, Names.Strings[I]);
    if not (C is TControl) then
    begin
      AErr := 'not a control on this form: ' + Names.Strings[I];
      Exit;
    end;
    Ctls[I] := TControl(C);
    if (I > 0) and (Ctls[I].Parent <> Ctls[0].Parent) then
    begin
      AErr := 'all components must have the same parent (' + Ctls[I].Name + ')';
      Exit;
    end;
  end;
  First    := Ctls[0];
  SameSize := AParams.Get('same_size', '');
  Distrib  := AParams.Get('distribute', '');
  AlignTo  := AParams.Get('align', '');
  ToParent := AParams.Get('relative_to', 'first') = 'parent';
  HasGap   := AParams.IndexOfName('spacing') >= 0;
  Gap      := AParams.Get('spacing', 0);
  if (SameSize = '') and (Distrib = '') and (AlignTo = '') then
  begin
    AErr := 'nothing to do: give same_size, distribute and/or align';
    Exit;
  end;
  { checked up front, so that the steps below either all run or none does }
  if (Distrib <> '') and not HasGap and (N < 3) then
  begin
    AErr := 'distribute without spacing needs at least 3 controls';
    Exit;
  end;
  if (AlignTo <> '') and (AnsiIndexStr(AlignTo,
       ['left', 'right', 'top', 'bottom', 'hcenter', 'vcenter']) < 0) then
  begin
    AErr := 'unknown align: ' + AlignTo;
    Exit;
  end;
  if (AlignTo <> '') and ToParent and (First.Parent = nil) then
  begin
    AErr := First.Name + ' has no parent';
    Exit;
  end;
  SetLength(Old, N);
  for I := 0 to N - 1 do
    Old[I] := Ctls[I].BoundsRect;

  { 1. size }
  for I := 1 to N - 1 do
  begin
    if (SameSize = 'width') or (SameSize = 'both') then
      Ctls[I].Width := First.Width;
    if (SameSize = 'height') or (SameSize = 'both') then
      Ctls[I].Height := First.Height;
  end;

  { 2. distribute }
  if Distrib <> '' then
  begin
    if HasGap then
    begin
      for I := 1 to N - 1 do
        if Distrib = 'horizontal' then
          Ctls[I].Left := Ctls[I - 1].Left + Ctls[I - 1].Width + Gap
        else
          Ctls[I].Top := Ctls[I - 1].Top + Ctls[I - 1].Height + Gap;
    end
    else
    begin
      Total := 0;
      for I := 0 to N - 1 do
        if Distrib = 'horizontal' then Inc(Total, Ctls[I].Width)
        else Inc(Total, Ctls[I].Height);
      if Distrib = 'horizontal' then
      begin
        Gap  := (Ctls[N - 1].Left + Ctls[N - 1].Width - First.Left - Total) div (N - 1);
        Pos0 := First.Left;
        for I := 1 to N - 2 do
        begin
          Pos0 := Pos0 + Ctls[I - 1].Width + Gap;
          Ctls[I].Left := Pos0;
        end;
      end
      else
      begin
        Gap  := (Ctls[N - 1].Top + Ctls[N - 1].Height - First.Top - Total) div (N - 1);
        Pos0 := First.Top;
        for I := 1 to N - 2 do
        begin
          Pos0 := Pos0 + Ctls[I - 1].Height + Gap;
          Ctls[I].Top := Pos0;
        end;
      end;
    end;
  end;

  { 3. align }
  if AlignTo <> '' then
  begin
    if ToParent then
    begin
      RefL := 0; RefT := 0;
      RefW := First.Parent.ClientWidth;
      RefH := First.Parent.ClientHeight;
    end
    else
    begin
      RefL := First.Left;  RefT := First.Top;
      RefW := First.Width; RefH := First.Height;
    end;
    RefR := RefL + RefW;
    RefB := RefT + RefH;
    for I := 0 to N - 1 do
    begin
      if (I = 0) and not ToParent then Continue;
      if AlignTo = 'left' then         Ctls[I].Left := RefL
      else if AlignTo = 'right' then   Ctls[I].Left := RefR - Ctls[I].Width
      else if AlignTo = 'top' then     Ctls[I].Top  := RefT
      else if AlignTo = 'bottom' then  Ctls[I].Top  := RefB - Ctls[I].Height
      else if AlignTo = 'hcenter' then Ctls[I].Left := RefL + (RefW - Ctls[I].Width) div 2
      else if AlignTo = 'vcenter' then Ctls[I].Top  := RefT + (RefH - Ctls[I].Height) div 2;
    end;
  end;

  { one undo step for the whole arrangement }
  Group := NewUndoGroup(ADesigner);
  for I := 0 to N - 1 do
  begin
    AddUndo(Group, Ctls[I], uopChange, 'Left',   IntToStr(Old[I].Left),   IntToStr(Ctls[I].Left));
    AddUndo(Group, Ctls[I], uopChange, 'Top',    IntToStr(Old[I].Top),    IntToStr(Ctls[I].Top));
    AddUndo(Group, Ctls[I], uopChange, 'Width',  IntToStr(Old[I].Width),  IntToStr(Ctls[I].Width));
    AddUndo(Group, Ctls[I], uopChange, 'Height', IntToStr(Old[I].Height), IntToStr(Ctls[I].Height));
  end;

  ADesigner.Modified;
  Result := TJSONArray.Create;
  for I := 0 to N - 1 do
  begin
    Obj := TJSONObject.Create;
    Obj.Add('name',   Ctls[I].Name);
    Obj.Add('left',   Ctls[I].Left);
    Obj.Add('top',    Ctls[I].Top);
    Obj.Add('width',  Ctls[I].Width);
    Obj.Add('height', Ctls[I].Height);
    Result.Add(Obj);
  end;
end;

{ ── Dispatch ─────────────────────────────────────────────────────────────── }

function IsFormTool(const Name: string): Boolean;
begin
  Result := (Name = 'form_list_components') or (Name = 'form_get_properties') or
            (Name = 'form_set_properties') or (Name = 'form_add_component') or
            (Name = 'form_delete_component') or (Name = 'form_arrange') or
            (Name = 'form_get_lfm') or (Name = 'form_create_event_handler') or
            (Name = 'form_list_collection_items') or (Name = 'form_add_collection_item') or
            (Name = 'form_delete_collection_item') or (Name = 'form_move_collection_item') or
            (Name = 'form_get_menu') or (Name = 'form_add_menu_item') or
            (Name = 'form_move_menu_item') or
            (Name = 'form_undo') or (Name = 'form_redo');
end;

{ form_*_collection_item and form_list_collection_items. }
procedure DoCollectionTool(const Name: string; ADesigner: TIDesigner;
  AComp: TComponent; var Ctx: TMcpToolCall);
var
  Coll      : TCollection;
  Item      : TCollectionItem;
  Err       : string;
  Obj, IObj : TJSONObject;
  Arr, Res  : TJSONArray;
  Pool      : TEditorPool;
  I, Idx, NewIdx, Failed : Integer;
  Props     : TJSONObject;
  Snap      : TSnapshot;
  Snapped   : Boolean;
begin
  Snapped := False;
  if AComp = nil then
  begin
    Ctx.Error := True; Ctx.Result := 'component_name required'; Exit;
  end;
  Coll := FindCollection(AComp, Ctx.Params.Get('property', ''), Err);
  if Coll = nil then
  begin
    Ctx.Error := True; Ctx.Result := Err; Exit;
  end;
  Obj := TJSONObject.Create;
  try
    Obj.Add('component_name', AComp.Name);
    Obj.Add('property', Ctx.Params.Get('property', ''));

    if Name = 'form_list_collection_items' then
    begin
      Obj.Add('collection_class', Coll.ClassName);
      Obj.Add('item_class', Coll.ItemClass.ClassName);
      Obj.Add('count', Coll.Count);
      Arr  := TJSONArray.Create;
      Obj.Add('items', Arr);
      Pool := TEditorPool.Create;
      try
        for I := 0 to Coll.Count - 1 do
        begin
          IObj := TJSONObject.Create;
          IObj.Add('index', I);
          IObj.Add('display_name', Coll.Items[I].DisplayName);
          if Ctx.Params.Get('include_properties', True) then
          begin
            Res := TJSONArray.Create;
            Pool.CollectTop(Coll.Items[I], tkProperties);
            ListLevel(Pool, '', 0, nil, Res);
            IObj.Add('properties', Res);
          end;
          Arr.Add(IObj);
        end;
      finally
        Pool.Free;
      end;
    end

    else if Name = 'form_add_collection_item' then
    begin
      Snapped := SnapBegin(Snap, ADesigner, [AComp]);
      Item := Coll.Add;
      Idx  := Ctx.Params.Get('index', -1);
      if (Idx >= 0) and (Idx < Coll.Count) then
        Item.Index := Idx;
      Props := Ctx.Params.Get('properties', TJSONObject(nil));
      Failed := 0;
      if Assigned(Props) and (Props.Count > 0) then
      begin
        Res := TJSONArray.Create;
        Obj.Add('results', Res);
        Failed := ApplyProperties(ADesigner, Item, Props, Res, nil);
        if Failed > 0 then
          Obj.Add('warning', IntToStr(Failed) + ' property assignment(s) failed; see results');
      end;
      Obj.Add('status', 'added');
      Obj.Add('index', Item.Index);
      Obj.Add('display_name', Item.DisplayName);
      Obj.Add('count', Coll.Count);
    end

    else if Name = 'form_delete_collection_item' then
    begin
      Idx := Ctx.Params.Get('index', -1);
      if (Idx < 0) or (Idx >= Coll.Count) then
      begin
        Ctx.Error := True;
        Ctx.Result := Format('index out of range (count %d)', [Coll.Count]);
        Exit;
      end;
      Obj.Add('display_name', Coll.Items[Idx].DisplayName);
      { The Object Inspector may show the item; never free it under its feet. }
      SelectOnly(AComp);
      Snapped := SnapBegin(Snap, ADesigner, [AComp]);
      Coll.Items[Idx].Free;
      Obj.Add('status', 'deleted');
      Obj.Add('count', Coll.Count);
    end

    else if Name = 'form_move_collection_item' then
    begin
      Idx    := Ctx.Params.Get('index', -1);
      NewIdx := Ctx.Params.Get('new_index', -1);
      if (Idx < 0) or (Idx >= Coll.Count) or (NewIdx < 0) or (NewIdx >= Coll.Count) then
      begin
        Ctx.Error := True;
        Ctx.Result := Format('index or new_index out of range (count %d)', [Coll.Count]);
        Exit;
      end;
      Snapped := SnapBegin(Snap, ADesigner, [AComp]);
      Coll.Items[Idx].Index := NewIdx;
      Obj.Add('status', 'moved');
      Obj.Add('display_name', Coll.Items[NewIdx].DisplayName);
      Obj.Add('index', NewIdx);
    end;

    if Name <> 'form_list_collection_items' then
    begin
      if Snapped then
        SnapEnd(Snap);
      Obj.Add('undoable', Snapped);
      GlobalDesignHook.Modified(Coll);
      GlobalDesignHook.RefreshPropertyValues;
      ADesigner.Modified;
    end;
    Ctx.Result := Obj.AsJSON;
  finally
    Obj.Free;
  end;
end;

{ form_get_menu, form_add_menu_item, form_move_menu_item. }
procedure DoMenuTool(const Name: string; ADesigner: TIDesigner;
  AComp: TComponent; var Ctx: TMcpToolCall);
var
  Root       : TComponent;
  Target     : TComponent;
  Items      : TMenuItem;
  MI         : TMenuItem;
  Obj, Props : TJSONObject;
  Given      : TJSONObject;
  Res        : TJSONArray;
  Idx, I, Failed : Integer;
  Caption, NewName : string;
  Walk       : TMenuItem;
  Snap       : TSnapshot;
  Snapped    : Boolean;
  MenuNames  : TStringList;
  MenuName   : string;
begin
  Root := ADesigner.LookupRoot;
  Target  := nil;
  Snapped := False;
  Obj  := TJSONObject.Create;
  try
    if Name = 'form_get_menu' then
    begin
      MenuNames := MenuNamesOf(Root);
      try
        MenuName := Ctx.Params.Get('menu_name', '');
        if (MenuName = '') and (MenuNames.Count = 1) then
          MenuName := MenuNames[0];   { the only menu of the form }
        Target := FindComp(ADesigner, MenuName);
        Items  := nil;
        if Assigned(Target) then
          Items := MenuItemsOf(Target);
        if Items = nil then
        begin
          Ctx.Error := True;
          if MenuNames.Count = 0 then
            Ctx.Result := 'This form has no menu (add a TMainMenu or TPopupMenu with form_add_component)'
          else if MenuName = '' then
            Ctx.Result := 'menu_name required: the menus of this form are ' + MenuNames.CommaText
          else
            Ctx.Result := 'Menu or menu item not found: ' + MenuName +
                          '. The menus of this form: ' + MenuNames.CommaText;
          Exit;
        end;
      finally
        MenuNames.Free;
      end;
      Obj.Add('menu_name',  Target.Name);
      Obj.Add('menu_class', Target.ClassName);
      Obj.Add('items', MenuTreeJSON(Items));
      Ctx.Result := Obj.AsJSON;
      Exit;
    end;

    if Name = 'form_add_menu_item' then
    begin
      Target := FindComp(ADesigner, Ctx.Params.Get('parent_name', ''));
      Items  := nil;
      if Assigned(Target) then
        Items := MenuItemsOf(Target);
      if Items = nil then
      begin
        Ctx.Error := True;
        Ctx.Result := 'parent_name must name a TMainMenu/TPopupMenu or a menu item: ' +
                      Ctx.Params.Get('parent_name', '');
        Exit;
      end;
      if not (ADesigner is TComponentEditorDesigner) then
      begin
        Ctx.Error := True; Ctx.Result := 'Designer cannot create menu items'; Exit;
      end;
      Obj.Add('menu_editor_hidden', HideMenuEditor);
      Snapped := SnapBegin(Snap, ADesigner, [Target]);
      Caption := Ctx.Params.Get('caption', '');
      MI := TMenuItem.Create(Root);
      if Caption = cLineCaption then
        NewName := 'Separator'
      else
        NewName := MI.ClassName;
      MI.Name    := TComponentEditorDesigner(ADesigner).CreateUniqueComponentName(NewName);
      MI.Caption := Caption;
      Idx := Ctx.Params.Get('index', -1);
      if (Idx < 0) or (Idx > Items.Count) then
        Idx := Items.Count;
      Items.Insert(Idx, MI);
      { adds the field to the class, as for a palette drop }
      GlobalDesignHook.PersistentAdded(MI, False);
      GlobalDesignHook.Modified(MI);
      Props := TJSONObject.Create;
      try
        Given := Ctx.Params.Get('properties', TJSONObject(nil));
        if Assigned(Given) then
          for I := 0 to Given.Count - 1 do
            if not SameText(Given.Names[I], 'Name') then
              Props.Add(Given.Names[I], Given.Items[I].Clone);
        if Ctx.Params.Get('name', '') <> '' then
          Props.Add('Name', Ctx.Params.Get('name', ''));
        if Props.Count > 0 then
        begin
          Res := TJSONArray.Create;
          Obj.Add('results', Res);
          Failed := ApplyProperties(ADesigner, MI, Props, Res, nil);
          if Failed > 0 then
            Obj.Add('warning', IntToStr(Failed) + ' property assignment(s) failed; see results');
        end;
      finally
        Props.Free;
      end;
      Obj.Add('status', 'added');
      Obj.Add('name',   MI.Name);
      Obj.Add('parent', MenuParentName(MI));
      Obj.Add('index',  MI.MenuIndex);
    end

    else if Name = 'form_move_menu_item' then
    begin
      if not (AComp is TMenuItem) then
      begin
        Ctx.Error := True; Ctx.Result := 'component_name must name a menu item'; Exit;
      end;
      MI := TMenuItem(AComp);
      Items := MI.Parent;
      if Ctx.Params.Get('parent_name', '') <> '' then
      begin
        Target := FindComp(ADesigner, Ctx.Params.Get('parent_name', ''));
        Items  := nil;
        if Assigned(Target) then
          Items := MenuItemsOf(Target);
        if Items = nil then
        begin
          Ctx.Error := True;
          Ctx.Result := 'parent_name must name a menu or a menu item: ' +
                        Ctx.Params.Get('parent_name', '');
          Exit;
        end;
        Walk := Items;  { refuse moving an item into itself or its own submenu }
        while Assigned(Walk) and (Walk <> MI) do
          Walk := Walk.Parent;
        if Walk = MI then
        begin
          Ctx.Error := True; Ctx.Result := 'cannot move a menu item into its own submenu'; Exit;
        end;
      end;
      if Items = nil then
      begin
        Ctx.Error := True; Ctx.Result := 'menu item has no parent'; Exit;
      end;
      Obj.Add('menu_editor_hidden', HideMenuEditor);
      if Assigned(Target) then
        Snapped := SnapBegin(Snap, ADesigner, [MI, Target])
      else
        Snapped := SnapBegin(Snap, ADesigner, [MI]);
      if Assigned(MI.Parent) then
        MI.Parent.Remove(MI);
      Idx := Ctx.Params.Get('index', -1);
      if (Idx < 0) or (Idx > Items.Count) then
        Idx := Items.Count;
      Items.Insert(Idx, MI);
      GlobalDesignHook.Modified(MI);
      Obj.Add('status', 'moved');
      Obj.Add('name',   MI.Name);
      Obj.Add('parent', MenuParentName(MI));
      Obj.Add('index',  MI.MenuIndex);
    end;

    if Snapped then
      SnapEnd(Snap);
    Obj.Add('undoable', Snapped);
    ADesigner.Modified;
    Ctx.Result := Obj.AsJSON;
  finally
    Obj.Free;
  end;
end;

function DispatchFormsTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  Designer     : TIDesigner;
  Root, Comp   : TComponent;
  Err          : string;
  Obj          : TJSONObject;
  Arr          : TJSONArray;
  Filter       : TStringList;
  NamesArr     : TJSONArray;
  Pool         : TEditorPool;
  Kinds        : TTypeKinds;
  I, Failed    : Integer;
  RegComp      : TRegisteredComponent;
  Query        : string;
  NewCompClass : string;
  ParentComp   : TComponent;
  NewComp      : TComponent;
  ALeft, ATop, AWidth, AHeight : Integer;
  Props        : TJSONObject;
  NameProps    : TJSONObject;
  Lfm          : string;
  Sel          : TPersistentSelectionList;
  PropInfo     : PPropInfo;
  EventName, HandlerName, ExistingName, EventSuffix : string;
  Ed           : TPropertyEditor;
  CEDesigner   : TComponentEditorDesigner;
  Ok           : Boolean;
  Group        : TUndoGroup;
  Snap         : TSnapshot;
  Others       : TJSONObject;
begin
  Result := False;

  { ── form_search_palette (no designer needed) ──────────────────────────── }
  if Name = 'form_search_palette' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('query', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'query required'; Exit;
    end;
    Query := LowerCase(Ctx.Params.Get('query', ''));
    Arr := TJSONArray.Create;
    try
      if Assigned(IDEComponentPalette) then
        for I := 0 to IDEComponentPalette.Comps.Count - 1 do
        begin
          RegComp := IDEComponentPalette.Comps[I];
          if Pos(Query, LowerCase(RegComp.ComponentClass.ClassName)) > 0 then
          begin
            Obj := TJSONObject.Create;
            Obj.Add('class_name', RegComp.ComponentClass.ClassName);
            Obj.Add('unit_name',  RegComp.GetUnitName);
            if Assigned(RegComp.RealPage) then
              Obj.Add('palette_page', RegComp.RealPage.PageName)
            else
              Obj.Add('palette_page', RegComp.OrigPageName);
            Arr.Add(Obj);
          end;
        end;
      Ctx.Result := Arr.AsJSON;
    finally
      Arr.Free;
    end;
    Exit;
  end;

  if not IsFormTool(Name) then Exit;
  Result := True;

  { ── Shared preamble: the form's designer ─────────────────────────────── }
  if not Assigned(Ctx.Params) or (Ctx.Params.Get('form_file', '') = '') then
  begin
    Ctx.Error := True; Ctx.Result := 'form_file argument required'; Exit;
  end;
  Designer := FindDesigner(Ctx.Params.Get('form_file', ''), Err);
  if Designer = nil then
  begin
    Ctx.Error := True; Ctx.Result := Err; Exit;
  end;
  Root := Designer.LookupRoot;

  Comp := nil;
  if Ctx.Params.Get('component_name', '') <> '' then
  begin
    Comp := FindComp(Designer, Ctx.Params.Get('component_name', ''));
    if Comp = nil then
    begin
      Ctx.Error := True;
      Ctx.Result := 'Component not found: ' + Ctx.Params.Get('component_name', '');
      Exit;
    end;
  end;

  if Pos('collection_item', Name) > 0 then
    DoCollectionTool(Name, Designer, Comp, Ctx)

  else if Pos('menu', Name) > 0 then
    DoMenuTool(Name, Designer, Comp, Ctx)

  else if Name = 'form_list_components' then
  begin
    Obj := TJSONObject.Create;
    try
      Obj.Add('root_name',  Root.Name);
      Obj.Add('root_class', Root.ClassName);
      if Root is TControl then
      begin
        Obj.Add('width',         TControl(Root).Width);
        Obj.Add('height',        TControl(Root).Height);
        Obj.Add('client_width',  TControl(Root).ClientWidth);
        Obj.Add('client_height', TControl(Root).ClientHeight);
      end;
      Arr := TJSONArray.Create;
      for I := 0 to Root.ComponentCount - 1 do
        Arr.Add(ControlInfo(Root.Components[I], Root));
      Obj.Add('components', Arr);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'form_get_properties' then
  begin
    if Comp = nil then
    begin
      Ctx.Error := True; Ctx.Result := 'component_name required'; Exit;
    end;
    Filter := TStringList.Create;
    Pool   := TEditorPool.Create;
    Obj    := TJSONObject.Create;
    try
      NamesArr := Ctx.Params.Get('names', TJSONArray(nil));
      if Assigned(NamesArr) then
        for I := 0 to NamesArr.Count - 1 do
          Filter.Add(NamesArr.Strings[I]);
      if Ctx.Params.Get('include_events', False) or (Filter.Count > 0) then
        Kinds := tkAny
      else
        Kinds := tkProperties;
      Obj.Add('component_name',  Comp.Name);
      Obj.Add('component_class', Comp.ClassName);
      Arr := TJSONArray.Create;
      Obj.Add('properties', Arr);
      Pool.CollectTop(Comp, Kinds);
      ListLevel(Pool, '', 0, Filter, Arr);
      ListAnchorSides(Pool, Comp, Kinds, Filter, Arr);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
      Pool.Free;
      Filter.Free;
    end;
  end

  else if Name = 'form_set_properties' then
  begin
    if Comp = nil then
    begin
      Ctx.Error := True; Ctx.Result := 'component_name required'; Exit;
    end;
    Props := Ctx.Params.Get('properties', TJSONObject(nil));
    if (Props = nil) or (Props.Count = 0) then
    begin
      Ctx.Error := True; Ctx.Result := 'properties object required'; Exit;
    end;
    Obj := TJSONObject.Create;
    try
      Arr := TJSONArray.Create;
      Obj.Add('component_name', Comp.Name);  { before a rename }
      if not AllNativeUndoable(Comp, Props) and SnapBegin(Snap, Designer, [Comp]) then
      begin
        { Name is changed after the replacement, as an entry of its own: undo
          renames back first (event handlers too), so each stream it inserts
          matches the names in the source. }
        Others := TJSONObject(Props.Clone);
        NameProps := TJSONObject.Create;
        try
          I := Others.IndexOfName('Name', True);
          if I >= 0 then
          begin
            NameProps.Add('Name', Others.Items[I].Clone);
            Others.Delete(I);
          end;
          Failed := ApplyProperties(Designer, Comp, Others, Arr, nil);
          SnapEnd(Snap);
          if NameProps.Count > 0 then
            Inc(Failed, ApplyProperties(Designer, Comp, NameProps, Arr, @Snap.Group));
        finally
          NameProps.Free;
          Others.Free;
        end;
        Obj.Add('undoable', True);
      end
      else
      begin
        Group := NewUndoGroup(Designer);
        Failed := ApplyProperties(Designer, Comp, Props, Arr, @Group);
        Ok := True;
        for I := 0 to Arr.Count - 1 do
          Ok := Ok and TJSONObject(Arr[I]).Get('undoable', True);
        Obj.Add('undoable', Ok);
      end;
      Obj.Add('results', Arr);
      Obj.Add('component_name_now', Comp.Name);
      Ctx.Error  := Failed = Props.Count;  { error only if nothing applied }
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'form_add_component' then
  begin
    NewCompClass := Ctx.Params.Get('class_name', '');
    if NewCompClass = '' then
    begin
      Ctx.Error := True; Ctx.Result := 'class_name required'; Exit;
    end;
    RegComp := nil;
    if Assigned(IDEComponentPalette) then
      for I := 0 to IDEComponentPalette.Comps.Count - 1 do
        if SameText(IDEComponentPalette.Comps[I].ComponentClass.ClassName, NewCompClass) then
        begin
          RegComp := IDEComponentPalette.Comps[I];
          Break;
        end;
    if RegComp = nil then
    begin
      Ctx.Error  := True;
      Ctx.Result := 'Component class not in IDE palette: ' + NewCompClass +
                    ' (use form_search_palette)';
      Exit;
    end;
    ParentComp := Root;
    if Ctx.Params.Get('parent_name', '') <> '' then
    begin
      ParentComp := FindComp(Designer, Ctx.Params.Get('parent_name', ''));
      if ParentComp = nil then
      begin
        Ctx.Error := True;
        Ctx.Result := 'Parent not found: ' + Ctx.Params.Get('parent_name', '');
        Exit;
      end;
    end;
    ALeft   := Ctx.Params.Get('left',   8);
    ATop    := Ctx.Params.Get('top',    8);
    AWidth  := Ctx.Params.Get('width',  0);   { 0 = class default }
    AHeight := Ctx.Params.Get('height', 0);
    NewComp := FormEditingHook.CreateComponent(ParentComp, RegComp.ComponentClass,
      RegComp.GetUnitName, ALeft, ATop, AWidth, AHeight, False);
    if NewComp = nil then
    begin
      Ctx.Error  := True;
      Ctx.Result := 'CreateComponent returned nil for: ' + NewCompClass;
      Exit;
    end;
    { What the designer does after a palette drop: the IDE adds the class
      field, the unit to the uses clause and the package dependency. }
    GlobalDesignHook.PersistentAdded(NewComp, False);
    Designer.Modified;
    Obj := TJSONObject.Create;
    NameProps := TJSONObject.Create;
    try
      Arr := TJSONArray.Create;
      { name last, after the requested properties }
      Props := Ctx.Params.Get('properties', TJSONObject(nil));
      if Assigned(Props) then
        for I := 0 to Props.Count - 1 do
          if not SameText(Props.Names[I], 'Name') then
            NameProps.Add(Props.Names[I], Props.Items[I].Clone);
      if Ctx.Params.Get('name', '') <> '' then
        NameProps.Add('Name', Ctx.Params.Get('name', ''));
      Failed := 0;
      if NameProps.Count > 0 then
        Failed := ApplyProperties(Designer, NewComp, NameProps, Arr, nil);
      { One undo step for the whole call, recorded with the final name and
        properties, as TDesigner.AddComponent does after a palette drop:
        undo deletes the component, redo inserts it again. }
      Group := NewUndoGroup(Designer);
      AddUndo(Group, NewComp, uopAdd, 'Name', '', NewComp.Name);
      Obj.Add('status', 'ok');
      Obj.Add('component', ControlInfo(NewComp, Root));
      if Arr.Count > 0 then
        Obj.Add('results', Arr)
      else
        Arr.Free;
      if Failed > 0 then
        Obj.Add('warning', IntToStr(Failed) + ' property assignment(s) failed; see results');
      Ctx.Result := Obj.AsJSON;
    finally
      NameProps.Free;
      Obj.Free;
    end;
  end

  else if Name = 'form_delete_component' then
  begin
    if Comp = nil then
    begin
      Ctx.Error := True; Ctx.Result := 'component_name required'; Exit;
    end;
    if Comp = Root then
    begin
      Ctx.Error := True; Ctx.Result := 'Cannot delete the form itself'; Exit;
    end;
    if Comp is TMenuItem then
    begin
      { the designer's DeleteSelection would leave the submenu's fields behind }
      Obj := TJSONObject.Create;
      try
        Obj.Add('menu_editor_hidden', HideMenuEditor);
        Obj.Add('component', Comp.Name);
        SelectOnly(Root);
        Ok := SnapBegin(Snap, Designer, [Comp]);   { the item's whole menu }
        DeleteMenuItem(TMenuItem(Comp));
        if Ok then
          SnapEnd(Snap);
        Designer.Modified;
        Obj.Add('status', 'deleted');
        Obj.Add('undoable', Ok);
        Ctx.Result := Obj.AsJSON;
      finally
        Obj.Free;
      end;
      Exit;
    end;
    if not (Designer is TComponentEditorDesigner) then
    begin
      Ctx.Error := True; Ctx.Result := 'Designer does not support deletion'; Exit;
    end;
    Err := Comp.Name;
    { Select through the property hook, as the Object Inspector does; the
      designer's control selection follows it. }
    Sel := TPersistentSelectionList.Create;
    try
      Sel.Add(Comp);
      GlobalDesignHook.SetSelection(Sel);
    finally
      Sel.Free;
    end;
    Designer.SelectOnlyThisComponent(Comp);
    TComponentEditorDesigner(Designer).DeleteSelection;
    Obj := TJSONObject.Create;
    try
      if FindComp(Designer, Err) = nil then
        Obj.Add('status', 'deleted')
      else
      begin
        Ctx.Error := True;
        Obj.Add('status', 'not deleted');
        Sel := TPersistentSelectionList.Create;
        try
          GlobalDesignHook.GetSelection(Sel);
          Obj.Add('selection_count', Sel.Count);
          if (Sel.Count > 0) and (Sel[0] is TComponent) then
            Obj.Add('selected', TComponent(Sel[0]).Name);
        finally
          Sel.Free;
        end;
      end;
      Obj.Add('component', Err);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'form_arrange' then
  begin
    Arr := ArrangeControls(Designer, Ctx.Params, Err);
    if Arr = nil then
    begin
      Ctx.Error := True; Ctx.Result := Err; Exit;
    end;
    try
      Ctx.Result := Arr.AsJSON;
    finally
      Arr.Free;
    end;
  end

  else if (Name = 'form_undo') or (Name = 'form_redo') then
  begin
    { What Edit > Undo / Redo does while the designer is active. }
    if not (Designer is TComponentEditorDesigner) then
    begin
      Ctx.Error := True; Ctx.Result := 'Designer does not support undo'; Exit;
    end;
    CEDesigner := TComponentEditorDesigner(Designer);
    Obj := TJSONObject.Create;
    try
      try
        if Name = 'form_undo' then
        begin
          Ok := CEDesigner.CanUndo and CEDesigner.Undo;
          if Ok then Obj.Add('status', 'undone') else Obj.Add('status', 'nothing to undo');
        end
        else
        begin
          Ok := CEDesigner.CanRedo and CEDesigner.Redo;
          if Ok then Obj.Add('status', 'redone') else Obj.Add('status', 'nothing to redo');
        end;
      except
        { an entry whose component is gone (renamed or deleted without an
          undo entry of its own) }
        on E: Exception do
        begin
          Ok := False;
          Obj.Add('status', 'failed');
          Obj.Add('error', E.Message);
        end;
      end;
      Ctx.Error := not Ok;
      Obj.Add('can_undo', CEDesigner.CanUndo);
      Obj.Add('can_redo', CEDesigner.CanRedo);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'form_get_lfm' then
  begin
    try
      Lfm := DesignerLfm(Designer);
    except
      on E: Exception do
      begin
        Ctx.Error := True; Ctx.Result := 'Could not stream the form: ' + E.Message; Exit;
      end;
    end;
    if Assigned(Comp) and (Comp <> Root) then
      Lfm := ExtractObjectBlock(Lfm, Comp.Name);
    Ctx.Result := Lfm;
  end

  else if Name = 'form_create_event_handler' then
  begin
    EventName := Ctx.Params.Get('event_name', '');
    if (Comp = nil) or (EventName = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'component_name and event_name required'; Exit;
    end;
    PropInfo := GetPropInfo(Comp.ClassInfo, EventName);
    if PropInfo = nil then
    begin
      Ctx.Error := True; Ctx.Result := 'Event property not found: ' + EventName; Exit;
    end;
    if PropInfo^.PropType^.Kind <> tkMethod then
    begin
      Ctx.Error := True; Ctx.Result := EventName + ' is not an event property'; Exit;
    end;

    { If already assigned, navigate to existing handler.  The designer's
      methods are JIT methods: Code can be nil with only Data set, so ask the
      design hook for the name. }
    ExistingName := EventHandlerName(Comp, PropInfo);
    if ExistingName <> '' then
    begin
      GlobalDesignHook.ShowMethod(ExistingName);
      Obj := TJSONObject.Create;
      try
        Obj.Add('status',       'existing');
        Obj.Add('handler_name', ExistingName);
        Ctx.Result := Obj.AsJSON;
      finally
        Obj.Free;
      end;
      Exit;
    end;

    { Generate default handler name if not supplied }
    HandlerName := Ctx.Params.Get('handler_name', '');
    if HandlerName = '' then
    begin
      EventSuffix := EventName;
      if (Length(EventSuffix) > 2) and
         (LowerCase(Copy(EventSuffix, 1, 2)) = 'on') then
        EventSuffix := Copy(EventSuffix, 3, MaxInt);
      if Comp = Root then
        HandlerName := Root.Name + EventSuffix
      else
        HandlerName := Comp.Name + EventSuffix;
    end;

    { Through the event's property editor, as the Object Inspector does: it
      reuses a method of that name or creates the stub in the source. }
    Err := '';
    Ok := SnapBegin(Snap, Designer, [Comp]);   { undo unassigns the event; the method stays }
    Pool := TEditorPool.Create;
    try
      try
        Ed := ResolvePath(Pool, Comp, EventName, Err);
        if Assigned(Ed) then
          Ed.SetValue(HandlerName);
      except
        on E: Exception do Err := E.Message;
      end;
    finally
      Pool.Free;
      if Ok then
        SnapEnd(Snap);
    end;
    if not SameText(EventHandlerName(Comp, PropInfo), HandlerName) then
    begin
      Ctx.Error := True;
      Ctx.Result := 'Failed to create handler: ' + HandlerName;
      if Err <> '' then
        Ctx.Result := Ctx.Result + ': ' + Err;
      Exit;
    end;
    Designer.Modified;
    GlobalDesignHook.ShowMethod(HandlerName);

    Obj := TJSONObject.Create;
    try
      Obj.Add('status',       'created');
      Obj.Add('handler_name', HandlerName);
      Obj.Add('undoable',     Ok);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end;
end;

{ ── Schema registration ──────────────────────────────────────────────────── }

procedure RegisterFormsSchemas(Tools: TJSONArray);
begin
  Tools.Add(MakeTool('form_list_components',
    'List every component on a form with class, parent, bounds and key ' +
    'properties, plus the form''s size. Opens the form in the designer if needed.',
    SCHEMA_FORM_LIST_COMPONENTS, MCP_ANN_RO));
  Tools.Add(MakeTool('form_get_properties',
    'Read a component''s published properties as the Object Inspector shows them, ' +
    'nested ones as dotted paths (BorderSpacing.Around, Font.Style).',
    SCHEMA_FORM_GET_PROPERTIES, MCP_ANN_RO));
  Tools.Add(MakeTool('form_set_properties',
    'Set component properties through the Object Inspector''s property editors. ' +
    'For layout prefer Align, Anchors, AnchorSide*, BorderSpacing.* and the ' +
    'container''s ChildSizing.* to pixel positions. Save with editor_save.',
    SCHEMA_FORM_SET_PROPERTIES, MCP_ANN_WRITE_IDEM));
  Tools.Add(MakeTool('form_add_component',
    'Add a component from the IDE palette to a form, optionally inside a container, ' +
    'with a given name and initial properties (same format as form_set_properties). ' +
    'Use form_search_palette to find class names. Save with editor_save.',
    SCHEMA_FORM_ADD_COMPONENT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('form_delete_component',
    'Delete a component (and its child controls) from a form, as the designer''s ' +
    'Delete command does; its field is removed from the source. Also deletes menu ' +
    'items with their submenus. form_undo brings it back. Save with editor_save.',
    SCHEMA_FORM_DELETE_COMPONENT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('form_arrange',
    'Arrange controls that share a parent: same_size, then distribute, then ' +
    'align. Returns the new bounds.',
    SCHEMA_FORM_ARRANGE, MCP_ANN_WRITE_IDEM));
  Tools.Add(MakeTool('form_get_lfm',
    'Return the form as LFM text from the live designer state (including unsaved ' +
    'changes) — the most compact view of the whole layout. Pass component_name ' +
    'to get only that component''s object block.',
    SCHEMA_FORM_GET_LFM, MCP_ANN_RO));
  Tools.Add(MakeTool('form_create_event_handler',
    'Create an event handler stub for a component event and show it in the ' +
    'source editor. If a handler is already assigned, shows the existing one and ' +
    'returns status=existing. Save the unit with editor_save.',
    SCHEMA_FORM_CREATE_EVENT_HANDLER, MCP_ANN_WRITE));
  Tools.Add(MakeTool('form_list_collection_items',
    'List the items of a collection property (ListView Columns, StatusBar Panels, ' +
    '...). Edit them with form_set_properties and indexed paths: Columns[0].Caption.',
    SCHEMA_FORM_LIST_COLLECTION_ITEMS, MCP_ANN_RO));
  Tools.Add(MakeTool('form_add_collection_item',
    'Add an item to a collection property (Columns, Panels, Sections, Bands, ...), ' +
    'optionally at an index and with initial properties, as the IDE''s collection ' +
    'editor does. Returns the new item''s index. Save with editor_save.',
    SCHEMA_FORM_ADD_COLLECTION_ITEM, MCP_ANN_WRITE));
  Tools.Add(MakeTool('form_delete_collection_item',
    'Delete the item at index from a collection property. Later items shift down ' +
    'by one. form_undo brings it back. Save with editor_save.',
    SCHEMA_FORM_DELETE_COLLECTION_ITEM, MCP_ANN_WRITE));
  Tools.Add(MakeTool('form_move_collection_item',
    'Move a collection item from index to new_index (e.g. reorder grid columns). ' +
    'Save with editor_save.',
    SCHEMA_FORM_MOVE_COLLECTION_ITEM, MCP_ANN_WRITE));
  Tools.Add(MakeTool('form_get_menu',
    'Return the item tree of a TMainMenu/TPopupMenu or submenu. Edit items with ' +
    'form_set_properties; delete them (with submenus) with form_delete_component.',
    SCHEMA_FORM_GET_MENU, MCP_ANN_RO));
  Tools.Add(MakeTool('form_add_menu_item',
    'Add an item to a TMainMenu/TPopupMenu or a submenu. Closes the IDE''s Menu ' +
    'Editor if open. Save with editor_save.',
    SCHEMA_FORM_ADD_MENU_ITEM, MCP_ANN_WRITE));
  Tools.Add(MakeTool('form_move_menu_item',
    'Move a menu item (with its submenu) to another position and/or another parent ' +
    'menu or menu item. Closes the IDE''s Menu Editor window if open. Save with editor_save.',
    SCHEMA_FORM_MOVE_MENU_ITEM, MCP_ANN_WRITE));
  Tools.Add(MakeTool('form_search_palette',
    'Search the IDE component palette for classes whose name contains query. ' +
    'Returns class_name, unit_name and palette_page for each match.',
    SCHEMA_FORM_SEARCH_PALETTE, MCP_ANN_RO));
  Tools.Add(MakeTool('form_undo',
    'Undo the last change on a form, as Edit > Undo in the designer: one step of ' +
    'the designer''s undo list, shared with the user and other clients. Returns ' +
    'can_undo and can_redo.',
    SCHEMA_FORM_LIST_COMPONENTS, MCP_ANN_WRITE));
  Tools.Add(MakeTool('form_redo',
    'Redo the last undone change on a form, as Edit > Redo in the designer. ' +
    'Returns can_undo and can_redo.',
    SCHEMA_FORM_LIST_COMPONENTS, MCP_ANN_WRITE));
end;

initialization
  RegisterMcpGroup(@DispatchFormsTool);
  RegisterMcpSchemas(@RegisterFormsSchemas);

end.
