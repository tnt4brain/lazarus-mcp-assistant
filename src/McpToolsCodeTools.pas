{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsCodeTools;

{ Codetools / search tools: get_symbol_declaration, get_identifier_context,
  get_code_outline, find_all_references, rename_identifier, goto_declaration,
  create_unit, add_unit_to_uses, insert_in_procedure, replace_procedure_body,
  add_to_class_section.
  Schema registration also covers get_unit_interface and search_in_project,
  which run off the main thread and remain handled in HandleToolsCall. }

{$mode objfpc}{$H+}

interface

implementation

uses
  Classes, SysUtils, StrUtils,
  LazIDEIntf, SrcEditorIntf, ProjectIntf, LazFileUtils,
  CodeToolManager, CodeCache, CodeTree, AVL_Tree,
  Controls,
  fpjson, jsonparser,
  McpToolContext;

{ ── Schema constants ─────────────────────────────────────────────────────── }

const
  SCHEMA_GET_SYMBOL_DECLARATION =
    '{"type":"object","properties":{' +
    '"symbol":{"type":"string","description":"Identifier name to look up"},' +
    '"file":{"type":"string","description":"Absolute path of the file containing the identifier"}},' +
    '"required":["symbol","file"]}';

  SCHEMA_GET_UNIT_INTERFACE =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path to the .pas file"}},' +
    '"required":["file"]}';

  SCHEMA_GET_IDENTIFIER_CONTEXT =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path to the file"},' +
    '"line":{"type":"integer","description":"Line number (1-based)"},' +
    '"col":{"type":"integer","description":"Column number (1-based)"}},' +
    '"required":["file","line","col"]}';

  SCHEMA_GET_CODE_OUTLINE =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path to the .pas file"}},' +
    '"required":["file"]}';

  SCHEMA_FIND_ALL_REFERENCES =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path to the file containing the declaration"},' +
    '"line":{"type":"integer","description":"Line of the declaration (1-based)"},' +
    '"col":{"type":"integer","description":"Column of the declaration (1-based)"}},' +
    '"required":["file","line","col"]}';

  SCHEMA_RENAME_IDENTIFIER =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path to the file containing the declaration"},' +
    '"line":{"type":"integer","description":"Line of the declaration (1-based)"},' +
    '"col":{"type":"integer","description":"Column of the declaration (1-based)"},' +
    '"new_name":{"type":"string","description":"New identifier name"}},' +
    '"required":["file","line","col","new_name"]}';

  SCHEMA_GOTO_DECLARATION =
    '{"type":"object","properties":{' +
    '"symbol":{"type":"string","description":"Identifier name to look up"},' +
    '"file":{"type":"string","description":"Absolute path of the file that contains (or imports) the identifier"}},' +
    '"required":["symbol","file"]}';

  SCHEMA_SEARCH_IN_PROJECT =
    '{"type":"object","properties":{' +
    '"query":{"type":"string","description":"Text or substring to search for (case-insensitive)"}},' +
    '"required":["query"]}';

  SCHEMA_CREATE_UNIT =
    '{"type":"object","properties":{' +
    '"filename":{"type":"string","description":"Absolute path for the new .pas file"},' +
    '"content":{"type":"string","description":"Full source content; omit for a blank unit skeleton"}},' +
    '"required":["filename"]}';

  SCHEMA_ADD_UNIT_TO_USES =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path to the Pascal file to modify"},' +
    '"unit_name":{"type":"string","description":"Unit name to add to the uses clause"},' +
    '"in_interface":{"type":"boolean","description":"Add to interface uses (true, default) or implementation uses (false)"}},' +
    '"required":["file","unit_name"]}';

  SCHEMA_INSERT_IN_PROCEDURE =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path to the .pas file"},' +
    '"proc_name":{"type":"string","description":"Procedure or function name, without class prefix"},' +
    '"class_name":{"type":"string","description":"Class name for a method; omit for a standalone procedure"},' +
    '"text":{"type":"string","description":"Pascal text to insert at the start of the procedure body, immediately after begin"},' +
    '"auto_save":{"type":"boolean","description":"Save the file to disk immediately after editing (default false)"}},' +
    '"required":["file","proc_name","text"]}';

  SCHEMA_REPLACE_PROCEDURE_BODY =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path to the .pas file"},' +
    '"proc_name":{"type":"string","description":"Procedure or function name, without class prefix"},' +
    '"class_name":{"type":"string","description":"Class name for a method; omit for a standalone procedure"},' +
    '"new_body":{"type":"string","description":"New body content placed between begin and end; replaces everything currently there"},' +
    '"auto_save":{"type":"boolean","description":"Save the file to disk immediately after editing (default false)"}},' +
    '"required":["file","proc_name","new_body"]}';

  SCHEMA_ADD_TO_CLASS_SECTION =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path to the .pas file"},' +
    '"class_name":{"type":"string","description":"Class type name (e.g. TMyForm)"},' +
    '"section":{"type":"string","description":"Class section to append to: public (default), private, protected, or published"},' +
    '"text":{"type":"string","description":"Declaration text to append to the section"},' +
    '"auto_save":{"type":"boolean","description":"Save the file to disk immediately after editing (default false)"}},' +
    '"required":["file","class_name","text"]}';

  SCHEMA_GET_AST_PARTIAL =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path to the .pas file"},' +
    '"proc_name":{"type":"string","description":"Procedure or function name to inspect (without class prefix)"},' +
    '"class_name":{"type":"string","description":"Class name for a method; omit for standalone procedures"},' +
    '"line":{"type":"integer","description":"1-based line inside the procedure — alternative to proc_name; finds the enclosing scope"},' +
    '"col":{"type":"integer","description":"1-based column used together with line"}},' +
    '"required":["file"]}';

{ ── Structural helpers ───────────────────────────────────────────────────── }

{ Extract qualified name from a ctnProcedure node's source line, lower-cased.
  E.g. 'TMyClass.DoSomething' or 'dosomething'. }
function ExtractProcNodeName(CodeBuf: TCodeBuffer;
  Node: TCodeTreeNode): string;
var
  L, C, I : Integer;
  S       : string;
begin
  Result := '';
  CodeBuf.AbsoluteToLineCol(Node.StartPos, L, C);
  S := Trim(CodeBuf.GetLine(L - 1, False));
  I := 1;
  while (I <= Length(S)) and not (S[I] in [' ', #9]) do Inc(I);
  S := Trim(Copy(S, I, MaxInt));
  I := 1;
  while (I <= Length(S)) and (S[I] in ['A'..'Z','a'..'z','0'..'9','_','.']) do Inc(I);
  Result := LowerCase(Copy(S, 1, I - 1));
end;

{ Find the begin..end block of a named procedure/function.
  Returns line numbers of begin and end (1-based). }
function FindProcBodyLines(Tool: TCodeTool; CodeBuf: TCodeBuffer;
  const ProcName, ClassName: string;
  out BeginLine, EndLine: Integer): Boolean;
var
  Node      : TCodeTreeNode;
  Child     : TCodeTreeNode;
  BeginNode : TCodeTreeNode;
  NodeName  : string;
  SearchKey : string;
  C         : Integer;
begin
  Result    := False;
  BeginLine := 0;
  EndLine   := 0;
  if ClassName <> '' then
    SearchKey := LowerCase(ClassName + '.' + ProcName)
  else
    SearchKey := LowerCase(ProcName);
  Node := Tool.Tree.Root;
  while Assigned(Node) do
  begin
    if Node.Desc = ctnProcedure then
    begin
      BeginNode := nil;
      Child := Node.FirstChild;
      while Assigned(Child) do
      begin
        if Child.Desc = ctnBeginBlock then begin BeginNode := Child; Break; end;
        Child := Child.NextBrother;
      end;
      if Assigned(BeginNode) then
      begin
        NodeName := ExtractProcNodeName(CodeBuf, Node);
        if (NodeName = SearchKey) or
           ((ClassName = '') and
            (RightStr(NodeName, Length(SearchKey) + 1) = '.' + SearchKey)) then
        begin
          CodeBuf.AbsoluteToLineCol(BeginNode.StartPos,     BeginLine, C);
          CodeBuf.AbsoluteToLineCol(BeginNode.EndPos - 1,   EndLine,   C);
          Result := True;
          Exit;
        end;
      end;
    end;
    if Assigned(Node.FirstChild) then Node := Node.FirstChild
    else if Assigned(Node.NextBrother) then Node := Node.NextBrother
    else
    begin
      repeat Node := Node.Parent until not Assigned(Node) or Assigned(Node.NextBrother);
      if Assigned(Node) then Node := Node.NextBrother;
    end;
  end;
end;

{ Find the line at which to insert into a named class section.
  InsertLine is the first line of the NEXT section (or the end line of the
  class), so ReplaceText(Point(1,InsertLine), Point(1,InsertLine), text+LF)
  inserts text just before that line. }
function FindClassSectionLine(Tool: TCodeTool; CodeBuf: TCodeBuffer;
  const ClassName, SectionName: string;
  out InsertLine: Integer): Boolean;
var
  Node     : TCodeTreeNode;
  ClsNode  : TCodeTreeNode;
  SectNode : TCodeTreeNode;
  SectDesc : TCodeTreeNodeDesc;
  C        : Integer;
begin
  Result     := False;
  InsertLine := 0;
  if LowerCase(SectionName) = 'private' then
    SectDesc := ctnClassPrivate
  else if LowerCase(SectionName) = 'protected' then
    SectDesc := ctnClassProtected
  else if LowerCase(SectionName) = 'published' then
    SectDesc := ctnClassPublished
  else
    SectDesc := ctnClassPublic;
  Node := Tool.Tree.Root;
  while Assigned(Node) do
  begin
    if (Node.Desc = ctnTypeDefinition) and
       (LowerCase(Tool.ExtractIdentifier(Node.StartPos)) = LowerCase(ClassName)) then
    begin
      ClsNode := Node.FirstChild;
      while Assigned(ClsNode) and
            not (ClsNode.Desc in [ctnClass, ctnClassInterface]) do
        ClsNode := ClsNode.NextBrother;
      if Assigned(ClsNode) then
      begin
        SectNode := ClsNode.FirstChild;
        while Assigned(SectNode) and (SectNode.Desc <> SectDesc) do
          SectNode := SectNode.NextBrother;
        if Assigned(SectNode) then
        begin
          if Assigned(SectNode.NextBrother) then
            CodeBuf.AbsoluteToLineCol(SectNode.NextBrother.StartPos, InsertLine, C)
          else
            CodeBuf.AbsoluteToLineCol(ClsNode.EndPos - 1, InsertLine, C);
          Result := True;
          Exit;
        end;
      end;
    end;
    if Assigned(Node.FirstChild) then Node := Node.FirstChild
    else if Assigned(Node.NextBrother) then Node := Node.NextBrother
    else
    begin
      repeat Node := Node.Parent until not Assigned(Node) or Assigned(Node.NextBrother);
      if Assigned(Node) then Node := Node.NextBrother;
    end;
  end;
end;

{ ── Dispatch ─────────────────────────────────────────────────────────────── }

function DispatchCodeToolsTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  FilePath   : string;
  Symbol     : string;
  NewName    : string;
  Col        : Integer;
  Line       : Integer;
  CodeBuf    : TCodeBuffer;
  NewCode    : TCodeBuffer;
  NewX       : Integer;
  NewY       : Integer;
  NewTopLine : Integer;
  DeclPt     : TPoint;
  Snippet    : string;
  Tool       : TCodeTool;
  TreeNode   : TCodeTreeNode;
  Outline    : TJSONArray;
  Entry      : TJSONObject;
  FileListJ  : TJSONArray;
  FileNames  : TStringList;
  RefTree    : TAVLTree;
  RefNode    : TAVLTreeNode;
  RefPos     : PCodeXYPosition;
  RefArr     : TJSONArray;
  RefObj     : TJSONObject;
  Obj        : TJSONObject;
  Ed         : TSourceEditorInterface;
  Proj       : TLazProject;
  PasName    : string;
  I, J                 : Integer;
  BeginLine, EndLine   : Integer;
  InsertLine           : Integer;
  BeginNode            : TCodeTreeNode;
  Child                : TCodeTreeNode;
  AutoSave             : Boolean;
begin
  Result := False;

  if Name = 'get_symbol_declaration' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) then
    begin
      Ctx.Error := True; Ctx.Result := 'Missing params'; Exit;
    end;
    Symbol   := Ctx.Params.Get('symbol', '');
    FilePath := Ctx.Params.Get('file',   '');
    if (Symbol = '') or (FilePath = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'symbol and file arguments required'; Exit;
    end;
    CodeBuf := CodeToolBoss.LoadFile(FilePath, False, False);
    if not Assigned(CodeBuf) then
    begin
      Ctx.Error := True; Ctx.Result := 'Could not load file: ' + FilePath; Exit;
    end;
    if CodeToolBoss.FindDeclarationInInterface(CodeBuf, Symbol,
         NewCode, NewX, NewY, NewTopLine) then
    begin
      Obj := TJSONObject.Create;
      try
        Obj.Add('declaration_file', NewCode.Filename);
        Obj.Add('line', NewY);
        Obj.Add('col',  NewX);
        if NewY >= 1 then
        begin
          Snippet := NewCode.GetLine(NewY - 1, False);
          Obj.Add('context', Trim(Snippet));
        end;
        Ctx.Result := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    end
    else
    begin
      Ctx.Error  := True;
      Ctx.Result := 'Declaration not found for: ' + Symbol +
                    ' (' + CodeToolBoss.ErrorMessage + ')';
    end;
  end

  else if Name = 'get_identifier_context' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) then
    begin
      Ctx.Error := True; Ctx.Result := 'Missing params'; Exit;
    end;
    FilePath := Ctx.Params.Get('file', '');
    NewX     := Ctx.Params.Get('col',  0);
    NewY     := Ctx.Params.Get('line', 0);
    if FilePath = '' then
    begin
      Ctx.Error := True; Ctx.Result := 'file argument required'; Exit;
    end;
    CodeBuf := CodeToolBoss.LoadFile(FilePath, False, False);
    if not Assigned(CodeBuf) then
    begin
      Ctx.Error := True; Ctx.Result := 'Could not load file: ' + FilePath; Exit;
    end;
    Snippet := CodeToolBoss.FindSmartHint(CodeBuf, NewX, NewY);
    Ctx.Result := '{"hint":' + TJSONString.Create(Snippet).AsJSON + '}';
  end

  else if Name = 'get_code_outline' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('file', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'file argument required'; Exit;
    end;
    FilePath := Ctx.Params.Get('file', '');
    CodeBuf  := CodeToolBoss.LoadFile(FilePath, False, False);
    if not Assigned(CodeBuf) then
    begin
      Ctx.Error := True; Ctx.Result := 'Could not load: ' + FilePath; Exit;
    end;
    if not CodeToolBoss.Explore(CodeBuf, Tool, False, True) then
    begin
      Ctx.Error := True; Ctx.Result := 'Parse error: ' + CodeToolBoss.ErrorMessage; Exit;
    end;
    Outline := TJSONArray.Create;
    try
      TreeNode := Tool.Tree.Root;
      while Assigned(TreeNode) do
      begin
        if TreeNode.Desc in [ctnTypeDefinition, ctnVarDefinition,
                              ctnProcedure, ctnUseUnit] then
        begin
          CodeBuf.AbsoluteToLineCol(TreeNode.StartPos, NewY, NewX);
          Entry := TJSONObject.Create;
          Entry.Add('kind', NodeDescriptionAsString(TreeNode.Desc));
          Entry.Add('line', NewY);
          Entry.Add('name', Tool.ExtractIdentifier(TreeNode.StartPos));
          Outline.Add(Entry);
        end;
        if Assigned(TreeNode.FirstChild) and
           (TreeNode.Desc in [ctnUnit, ctnInterface, ctnImplementation,
                               ctnTypeSection, ctnVarSection, ctnConstSection,
                               ctnUsesSection, ctnTypeDefinition,
                               ctnClass, ctnRecordType, ctnObject]) then
          TreeNode := TreeNode.FirstChild
        else if Assigned(TreeNode.NextBrother) then
          TreeNode := TreeNode.NextBrother
        else
        begin
          TreeNode := TreeNode.Parent;
          while Assigned(TreeNode) and not Assigned(TreeNode.NextBrother) do
            TreeNode := TreeNode.Parent;
          if Assigned(TreeNode) then
            TreeNode := TreeNode.NextBrother;
        end;
      end;
      Ctx.Result := Outline.AsJSON;
    finally
      Outline.Free;
    end;
  end

  else if Name = 'find_all_references' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) then
    begin
      Ctx.Error := True; Ctx.Result := 'Missing params'; Exit;
    end;
    FilePath := Ctx.Params.Get('file', '');
    NewX     := Ctx.Params.Get('col',  0);
    NewY     := Ctx.Params.Get('line', 0);
    if FilePath = '' then
    begin
      Ctx.Error := True; Ctx.Result := 'file argument required'; Exit;
    end;
    CodeBuf := CodeToolBoss.LoadFile(FilePath, False, False);
    if not Assigned(CodeBuf) then
    begin
      Ctx.Error := True; Ctx.Result := 'Could not load: ' + FilePath; Exit;
    end;
    FileListJ := TJSONArray(GetJSON(Ctx.FileList));
    FileNames := TStringList.Create;
    RefTree   := nil;
    try
      for J := 0 to FileListJ.Count - 1 do
        FileNames.Add(FileListJ.Strings[J]);
      DeclPt := Point(NewX, NewY);
      if not CodeToolBoss.FindReferencesInFiles(FileNames, CodeBuf,
             DeclPt, False, RefTree) then
      begin
        Ctx.Error  := True;
        Ctx.Result := 'FindReferences failed: ' + CodeToolBoss.ErrorMessage;
        Exit;
      end;
      RefArr := TJSONArray.Create;
      try
        if Assigned(RefTree) then
        begin
          RefNode := RefTree.FindLowest;
          while Assigned(RefNode) do
          begin
            RefPos := PCodeXYPosition(RefNode.Data);
            RefObj := TJSONObject.Create;
            RefObj.Add('file', RefPos^.Code.Filename);
            RefObj.Add('line', RefPos^.Y);
            RefObj.Add('col',  RefPos^.X);
            RefArr.Add(RefObj);
            RefNode := RefNode.Successor;
          end;
        end;
        Ctx.Result := RefArr.AsJSON;
      finally
        RefArr.Free;
      end;
    finally
      FileNames.Free;
      FileListJ.Free;
      if Assigned(RefTree) then
        CodeToolBoss.FreeTreeOfPCodeXYPosition(RefTree);
    end;
  end

  else if Name = 'rename_identifier' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) then
    begin
      Ctx.Error := True; Ctx.Result := 'Missing params'; Exit;
    end;
    FilePath := Ctx.Params.Get('file',     '');
    NewX     := Ctx.Params.Get('col',       0);
    NewY     := Ctx.Params.Get('line',      0);
    NewName  := Ctx.Params.Get('new_name', '');
    if (FilePath = '') or (NewName = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'file and new_name required'; Exit;
    end;
    for I := 0 to SourceEditorManagerIntf.SourceEditorCount - 1 do
    begin
      Ed := SourceEditorManagerIntf.SourceEditors[I];
      if Ed.Modified then
        LazarusIDE.DoSaveEditorFile(Ed, []);
    end;
    CodeBuf := CodeToolBoss.LoadFile(FilePath, False, False);
    if not Assigned(CodeBuf) then
    begin
      Ctx.Error := True; Ctx.Result := 'Could not load: ' + FilePath; Exit;
    end;
    Snippet := CodeBuf.GetLine(NewY - 1, False);
    I := NewX;
    while (I > 1) and (Snippet[I - 1] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
      Dec(I);
    Symbol := '';
    while (I <= Length(Snippet)) and (Snippet[I] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
    begin
      Symbol := Symbol + Snippet[I];
      Inc(I);
    end;
    if Symbol = '' then
    begin
      Ctx.Error := True;
      Ctx.Result := 'No identifier at line ' + IntToStr(NewY) + ' col ' + IntToStr(NewX);
      Exit;
    end;
    FileListJ := TJSONArray(GetJSON(Ctx.FileList));
    FileNames := TStringList.Create;
    RefTree   := nil;
    try
      for J := 0 to FileListJ.Count - 1 do
        FileNames.Add(FileListJ.Strings[J]);
      DeclPt := Point(NewX, NewY);
      if not CodeToolBoss.FindReferencesInFiles(FileNames, CodeBuf,
             DeclPt, False, RefTree) then
      begin
        Ctx.Error  := True;
        Ctx.Result := 'FindReferences failed: ' + CodeToolBoss.ErrorMessage;
        Exit;
      end;
      if not CodeToolBoss.RenameIdentifier(RefTree, Symbol, NewName,
             CodeBuf, @DeclPt, False) then
      begin
        Ctx.Error  := True;
        Ctx.Result := 'RenameIdentifier failed: ' + CodeToolBoss.ErrorMessage;
        Exit;
      end;
      if not CodeToolBoss.ApplyChanges then
      begin
        Ctx.Error := True; Ctx.Result := 'ApplyChanges failed'; Exit;
      end;
      RefArr := TJSONArray.Create;
      try
        for J := 0 to FileNames.Count - 1 do
        begin
          NewCode := CodeToolBoss.SourceCache.FindFile(FileNames[J]);
          if Assigned(NewCode) and NewCode.Modified then
          begin
            NewCode.Save;
            LazarusIDE.DoRevertEditorFile(NewCode.Filename);
            RefArr.Add(NewCode.Filename);
          end;
        end;
        Obj := TJSONObject.Create;
        try
          Obj.Add('renamed_to',    NewName);
          Obj.Add('files_changed', RefArr.Count);
          Obj.Add('files',         RefArr.Clone as TJSONArray);
          Ctx.Result := Obj.AsJSON;
        finally
          Obj.Free;
        end;
      finally
        RefArr.Free;
      end;
    finally
      FileNames.Free;
      FileListJ.Free;
      if Assigned(RefTree) then
        CodeToolBoss.FreeTreeOfPCodeXYPosition(RefTree);
    end;
  end

  else if Name = 'goto_declaration' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) then
    begin
      Ctx.Error := True; Ctx.Result := 'symbol and file required'; Exit;
    end;
    Symbol   := Ctx.Params.Get('symbol', '');
    FilePath := Ctx.Params.Get('file',   '');
    if (Symbol = '') or (FilePath = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'symbol and file required'; Exit;
    end;
    CodeBuf := CodeToolBoss.LoadFile(FilePath, False, False);
    if not Assigned(CodeBuf) then
    begin
      Ctx.Error := True; Ctx.Result := 'Could not load file: ' + FilePath; Exit;
    end;
    if not CodeToolBoss.FindDeclarationInInterface(CodeBuf, Symbol,
             NewCode, NewX, NewY, NewTopLine) then
    begin
      Ctx.Error  := True;
      Ctx.Result := 'Declaration not found for: ' + Symbol +
                    ' (' + CodeToolBoss.ErrorMessage + ')';
      Exit;
    end;
    DeclPt := Point(NewX, NewY);
    if LazarusIDE.DoOpenFileAndJumpToPos(NewCode.Filename, DeclPt,
         NewTopLine, -1, -1, [ofOnlyIfExists, ofRegularFile]) <> mrOK then
    begin
      Ctx.Error := True; Ctx.Result := 'Could not open: ' + NewCode.Filename; Exit;
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('declaration_file', NewCode.Filename);
      Obj.Add('line', NewY);
      Obj.Add('col',  NewX);
      if NewY >= 1 then
        Obj.Add('context', Trim(NewCode.GetLine(NewY - 1, False)));
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'create_unit' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('filename', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'filename required'; Exit;
    end;
    FilePath := Ctx.Params.Get('filename', '');
    if not FilenameIsAbsolute(FilePath) then
    begin
      Proj := LazarusIDE.ActiveProject;
      if Assigned(Proj) then
        FilePath := AppendPathDelim(ExtractFilePath(Proj.ProjectInfoFile)) + FilePath
      else
      begin
        Ctx.Error := True; Ctx.Result := 'No active project to resolve relative path'; Exit;
      end;
    end;
    if FileExists(FilePath) then
    begin
      Ctx.Error := True; Ctx.Result := 'File already exists: ' + FilePath; Exit;
    end;
    NewName := Ctx.Params.Get('content', '');
    if NewName = '' then
    begin
      PasName := ChangeFileExt(ExtractFileName(FilePath), '');
      NewName :=
        'unit ' + PasName + ';' + LineEnding +
        LineEnding +
        '{$mode objfpc}{$H+}' + LineEnding +
        LineEnding +
        'interface' + LineEnding +
        LineEnding +
        'implementation' + LineEnding +
        LineEnding +
        'end.' + LineEnding;
    end;
    CodeBuf := CodeToolBoss.CreateFile(FilePath);
    if not Assigned(CodeBuf) then
    begin
      Ctx.Error := True; Ctx.Result := 'Could not create buffer for: ' + FilePath; Exit;
    end;
    CodeBuf.Source := NewName;
    if not CodeBuf.Save then
    begin
      Ctx.Error := True; Ctx.Result := 'Could not save: ' + FilePath; Exit;
    end;
    Proj := LazarusIDE.ActiveProject;
    if Assigned(Proj) then
      Proj.AddFile(Proj.CreateProjectFile(FilePath), False);
    LazarusIDE.DoOpenEditorFile(FilePath, -1, -1, [ofRegularFile]);
    Obj := TJSONObject.Create;
    try
      Obj.Add('filename', FilePath);
      Obj.Add('created',  True);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'add_unit_to_uses' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) then
    begin
      Ctx.Error := True; Ctx.Result := 'Missing params'; Exit;
    end;
    FilePath := Ctx.Params.Get('file',      '');
    Symbol   := Ctx.Params.Get('unit_name', '');
    if (FilePath = '') or (Symbol = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'file and unit_name required'; Exit;
    end;
    Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(FilePath);
    if Assigned(Ed) and Ed.Modified then
      LazarusIDE.DoSaveEditorFile(FilePath, []);
    CodeBuf := CodeToolBoss.LoadFile(FilePath, False, False);
    if not Assigned(CodeBuf) then
    begin
      Ctx.Error := True; Ctx.Result := 'Could not load: ' + FilePath; Exit;
    end;
    if Ctx.Params.Get('in_interface', True) then
    begin
      if not CodeToolBoss.AddUnitToMainUsesSection(CodeBuf, Symbol, '') then
      begin
        Ctx.Error := True;
        Ctx.Result := 'AddUnitToMainUsesSection failed: ' + CodeToolBoss.ErrorMessage;
        Exit;
      end;
    end
    else
    begin
      if not CodeToolBoss.AddUnitToImplementationUsesSection(CodeBuf, Symbol, '') then
      begin
        Ctx.Error := True;
        Ctx.Result := 'AddUnitToImplementationUsesSection failed: ' + CodeToolBoss.ErrorMessage;
        Exit;
      end;
    end;
    if not CodeToolBoss.ApplyChanges then
    begin
      Ctx.Error := True; Ctx.Result := 'ApplyChanges failed'; Exit;
    end;
    CodeBuf.Save;
    LazarusIDE.DoRevertEditorFile(FilePath);
    Obj := TJSONObject.Create;
    try
      Obj.Add('file',      FilePath);
      Obj.Add('unit_name', Symbol);
      Obj.Add('added',     True);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'insert_in_procedure' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) then
    begin
      Ctx.Error := True; Ctx.Result := 'Missing params'; Exit;
    end;
    FilePath := Ctx.Params.Get('file',       '');
    Symbol   := Ctx.Params.Get('proc_name',  '');
    NewName  := Ctx.Params.Get('class_name', '');
    Snippet  := Ctx.Params.Get('text',       '');
    AutoSave := Ctx.Params.Get('auto_save',  False);
    if (FilePath = '') or (Symbol = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'file and proc_name required'; Exit;
    end;
    Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(FilePath);
    if Assigned(Ed) and Ed.Modified then LazarusIDE.DoSaveEditorFile(FilePath, []);
    CodeBuf := CodeToolBoss.LoadFile(FilePath, False, False);
    if not Assigned(CodeBuf) then
    begin
      Ctx.Error := True; Ctx.Result := 'Could not load: ' + FilePath; Exit;
    end;
    if not CodeToolBoss.Explore(CodeBuf, Tool, True, False) then
    begin
      Ctx.Error := True; Ctx.Result := 'Parse error: ' + CodeToolBoss.ErrorMessage; Exit;
    end;
    if not FindProcBodyLines(Tool, CodeBuf, Symbol, NewName, BeginLine, EndLine) then
    begin
      Ctx.Error := True; Ctx.Result := 'Procedure not found: ' + Symbol; Exit;
    end;
    if not Assigned(Ed) then
    begin
      if LazarusIDE.DoOpenEditorFile(FilePath, -1, -1,
           [ofOnlyIfExists, ofRegularFile]) <> mrOK then
      begin
        Ctx.Error := True; Ctx.Result := 'Could not open: ' + FilePath; Exit;
      end;
      Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(FilePath);
    end;
    Snippet := StringReplace(Snippet, #13#10, #10, [rfReplaceAll]);
    Ed.ReplaceText(Point(1, BeginLine + 1), Point(1, BeginLine + 1),
                   Snippet + #10);
    if AutoSave then LazarusIDE.DoSaveEditorFile(FilePath, []);
    Obj := TJSONObject.Create;
    try
      Obj.Add('file',       FilePath);
      Obj.Add('procedure',  Symbol);
      Obj.Add('begin_line', BeginLine);
      Obj.Add('inserted',   True);
      if AutoSave then Obj.Add('saved', True);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'replace_procedure_body' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) then
    begin
      Ctx.Error := True; Ctx.Result := 'Missing params'; Exit;
    end;
    FilePath := Ctx.Params.Get('file',       '');
    Symbol   := Ctx.Params.Get('proc_name',  '');
    NewName  := Ctx.Params.Get('class_name', '');
    Snippet  := Ctx.Params.Get('new_body',   '');
    AutoSave := Ctx.Params.Get('auto_save',  False);
    if (FilePath = '') or (Symbol = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'file and proc_name required'; Exit;
    end;
    Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(FilePath);
    if Assigned(Ed) and Ed.Modified then LazarusIDE.DoSaveEditorFile(FilePath, []);
    CodeBuf := CodeToolBoss.LoadFile(FilePath, False, False);
    if not Assigned(CodeBuf) then
    begin
      Ctx.Error := True; Ctx.Result := 'Could not load: ' + FilePath; Exit;
    end;
    if not CodeToolBoss.Explore(CodeBuf, Tool, True, False) then
    begin
      Ctx.Error := True; Ctx.Result := 'Parse error: ' + CodeToolBoss.ErrorMessage; Exit;
    end;
    if not FindProcBodyLines(Tool, CodeBuf, Symbol, NewName, BeginLine, EndLine) then
    begin
      Ctx.Error := True; Ctx.Result := 'Procedure not found: ' + Symbol; Exit;
    end;
    if not Assigned(Ed) then
    begin
      if LazarusIDE.DoOpenEditorFile(FilePath, -1, -1,
           [ofOnlyIfExists, ofRegularFile]) <> mrOK then
      begin
        Ctx.Error := True; Ctx.Result := 'Could not open: ' + FilePath; Exit;
      end;
      Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(FilePath);
    end;
    Snippet := StringReplace(Snippet, #13#10, #10, [rfReplaceAll]);
    Ed.ReplaceText(Point(1, BeginLine + 1), Point(1, EndLine),
                   Snippet + #10);
    if AutoSave then LazarusIDE.DoSaveEditorFile(FilePath, []);
    Obj := TJSONObject.Create;
    try
      Obj.Add('file',       FilePath);
      Obj.Add('procedure',  Symbol);
      Obj.Add('begin_line', BeginLine);
      Obj.Add('end_line',   EndLine);
      Obj.Add('replaced',   True);
      if AutoSave then Obj.Add('saved', True);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'add_to_class_section' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) then
    begin
      Ctx.Error := True; Ctx.Result := 'Missing params'; Exit;
    end;
    FilePath := Ctx.Params.Get('file',       '');
    Symbol   := Ctx.Params.Get('class_name', '');
    NewName  := Ctx.Params.Get('section',    'public');
    Snippet  := Ctx.Params.Get('text',       '');
    AutoSave := Ctx.Params.Get('auto_save',  False);
    if (FilePath = '') or (Symbol = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'file and class_name required'; Exit;
    end;
    Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(FilePath);
    if Assigned(Ed) and Ed.Modified then LazarusIDE.DoSaveEditorFile(FilePath, []);
    CodeBuf := CodeToolBoss.LoadFile(FilePath, False, False);
    if not Assigned(CodeBuf) then
    begin
      Ctx.Error := True; Ctx.Result := 'Could not load: ' + FilePath; Exit;
    end;
    if not CodeToolBoss.Explore(CodeBuf, Tool, False, False) then
    begin
      Ctx.Error := True; Ctx.Result := 'Parse error: ' + CodeToolBoss.ErrorMessage; Exit;
    end;
    if not FindClassSectionLine(Tool, CodeBuf, Symbol, NewName, InsertLine) then
    begin
      Ctx.Error := True;
      Ctx.Result := 'Class or section not found: ' + Symbol + ' / ' + NewName;
      Exit;
    end;
    if not Assigned(Ed) then
    begin
      if LazarusIDE.DoOpenEditorFile(FilePath, -1, -1,
           [ofOnlyIfExists, ofRegularFile]) <> mrOK then
      begin
        Ctx.Error := True; Ctx.Result := 'Could not open: ' + FilePath; Exit;
      end;
      Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(FilePath);
    end;
    Snippet := StringReplace(Snippet, #13#10, #10, [rfReplaceAll]);
    Ed.ReplaceText(Point(1, InsertLine), Point(1, InsertLine),
                   Snippet + #10);
    if AutoSave then LazarusIDE.DoSaveEditorFile(FilePath, []);
    Obj := TJSONObject.Create;
    try
      Obj.Add('file',     FilePath);
      Obj.Add('class',    Symbol);
      Obj.Add('section',  NewName);
      Obj.Add('inserted', True);
      if AutoSave then Obj.Add('saved', True);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'get_ast_partial' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) then
    begin
      Ctx.Error := True; Ctx.Result := 'Missing params'; Exit;
    end;
    FilePath := Ctx.Params.Get('file',       '');
    Symbol   := Ctx.Params.Get('proc_name',  '');
    NewName  := Ctx.Params.Get('class_name', '');
    NewY     := Ctx.Params.Get('line',       0);
    NewX     := Ctx.Params.Get('col',        0);
    if FilePath = '' then
    begin
      Ctx.Error := True; Ctx.Result := 'file required'; Exit;
    end;
    if (Symbol = '') and (NewY = 0) then
    begin
      Ctx.Error := True; Ctx.Result := 'proc_name or line required'; Exit;
    end;
    CodeBuf := CodeToolBoss.LoadFile(FilePath, False, False);
    if not Assigned(CodeBuf) then
    begin
      Ctx.Error := True; Ctx.Result := 'Could not load: ' + FilePath; Exit;
    end;
    if not CodeToolBoss.Explore(CodeBuf, Tool, True, False) then
    begin
      Ctx.Error := True; Ctx.Result := 'Parse error: ' + CodeToolBoss.ErrorMessage; Exit;
    end;
    BeginNode := nil;
    BeginLine := 0;
    EndLine   := 0;
    if Symbol <> '' then
    begin
      { Name-based: use FindProcBodyLines to get lines, then find BeginBlock node }
      if not FindProcBodyLines(Tool, CodeBuf, Symbol, NewName, BeginLine, EndLine) then
      begin
        Ctx.Error := True; Ctx.Result := 'Procedure not found: ' + Symbol; Exit;
      end;
      TreeNode := Tool.Tree.Root;
      while Assigned(TreeNode) do
      begin
        if TreeNode.Desc = ctnProcedure then
        begin
          Child := TreeNode.FirstChild;
          while Assigned(Child) do
          begin
            if Child.Desc = ctnBeginBlock then
            begin
              CodeBuf.AbsoluteToLineCol(Child.StartPos, I, J);
              if I = BeginLine then begin BeginNode := Child; Break; end;
            end;
            Child := Child.NextBrother;
          end;
          if Assigned(BeginNode) then Break;
        end;
        if Assigned(TreeNode.FirstChild) then TreeNode := TreeNode.FirstChild
        else if Assigned(TreeNode.NextBrother) then TreeNode := TreeNode.NextBrother
        else
        begin
          repeat TreeNode := TreeNode.Parent until not Assigned(TreeNode) or Assigned(TreeNode.NextBrother);
          if Assigned(TreeNode) then TreeNode := TreeNode.NextBrother;
        end;
      end;
    end
    else
    begin
      { Position-based: find BeginBlock whose line range contains NewY }
      TreeNode := Tool.Tree.Root;
      while Assigned(TreeNode) do
      begin
        if TreeNode.Desc = ctnProcedure then
        begin
          Child := TreeNode.FirstChild;
          while Assigned(Child) do
          begin
            if Child.Desc = ctnBeginBlock then
            begin
              CodeBuf.AbsoluteToLineCol(Child.StartPos,   I, J);
              CodeBuf.AbsoluteToLineCol(Child.EndPos - 1, EndLine, J);
              if (NewY >= I) and (NewY <= EndLine) then
              begin
                BeginNode := Child;
                BeginLine := I;
                Symbol    := ExtractProcNodeName(CodeBuf, TreeNode);
                Break;
              end;
            end;
            Child := Child.NextBrother;
          end;
          if Assigned(BeginNode) then Break;
        end;
        if Assigned(TreeNode.FirstChild) then TreeNode := TreeNode.FirstChild
        else if Assigned(TreeNode.NextBrother) then TreeNode := TreeNode.NextBrother
        else
        begin
          repeat TreeNode := TreeNode.Parent until not Assigned(TreeNode) or Assigned(TreeNode.NextBrother);
          if Assigned(TreeNode) then TreeNode := TreeNode.NextBrother;
        end;
      end;
      if not Assigned(BeginNode) then
      begin
        Ctx.Error := True;
        Ctx.Result := 'No procedure found containing line ' + IntToStr(NewY);
        Exit;
      end;
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('scope',      Symbol);
      Obj.Add('begin_line', BeginLine);
      Obj.Add('end_line',   EndLine);
      { Locals: ctnVarSection children of the enclosing ctnProcedure }
      Outline := TJSONArray.Create;
      if Assigned(BeginNode) and Assigned(BeginNode.Parent) then
      begin
        Child := BeginNode.Parent.FirstChild;
        while Assigned(Child) do
        begin
          if Child.Desc = ctnVarSection then
          begin
            TreeNode := Child.FirstChild;
            while Assigned(TreeNode) do
            begin
              if TreeNode.Desc = ctnVarDefinition then
              begin
                CodeBuf.AbsoluteToLineCol(TreeNode.StartPos, I, J);
                Entry := TJSONObject.Create;
                Entry.Add('name', Tool.ExtractIdentifier(TreeNode.StartPos));
                Entry.Add('line', I);
                Outline.Add(Entry);
              end;
              TreeNode := TreeNode.NextBrother;
            end;
          end;
          Child := Child.NextBrother;
        end;
      end;
      Obj.Add('locals', Outline);
      { Block-level nodes: direct children of the BeginBlock }
      RefArr := TJSONArray.Create;
      if Assigned(BeginNode) then
      begin
        Child := BeginNode.FirstChild;
        while Assigned(Child) do
        begin
          CodeBuf.AbsoluteToLineCol(Child.StartPos, I, J);
          RefObj := TJSONObject.Create;
          RefObj.Add('kind', LowerCase(NodeDescriptionAsString(Child.Desc)));
          RefObj.Add('line', I);
          if Child.EndPos > Child.StartPos then
          begin
            CodeBuf.AbsoluteToLineCol(Child.EndPos - 1, J, NewTopLine);
            if J > I then RefObj.Add('end_line', J);
          end;
          RefArr.Add(RefObj);
          Child := Child.NextBrother;
        end;
      end;
      Obj.Add('nodes', RefArr);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end;
end;

{ ── Schema registration ──────────────────────────────────────────────────── }

procedure RegisterCodeToolsSchemas(Tools: TJSONArray);
begin
  Tools.Add(MakeTool('get_symbol_declaration',
    'Find where an identifier is declared using Codetools. ' +
    'Returns declaration file, line, column and a short context snippet.',
    SCHEMA_GET_SYMBOL_DECLARATION, MCP_ANN_RO));
  Tools.Add(MakeTool('get_unit_interface',
    'Return only the interface section of a Pascal unit ' +
    '(everything above the implementation keyword).',
    SCHEMA_GET_UNIT_INTERFACE, MCP_ANN_RO));
  Tools.Add(MakeTool('get_identifier_context',
    'Return type, declaration location, and hint text for the identifier ' +
    'at a given file/line/col using Codetools FindSmartHint.',
    SCHEMA_GET_IDENTIFIER_CONTEXT, MCP_ANN_RO));
  Tools.Add(MakeTool('get_code_outline',
    'Return the structural outline of a Pascal unit: uses clauses, type ' +
    'names, class members, and top-level routines with their line numbers. ' +
    'Does not include method bodies.',
    SCHEMA_GET_CODE_OUTLINE, MCP_ANN_RO));
  Tools.Add(MakeTool('find_all_references',
    'Find every reference to the identifier at the given declaration position ' +
    'across all project files.',
    SCHEMA_FIND_ALL_REFERENCES, MCP_ANN_RO));
  Tools.Add(MakeTool('rename_identifier',
    'Rename an identifier at the given declaration position across all ' +
    'project files. WARNING: this operation writes directly to disk and ' +
    'bypasses the IDE undo stack — it CANNOT be undone with Ctrl+Z. ' +
    'Use git to revert if needed. Only call this after confirming the ' +
    'new name with the user.',
    SCHEMA_RENAME_IDENTIFIER, MCP_ANN_DEST));
  Tools.Add(MakeTool('goto_declaration',
    'Find where an identifier is declared and jump the editor cursor there. ' +
    'Opens the declaration file if needed.',
    SCHEMA_GOTO_DECLARATION, MCP_ANN_RO));
  Tools.Add(MakeTool('search_in_project',
    'Search for a text substring across all project source files. ' +
    'Returns matching file, line number, and line content.',
    SCHEMA_SEARCH_IN_PROJECT, MCP_ANN_RO));
  Tools.Add(MakeTool('create_unit',
    'Create a new Pascal unit file on disk, add it to the active project, ' +
    'and open it in the editor. Provide content or receive a blank unit skeleton.',
    SCHEMA_CREATE_UNIT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('add_unit_to_uses',
    'Add a unit to the uses clause of a Pascal file using Codetools. ' +
    'Writes directly to disk (not undoable via Ctrl+Z; use git to revert). ' +
    'Set in_interface=false to target the implementation uses clause.',
    SCHEMA_ADD_UNIT_TO_USES, MCP_ANN_DEST));
  Tools.Add(MakeTool('insert_in_procedure',
    'Insert text at the start of a named procedure or function body (immediately ' +
    'after begin), located via CodeTools AST. No string matching — robust to ' +
    'whitespace and formatting changes. Uses the editor undo stack (Ctrl+Z works).',
    SCHEMA_INSERT_IN_PROCEDURE, MCP_ANN_WRITE));
  Tools.Add(MakeTool('replace_procedure_body',
    'Replace the entire body of a named procedure or function (everything between ' +
    'begin and end) with new_body, located via CodeTools AST. No string matching. ' +
    'Uses the editor undo stack (Ctrl+Z works).',
    SCHEMA_REPLACE_PROCEDURE_BODY, MCP_ANN_WRITE));
  Tools.Add(MakeTool('add_to_class_section',
    'Append a declaration to a named section of a class (public, private, ' +
    'protected, or published), located via CodeTools AST. No string matching. ' +
    'Uses the editor undo stack (Ctrl+Z works).',
    SCHEMA_ADD_TO_CLASS_SECTION, MCP_ANN_WRITE));
  Tools.Add(MakeTool('get_ast_partial',
    'Return the structural content of a named procedure body: local variable ' +
    'declarations and a flat list of block-level control-flow nodes (if, for, ' +
    'while, try, case, repeat, with) with their line ranges. Locate by ' +
    'proc_name (+ optional class_name) or by a line number inside the body. ' +
    'Read-only — use the returned line numbers as inputs to edit_at_position ' +
    'or the Tier-2 structural edit tools.',
    SCHEMA_GET_AST_PARTIAL, MCP_ANN_RO));
end;

initialization
  RegisterMcpGroup(@DispatchCodeToolsTool);
  RegisterMcpSchemas(@RegisterCodeToolsSchemas);

end.
