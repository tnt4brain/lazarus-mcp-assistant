{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsCodeNav;

{ Code navigation and refactoring beyond references and rename (ADR-027):
  code_find_descendants, code_find_overrides, code_unit_dependencies,
  code_find_unused, code_extract_method.  All on CodeTools, main thread.
  Descendants are found through the references of a class name: a reference inside
  the heritage list `class(TBase, IFoo)` is a descendant (or implementer). }

{$mode objfpc}{$H+}

interface

implementation

uses
  Classes, SysUtils, StrUtils, fpjson, jsonparser,
  LazIDEIntf, SrcEditorIntf, LazFileUtils, FileUtil,
  CodeToolManager, CodeCache, CodeTree, AVL_Tree, BasicCodeTools,
  CustomCodeTool, ExtractProcTool, PascalReaderTool,
  McpToolContext, McpToolsCodeTools;

const
  PKG_SCOPE =
    '"package_name":{"type":"string","description":"Use this loaded package''s files instead of the project''s"},' +
    '"lpk_path":{"type":"string","description":"Or the package''s .lpk, loaded for the call"}';

  SCOPE_PROPS =
    '"also":{"type":"array","items":{"type":"string"},"description":"Also search other sources: same_folder, lcl, components, rtl, fcl, packages (as in code_find_references)"},' +
    '"search_dir":{"type":"string","description":"Also search this folder and its subfolders"},' +
    '"max_files":{"type":"integer","description":"At most this many extra files that mention the name are searched (default 300; 0 searches none)"},' +
    PKG_SCOPE;

  SCHEMA_DESCENDANTS =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path of the file with the class or interface"},' +
    '"line":{"type":"integer","description":"Line (1-based) of the class name: its declaration or any use"},' +
    '"col":{"type":"integer","description":"Column (1-based) of the class name"},' +
    '"direct_only":{"type":"boolean","description":"Only the classes that name it in their heritage list (default false: the whole tree below it)"},' +
    '"max_results":{"type":"integer","description":"Stop after this many classes (default 500; 0 finds none)"},' +
    SCOPE_PROPS + '},"required":["file","line","col"]}';

  SCHEMA_OVERRIDES =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path of the file with the method"},' +
    '"line":{"type":"integer","description":"Line (1-based) of the method name in its class declaration, its implementation or a call"},' +
    '"col":{"type":"integer","description":"Column (1-based) of the method name"},' +
    '"max_results":{"type":"integer","description":"Stop after this many classes (default 500; 0 finds none)"},' +
    SCOPE_PROPS + '},"required":["file","line","col"]}';

  SCHEMA_DEPENDENCIES =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"One unit: what it uses, what uses it, and which of its used units it does not need. Omit for the whole project or package"},' +
    '"max_units":{"type":"integer","description":"Whole-project answer: at most this many units (default 300)"},' +
    PKG_SCOPE + '}}';

  SCHEMA_UNUSED =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path of the unit to check"},' +
    '"max_symbols":{"type":"integer","description":"Check at most this many symbols (default 200); the answer says how many were left"},' +
    '"include_published":{"type":"boolean","description":"Also check published members (default false: forms and the streaming system use them without a reference in code)"},' +
    SCOPE_PROPS + '},"required":["file"]}';

  SCHEMA_EXTRACT =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path of the unit"},' +
    '"start_line":{"type":"integer","description":"First line of the statements to extract (1-based)"},' +
    '"start_col":{"type":"integer","description":"Column where the selection starts (1-based)"},' +
    '"end_line":{"type":"integer","description":"Last line (1-based)"},' +
    '"end_col":{"type":"integer","description":"Column just after the selection (1-based, exclusive)"},' +
    '"name":{"type":"string","description":"Name of the new procedure or method (not needed with dry_run)"},' +
    '"kind":{"type":"string","description":"procedure (default), sub_procedure, sub_procedure_same_level, private_method, protected_method, public_method, published_method"},' +
    '"dry_run":{"type":"boolean","description":"Only report which kinds are possible and which identifiers the new routine would need (default false)"},' +
    '"auto_save":{"type":"boolean","description":"Save the changed files (default false: they stay unsaved, Ctrl+Z works)"}},' +
    '"required":["file","start_line","start_col","end_line","end_col"]}';

{ ── Helpers ──────────────────────────────────────────────────────────────── }

function Fail(var Ctx: TMcpToolCall; const Msg: string): Boolean;
begin
  Ctx.Error := True;
  Ctx.Result := Msg;
  Result := True;
end;

function LoadCode(const AFile: string): TCodeBuffer;
begin
  Result := McpLoadCode(AFile, False);
end;

function PosObj(Code: TCodeBuffer; X, Y: Integer): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('file', Code.Filename);
  Result.Add('line', Y);
  Result.Add('col', X);
end;

{ The definition (type or generic type) around a node, or nil. }
function TypeDefOf(Node: TCodeTreeNode): TCodeTreeNode;
begin
  Result := Node;
  while (Result <> nil) and not (Result.Desc in [ctnTypeDefinition, ctnGenericType]) do
    Result := Result.Parent;
end;

