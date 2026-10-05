{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsCodeTools;

{ Codetools / search tools: get_symbol_declaration, get_identifier_context,
  get_code_outline, find_all_references, rename_identifier, goto_declaration,
  create_unit, add_unit_to_uses.
  Schema registration also covers get_unit_interface and search_in_project,
  which run off the main thread and remain handled in HandleToolsCall. }

{$mode objfpc}{$H+}

interface

implementation

uses
  Classes, SysUtils,
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
  I, J       : Integer;
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
  end;
end;

{ ── Schema registration ──────────────────────────────────────────────────── }

procedure RegisterCodeToolsSchemas(Tools: TJSONArray);
begin
  Tools.Add(MakeTool('get_symbol_declaration',
    'Find where an identifier is declared using Codetools. ' +
    'Returns declaration file, line, column and a short context snippet.',
    SCHEMA_GET_SYMBOL_DECLARATION));
  Tools.Add(MakeTool('get_unit_interface',
    'Return only the interface section of a Pascal unit ' +
    '(everything above the implementation keyword).',
    SCHEMA_GET_UNIT_INTERFACE));
  Tools.Add(MakeTool('get_identifier_context',
    'Return type, declaration location, and hint text for the identifier ' +
    'at a given file/line/col using Codetools FindSmartHint.',
    SCHEMA_GET_IDENTIFIER_CONTEXT));
  Tools.Add(MakeTool('get_code_outline',
    'Return the structural outline of a Pascal unit: uses clauses, type ' +
    'names, class members, and top-level routines with their line numbers. ' +
    'Does not include method bodies.',
    SCHEMA_GET_CODE_OUTLINE));
  Tools.Add(MakeTool('find_all_references',
    'Find every reference to the identifier at the given declaration position ' +
    'across all project files.',
    SCHEMA_FIND_ALL_REFERENCES));
  Tools.Add(MakeTool('rename_identifier',
    'Rename an identifier at the given declaration position across all ' +
    'project files. WARNING: this operation writes directly to disk and ' +
    'bypasses the IDE undo stack — it CANNOT be undone with Ctrl+Z. ' +
    'Use git to revert if needed. Only call this after confirming the ' +
    'new name with the user.',
    SCHEMA_RENAME_IDENTIFIER));
  Tools.Add(MakeTool('goto_declaration',
    'Find where an identifier is declared and jump the editor cursor there. ' +
    'Opens the declaration file if needed.',
    SCHEMA_GOTO_DECLARATION));
  Tools.Add(MakeTool('search_in_project',
    'Search for a text substring across all project source files. ' +
    'Returns matching file, line number, and line content.',
    SCHEMA_SEARCH_IN_PROJECT));
  Tools.Add(MakeTool('create_unit',
    'Create a new Pascal unit file on disk, add it to the active project, ' +
    'and open it in the editor. Provide content or receive a blank unit skeleton.',
    SCHEMA_CREATE_UNIT));
  Tools.Add(MakeTool('add_unit_to_uses',
    'Add a unit to the uses clause of a Pascal file using Codetools. ' +
    'Writes directly to disk (not undoable via Ctrl+Z; use git to revert). ' +
    'Set in_interface=false to target the implementation uses clause.',
    SCHEMA_ADD_UNIT_TO_USES));
end;

initialization
  RegisterMcpGroup(@DispatchCodeToolsTool);
  RegisterMcpSchemas(@RegisterCodeToolsSchemas);

end.
