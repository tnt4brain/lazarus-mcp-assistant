{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsForms;

{ Form designer tools: get_form_components, get_component_properties,
  set_component_property, search_components.
  All three form tools share a designer-opening preamble. }

{$mode objfpc}{$H+}

interface

implementation

uses
  Classes, SysUtils,
  LazIDEIntf, SrcEditorIntf, LazFileUtils,
  Forms, FormEditingIntf,
  TypInfo, Variants,
  ComponentReg,
  fpjson,
  McpToolContext;

{ ── Schema constants ─────────────────────────────────────────────────────── }

const
  SCHEMA_GET_FORM_COMPONENTS =
    '{"type":"object","properties":{' +
    '"form_file":{"type":"string","description":"Absolute path to the .lfm form file"}},' +
    '"required":["form_file"]}';

  SCHEMA_GET_COMPONENT_PROPERTIES =
    '{"type":"object","properties":{' +
    '"component_name":{"type":"string","description":"Component name as it appears in the form (e.g. btnOK)"},' +
    '"form_file":{"type":"string","description":"Absolute path to the .lfm form file"}},' +
    '"required":["component_name","form_file"]}';

  SCHEMA_SET_COMPONENT_PROPERTY =
    '{"type":"object","properties":{' +
    '"component_name":{"type":"string","description":"Component name (e.g. btnOK)"},' +
    '"prop_name":{"type":"string","description":"Property name (e.g. Caption)"},' +
    '"prop_value":{"type":"string","description":"New value as a string; numeric and boolean are coerced"},' +
    '"form_file":{"type":"string","description":"Absolute path to the .lfm form file"}},' +
    '"required":["component_name","prop_name","prop_value","form_file"]}';

  SCHEMA_SEARCH_COMPONENTS =
    '{"type":"object","properties":{' +
    '"query":{"type":"string","description":"Substring to match against component class names (case-insensitive)"}},' +
    '"required":["query"]}';

{ ── Dispatch ─────────────────────────────────────────────────────────────── }

function DispatchFormsTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  FormFile    : string;
  CompName    : string;
  PropName    : string;
  PropValue   : string;
  Designer    : TIDesigner;
  Comp        : TComponent;
  PropList    : PPropList;
  PropCount   : Integer;
  PropInfo    : PPropInfo;
  PropVal     : string;
  Method      : TMethod;
  MethodAddr  : Pointer;
  Obj         : TJSONObject;
  CompObj     : TJSONObject;
  Arr         : TJSONArray;
  Ed          : TSourceEditorInterface;
  RegComp     : TRegisteredComponent;
  Query       : string;
  I, J        : Integer;
begin
  Result := False;

  { ── Form-tool preamble (shared by the three designer tools) ──────────── }
  if (Name = 'get_form_components') or
     (Name = 'get_component_properties') or
     (Name = 'set_component_property') then
  begin
    Result := True;
    if not Assigned(FormEditingHook) then
    begin
      Ctx.Error := True; Ctx.Result := 'FormEditingHook is nil'; Exit;
    end;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('form_file', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'form_file argument required'; Exit;
    end;
    FormFile := Ctx.Params.Get('form_file', '');

    { Find an already-open designer for this LFM }
    Designer := nil;
    for I := 0 to FormEditingHook.DesignerCount - 1 do
      if Assigned(FormEditingHook.Designer[I]) and
         Assigned(FormEditingHook.Designer[I].LookupRoot) then
        for J := 0 to SourceEditorManagerIntf.SourceEditorCount - 1 do
          if CompareFilenames(SourceEditorManagerIntf.SourceEditors[J].FileName,
                              FormFile) = 0 then
          begin
            Designer := FormEditingHook.Designer[I];
            Break;
          end;

    { If not found, open the LFM and activate the designer }
    if not Assigned(Designer) then
    begin
      Ed := nil;
      for J := 0 to SourceEditorManagerIntf.SourceEditorCount - 1 do
        if CompareFilenames(SourceEditorManagerIntf.SourceEditors[J].FileName,
                            FormFile) = 0 then
        begin
          Ed := SourceEditorManagerIntf.SourceEditors[J];
          Break;
        end;
      if not Assigned(Ed) then
      begin
        LazarusIDE.DoOpenEditorFile(FormFile, -1, -1, [ofOnlyIfExists]);
        for J := 0 to SourceEditorManagerIntf.SourceEditorCount - 1 do
          if CompareFilenames(SourceEditorManagerIntf.SourceEditors[J].FileName,
                              FormFile) = 0 then
          begin
            Ed := SourceEditorManagerIntf.SourceEditors[J];
            Break;
          end;
      end;
      if Assigned(Ed) then
        LazarusIDE.DoShowDesignerFormOfSrc(Ed);
      { Search again after opening }
      for I := 0 to FormEditingHook.DesignerCount - 1 do
        if Assigned(FormEditingHook.Designer[I]) and
           Assigned(FormEditingHook.Designer[I].LookupRoot) then
          for J := 0 to SourceEditorManagerIntf.SourceEditorCount - 1 do
            if CompareFilenames(SourceEditorManagerIntf.SourceEditors[J].FileName,
                                FormFile) = 0 then
            begin
              Designer := FormEditingHook.Designer[I];
              Break;
            end;
      if not Assigned(Designer) and (FormEditingHook.DesignerCount > 0) then
        Designer := FormEditingHook.Designer[0];
    end;

    if not Assigned(Designer) then
    begin
      Ctx.Error  := True;
      Ctx.Result := 'Could not open or find designer for: ' + FormFile;
      Exit;
    end;

    { ── Per-tool handlers ────────────────────────────────────────────── }

    if Name = 'get_form_components' then
    begin
      Obj := TJSONObject.Create;
      try
        Obj.Add('root_name',       Designer.LookupRoot.Name);
        Obj.Add('root_class',      Designer.LookupRoot.ClassName);
        Obj.Add('component_count', Designer.LookupRoot.ComponentCount);
        Arr := TJSONArray.Create;
        for I := 0 to Designer.LookupRoot.ComponentCount - 1 do
        begin
          CompObj := TJSONObject.Create;
          CompObj.Add('name',  Designer.LookupRoot.Components[I].Name);
          CompObj.Add('class', Designer.LookupRoot.Components[I].ClassName);
          Arr.Add(CompObj);
        end;
        Obj.Add('components', Arr);
        Ctx.Result := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    end

    else if Name = 'get_component_properties' then
    begin
      CompName := Ctx.Params.Get('component_name', '');
      if CompName = '' then
      begin
        Ctx.Error := True; Ctx.Result := 'component_name argument required'; Exit;
      end;
      Comp := Designer.LookupRoot.FindComponent(CompName);
      if Comp = nil then
        Comp := Designer.LookupRoot;
      if (Comp = nil) or not SameText(Comp.Name, CompName) then
      begin
        if SameText(Designer.LookupRoot.Name, CompName) then
          Comp := Designer.LookupRoot
        else
        begin
          Ctx.Error := True; Ctx.Result := 'Component not found: ' + CompName; Exit;
        end;
      end;
      PropCount := GetPropList(Comp.ClassInfo, tkAny, nil);
      GetMem(PropList, PropCount * SizeOf(Pointer));
      try
        GetPropList(Comp.ClassInfo, tkAny, PropList);
        Obj := TJSONObject.Create;
        try
          Obj.Add('component_name',  Comp.Name);
          Obj.Add('component_class', Comp.ClassName);
          Arr := TJSONArray.Create;
          for I := 0 to PropCount - 1 do
          begin
            PropInfo := PropList^[I];
            CompObj := TJSONObject.Create;
            CompObj.Add('name', PropInfo^.Name);
            CompObj.Add('type', GetEnumName(TypeInfo(TTypeKind),
                                    Integer(PropInfo^.PropType^.Kind)));
            try
              PropVal := VarToStr(GetPropValue(Comp, PropInfo^.Name, True));
              CompObj.Add('value', PropVal);
            except
              CompObj.Add('value', '(unreadable)');
            end;
            Arr.Add(CompObj);
          end;
          Obj.Add('properties', Arr);
          Ctx.Result := Obj.AsJSON;
        finally
          Obj.Free;
        end;
      finally
        FreeMem(PropList);
      end;
    end

    else if Name = 'set_component_property' then
    begin
      CompName  := Ctx.Params.Get('component_name', '');
      PropName  := Ctx.Params.Get('prop_name',      '');
      PropValue := Ctx.Params.Get('prop_value',     '');
      if (CompName = '') or (PropName = '') then
      begin
        Ctx.Error := True; Ctx.Result := 'component_name and prop_name are required'; Exit;
      end;
      Comp := Designer.LookupRoot.FindComponent(CompName);
      if (Comp = nil) and SameText(Designer.LookupRoot.Name, CompName) then
        Comp := Designer.LookupRoot;
      if Comp = nil then
      begin
        Ctx.Error := True; Ctx.Result := 'Component not found: ' + CompName; Exit;
      end;
      PropInfo := GetPropInfo(Comp.ClassInfo, PropName);
      if PropInfo = nil then
      begin
        Ctx.Error := True; Ctx.Result := 'Property not found: ' + PropName; Exit;
      end;
      try
        if PropInfo^.PropType^.Kind = tkMethod then
        begin
          if PropValue = '' then
          begin
            Method.Code := nil;
            Method.Data := nil;
          end
          else
          begin
            MethodAddr := Designer.LookupRoot.MethodAddress(PropValue);
            if MethodAddr = nil then
            begin
              Ctx.Error := True; Ctx.Result := 'Method not found on form: ' + PropValue; Exit;
            end;
            Method.Code := MethodAddr;
            Method.Data := Designer.LookupRoot;
          end;
          SetMethodProp(Comp, PropInfo, Method);
        end
        else
          SetPropValue(Comp, PropName, PropValue);
        Designer.Modified;
        Obj := TJSONObject.Create;
        try
          Obj.Add('status',         'ok');
          Obj.Add('component_name', CompName);
          Obj.Add('prop_name',      PropName);
          if PropInfo^.PropType^.Kind = tkMethod then
          begin
            Method := GetMethodProp(Comp, PropInfo);
            if Method.Code <> nil then
              Obj.Add('new_value', Designer.LookupRoot.MethodName(Method.Code))
            else
              Obj.Add('new_value', '');
          end
          else
            Obj.Add('new_value', VarToStr(GetPropValue(Comp, PropName, True)));
          Ctx.Result := Obj.AsJSON;
        finally
          Obj.Free;
        end;
      except
        on E: Exception do
        begin
          Ctx.Error  := True;
          Ctx.Result := 'Error setting property: ' + E.Message;
        end;
      end;
    end;

    Exit; { done with the preamble block }
  end;

  { ── search_components (no preamble needed) ─────────────────────────────── }

  if Name = 'search_components' then
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
  end;
end;

{ ── Schema registration ──────────────────────────────────────────────────── }

procedure RegisterFormsSchemas(Tools: TJSONArray);
begin
  Tools.Add(MakeTool('get_form_components',
    'Return the component tree for a form: root class/name and all owned ' +
    'components with their name and class. Opens the form in the designer ' +
    'if it is not already open.',
    SCHEMA_GET_FORM_COMPONENTS));
  Tools.Add(MakeTool('get_component_properties',
    'Return all published RTTI properties and their current values for a ' +
    'named component on a form. Opens the form in the designer if needed.',
    SCHEMA_GET_COMPONENT_PROPERTIES));
  Tools.Add(MakeTool('set_component_property',
    'Set a published RTTI property on a form component to a new value. ' +
    'Marks the designer modified so the change is saved with the form. ' +
    'Opens the form in the designer if needed. ' +
    'WARNING: changes the live designer state; use save_file to persist to disk.',
    SCHEMA_SET_COMPONENT_PROPERTY));
  Tools.Add(MakeTool('search_components',
    'Search the IDE Component Class Registry (CCR) for components whose class name ' +
    'contains the query string. Returns class_name, unit_name, and palette_page for each match. ' +
    'Use this to find which unit and palette page a component lives on before adding it.',
    SCHEMA_SEARCH_COMPONENTS));
end;

initialization
  RegisterMcpGroup(@DispatchFormsTool);
  RegisterMcpSchemas(@RegisterFormsSchemas);

end.