{ The start of a type definition's name. }
function TypeNamePos(TypeDef: TCodeTreeNode): Integer;
begin
  if (TypeDef.Desc = ctnGenericType) and (TypeDef.FirstChild <> nil) then
    Result := TypeDef.FirstChild.StartPos
  else
    Result := TypeDef.StartPos;
end;

function ClassNodeOf(TypeDef: TCodeTreeNode): TCodeTreeNode;
var
  N : TCodeTreeNode;
begin
  Result := nil;
  if TypeDef = nil then Exit;
  N := TypeDef.FirstChild;
  while N <> nil do
  begin
    if N.Desc in AllClasses then Exit(N);
    N := N.NextBrother;
  end;
end;

{ ── Descendants ──────────────────────────────────────────────────────────── }

type
  TClassInfo = record
    Name     : string;
    Code     : TCodeBuffer;
    X, Y     : Integer;
    Parent   : string;
    Depth    : Integer;
  end;
  TClassInfos = array of TClassInfo;

{ The class whose heritage list holds the reference Ref (a place in Tool's source). }
function ClassOfHeritageRef(Tool: TCodeTool; const Ref: TCodeXYPosition;
  out Info: TClassInfo): Boolean;
var
  CleanPos : Integer;
  Node, TypeDef : TCodeTreeNode;
  NamePos  : Integer;
  At       : TCodeXYPosition;
begin
  Result := False;
  if Tool.CaretToCleanPos(Ref, CleanPos) <> 0 then Exit;
  Node := Tool.FindDeepestNodeAtPos(CleanPos, False);
  while (Node <> nil) and (Node.Desc <> ctnClassInheritance) do
    Node := Node.Parent;
  if Node = nil then Exit;
  TypeDef := TypeDefOf(Node.Parent);
  if TypeDef = nil then Exit;
  NamePos := TypeNamePos(TypeDef);
  if not Tool.CleanPosToCaret(NamePos, At) then Exit;
  Info.Name := GetIdentifier(@Tool.Src[NamePos]);
  Info.Code := At.Code;
  Info.X := At.X;
  Info.Y := At.Y;
  Result := True;
end;

function InfoKnown(const Infos: TClassInfos; const Info: TClassInfo): Boolean;
var
  I : Integer;
begin
  for I := 0 to High(Infos) do
    if (Infos[I].Code = Info.Code) and (Infos[I].Y = Info.Y) and (Infos[I].X = Info.X) then
      Exit(True);
  Result := False;
end;

{ Every class that names the class at X/Y of Code in its heritage list (and, unless
  Direct, those below them).  Capped says the search stopped at MaxResults. }
function CollectDescendants(Code: TCodeBuffer; X, Y: Integer; const RootName: string;
  Files: TStringList; Direct: Boolean; MaxResults: Integer; out Infos: TClassInfos;
  out Capped: Boolean; out Err: string): Boolean;
var
  Queue  : TClassInfos;
  Qi     : Integer;
  Tree   : TAVLTree;
  Node   : TAVLTreeNode;
  Ref    : PCodeXYPosition;
  Tool   : TCodeTool;
  Info   : TClassInfo;
begin
  Result := True;
  Capped := False;
  Err := '';
  SetLength(Infos, 0);
  SetLength(Queue, 1);
  Queue[0].Name := RootName; Queue[0].Code := Code; Queue[0].X := X; Queue[0].Y := Y;
  Queue[0].Parent := ''; Queue[0].Depth := 0;
  Qi := 0;
  while Qi < Length(Queue) do
  begin
    Tree := nil;
    if not CodeToolBoss.FindReferencesInFiles(Files, Queue[Qi].Code,
             Point(Queue[Qi].X, Queue[Qi].Y), False, Tree) then
    begin
      if Qi = 0 then
      begin
        Err := 'FindReferences failed: ' + CodeToolBoss.ErrorMessage;
        Exit(False);
      end;
      Inc(Qi);
      Continue;
    end;
    try
      if Assigned(Tree) then
      begin
        Node := Tree.FindLowest;
        while Node <> nil do
        begin
          Ref := PCodeXYPosition(Node.Data);
          Node := Node.Successor;
          if not CodeToolBoss.Explore(Ref^.Code, Tool, False, False) then Continue;
          if not ClassOfHeritageRef(Tool, Ref^, Info) then Continue;
          if (Info.Code = Queue[Qi].Code) and (Info.X = Queue[Qi].X) and (Info.Y = Queue[Qi].Y) then
            Continue;
          if InfoKnown(Infos, Info) then Continue;
          Info.Parent := Queue[Qi].Name;
          Info.Depth := Queue[Qi].Depth + 1;
          if Length(Infos) >= MaxResults then
          begin
            Capped := True;
            Break;
          end;
          SetLength(Infos, Length(Infos) + 1);
          Infos[High(Infos)] := Info;
          if not Direct then
          begin
            SetLength(Queue, Length(Queue) + 1);
            Queue[High(Queue)] := Info;
          end;
        end;
      end;
    finally
      if Assigned(Tree) then CodeToolBoss.FreeTreeOfPCodeXYPosition(Tree);
    end;
    if Capped then Break;
    if Direct then Break;
    Inc(Qi);
  end;
end;

{ Where the class named by the identifier at Line/Col of Code is declared (a use of the
  name resolves through the uses clauses). }
function ResolveClass(Code: TCodeBuffer; Line, Col: Integer; out DCode: TCodeBuffer;
  out DX, DY: Integer; out Name: string; out Err: string): Boolean;
var
  TopLine, BTop, BBottom, CleanPos, P : Integer;
  Tool     : TCodeTool;
  Node, TypeDef : TCodeTreeNode;
  At       : TCodeXYPosition;
begin
  Result := False;
  Err := '';
  if not CodeToolBoss.FindDeclaration(Code, Col, Line, DCode, DX, DY, TopLine, BTop, BBottom) then
  begin
    { the position may be the declaration itself }
    DCode := Code; DX := Col; DY := Line;
  end;
  if not CodeToolBoss.Explore(DCode, Tool, False, False) then
  begin
    Err := 'Parse error: ' + CodeToolBoss.ErrorMessage;
    Exit;
  end;
  if Tool.CaretToCleanPos(CodeXYPosition(DX, DY, DCode), CleanPos) <> 0 then
  begin
    Err := 'No identifier at that position';
    Exit;
  end;
  Node := Tool.FindDeepestNodeAtPos(CleanPos, False);
  TypeDef := TypeDefOf(Node);
  if (TypeDef = nil) or (ClassNodeOf(TypeDef) = nil) then
  begin
    Err := 'That is not a class, object, record or interface';
    Exit;
  end;
  P := TypeNamePos(TypeDef);
  Name := GetIdentifier(@Tool.Src[P]);
  if Tool.CleanPosToCaret(P, At) then
  begin
    DCode := At.Code; DX := At.X; DY := At.Y;
  end;
  Result := True;
end;

function InfosToJson(const Infos: TClassInfos): TJSONArray;
var
  I : Integer;
  O : TJSONObject;
begin
  Result := TJSONArray.Create;
  for I := 0 to High(Infos) do
  begin
    O := PosObj(Infos[I].Code, Infos[I].X, Infos[I].Y);
    O.Add('class', Infos[I].Name);
    O.Add('parent', Infos[I].Parent);
    O.Add('depth', Infos[I].Depth);
    Result.Add(O);
  end;
end;

function DoDescendants(var Ctx: TMcpToolCall): Boolean;
var
  Code, DCode : TCodeBuffer;
  DX, DY      : Integer;
  Name, Err   : string;
  Files       : TStringList;
  Used, Trunc, Capped : Boolean;
  Searched    : Integer;
  Infos       : TClassInfos;
  Obj         : TJSONObject;
begin
  Result := True;
  Code := LoadCode(Ctx.Params.Get('file', ''));
  if Code = nil then Exit(Fail(Ctx, 'Could not load: ' + Ctx.Params.Get('file', '')));
  if not ResolveClass(Code, Ctx.Params.Get('line', 0), Ctx.Params.Get('col', 0),
           DCode, DX, DY, Name, Err) then Exit(Fail(Ctx, Err));
  Files := TStringList.Create;
  try
    if not McpScopeFiles(Ctx.Params, DCode, DX, DY, Files, Used, Trunc, Searched, Err) then
      Exit(Fail(Ctx, Err));
    if not CollectDescendants(DCode, DX, DY, Name, Files, Ctx.Params.Get('direct_only', False),
             Ctx.Params.Get('max_results', 500), Infos, Capped, Err) then
      Exit(Fail(Ctx, Err));
    Obj := TJSONObject.Create;
    try
      Obj.Add('class', Name);
      Obj.Add('declaration', PosObj(DCode, DX, DY));
      Obj.Add('descendants', InfosToJson(Infos));
      Obj.Add('count', Length(Infos));
      Obj.Add('files_searched', Files.Count);
      if Capped then Obj.Add('truncated', True);
      if Trunc then Obj.Add('extra_files_truncated', True);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  finally
    Files.Free;
  end;
end;

{ ── Overrides ────────────────────────────────────────────────────────────── }

{ The method called MethodName in the class declared at X/Y of Code; nil when it has none. }
function FindMethodIn(Code: TCodeBuffer; X, Y: Integer; const MethodName: string;
  out Tool: TCodeTool; out Proc: TCodeTreeNode): Boolean;
var
  CleanPos : Integer;
  TypeDef, ClassNode, Sect, Child : TCodeTreeNode;
begin
  Result := False;
  Proc := nil;
  if not CodeToolBoss.Explore(Code, Tool, False, False) then Exit;
  if Tool.CaretToCleanPos(CodeXYPosition(X, Y, Code), CleanPos) <> 0 then Exit;
  TypeDef := TypeDefOf(Tool.FindDeepestNodeAtPos(CleanPos, False));
  ClassNode := ClassNodeOf(TypeDef);
  if ClassNode = nil then Exit;
  Sect := ClassNode.FirstChild;
  while Sect <> nil do
  begin
    if Sect.Desc in AllClassBaseSections then
    begin
      Child := Sect.FirstChild;
      while Child <> nil do
      begin
        if Child.Desc = ctnProcedure then
        begin
          Tool.MoveCursorToProcName(Child, True);
          if SameText(GetIdentifier(@Tool.Src[Tool.CurPos.StartPos]), MethodName) then
          begin
            Proc := Child;
            Exit(True);
          end;
        end;
        Child := Child.NextBrother;
      end;
    end;
    Sect := Sect.NextBrother;
  end;
end;

function DoOverrides(var Ctx: TMcpToolCall): Boolean;
var
  Code, DCode, MCode : TCodeBuffer;
  MX, MY, TopLine, BTop, BBottom, CleanPos, I : Integer;
  Tool, Tool2 : TCodeTool;
  Node, ProcNode, Proc2, TypeDef : TCodeTreeNode;
  MethodName, ClassName, Err, Kind : string;
  At       : TCodeXYPosition;
  Files    : TStringList;
  Used, Trunc, Capped : Boolean;
  Searched : Integer;
  Infos    : TClassInfos;
  Obj, O   : TJSONObject;
  Arr      : TJSONArray;
begin
  Result := True;
  Code := LoadCode(Ctx.Params.Get('file', ''));
  if Code = nil then Exit(Fail(Ctx, 'Could not load: ' + Ctx.Params.Get('file', '')));
  if not CodeToolBoss.FindDeclaration(Code, Ctx.Params.Get('col', 0), Ctx.Params.Get('line', 0),
           MCode, MX, MY, TopLine, BTop, BBottom) then
  begin
    MCode := Code; MX := Ctx.Params.Get('col', 0); MY := Ctx.Params.Get('line', 0);
  end;
  if not CodeToolBoss.Explore(MCode, Tool, False, False) then
    Exit(Fail(Ctx, 'Parse error: ' + CodeToolBoss.ErrorMessage));
  if Tool.CaretToCleanPos(CodeXYPosition(MX, MY, MCode), CleanPos) <> 0 then
    Exit(Fail(Ctx, 'No identifier at that position'));
  Node := Tool.FindDeepestNodeAtPos(CleanPos, False);
  ProcNode := Node;
  while (ProcNode <> nil) and (ProcNode.Desc <> ctnProcedure) do ProcNode := ProcNode.Parent;
  if (ProcNode = nil) or (ProcNode.Parent = nil) or not (ProcNode.Parent.Desc in AllClassBaseSections) then
    Exit(Fail(Ctx, 'That is not a method declared in a class or interface'));
  Tool.MoveCursorToProcName(ProcNode, True);
  MethodName := GetIdentifier(@Tool.Src[Tool.CurPos.StartPos]);
  TypeDef := TypeDefOf(ProcNode);
  if TypeDef = nil then Exit(Fail(Ctx, 'The class of the method was not found'));
  if not Tool.CleanPosToCaret(TypeNamePos(TypeDef), At) then
    Exit(Fail(Ctx, 'The class of the method was not found'));
  ClassName := GetIdentifier(@Tool.Src[TypeNamePos(TypeDef)]);
  DCode := At.Code;

  Files := TStringList.Create;
  try
    if not McpScopeFiles(Ctx.Params, DCode, At.X, At.Y, Files, Used, Trunc, Searched, Err) then
      Exit(Fail(Ctx, Err));
    if not CollectDescendants(DCode, At.X, At.Y, ClassName, Files, False,
             Ctx.Params.Get('max_results', 500), Infos, Capped, Err) then
      Exit(Fail(Ctx, Err));
    Arr := TJSONArray.Create;
    Obj := TJSONObject.Create;
    try
      for I := 0 to High(Infos) do
        if FindMethodIn(Infos[I].Code, Infos[I].X, Infos[I].Y, MethodName, Tool2, Proc2) then
        begin
          if Tool2.ProcNodeHasSpecifier(Proc2, psOverride) then Kind := 'override'
          else if Tool2.ProcNodeHasSpecifier(Proc2, psReintroduce) then Kind := 'reintroduce'
          else Kind := 'same name, not an override';
          Tool2.MoveCursorToProcName(Proc2, True);
          if Tool2.CleanPosToCaret(Tool2.CurPos.StartPos, At) then
          begin
            O := PosObj(At.Code, At.X, At.Y);
            O.Add('class', Infos[I].Name);
            O.Add('kind', Kind);
            O.Add('signature', Trim(At.Code.GetLine(At.Y - 1, False)));
            Arr.Add(O);
          end;
        end;
      Obj.Add('method', ClassName + '.' + MethodName);
      Obj.Add('declaration', PosObj(MCode, MX, MY));
      Obj.Add('overrides', Arr); Arr := nil;
      Obj.Add('descendants_checked', Length(Infos));
      if Capped then Obj.Add('truncated', True);
      Ctx.Result := Obj.AsJSON;
    finally
      Arr.Free;
      Obj.Free;
    end;
  finally
    Files.Free;
  end;
end;

{ ── Unit dependencies ────────────────────────────────────────────────────── }

type
  TUnitRec = class
    Name   : string;        { lower case }
    FileName : string;
    IntfUses, ImplUses : TStringList;
    Error  : string;
    constructor Create;
    destructor Destroy; override;
  end;

constructor TUnitRec.Create;
begin
  IntfUses := TStringList.Create;
  ImplUses := TStringList.Create;
end;

destructor TUnitRec.Destroy;
begin
  IntfUses.Free;
  ImplUses.Free;
  inherited Destroy;
end;

{ Tarjan: the strongly connected groups of more than one unit (or with a self edge).
  Edges are the indexes in Adj[I] (a TList of PtrInt). }
procedure FindCycles(Count: Integer; Adj: TFPList; Groups: TJSONArray; Units: TFPList);
var
  Index, Low : array of Integer;
  OnStack    : array of Boolean;
  Stack      : TFPList;
  Counter    : Integer;

  procedure Visit(V: Integer);
  var
    K, W : Integer;
    Comp : TFPList;
    Arr  : TJSONArray;
    Edges: TFPList;
  begin
    Index[V] := Counter; Low[V] := Counter; Inc(Counter);
    Stack.Add(Pointer(PtrInt(V)));
    OnStack[V] := True;
    Edges := TFPList(Adj[V]);
    for K := 0 to Edges.Count - 1 do
    begin
      W := PtrInt(Edges[K]);
      if Index[W] < 0 then
      begin
        Visit(W);
        if Low[W] < Low[V] then Low[V] := Low[W];
      end
      else if OnStack[W] and (Index[W] < Low[V]) then
        Low[V] := Index[W];
    end;
    if Low[V] = Index[V] then
    begin
      Comp := TFPList.Create;
      try
        repeat
          W := PtrInt(Stack[Stack.Count - 1]);
          Stack.Delete(Stack.Count - 1);
          OnStack[W] := False;
          Comp.Add(Pointer(PtrInt(W)));
        until W = V;
        if Comp.Count > 1 then
        begin
          Arr := TJSONArray.Create;
          for K := Comp.Count - 1 downto 0 do
            Arr.Add(TUnitRec(Units[PtrInt(Comp[K])]).Name);
          Groups.Add(Arr);
        end;
      finally
        Comp.Free;
      end;
    end;
  end;

var
  I : Integer;
begin
  SetLength(Index, Count); SetLength(Low, Count); SetLength(OnStack, Count);
  for I := 0 to Count - 1 do begin Index[I] := -1; OnStack[I] := False; end;
  Counter := 0;
  Stack := TFPList.Create;
  try
    for I := 0 to Count - 1 do
      if Index[I] < 0 then Visit(I);
  finally
    Stack.Free;
  end;
end;

function UnitIndex(Units: TFPList; const LowName: string): Integer;
var
  I : Integer;
begin
  for I := 0 to Units.Count - 1 do
    if TUnitRec(Units[I]).Name = LowName then Exit(I);
  Result := -1;
end;

procedure AddNames(Src: TStrings; Dst: TStringList);
var
  I : Integer;
  N : string;
begin
  if Src = nil then Exit;
  for I := 0 to Src.Count - 1 do
  begin
    N := Src[I];
    if Pos(' ', N) > 0 then N := Copy(N, 1, Pos(' ', N) - 1);
    Dst.Add(N);
  end;
end;

function DoDependencies(var Ctx: TMcpToolCall): Boolean;
var
  Handled : Boolean;
  Tmp     : TMcpToolCall;
  List    : TJSONArray;
  Units   : TFPList;
  I, J, K, MaxUnits : Integer;
  U       : TUnitRec;
  Code    : TCodeBuffer;
  MainU, ImplU : TStrings;
  AdjAll, AdjIntf : TFPList;
  Obj, O  : TJSONObject;
  Arr, Arr2 : TJSONArray;
  FileArg, Ext : string;
  Unused  : TStringList;
  One     : TUnitRec;
begin
  Result := True;
  Tmp.Params := Ctx.Params; Tmp.Result := ''; Tmp.Error := False; Tmp.StopServer := nil;
  McpDispatch('project_list_files', Tmp, Handled);
  if Tmp.Error then Exit(Fail(Ctx, Tmp.Result));
  Units := TFPList.Create;
  List := TJSONArray(GetJSON(Tmp.Result));
  try
    for I := 0 to List.Count - 1 do
    begin
      Ext := LowerCase(ExtractFileExt(List.Strings[I]));
      if (Ext <> '.pas') and (Ext <> '.pp') and (Ext <> '.lpr') then Continue;
      U := TUnitRec.Create;
      U.FileName := List.Strings[I];
      U.Name := LowerCase(ExtractFileNameOnly(U.FileName));
      Units.Add(U);
    end;
    FileArg := Ctx.Params.Get('file', '');
    if (FileArg <> '') and (UnitIndex(Units, LowerCase(ExtractFileNameOnly(FileArg))) < 0) then
    begin
      U := TUnitRec.Create;
      U.FileName := FileArg;
      U.Name := LowerCase(ExtractFileNameOnly(FileArg));
      Units.Add(U);
    end;
    for I := 0 to Units.Count - 1 do
    begin
      U := TUnitRec(Units[I]);
      Code := LoadCode(U.FileName);
      if Code = nil then begin U.Error := 'could not load'; Continue; end;
      MainU := nil; ImplU := nil;
      if CodeToolBoss.FindUsedUnitNames(Code, MainU, ImplU) then
      begin
        AddNames(MainU, U.IntfUses);
        AddNames(ImplU, U.ImplUses);
      end else
        U.Error := CodeToolBoss.ErrorMessage;
      MainU.Free; ImplU.Free;
    end;

    if FileArg <> '' then
    begin
      One := TUnitRec(Units[UnitIndex(Units, LowerCase(ExtractFileNameOnly(FileArg)))]);
      Obj := TJSONObject.Create;
      try
        Obj.Add('unit', One.Name);
        Obj.Add('file', One.FileName);
        if One.Error <> '' then Obj.Add('error', One.Error);
        Arr := TJSONArray.Create;
        for J := 0 to One.IntfUses.Count - 1 do
        begin
          O := TJSONObject.Create;
          O.Add('unit', One.IntfUses[J]);
          O.Add('in_project', UnitIndex(Units, LowerCase(One.IntfUses[J])) >= 0);
          Arr.Add(O);
        end;
        Obj.Add('uses_interface', Arr);
        Arr := TJSONArray.Create;
        for J := 0 to One.ImplUses.Count - 1 do
        begin
          O := TJSONObject.Create;
          O.Add('unit', One.ImplUses[J]);
          O.Add('in_project', UnitIndex(Units, LowerCase(One.ImplUses[J])) >= 0);
          Arr.Add(O);
        end;
        Obj.Add('uses_implementation', Arr);
        Arr := TJSONArray.Create;
        for J := 0 to Units.Count - 1 do
        begin
          U := TUnitRec(Units[J]);
          if U = One then Continue;
          if U.IntfUses.IndexOf(One.Name) >= 0 then
          begin
            O := TJSONObject.Create; O.Add('unit', U.Name); O.Add('in', 'interface'); Arr.Add(O);
          end else if U.ImplUses.IndexOf(One.Name) >= 0 then
          begin
            O := TJSONObject.Create; O.Add('unit', U.Name); O.Add('in', 'implementation'); Arr.Add(O);
          end;
        end;
        Obj.Add('used_by', Arr);
        Unused := TStringList.Create;
        try
          Code := LoadCode(One.FileName);
          if Assigned(Code) and CodeToolBoss.FindUnusedUnits(Code, Unused) then
          begin
            Arr := TJSONArray.Create;
            for J := 0 to Unused.Count - 1 do Arr.Add(Unused[J]);
            Obj.Add('unused_units', Arr);
          end else
            Obj.Add('unused_units_error', CodeToolBoss.ErrorMessage);
        finally
          Unused.Free;
        end;
        Ctx.Result := Obj.AsJSON;
      finally
        Obj.Free;
      end;
      Exit;
    end;

    { the whole project: edges between its own units, and the cycles }
    AdjAll := TFPList.Create; AdjIntf := TFPList.Create;
    try
      for I := 0 to Units.Count - 1 do
      begin
        AdjAll.Add(TFPList.Create);
        AdjIntf.Add(TFPList.Create);
      end;
      for I := 0 to Units.Count - 1 do
      begin
        U := TUnitRec(Units[I]);
        for J := 0 to U.IntfUses.Count - 1 do
        begin
          K := UnitIndex(Units, LowerCase(U.IntfUses[J]));
          if (K >= 0) and (K <> I) then
          begin
            TFPList(AdjAll[I]).Add(Pointer(PtrInt(K)));
            TFPList(AdjIntf[I]).Add(Pointer(PtrInt(K)));
          end;
        end;
        for J := 0 to U.ImplUses.Count - 1 do
        begin
          K := UnitIndex(Units, LowerCase(U.ImplUses[J]));
          if (K >= 0) and (K <> I) then TFPList(AdjAll[I]).Add(Pointer(PtrInt(K)));
        end;
      end;
      MaxUnits := Ctx.Params.Get('max_units', 300);
      Obj := TJSONObject.Create;
      try
        Arr := TJSONArray.Create;
        for I := 0 to Units.Count - 1 do
        begin
          if I >= MaxUnits then
          begin
            Obj.Add('truncated', True);
            Break;
          end;
          U := TUnitRec(Units[I]);
          O := TJSONObject.Create;
          O.Add('unit', U.Name);
          O.Add('file', U.FileName);
          Arr2 := TJSONArray.Create;
          for J := 0 to U.IntfUses.Count - 1 do
            if UnitIndex(Units, LowerCase(U.IntfUses[J])) >= 0 then Arr2.Add(U.IntfUses[J]);
          O.Add('interface', Arr2);
          Arr2 := TJSONArray.Create;
          for J := 0 to U.ImplUses.Count - 1 do
            if UnitIndex(Units, LowerCase(U.ImplUses[J])) >= 0 then Arr2.Add(U.ImplUses[J]);
          O.Add('implementation', Arr2);
          if U.Error <> '' then O.Add('error', U.Error);
          Arr.Add(O);
        end;
        Obj.Add('units', Arr);
        Arr := TJSONArray.Create;
        FindCycles(Units.Count, AdjAll, Arr, Units);
        Obj.Add('cycles', Arr);
        Arr := TJSONArray.Create;
        FindCycles(Units.Count, AdjIntf, Arr, Units);
        Obj.Add('interface_cycles', Arr);
        Obj.Add('note', 'cycles: units that reach each other through any uses clause (legal when the ' +
                'loop passes an implementation clause); interface_cycles: through interface clauses only ' +
                '(the compiler rejects those)');
        Ctx.Result := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    finally
      for I := 0 to AdjAll.Count - 1 do begin TFPList(AdjAll[I]).Free; TFPList(AdjIntf[I]).Free; end;
      AdjAll.Free; AdjIntf.Free;
    end;
  finally
    for I := 0 to Units.Count - 1 do TUnitRec(Units[I]).Free;
    Units.Free;
    List.Free;
  end;
end;

{ ── Unused symbols ───────────────────────────────────────────────────────── }

type
  TCand = record
    Name     : string;
    Kind     : string;
    Owner    : string;      { class name for a member }
    NamePos  : Integer;     { clean position of the name }
    Note     : string;
  end;
  TCands = array of TCand;

function WordIn(const LowText, LowWord: string): Boolean;
var
  P, L : Integer;
begin
  Result := False;
  L := Length(LowWord);
  P := Pos(LowWord, LowText);
  while P > 0 do
  begin
    if ((P = 1) or not (LowText[P - 1] in ['a'..'z', '0'..'9', '_'])) and
       ((P + L > Length(LowText)) or not (LowText[P + L] in ['a'..'z', '0'..'9', '_'])) then
      Exit(True);
    P := PosEx(LowWord, LowText, P + 1);
  end;
end;

procedure AddCand(var C: TCands; const AName, AKind, AOwner: string; APos: Integer;
  const ANote: string);
var
  I : Integer;
begin
  for I := 0 to High(C) do
    if (C[I].Name = AName) and (C[I].Owner = AOwner) and (C[I].Kind = AKind) then Exit;
  SetLength(C, Length(C) + 1);
  C[High(C)].Name := AName;
  C[High(C)].Kind := AKind;
  C[High(C)].Owner := AOwner;
  C[High(C)].NamePos := APos;
  C[High(C)].Note := ANote;
end;

{ Walk the unit's declarations and collect what could be unused. }
var
  GIncludePublished : Boolean = False;

procedure CollectCandidates(Tool: TCodeTool; Node: TCodeTreeNode; const Owner: string;
  InClass, Published: Boolean; var C: TCands);
var
  N, Sub : TCodeTreeNode;
  Nm : string;
  Note : string;
  Pub  : Boolean;
  NamePos : Integer;
begin
  N := Node;
  while N <> nil do
  begin
    case N.Desc of
      ctnUnit, ctnProgram, ctnLibrary, ctnPackage,
      ctnTypeSection, ctnVarSection, ctnConstSection, ctnInterface, ctnImplementation,
      ctnClassPrivate, ctnClassProtected, ctnClassPublic, ctnClassPublished:
        begin
          Pub := (not GIncludePublished) and (Published or (N.Desc = ctnClassPublished));
          CollectCandidates(Tool, N.FirstChild, Owner, InClass, Pub, C);
        end;
      ctnTypeDefinition, ctnGenericType:
        begin
          Sub := ClassNodeOf(N);
          Nm := GetIdentifier(@Tool.Src[TypeNamePos(N)]);
          if not InClass then
            AddCand(C, Nm, 'type', '', TypeNamePos(N), '');
          if Sub <> nil then
            CollectCandidates(Tool, Sub.FirstChild, Nm, True, False, C);
        end;
      ctnVarDefinition, ctnConstDefinition:
        if not Published then
        begin
          Nm := GetIdentifier(@Tool.Src[N.StartPos]);
          if Nm <> '' then
            AddCand(C, Nm, IfThen(N.Desc = ctnConstDefinition, 'const', IfThen(InClass, 'field', 'var')),
                    Owner, N.StartPos, '');
        end;
      ctnProperty:
        if not Published then
        begin
          if Tool.MoveCursorToPropName(N) then
            AddCand(C, GetIdentifier(@Tool.Src[Tool.CurPos.StartPos]), 'property', Owner,
                    Tool.CurPos.StartPos, '');
        end;
      ctnProcedure:
        if not Published and not Tool.NodeIsMethodBody(N) then
        begin
          Tool.MoveCursorToProcName(N, True);
          NamePos := Tool.CurPos.StartPos;   { the specifier tests below move the cursor }
          Nm := GetIdentifier(@Tool.Src[NamePos]);
          Note := '';
          if Tool.NodeIsConstructor(N) or Tool.NodeIsDestructor(N) then Nm := '';
          if InClass and (Tool.ProcNodeHasSpecifier(N, psOverride) or
                          Tool.ProcNodeHasSpecifier(N, psAbstract)) then Nm := '';
          if (Nm <> '') and InClass and (Tool.ProcNodeHasSpecifier(N, psVirtual) or
                                         Tool.ProcNodeHasSpecifier(N, psDynamic)) then
            Note := 'virtual: may be called through an ancestor';
          if SameText(Nm, 'Register') then Nm := '';
          if Nm <> '' then
            AddCand(C, Nm, IfThen(InClass, 'method', 'procedure'), Owner, NamePos, Note);
        end;
    end;
    N := N.NextBrother;
  end;
end;

function DoUnused(var Ctx: TMcpToolCall): Boolean;
var
  Code     : TCodeBuffer;
  Tool, Tool2 : TCodeTool;
  Files, Texts, Cand : TStringList;
  C        : TCands;
  I, J, MaxSym, Checked, Refs, CleanPos : Integer;
  Used, Trunc : Boolean;
  Searched : Integer;
  Err      : string;
  Low      : string;
  At       : TCodeXYPosition;
  Tree     : TAVLTree;
  RNode    : TAVLTreeNode;
  Ref      : PCodeXYPosition;
  Node     : TCodeTreeNode;
  Arr      : TJSONArray;
  O, Obj   : TJSONObject;
  Stream   : TStringList;
  SameDecl : Boolean;
  DbgNote : string;
begin
  DbgNote := '';
  Result := True;
  Code := LoadCode(Ctx.Params.Get('file', ''));
  if Code = nil then Exit(Fail(Ctx, 'Could not load: ' + Ctx.Params.Get('file', '')));
  if not CodeToolBoss.Explore(Code, Tool, False, False) then
    Exit(Fail(Ctx, 'Parse error: ' + CodeToolBoss.ErrorMessage));
  GIncludePublished := Ctx.Params.Get('include_published', False);
  SetLength(C, 0);
  CollectCandidates(Tool, Tool.Tree.Root, '', False, False, C);
  MaxSym := Ctx.Params.Get('max_symbols', 200);
  Files := TStringList.Create;
  Texts := TStringList.Create;
  Arr := TJSONArray.Create;
  Obj := TJSONObject.Create;
  try
    if not McpScopeFiles(Ctx.Params, Code, 1, 1, Files, Used, Trunc, Searched, Err) then
      Exit(Fail(Ctx, Err));
    { the lower-case text of each file, to leave out the files that cannot mention a name }
    Stream := TStringList.Create;
    try
      for I := 0 to Files.Count - 1 do
      begin
        try
          Stream.LoadFromFile(Files[I]);
          Texts.Add(LowerCase(Stream.Text));
        except
          Texts.Add('');
        end;
      end;
    finally
      Stream.Free;
    end;
    Checked := 0;
    for I := 0 to High(C) do
    begin
      if Checked >= MaxSym then Break;
      Inc(Checked);
      Low := LowerCase(C[I].Name);
      if not Tool.CleanPosToCaret(C[I].NamePos, At) then Continue;
      Cand := TStringList.Create;
      try
        for J := 0 to Files.Count - 1 do
          if WordIn(Texts[J], Low) then Cand.Add(Files[J]);
        if Cand.IndexOf(Code.Filename) < 0 then Cand.Add(Code.Filename);
        Tree := nil;
        if not CodeToolBoss.FindReferencesInFiles(Cand, At.Code, Point(At.X, At.Y), False, Tree) then
        begin
          DbgNote := DbgNote + 'FAILED ' + C[I].Name + ': ' + CodeToolBoss.ErrorMessage + ' | ';
          Continue;
        end;
        Refs := 0;
        try
          if Assigned(Tree) then
          begin
            RNode := Tree.FindLowest;
            while RNode <> nil do
            begin
              Ref := PCodeXYPosition(RNode.Data);
              RNode := RNode.Successor;
              if (Ref^.Code = At.Code) and (Ref^.Y = At.Y) and (Ref^.X = At.X) then Continue;
              { a mention in a routine header is its implementation or another declaration }
              Node := nil;
              if CodeToolBoss.Explore(Ref^.Code, Tool2, False, False) and
                 (Tool2.CaretToCleanPos(Ref^, CleanPos) = 0) then
                Node := Tool2.FindDeepestNodeAtPos(CleanPos, False);
              SameDecl := False;
              while Node <> nil do
              begin
                if Node.Desc = ctnProcedureHead then begin SameDecl := True; Break; end;
                { a method header outside its class starts at the class name: the head node may begin after the routine's name }
                if (Node.Desc = ctnProcedure) and (Node.FirstChild <> nil) and
                   (CleanPos < Node.FirstChild.EndPos) then begin SameDecl := True; Break; end;
                if Node.Desc in [ctnBeginBlock, ctnAsmBlock] then Break;
                Node := Node.Parent;
              end;
              if not SameDecl then Inc(Refs);
            end;
          end;
        finally
          if Assigned(Tree) then CodeToolBoss.FreeTreeOfPCodeXYPosition(Tree);
        end;
        if Refs = 0 then
        begin
          O := PosObj(At.Code, At.X, At.Y);
          O.Add('name', IfThen(C[I].Owner <> '', C[I].Owner + '.', '') + C[I].Name);
          O.Add('kind', C[I].Kind);
          if C[I].Note <> '' then O.Add('note', C[I].Note);
          Arr.Add(O);
        end;
      finally
        Cand.Free;
      end;
    end;
    Obj.Add('unused', Arr); Arr := nil;
    Obj.Add('checked', Checked);
    if DbgNote <> '' then Obj.Add('notes', DbgNote);
    if Checked < Length(C) then Obj.Add('not_checked', Length(C) - Checked);
    Obj.Add('files_searched', Files.Count);
    Obj.Add('note', 'No reference found in the searched files. A unit of a package may be used by projects ' +
            'outside them (widen the search with also/search_dir), a name may be reached through ' +
            'streaming (published) or an interface, and a written-only field counts as used.');
    Ctx.Result := Obj.AsJSON;
  finally
    Arr.Free;
    Obj.Free;
    Texts.Free;
    Files.Free;
  end;
end;

{ ── Extract method ───────────────────────────────────────────────────────── }

function KindOf(const S: string; out K: TExtractProcType): Boolean;
begin
  Result := True;
  if (S = '') or (S = 'procedure') then K := eptProcedure
  else if S = 'procedure_with_interface' then K := eptProcedureWithInterface
  else if S = 'sub_procedure' then K := eptSubProcedure
  else if S = 'sub_procedure_same_level' then K := eptSubProcedureSameLvl
  else if S = 'private_method' then K := eptPrivateMethod
  else if S = 'protected_method' then K := eptProtectedMethod
  else if S = 'public_method' then K := eptPublicMethod
  else if S = 'published_method' then K := eptPublishedMethod
  else Result := False;
end;

function DoExtract(var Ctx: TMcpToolCall): Boolean;
var
  Code, NewCode : TCodeBuffer;
  P1, P2 : TPoint;
  Kind   : TExtractProcType;
  Missing: TAVLTree;
  MethodOk, SubOk, SubSameOk : Boolean;
  NewX, NewY, NewTop, BTop, BBottom, I : Integer;
  Obj, O : TJSONObject;
  Arr    : TJSONArray;
  Node   : TAVLTreeNode;
  Ref    : PCodeXYPosition;
  Name   : string;
  Bufs   : TFPList;
  OldSrc : TStringList;
  OldOpen: Boolean;
  Changed: TJSONArray;
  AutoSave : Boolean;
  Before : string;
  Done   : Boolean;
begin
  Result := True;
  Code := LoadCode(Ctx.Params.Get('file', ''));
  if Code = nil then Exit(Fail(Ctx, 'Could not load: ' + Ctx.Params.Get('file', '')));
  if not KindOf(Ctx.Params.Get('kind', ''), Kind) then
    Exit(Fail(Ctx, 'kind must be procedure, procedure_with_interface, sub_procedure, ' +
                   'sub_procedure_same_level, private_method, protected_method, public_method or published_method'));
  P1 := Point(Ctx.Params.Get('start_col', 0), Ctx.Params.Get('start_line', 0));
  P2 := Point(Ctx.Params.Get('end_col', 0), Ctx.Params.Get('end_line', 0));
  Missing := nil;
  Obj := TJSONObject.Create;
  try
    if not CodeToolBoss.CheckExtractProc(Code, P1, P2, MethodOk, SubOk, SubSameOk, Missing, nil) then
      Exit(Fail(Ctx, 'These statements cannot be extracted' +
                IfThen(CodeToolBoss.ErrorMessage <> '', ': ' + CodeToolBoss.ErrorMessage, '') +
                '. Select whole statements.'));
    if Ctx.Params.Get('dry_run', False) then
    begin
      Obj.Add('method_possible', MethodOk);
      Obj.Add('sub_procedure_possible', SubOk);
      Obj.Add('sub_procedure_same_level_possible', SubSameOk);
      Arr := TJSONArray.Create;
      if Assigned(Missing) then
      begin
        Node := Missing.FindLowest;
        while Node <> nil do
        begin
          Ref := PCodeXYPosition(Node.Data);
          O := PosObj(Ref^.Code, Ref^.X, Ref^.Y);
          O.Add('text', Trim(Ref^.Code.GetLine(Ref^.Y - 1, False)));
          Arr.Add(O);
          Node := Node.Successor;
        end;
      end;
      Obj.Add('missing_identifiers', Arr);
      Ctx.Result := Obj.AsJSON;
      Exit;
    end;
    Name := Trim(Ctx.Params.Get('name', ''));
    if not IsValidIdent(Name) then
      Exit(Fail(Ctx, 'name must be a valid identifier'));
    if (Kind in [eptPrivateMethod, eptProtectedMethod, eptPublicMethod, eptPublishedMethod]) and not MethodOk then
      Exit(Fail(Ctx, 'The selection is not in a method: a method cannot be extracted from it'));
    if (Kind = eptSubProcedure) and not SubOk then
      Exit(Fail(Ctx, 'A sub procedure is not possible here'));
    if (Kind = eptSubProcedureSameLvl) and not SubSameOk then
      Exit(Fail(Ctx, 'A sub procedure at the same level is not possible here'));
    AutoSave := Ctx.Params.Get('auto_save', False);
    Bufs := TFPList.Create;
    OldSrc := TStringList.Create;
    try
      Before := Code.Source;
      NewCode := Code; NewX := 1; NewY := 1; NewTop := 1; BTop := 1; BBottom := 1;
      OldOpen := LazarusIDE.OpenEditorsOnCodeToolChange;
      LazarusIDE.OpenEditorsOnCodeToolChange := True;
      try
        Done := CodeToolBoss.ExtractProc(Code, P1, P2, Kind, Name, Missing, NewCode,
                 NewX, NewY, NewTop, BTop, BBottom);
        { CodeTools applies the change and then looks for the new routine to jump to; that
          second step can fail after the text is changed: the buffer tells which happened }
        if not Done and (Code.Source = Before) then
          Exit(Fail(Ctx, 'ExtractProc failed: ' + CodeToolBoss.ErrorMessage));
        if not Done then
        begin
          NewCode := Code;
          I := Pos('procedure ' + LowerCase(Name), LowerCase(Code.Source));
          if I = 0 then I := Pos('function ' + LowerCase(Name), LowerCase(Code.Source));
          if I > 0 then Code.AbsoluteToLineCol(I, NewY, NewX);
        end;
      finally
        LazarusIDE.OpenEditorsOnCodeToolChange := OldOpen;
        CodeToolBoss.SourceCache.ClearAllSourceLogEntries;
      end;
      Obj.Add('extracted', Name);
      Obj.Add('kind', Ctx.Params.Get('kind', 'procedure'));
      Obj.Add('new_routine', PosObj(NewCode, NewX, NewY));
      Obj.Add('block_first_line', BTop);
      Obj.Add('block_last_line', BBottom);
      Changed := TJSONArray.Create;
      Changed.Add(Code.Filename);
      if (NewCode <> nil) and (NewCode <> Code) then Changed.Add(NewCode.Filename);
      Obj.Add('files_changed', Changed);
      if AutoSave then
        for I := 0 to Changed.Count - 1 do
          LazarusIDE.DoSaveEditorFile(Changed.Strings[I], []);
      Obj.Add('saved', AutoSave);
      Ctx.Result := Obj.AsJSON;
    finally
      OldSrc.Free;
      Bufs.Free;
    end;
  finally
    Obj.Free;
    if Assigned(Missing) then CodeToolBoss.FreeTreeOfPCodeXYPosition(Missing);
  end;
end;

{ ── package_move_unit ────────────────────────────────────────────────────── }

const
  SCHEMA_MOVE_UNIT =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path of the unit; it must belong to the source package"},' +
    '"from_package":{"type":"string","description":"The package that has the unit now: its name (loaded in the IDE) or its .lpk file"},' +
    '"to_package":{"type":"string","description":"The package that gets it: name or .lpk file"},' +
    '"dry_run":{"type":"boolean","description":"Only report the plan: the dependencies that would be added and why (default false)"}},' +
    '"required":["file","from_package","to_package"]}';

function PackageTarget(const S: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  if LowerCase(ExtractFileExt(S)) = '.lpk' then
    Result.Add('lpk_path', S)
  else
    Result.Add('package_name', S);
end;

{ Runs another tool of this server on the main thread; Params is consumed. }
function RunTool(const AName: string; Params: TJSONObject; out Res: string): Boolean;
var
  T : TMcpToolCall;
  H : Boolean;
begin
  T.Params := Params; T.Result := ''; T.Error := False; T.StopServer := nil;
  H := False;
  try
    McpDispatch(AName, T, H);
  finally
    Params.Free;
  end;
  Res := T.Result;
  Result := H and not T.Error;
end;

{ The unit names a file's uses clauses list. }
procedure UsedNamesOf(const AFile: string; Dst: TStringList);
var
  Code : TCodeBuffer;
  MainU, ImplU : TStrings;
begin
  Dst.Clear;
  Code := LoadCode(AFile);
  if Code = nil then Exit;
  MainU := nil; ImplU := nil;
  if CodeToolBoss.FindUsedUnitNames(Code, MainU, ImplU) then
  begin
    AddNames(MainU, Dst);
    AddNames(ImplU, Dst);
  end;
  MainU.Free;
  ImplU.Free;
end;

function RequiresPackage(Info: TJSONData; const AName: string): Boolean;
var
  Reqs : TJSONArray;
  I    : Integer;
begin
  Result := False;
  Reqs := TJSONArray(TJSONObject(Info).Find('requires'));
  if Reqs <> nil then
    for I := 0 to Reqs.Count - 1 do
      if SameText(TJSONObject(Reqs[I]).Get('name', ''), AName) then Exit(True);
end;

function DoMoveUnit(var Ctx: TMcpToolCall): Boolean;
var
  FileArg, FromArg, ToArg, Res, FromName, ToName, MovedUnit, FromDir, Abs : string;
  P       : TJSONObject;
  FromInfo, ToInfo : TJSONData;
  Files   : TJSONArray;
  I, J    : Integer;
  Used    : TStringList;
  FromUnits : TStringList;   { lower-case unit name = file, of the source package }
  NeedsFrom, NeedsTo : Boolean;
  Obj     : TJSONObject;
  Steps, Why : TJSONArray;
begin
  Result := True;
  FileArg := Ctx.Params.Get('file', '');
  FromArg := Ctx.Params.Get('from_package', '');
  ToArg   := Ctx.Params.Get('to_package', '');
  if SameText(FromArg, ToArg) then Exit(Fail(Ctx, 'from_package and to_package are the same'));
  P := PackageTarget(FromArg); P.Add('files', True);
  if not RunTool('package_get_info', P, Res) then Exit(Fail(Ctx, Res));
  FromInfo := GetJSON(Res);
  try
    P := PackageTarget(ToArg); P.Add('files', True);
    if not RunTool('package_get_info', P, Res) then Exit(Fail(Ctx, Res));
    ToInfo := GetJSON(Res);
    try
      FromName := TJSONObject(FromInfo).Get('package_name', '');
      ToName   := TJSONObject(ToInfo).Get('package_name', '');
      FromDir  := ExtractFilePath(TJSONObject(FromInfo).Get('loaded_file', TJSONObject(FromInfo).Get('package_file', '')));
      Files := TJSONArray(TJSONObject(FromInfo).Find('files'));
      MovedUnit := '';
      FromUnits := TStringList.Create;
      Used := TStringList.Create;
      Why := TJSONArray.Create;
      Steps := nil;
      Obj := nil;
      try
        if Files <> nil then
          for I := 0 to Files.Count - 1 do
          begin
            Abs := ExpandFileName(FromDir + TJSONObject(Files[I]).Get('file', ''));
            if TJSONObject(Files[I]).Get('unit', '') <> '' then
              FromUnits.Values[LowerCase(TJSONObject(Files[I]).Get('unit', ''))] := Abs;
            if SameFileName(Abs, FileArg) then
              MovedUnit := TJSONObject(Files[I]).Get('unit', '');
          end;
        if MovedUnit = '' then
          Exit(Fail(Ctx, FileArg + ' is not a unit of ' + FromName));
        Files := TJSONArray(TJSONObject(ToInfo).Find('files'));
        if Files <> nil then
          for I := 0 to Files.Count - 1 do
            if SameText(TJSONObject(Files[I]).Get('unit', ''), MovedUnit) then
              Exit(Fail(Ctx, ToName + ' has a unit called ' + MovedUnit + ' already'));

        { what the unit needs from the units it leaves behind }
        NeedsFrom := False; NeedsTo := False;
        UsedNamesOf(FileArg, Used);
        for I := 0 to Used.Count - 1 do
          if (LowerCase(Used[I]) <> LowerCase(MovedUnit)) and
             (FromUnits.Values[LowerCase(Used[I])] <> '') then
          begin
            NeedsFrom := True;
            Why.Add(MovedUnit + ' uses ' + Used[I] + ', which stays in ' + FromName);
          end;
        { and what the units left behind need from it }
        for I := 0 to FromUnits.Count - 1 do
        begin
          Abs := FromUnits.ValueFromIndex[I];
          if SameFileName(Abs, FileArg) then Continue;
          UsedNamesOf(Abs, Used);
          for J := 0 to Used.Count - 1 do
            if SameText(Used[J], MovedUnit) then
            begin
              NeedsTo := True;
              Why.Add(ExtractFileNameOnly(Abs) + ' (stays in ' + FromName + ') uses ' + MovedUnit);
              Break;
            end;
        end;
        if NeedsFrom and NeedsTo then
          Exit(Fail(Ctx, 'Not possible without a cycle: ' + FromName + ' and ' + ToName +
            ' would have to require each other. ' + Why.AsJSON));

        NeedsFrom := NeedsFrom and not RequiresPackage(ToInfo, FromName);
        NeedsTo   := NeedsTo and not RequiresPackage(FromInfo, ToName);

        Obj := TJSONObject.Create;
        Steps := TJSONArray.Create;
        Obj.Add('unit', MovedUnit);
        Obj.Add('from', FromName);
        Obj.Add('to', ToName);
        Obj.Add('why_dependencies', Why); Why := nil;
        if Ctx.Params.Get('dry_run', False) then
        begin
          if NeedsFrom then Steps.Add(ToName + ' requires ' + FromName);
          if NeedsTo then Steps.Add(FromName + ' requires ' + ToName);
          Steps.Add('add ' + FileArg + ' to ' + ToName);
          Steps.Add('remove it from ' + FromName + ' (the file stays where it is)');
          Obj.Add('plan', Steps); Steps := nil;
          Ctx.Result := Obj.AsJSON;
          Exit;
        end;
        if NeedsFrom then
        begin
          P := PackageTarget(ToArg); P.Add('required_package', FromName);
          if not RunTool('package_add_dependency', P, Res) then
            Exit(Fail(Ctx, 'Nothing moved: ' + Res));
          Steps.Add(ToName + ' now requires ' + FromName);
        end;
        if NeedsTo then
        begin
          P := PackageTarget(FromArg); P.Add('required_package', ToName);
          if not RunTool('package_add_dependency', P, Res) then
            Exit(Fail(Ctx, 'Stopped before moving the file: ' + Res + ' ' + Steps.AsJSON));
          Steps.Add(FromName + ' now requires ' + ToName);
        end;
        P := PackageTarget(ToArg); P.Add('file', FileArg);
        if not RunTool('package_add_file', P, Res) then
          Exit(Fail(Ctx, 'Could not add the file to ' + ToName + ': ' + Res));
        Steps.Add('added to ' + ToName);
        P := PackageTarget(FromArg); P.Add('file', FileArg);
        if not RunTool('package_remove_file', P, Res) then
          Exit(Fail(Ctx, 'The file is in ' + ToName + ' now, but removing it from ' +
                         FromName + ' failed: ' + Res));
        Steps.Add('removed from ' + FromName);
        Obj.Add('done', Steps); Steps := nil;
        Obj.Add('note', 'The file was not moved on disk. A package is saved only when nothing else in it was unsaved: see package_get_info (saved).');
        Ctx.Result := Obj.AsJSON;
      finally
        Steps.Free;
        Why.Free;
        Obj.Free;
        Used.Free;
        FromUnits.Free;
      end;
    finally
      ToInfo.Free;
    end;
  finally
    FromInfo.Free;
  end;
end;

{ ── Dispatch ─────────────────────────────────────────────────────────────── }

function DispatchNav(const Name: string; var Ctx: TMcpToolCall): Boolean;
begin
  Result := False;
  if (Name <> 'code_find_descendants') and (Name <> 'code_find_overrides') and
     (Name <> 'code_unit_dependencies') and (Name <> 'code_find_unused') and
     (Name <> 'code_extract_method') and
     (Name <> 'package_move_unit') then Exit;
  Result := True;
  if not Assigned(Ctx.Params) then Exit(Fail(Ctx, 'Missing params'));
  if Assigned(LazarusIDE) then
    if not LazarusIDE.BeginCodeTools then
      Exit(Fail(Ctx, 'The IDE is busy (building, debugging or another code tool); try again'));
  CodeToolBoss.ClearError;
  case Name of
    'code_find_descendants':  DoDescendants(Ctx);
    'code_find_overrides':    DoOverrides(Ctx);
    'code_unit_dependencies': DoDependencies(Ctx);
    'code_find_unused':       DoUnused(Ctx);
    'package_move_unit':      DoMoveUnit(Ctx);
  else
    DoExtract(Ctx);
  end;
end;

procedure RegisterNavSchemas(Tools: TJSONArray);
begin
  Tools.Add(MakeTool('code_find_descendants',
    'List the classes (and interface implementers) that descend from a class or interface, ' +
    'with the whole tree below it unless direct_only. Searches the project (or package) files, ' +
    'and more with also/search_dir. Found through the heritage lists, so a class outside the ' +
    'searched files is missed.',
    SCHEMA_DESCENDANTS, MCP_ANN_RO));
  Tools.Add(MakeTool('code_find_overrides',
    'List the classes below the one that declares a method which have a method of the same name: ' +
    'overrides, reintroduces and plain same-name methods, each with its signature line. ' +
    'Use before changing the signature of a virtual method.',
    SCHEMA_OVERRIDES, MCP_ANN_RO));
  Tools.Add(MakeTool('code_unit_dependencies',
    'Unit dependencies from the uses clauses. With file: what that unit uses (interface and ' +
    'implementation), which project units use it, and which used units it does not need. Without: ' +
    'the graph of the whole project or package and its cycles (interface-only cycles do not compile).',
    SCHEMA_DEPENDENCIES, MCP_ANN_RO));
  Tools.Add(MakeTool('code_find_unused',
    'List the symbols of a unit (types, routines, methods, fields, properties, variables, constants) ' +
    'that nothing in the searched files refers to. Published members are left out unless asked. ' +
    'A hint, not proof: widen the search with also/search_dir before deleting anything of a package''s public API.',
    SCHEMA_UNUSED, MCP_ANN_RO));
  Tools.Add(MakeTool('code_extract_method',
    'Extract the selected statements (start/end line and column, whole statements) into a new ' +
    'procedure, sub procedure or method named name; the CodeTools engine works out the parameters ' +
    'and replaces the statements with a call. dry_run reports which kinds are possible and what the ' +
    'new routine would miss. The changed files stay unsaved (Ctrl+Z works) unless auto_save.',
    SCHEMA_EXTRACT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('package_move_unit',
    'Move a unit from one package to another (both by name or .lpk): adds it to the target, removes it ' +
    'from the source, and adds the package requirement the move makes necessary (refused when the two ' +
    'would need each other). The file itself stays where it is. dry_run shows the plan.',
    SCHEMA_MOVE_UNIT, MCP_ANN_WRITE));
end;

initialization
  RegisterMcpGroup(@DispatchNav);
  RegisterMcpSchemas(@RegisterNavSchemas);

end.
