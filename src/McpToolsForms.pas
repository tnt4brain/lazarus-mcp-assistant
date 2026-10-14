{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsForms;

{ Form designer tools: form_list_components, form_get_properties,
  form_set_properties, form_add_component, form_delete_component,
  form_arrange, form_get_lfm, form_create_event_handler, form_search_palette.

  Property access goes through the Object Inspector's property editors
  (PropEdits), so values read and write exactly as in the Object Inspector:
    - nested properties by dotted path: BorderSpacing.Around, Font.Style,
      Constraints.MinWidth, AnchorSideLeft.Control, ChildSizing.Layout
    - enums and sets as text: alClient, [akLeft,akTop], [fsBold]
    - component references by name: PopupMenu1
    - events by handler name: the handler is created when it does not exist
    - Name: renames the component and its field/references in the source
  "Parent" is accepted as a pseudo-property to move a control into another
  container.  Everything runs on the IDE main thread. }

{$mode objfpc}{$H+}

interface

implementation

uses
  Classes, SysUtils, Math,
  LazIDEIntf, SrcEditorIntf, LazFileUtils,
  Controls, Forms, FormEditingIntf, ComponentEditors,
  TypInfo, LResources,
  ComponentReg, PropEdits,
  fpjson,
  McpToolContext;

{ ── Schema constants ─────────────────────────────────────────────────────── }

const
  FORM_FILE_PROP =
    '"form_file":{"type":"string","description":"Absolute path to the form''s .lfm (or its .pas unit)"}';

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
    '"properties":{"type":"object","additionalProperties":{"type":["string","number","boolean"]},' +
      '"description":"Map of property path to value as the Object Inspector shows it, e.g. ' +
      '{\"Caption\":\"OK\",\"Align\":\"alBottom\",\"Anchors\":\"[akRight,akBottom]\",' +
      '\"BorderSpacing.Around\":6,\"Font.Style\":\"[fsBold]\",\"OnClick\":\"btnOKClick\",' +
      '\"Parent\":\"Panel1\",\"Name\":\"btnOK\"}. Parent moves the control into another container; ' +
      'Name renames it in the source as well. Applied in order Parent, others, Name."}},' +
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
  except
    on E: Exception do Result := '(unreadable: ' + E.Message + ')';
  end;
end;

{ Resolve a dotted property path ('BorderSpacing.Around') to its editor. }
function ResolvePath(Pool: TEditorPool; AItem: TPersistent;
  const APath: string; out AErr: string): TPropertyEditor;
var
  Rest, Part : string;
  P          : Integer;
begin
  Result := nil;
  AErr   := '';
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
        { sets and sub-objects report paReadOnly for their text field, yet
          are settable as text / via their sub-properties }
        if (paReadOnly in Ed.GetAttributes) and
           not (paSubProperties in Ed.GetAttributes) then
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
  { Designers belong to the unit's source editor, so look for the .pas }
  PasFile := AFormFile;
  if SameText(ExtractFileExt(PasFile), '.lfm') then
  begin
    PasFile := ChangeFileExt(AFormFile, '.pas');
    if not FileExists(PasFile) and FileExists(ChangeFileExt(AFormFile, '.pp')) then
      PasFile := ChangeFileExt(AFormFile, '.pp');
  end;
  Ed := FindEditorFor(PasFile);
  if Ed = nil then
  begin
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

{ Apply AProps to AComp; one result entry per property.  Returns the number
  of failures. }
function ApplyProperties(ADesigner: TIDesigner; AComp: TComponent;
  AProps: TJSONObject; AResults: TJSONArray): Integer;
var
  Pool    : TEditorPool;
  Pass, I : Integer;
  Key     : string;
  Val     : string;
  Ed      : TPropertyEditor;
  Err     : string;
  R       : TJSONObject;
begin
  Result := 0;
  if AProps = nil then Exit;
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
        try
          if Pass = 0 then
          begin
            if SetParentOf(ADesigner, AComp, Val, Err) then
              R.Add('value', TControl(AComp).Parent.Name);
          end
          else
          begin
            Ed := ResolvePath(Pool, AComp, Key, Err);
            if Assigned(Ed) then
            begin
              if (paReadOnly in Ed.GetAttributes) and not (paSubProperties in Ed.GetAttributes) then
                Err := 'read-only property'
              else
              begin
                Ed.SetValue(Val);
                R.Add('value', SafeValue(Ed));
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
        end;
        AResults.Add(R);
      end;
  finally
    Pool.Free;
  end;
  ADesigner.Modified;
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
    else if N >= 3 then
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
    end
    else
    begin
      AErr := 'distribute without spacing needs at least 3 controls';
      Exit;
    end;
  end;

  { 3. align }
  if AlignTo <> '' then
  begin
    if ToParent then
    begin
      if First.Parent = nil then
      begin
        AErr := First.Name + ' has no parent';
        Exit;
      end;
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
      else if AlignTo = 'vcenter' then Ctls[I].Top  := RefT + (RefH - Ctls[I].Height) div 2
      else
      begin
        AErr := 'unknown align: ' + AlignTo;
        Exit;
      end;
    end;
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
            (Name = 'form_get_lfm') or (Name = 'form_create_event_handler');
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
  Method       : TMethod;
  MethodAddr   : Pointer;
  NewMethod    : TMethod;
  EventName, HandlerName, ExistingName, EventSuffix : string;
  MethCompatible, MethPublished, IdentIsMethod : Boolean;
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

  if Name = 'form_list_components' then
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
      Failed := ApplyProperties(Designer, Comp, Props, Arr);
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
        Failed := ApplyProperties(Designer, NewComp, NameProps, Arr);
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

    { If already assigned, navigate to existing handler }
    Method := GetMethodProp(Comp, PropInfo);
    if Method.Code <> nil then
    begin
      ExistingName := Root.MethodName(Method.Code);
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

    { Reuse existing method or create a new stub }
    if GlobalDesignHook.MethodExists(HandlerName, GetTypeData(PropInfo^.PropType),
                                     MethCompatible, MethPublished, IdentIsMethod) then
    begin
      MethodAddr := Root.MethodAddress(HandlerName);
      NewMethod.Code := MethodAddr;
      NewMethod.Data := Root;
    end
    else
      NewMethod := GlobalDesignHook.CreateMethod(HandlerName, PropInfo^.PropType,
                                                 Root, PropInfo^.PropType^.Name);

    if NewMethod.Code = nil then
    begin
      Ctx.Error := True;
      Ctx.Result := 'Failed to create handler: ' + HandlerName;
      Exit;
    end;

    SetMethodProp(Comp, PropInfo, NewMethod);
    Designer.Modified;
    GlobalDesignHook.ShowMethod(HandlerName);

    Obj := TJSONObject.Create;
    try
      Obj.Add('status',       'created');
      Obj.Add('handler_name', HandlerName);
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
    'List every component on a form with class, parent, bounds (left/top/width/' +
    'height), Align, Anchors, Visible, Caption/Text and TabOrder; non-visual ' +
    'components are flagged. Also returns the form''s size and client size. ' +
    'Opens the form in the designer if needed.',
    SCHEMA_FORM_LIST_COMPONENTS, MCP_ANN_RO));
  Tools.Add(MakeTool('form_get_properties',
    'Read a component''s published properties as the Object Inspector shows them, ' +
    'including nested ones as dotted paths (BorderSpacing.Around, Font.Style, ' +
    'AnchorSideLeft.Control, ChildSizing.Layout). Pass names to read only some ' +
    'properties; then enum/set/reference properties also return their allowed values.',
    SCHEMA_FORM_GET_PROPERTIES, MCP_ANN_RO));
  Tools.Add(MakeTool('form_set_properties',
    'Set one or more properties on a component through the Object Inspector''s ' +
    'property editors: dotted paths for nested properties, enums/sets as text, ' +
    'component references by name, events by handler name (created if missing). ' +
    'Name renames the component in the source too; Parent moves it into another ' +
    'container. Use BorderSpacing.*, Anchors, AnchorSide*.Control/Side, Align ' +
    'and the container''s ChildSizing.* for layout and spacing. Returns one result ' +
    'per property. Changes are in the designer; save with editor_save.',
    SCHEMA_FORM_SET_PROPERTIES, MCP_ANN_WRITE));
  Tools.Add(MakeTool('form_add_component',
    'Add a component from the IDE palette to a form, optionally inside a container, ' +
    'with a given name and initial properties (same format as form_set_properties). ' +
    'Use form_search_palette to find class names. Save with editor_save.',
    SCHEMA_FORM_ADD_COMPONENT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('form_delete_component',
    'Delete a component (and its child controls) from a form, as the designer''s ' +
    'Delete command does; its field is removed from the source. Save with editor_save.',
    SCHEMA_FORM_DELETE_COMPONENT, MCP_ANN_DEST));
  Tools.Add(MakeTool('form_arrange',
    'Arrange controls that share a parent: copy the first control''s size ' +
    '(same_size), place them one after another with a fixed gap or spread them ' +
    'evenly (distribute, spacing), and align edges or centres to the first ' +
    'control or to the parent (align, relative_to). Applied in that order. ' +
    'Returns the new bounds.',
    SCHEMA_FORM_ARRANGE, MCP_ANN_WRITE));
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
  Tools.Add(MakeTool('form_search_palette',
    'Search the IDE component palette for classes whose name contains query. ' +
    'Returns class_name, unit_name and palette_page for each match.',
    SCHEMA_FORM_SEARCH_PALETTE, MCP_ANN_RO));
end;

initialization
  RegisterMcpGroup(@DispatchFormsTool);
  RegisterMcpSchemas(@RegisterFormsSchemas);

end.
