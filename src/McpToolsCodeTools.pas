{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsCodeTools;

{ Codetools / search tools: code_find_declaration, code_get_unit_interface,
  code_get_identifier_info, code_get_outline, code_find_references, code_rename_identifier,
  code_goto_declaration, project_search, project_create_unit, code_add_uses,
  code_insert_in_procedure, code_replace_procedure_body, code_add_to_class, code_complete,
  code_get_procedure_ast.
  All edit tools work through the editor buffer with an optional auto_save flag. }

{$mode objfpc}{$H+}

interface

uses
  CodeCache;

{ CodeToolBoss.LoadFile that also finds a file created since the IDE last
  looked at its directory: the IDE's file caches still say it does not exist,
  so on failure they are invalidated and the load is tried once more.
  Main thread. }
function McpLoadCode(const AFileName: string; AUpdateFromDisk: Boolean): TCodeBuffer;

implementation

uses
  Classes, SysUtils, StrUtils,
  LazIDEIntf, SrcEditorIntf, ProjectIntf, LazFileUtils, FileUtil,
  CodeToolManager, CodeTree, AVL_Tree, SourceChanger, CodeToolsStrConsts,
  BasicCodeTools,
  Controls,
  fpjson, jsonparser,
  McpToolContext, McpToolHelpers, McpLineDiff;

function McpLoadCode(const AFileName: string; AUpdateFromDisk: Boolean): TCodeBuffer;
begin
  Result := CodeToolBoss.LoadFile(AFileName, AUpdateFromDisk, False);
  if Result <> nil then Exit;
  InvalidateFileStateCache(AFileName);
  CodeToolBoss.DirectoryCachePool.IncreaseFileTimeStamp;
  Result := CodeToolBoss.LoadFile(AFileName, AUpdateFromDisk, False);
end;

{ TMcpReadLines for project_search: an open file is searched in its editor }
function EditorLines(const AFileName: string; ALines: TStrings): Boolean;
var
  Ed : TSourceEditorInterface;
begin
  Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(AFileName);
  Result := Assigned(Ed);
  if Result then ALines.Text := Ed.Lines.Text;
end;

{ Files under ADir matching AMask (FindAllFiles' ';'-separated masks), as
  the JSON array McpDoSearchInProject takes. }
function DirectoryFilesJSON(const ADir, AMask: string): string;
var
  Found : TStringList;
  Arr   : TJSONArray;
  I     : Integer;
begin
  Found := FindAllFiles(ADir, AMask, True);
  Arr   := TJSONArray.Create;
  try
    for I := 0 to Found.Count - 1 do
      Arr.Add(Found[I]);
    Result := Arr.AsJSON;
  finally
    Arr.Free;
    Found.Free;
  end;
end;

{ ── Schema constants ─────────────────────────────────────────────────────── }

const
  SCHEMA_GET_SYMBOL_DECLARATION =
    '{"type":"object","properties":{' +
    '"symbol":{"type":"string","description":"Identifier name to look up"},' +
    '"file":{"type":"string","description":"Absolute path of the file containing the identifier"}},' +
    '"required":["symbol","file"]}';

  SCHEMA_GET_UNIT_INTERFACE =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path"}},' +
    '"required":["file"]}';

  SCHEMA_GET_IDENTIFIER_CONTEXT =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path to the file"},' +
    '"line":{"type":"integer","description":"Line number (1-based)"},' +
    '"col":{"type":"integer","description":"Column number (1-based)"}},' +
    '"required":["file","line","col"]}';

  SCHEMA_GET_CODE_OUTLINE =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path"}},' +
    '"required":["file"]}';

  SCHEMA_FIND_ALL_REFERENCES =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path to the file containing the declaration"},' +
    '"line":{"type":"integer","description":"Line of the declaration (1-based)"},' +
    '"col":{"type":"integer","description":"Column of the declaration (1-based)"}},' +
    '"required":["file","line","col"]}';

  SCHEMA_RENAME_IDENTIFIER =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path to a file with the declaration or a reference"},' +
    '"line":{"type":"integer","description":"Line of the identifier (1-based)"},' +
    '"col":{"type":"integer","description":"Column of the identifier (1-based)"},' +
    '"new_name":{"type":"string","description":"New identifier name (not needed with dry_run)"},' +
    '"dry_run":{"type":"boolean","description":"List the references with their line text and change nothing (default false)"},' +
    '"auto_save":{"type":"boolean","description":"Save the changed files after renaming (default false: they stay unsaved, Ctrl+Z works)"}},' +
    '"required":["file","line","col"]}';

  SCHEMA_GOTO_DECLARATION =
    '{"type":"object","properties":{' +
    '"symbol":{"type":"string","description":"Identifier name to look up"},' +
    '"file":{"type":"string","description":"Absolute path of the file that contains (or imports) the identifier"}},' +
    '"required":["symbol","file"]}';

  SCHEMA_SEARCH_IN_PROJECT =
    '{"type":"object","properties":{' +
    '"query":{"type":"string","description":"Text or substring to search for (case-insensitive)"},' +
    '"directory":{"type":"string","description":"Search this folder and its subfolders ' +
    'instead of the project''s files, e.g. a package''s source folder"},' +
    '"mask":{"type":"string","description":"With directory: file masks, default ' +
    '*.pas;*.pp;*.inc;*.lpr;*.dpr;*.lfm"}},' +
    '"required":["query"]}';

  SCHEMA_LIST_TODOS =
    '{"type":"object","properties":{' +
    '"include_done":{"type":"boolean","description":"Also list DONE items (default false)"}}}';

  SCHEMA_CREATE_UNIT =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path for the new .pas file"},' +
    '"content":{"type":"string","description":"Full source content; omit for a blank unit skeleton"}},' +
    '"required":["file"]}';

  SCHEMA_ADD_UNIT_TO_USES =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path to the Pascal file to modify"},' +
    '"unit_name":{"type":"string","description":"Unit name to add to the uses clause"},' +
    '"in_interface":{"type":"boolean","description":"Add to interface uses (true, default) or implementation uses (false)"},' +
    '"auto_save":{"type":"boolean","description":"Also save to disk (default false)"}},' +
    '"required":["file","unit_name"]}';

  SCHEMA_INSERT_IN_PROCEDURE =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path"},' +
    '"proc_name":{"type":"string","description":"Procedure or function name, without class prefix"},' +
    '"class_name":{"type":"string","description":"Class name for a method; omit for a standalone procedure"},' +
    '"text":{"type":"string","description":"Pascal text to insert at the start of the procedure body, immediately after begin"},' +
    '"auto_save":{"type":"boolean","description":"Also save to disk (default false)"}},' +
    '"required":["file","proc_name","text"]}';

  SCHEMA_REPLACE_PROCEDURE_BODY =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path"},' +
    '"proc_name":{"type":"string","description":"Procedure or function name, without class prefix"},' +
    '"class_name":{"type":"string","description":"Class name for a method; omit for a standalone procedure"},' +
    '"new_body":{"type":"string","description":"New body content placed between begin and end; replaces everything currently there"},' +
    '"auto_save":{"type":"boolean","description":"Also save to disk (default false)"}},' +
    '"required":["file","proc_name","new_body"]}';

  SCHEMA_ADD_TO_CLASS_SECTION =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path"},' +
    '"class_name":{"type":"string","description":"Class type name (e.g. TMyForm)"},' +
    '"section":{"type":"string","description":"Class section to append to: public (default), private, protected, or published"},' +
    '"text":{"type":"string","description":"Declaration text to append to the section"},' +
    '"auto_save":{"type":"boolean","description":"Also save to disk (default false)"}},' +
    '"required":["file","class_name","text"]}';

  SCHEMA_GET_AST_PARTIAL =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path"},' +
    '"proc_name":{"type":"string","description":"Procedure or function name to inspect (without class prefix)"},' +
    '"class_name":{"type":"string","description":"Class name for a method; omit for standalone procedures"},' +
    '"line":{"type":"integer","description":"1-based line inside the procedure — alternative to proc_name; finds the enclosing scope"},' +
    '"col":{"type":"integer","description":"1-based column used together with line"}},' +
    '"required":["file"]}';

  SCHEMA_COMPLETE_CODE =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path"},' +
    '"line":{"type":"integer","description":"1-based line of the code to complete"},' +
    '"col":{"type":"integer","description":"1-based column on that line"},' +
    '"auto_save":{"type":"boolean","description":"Also save the changed files to disk (default false)"}},' +
    '"required":["file","line","col"]}';

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

{ code_complete: the IDE's Ctrl+Shift+C at (line, col), without its dialogs.
  As in TMainIDE.DoCompleteCodeAtCursor: the editors are committed to the
  CodeTools buffers (not to disk), CodeTools changes the buffers, and the
  IDE's change hook mirrors each change into the open editor, so Ctrl+Z
  undoes it.  The file is opened first for that hook to be there; other files
  the completion changes are opened by the IDE (OpenEditorsOnCodeToolChange).
  Main thread. }
procedure DoCompleteCode(var Ctx: TMcpToolCall);
var
  FilePath, OldSrc         : string;
  ErrText                  : string;
  Line, Col                : Integer;
  AutoSave, OldOpen, Done  : Boolean;
  CodeBuf, NewCode, Buf    : TCodeBuffer;
  NewX, NewY, NewTopLine   : Integer;
  BlockTop, BlockBottom    : Integer;
  I                        : Integer;
  Obj, Jump                : TJSONObject;
  Others                   : TJSONArray;
  OtherFiles               : TStringList;
begin
  if not Assigned(Ctx.Params) then
  begin
    Ctx.Error := True; Ctx.Result := 'Missing params'; Exit;
  end;
  FilePath := Ctx.Params.Get('file', '');
  Line     := Ctx.Params.Get('line', 0);
  Col      := Ctx.Params.Get('col', 0);
  AutoSave := Ctx.Params.Get('auto_save', False);
  if (FilePath = '') or (Line < 1) or (Col < 1) then
  begin
    Ctx.Error := True; Ctx.Result := 'file, line and col (1-based) required'; Exit;
  end;
  if SourceEditorManagerIntf.SourceEditorIntfWithFilename(FilePath) = nil then
  begin
    { opening a missing file shows the IDE's modal "File not found" }
    if not McpCheckFileToOpen(FilePath, ErrText) then
    begin
      Ctx.Error := True; Ctx.Result := ErrText; Exit;
    end;
    if LazarusIDE.DoOpenEditorFile(FilePath, -1, -1,
         [ofOnlyIfExists, ofRegularFile, ofDoNotActivateSourceEditor]) <> mrOK then
    begin
      Ctx.Error := True; Ctx.Result := 'Could not open: ' + FilePath; Exit;
    end;
  end;
  if not LazarusIDE.BeginCodeTools then
  begin
    Ctx.Error := True;
    Ctx.Result := 'The IDE is busy (building, debugging or another code tool); try again';
    Exit;
  end;
  CodeBuf := McpLoadCode(FilePath, False);
  if not Assigned(CodeBuf) then
  begin
    Ctx.Error := True; Ctx.Result := 'Could not load: ' + FilePath; Exit;
  end;
  if Line > CodeBuf.LineCount then
  begin
    Ctx.Error := True;
    Ctx.Result := Format('line %d is past the end of the file (%d lines)',
                         [Line, CodeBuf.LineCount]);
    Exit;
  end;
  OldSrc := CodeBuf.Source;
  OldOpen := LazarusIDE.OpenEditorsOnCodeToolChange;
  LazarusIDE.OpenEditorsOnCodeToolChange := True;
  OtherFiles := TStringList.Create;
  try
    try
      Done := CodeToolBoss.CompleteCode(CodeBuf, Col, Line, 1, NewCode,
                NewX, NewY, NewTopLine, BlockTop, BlockBottom, False);
      for I := 0 to CodeToolBoss.SourceChangeCache.BuffersToModifyCount - 1 do
      begin
        Buf := CodeToolBoss.SourceChangeCache.BuffersToModify[I];
        if (Buf <> CodeBuf) and (OtherFiles.IndexOf(Buf.Filename) < 0) then
          OtherFiles.Add(Buf.Filename);
      end;
    finally
      LazarusIDE.OpenEditorsOnCodeToolChange := OldOpen;
      CodeToolBoss.SourceCache.ClearAllSourceLogEntries;
    end;
    if CodeToolBoss.ErrorMessage <> '' then
    begin
      Ctx.Error := True;
      Ctx.Result := 'Completion failed: ' + CodeToolBoss.ErrorMessage;
      if Assigned(CodeToolBoss.ErrorCode) then
        Ctx.Result := Ctx.Result + Format(' (%s %d:%d)',
          [ExtractFileName(CodeToolBoss.ErrorCode.Filename),
           CodeToolBoss.ErrorLine, CodeToolBoss.ErrorColumn]);
      Exit;
    end;
    if (CodeBuf.Source = OldSrc) and (OtherFiles.Count = 0) then
    begin
      Ctx.Error := True;
      Ctx.Result := Format('Nothing to complete at %d:%d', [Line, Col]);
      Exit;
    end;
    if AutoSave then
    begin
      LazarusIDE.DoSaveEditorFile(FilePath, []);
      for I := 0 to OtherFiles.Count - 1 do
        LazarusIDE.DoSaveEditorFile(OtherFiles[I], []);
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('file', FilePath);
      Obj.Add('completed', Done);
      Obj.Add('changes', LineHunks(OldSrc, CodeBuf.Source));
      if OtherFiles.Count > 0 then
      begin
        Others := TJSONArray.Create;
        for I := 0 to OtherFiles.Count - 1 do Others.Add(OtherFiles[I]);
        Obj.Add('other_files_changed', Others);
      end;
      if Assigned(NewCode) and (NewY > 0) then
      begin
        Jump := TJSONObject.Create;
        Jump.Add('file', NewCode.Filename);
        Jump.Add('line', NewY);
        Jump.Add('col', NewX);
        Obj.Add('new_position', Jump);
      end;
      Obj.Add('saved', AutoSave);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  finally
    OtherFiles.Free;
  end;
end;

{ code_rename_identifier: the IDE's Rename Identifier without its dialogs.
  As in DoFindRenameIdentifier (findrenameidentifier.pas): (line, col) may be
  any reference, the main declaration is looked up first; CodeTools changes
  the buffers with OpenEditorsOnCodeToolChange on, so the IDE opens every
  changed file in an editor and mirrors the change there, unsaved: Ctrl+Z
  undoes it per file.  A unit name is refused, as the IDE does (Save As
  renames the file too).  dry_run lists the references and changes nothing.
  Main thread. }
procedure DoRenameIdentifier(var Ctx: TMcpToolCall);
var
  FilePath, NewName, Ident : string;
  Line, Col, I             : Integer;
  DeclX, DeclY, DeclTop    : Integer;
  DryRun, AutoSave, OldOpen: Boolean;
  CodeBuf, DeclCode, Buf   : TCodeBuffer;
  DeclPt                   : TPoint;
  TmpCtx                   : TMcpToolCall;
  TmpHandled               : Boolean;
  FileListJ                : TJSONArray;
  FileNames, OpenBefore    : TStringList;
  Bufs                     : TFPList;
  OldSources               : TStringList;
  RefTree                  : TAVLTree;
  RefNode                  : TAVLTreeNode;
  RefPos                   : PCodeXYPosition;
  Obj, RefObj              : TJSONObject;
  Refs, Changed, Opened    : TJSONArray;
begin
  if not Assigned(Ctx.Params) then
  begin
    Ctx.Error := True; Ctx.Result := 'Missing params'; Exit;
  end;
  FilePath := Ctx.Params.Get('file', '');
  Line     := Ctx.Params.Get('line', 0);
  Col      := Ctx.Params.Get('col', 0);
  NewName  := Ctx.Params.Get('new_name', '');
  DryRun   := Ctx.Params.Get('dry_run', False);
  AutoSave := Ctx.Params.Get('auto_save', False);
  if (FilePath = '') or (Line < 1) or (Col < 1) then
  begin
    Ctx.Error := True; Ctx.Result := 'file, line and col (1-based) required'; Exit;
  end;
  if not DryRun and not IsValidIdent(NewName, True, True) then
  begin
    Ctx.Error := True;
    Ctx.Result := 'new_name must be a Pascal identifier, got "' + NewName + '"';
    Exit;
  end;
  if not LazarusIDE.BeginCodeTools then
  begin
    Ctx.Error := True;
    Ctx.Result := 'The IDE is busy (building, debugging or another code tool); try again';
    Exit;
  end;
  CodeBuf := McpLoadCode(FilePath, False);
  if not Assigned(CodeBuf) then
  begin
    Ctx.Error := True; Ctx.Result := 'Could not load: ' + FilePath; Exit;
  end;
  if not CodeToolBoss.FindMainDeclaration(CodeBuf, Col, Line,
           DeclCode, DeclX, DeclY, DeclTop) then
  begin
    Ctx.Error := True;
    Ctx.Result := Format('No declaration found at %d:%d: %s',
                         [Line, Col, CodeToolBoss.ErrorMessage]);
    Exit;
  end;
  DeclPt := Point(DeclX, DeclY);
  if not CodeToolBoss.GetIdentifierAt(DeclCode, DeclX, DeclY, Ident) or
     (Ident = '') then
  begin
    Ctx.Error := True;
    Ctx.Result := Format('No identifier at %d:%d', [Line, Col]);
    Exit;
  end;
  if CompareDottedIdentifiers(PChar(Ident),
       PChar(ExtractFileNameOnly(DeclCode.Filename))) = 0 then
  begin
    Ctx.Error := True;
    Ctx.Result := '"' + Ident + '" is a unit name; renaming it means renaming ' +
      'the file too (File > Save As in the IDE)';
    Exit;
  end;
  if not DryRun and (Ident = NewName) then
  begin
    Ctx.Error := True; Ctx.Result := 'The identifier is already named ' + NewName; Exit;
  end;

  TmpCtx.Params := nil; TmpCtx.Result := ''; TmpCtx.Error := False;
  TmpCtx.StopServer := nil;
  McpDispatch('project_list_files', TmpCtx, TmpHandled);
  if TmpCtx.Error then
  begin
    Ctx.Error := True; Ctx.Result := TmpCtx.Result; Exit;
  end;
  FileListJ  := TJSONArray(GetJSON(TmpCtx.Result));
  FileNames  := TStringList.Create;
  OpenBefore := TStringList.Create;
  Bufs       := TFPList.Create;
  OldSources := TStringList.Create;
  RefTree    := nil;
  Obj        := TJSONObject.Create;
  try
    for I := 0 to FileListJ.Count - 1 do
      FileNames.Add(FileListJ.Strings[I]);
    { as the IDE does: the declaring file and the one asked about, either
      of them may be outside the project }
    if FileNames.IndexOf(DeclCode.Filename) < 0 then
      FileNames.Add(DeclCode.Filename);
    if FileNames.IndexOf(CodeBuf.Filename) < 0 then
      FileNames.Add(CodeBuf.Filename);
    if not CodeToolBoss.FindReferencesInFiles(FileNames, DeclCode,
             DeclPt, False, RefTree) then
    begin
      Ctx.Error  := True;
      Ctx.Result := 'FindReferences failed: ' + CodeToolBoss.ErrorMessage;
      Exit;
    end;
    { positions and text before the rename; the buffers each one is in }
    Refs := TJSONArray.Create;
    Obj.Add('identifier', Ident);
    Obj.Add('declaration', DeclCode.Filename + ':' + IntToStr(DeclY));
    Obj.Add('references', Refs);
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
        RefObj.Add('line_text', RefPos^.Code.GetLine(RefPos^.Y - 1, False));
        Refs.Add(RefObj);
        if Bufs.IndexOf(RefPos^.Code) < 0 then
        begin
          Bufs.Add(RefPos^.Code);
          OldSources.Add(RefPos^.Code.Source);
        end;
        RefNode := RefNode.Successor;
      end;
    end;
    if DryRun or (Refs.Count = 0) then
    begin
      Ctx.Result := Obj.AsJSON;
      Exit;
    end;

    for I := 0 to SourceEditorManagerIntf.SourceEditorCount - 1 do
      OpenBefore.Add(SourceEditorManagerIntf.SourceEditors[I].FileName);
    OldOpen := LazarusIDE.OpenEditorsOnCodeToolChange;
    LazarusIDE.OpenEditorsOnCodeToolChange := True;
    try
      if not CodeToolBoss.RenameIdentifier(RefTree, Ident, NewName,
               DeclCode, @DeclPt, False) then
      begin
        Ctx.Error  := True;
        Ctx.Result := 'RenameIdentifier failed: ' + CodeToolBoss.ErrorMessage;
        Exit;
      end;
    finally
      LazarusIDE.OpenEditorsOnCodeToolChange := OldOpen;
      { the editors have the changes: TMainIDE.ApplyCodeToolChanges }
      CodeToolBoss.SourceCache.ClearAllSourceLogEntries;
    end;

    Changed := TJSONArray.Create;
    Opened  := TJSONArray.Create;
    Obj.Add('renamed_to', NewName);
    Obj.Add('files_changed', Changed);
    Obj.Add('files_opened', Opened);
    for I := 0 to Bufs.Count - 1 do
    begin
      Buf := TCodeBuffer(Bufs[I]);
      if Buf.Source = OldSources[I] then Continue;
      Changed.Add(Buf.Filename);
      if OpenBefore.IndexOf(Buf.Filename) < 0 then
        Opened.Add(Buf.Filename);
      if AutoSave then
        LazarusIDE.DoSaveEditorFile(Buf.Filename, []);
    end;
    Obj.Add('saved', AutoSave);
    Ctx.Result := Obj.AsJSON;
  finally
    Obj.Free;
    OldSources.Free;
    Bufs.Free;
    OpenBefore.Free;
    FileNames.Free;
    FileListJ.Free;
    if Assigned(RefTree) then
      CodeToolBoss.FreeTreeOfPCodeXYPosition(RefTree);
  end;
end;

{ ── Dispatch ─────────────────────────────────────────────────────────────── }

function DoDispatchCodeTools(const Name: string; var Ctx: TMcpToolCall): Boolean;
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
  TmpCtx               : TMcpToolCall;
  TmpHandled           : Boolean;
begin
  Result := False;

  if Name = 'code_get_unit_interface' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('file', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'file argument required'; Exit;
    end;
    Ctx.Result := McpGetUnitInterface(Ctx.Params.Strings['file'], Ctx.Error);
  end

  else if Name = 'project_search' then
  begin
    Result := True;
    FilePath := '';
    if Assigned(Ctx.Params) then FilePath := Ctx.Params.Get('directory', '');
    if FilePath <> '' then
    begin
      if not DirectoryExists(FilePath) then
      begin
        Ctx.Error := True; Ctx.Result := 'Directory not found: ' + FilePath; Exit;
      end;
      TmpCtx.Result := DirectoryFilesJSON(FilePath,
        Ctx.Params.Get('mask', '*.pas;*.pp;*.inc;*.lpr;*.dpr;*.lfm'));
    end
    else
    begin
      TmpCtx.Params := nil; TmpCtx.Result := ''; TmpCtx.Error := False;
      TmpCtx.StopServer := nil;
      McpDispatch('project_list_files', TmpCtx, TmpHandled);
      if TmpCtx.Error then
      begin
        Ctx.Error := True; Ctx.Result := TmpCtx.Result; Exit;
      end;
    end;
    Ctx.Result := McpDoSearchInProject(TmpCtx.Result,
      IfThen(Assigned(Ctx.Params), Ctx.Params.Get('query', ''), ''), @EditorLines);
  end

  else if Name = 'project_list_todos' then
  begin
    Result := True;
    TmpCtx.Params := nil; TmpCtx.Result := ''; TmpCtx.Error := False;
    TmpCtx.StopServer := nil;
    McpDispatch('project_list_files', TmpCtx, TmpHandled);
    if TmpCtx.Error then
    begin
      Ctx.Error := True; Ctx.Result := TmpCtx.Result; Exit;
    end;
    Ctx.Result := McpDoListTodos(TmpCtx.Result,
      Assigned(Ctx.Params) and Ctx.Params.Get('include_done', False));
  end

  else if Name = 'code_find_declaration' then
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
    CodeBuf := McpLoadCode(FilePath, False);
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

  else if Name = 'code_get_identifier_info' then
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
    CodeBuf := McpLoadCode(FilePath, False);
    if not Assigned(CodeBuf) then
    begin
      Ctx.Error := True; Ctx.Result := 'Could not load file: ' + FilePath; Exit;
    end;
    Snippet := CodeToolBoss.FindSmartHint(CodeBuf, NewX, NewY);
    Ctx.Result := '{"hint":' + TJSONString.Create(Snippet).AsJSON + '}';
  end

  else if Name = 'code_get_outline' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('file', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'file argument required'; Exit;
    end;
    FilePath := Ctx.Params.Get('file', '');
    CodeBuf  := McpLoadCode(FilePath, False);
    if not Assigned(CodeBuf) then
    begin
      Ctx.Error := True; Ctx.Result := 'Could not load: ' + FilePath; Exit;
    end;
    { the whole unit: OnlyInterface=True left out every routine of the
      implementation }
    if not CodeToolBoss.Explore(CodeBuf, Tool, False, False) then
    begin
      Ctx.Error := True; Ctx.Result := 'Parse error: ' + CodeToolBoss.ErrorMessage; Exit;
    end;
    Outline := TJSONArray.Create;
    try
      TreeNode := Tool.Tree.Root;
      while Assigned(TreeNode) do
      begin
        if TreeNode.Desc in [ctnTypeDefinition, ctnVarDefinition, ctnConstDefinition,
                              ctnProcedure, ctnProperty, ctnUseUnit] then
        begin
          CodeBuf.AbsoluteToLineCol(TreeNode.StartPos, NewY, NewX);
          Entry := TJSONObject.Create;
          Entry.Add('kind', NodeDescriptionAsString(TreeNode.Desc));
          Entry.Add('line', NewY);
          { procedure and property nodes start with their keyword }
          if TreeNode.Desc = ctnProcedure then
            Entry.Add('name', Tool.ExtractProcName(TreeNode, []))
          else if TreeNode.Desc = ctnProperty then
            Entry.Add('name', Tool.ExtractPropName(TreeNode, False))
          else
            Entry.Add('name', Tool.ExtractIdentifier(TreeNode.StartPos));
          Outline.Add(Entry);
        end;
        if Assigned(TreeNode.FirstChild) and
           (TreeNode.Desc in [ctnUnit, ctnInterface, ctnImplementation,
                               ctnTypeSection, ctnVarSection, ctnConstSection,
                               ctnUsesSection, ctnTypeDefinition,
                               ctnClass, ctnRecordType, ctnObject,
                               ctnProgram, ctnLibrary, ctnPackage] + AllClassSections) then
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

  else if Name = 'code_find_references' then
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
    CodeBuf := McpLoadCode(FilePath, False);
    if not Assigned(CodeBuf) then
    begin
      Ctx.Error := True; Ctx.Result := 'Could not load: ' + FilePath; Exit;
    end;
    TmpCtx.Params := nil; TmpCtx.Result := ''; TmpCtx.Error := False;
    TmpCtx.StopServer := nil;
    McpDispatch('project_list_files', TmpCtx, TmpHandled);
    if TmpCtx.Error then
    begin
      Ctx.Error := True; Ctx.Result := TmpCtx.Result; Exit;
    end;
    FileListJ := TJSONArray(GetJSON(TmpCtx.Result));
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

  else if Name = 'code_rename_identifier' then
  begin
    Result := True;
    DoRenameIdentifier(Ctx);
  end

  else if Name = 'code_goto_declaration' then
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
    CodeBuf := McpLoadCode(FilePath, False);
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
    if (SourceEditorManagerIntf.SourceEditorIntfWithFilename(NewCode.Filename) = nil) and
       not McpCheckFileToOpen(NewCode.Filename, Symbol) then
    begin
      Ctx.Error := True; Ctx.Result := Symbol; Exit;
    end;
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

  else if Name = 'project_create_unit' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('file', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'file required'; Exit;
    end;
    FilePath := Ctx.Params.Get('file', '');
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

  else if Name = 'code_add_uses' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) then
    begin
      Ctx.Error := True; Ctx.Result := 'Missing params'; Exit;
    end;
    FilePath := Ctx.Params.Get('file',      '');
    Symbol   := Ctx.Params.Get('unit_name', '');
    AutoSave := Ctx.Params.Get('auto_save', False);
    if (FilePath = '') or (Symbol = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'file and unit_name required'; Exit;
    end;
    Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(FilePath);
    if Assigned(Ed) and Ed.Modified then
      LazarusIDE.DoSaveEditorFile(FilePath, []);
    CodeBuf := McpLoadCode(FilePath, False);
    if not Assigned(CodeBuf) then
    begin
      Ctx.Error := True; Ctx.Result := 'Could not load: ' + FilePath; Exit;
    end;
    { Snapshot source before CodeTools mutates TCodeBuffer via ApplyChanges }
    PasName := CodeBuf.Source;
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
    { Apply mutates TCodeBuffer in memory only — no disk write }
    if not CodeToolBoss.ApplyChanges then
    begin
      Ctx.Error := True; Ctx.Result := 'ApplyChanges failed'; Exit;
    end;
    { Diff OrigSource vs NewSource to find the single insertion point.
      CodeTools always produces one contiguous insertion for this operation. }
    Snippet := CodeBuf.Source;  { NewSource }
    I := 1;
    while (I <= Length(PasName)) and (I <= Length(Snippet))
          and (PasName[I] = Snippet[I]) do
      Inc(I);
    { I = first divergence (1-based absolute position in original) }
    J := 0;
    while (J < Length(PasName) - I + 1) and (J < Length(Snippet) - I + 1)
          and (PasName[Length(PasName) - J] = Snippet[Length(Snippet) - J]) do
      Inc(J);
    { InsertedText = Snippet[I .. Length(Snippet)-J] }
    NewName := Copy(Snippet, I, Length(Snippet) - J - I + 1);
    { Convert absolute position I in PasName to line/col }
    CodeBuf.Source := PasName;  { restore so AbsoluteToLineCol is consistent }
    CodeBuf.AbsoluteToLineCol(I, NewY, NewX);
    { Open editor if not already open }
    if not Assigned(Ed) then
    begin
      if not McpCheckFileToOpen(FilePath, NewName) then
      begin
        Ctx.Error := True; Ctx.Result := NewName; Exit;
      end;
      if LazarusIDE.DoOpenEditorFile(FilePath, -1, -1,
           [ofOnlyIfExists, ofRegularFile]) <> mrOK then
      begin
        Ctx.Error := True; Ctx.Result := 'Could not open: ' + FilePath; Exit;
      end;
      Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(FilePath);
    end;
    { Insert into editor buffer — lands on undo stack, no disk write }
    Ed.ReplaceText(Point(NewX, NewY), Point(NewX, NewY), NewName);
    if AutoSave then LazarusIDE.DoSaveEditorFile(FilePath, []);
    Obj := TJSONObject.Create;
    try
      Obj.Add('file',      FilePath);
      Obj.Add('unit_name', Symbol);
      Obj.Add('added',     True);
      if AutoSave then Obj.Add('saved', True);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'code_insert_in_procedure' then
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
    CodeBuf := McpLoadCode(FilePath, False);
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
      if not McpCheckFileToOpen(FilePath, NewName) then
      begin
        Ctx.Error := True; Ctx.Result := NewName; Exit;
      end;
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

  else if Name = 'code_replace_procedure_body' then
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
    CodeBuf := McpLoadCode(FilePath, False);
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
      if not McpCheckFileToOpen(FilePath, NewName) then
      begin
        Ctx.Error := True; Ctx.Result := NewName; Exit;
      end;
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

  else if Name = 'code_add_to_class' then
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
    CodeBuf := McpLoadCode(FilePath, False);
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
      if not McpCheckFileToOpen(FilePath, NewName) then
      begin
        Ctx.Error := True; Ctx.Result := NewName; Exit;
      end;
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

  else if Name = 'code_complete' then
  begin
    Result := True;
    DoCompleteCode(Ctx);
  end

  else if Name = 'code_get_procedure_ast' then
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
    CodeBuf := McpLoadCode(FilePath, False);
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
  Tools.Add(MakeTool('code_find_declaration',
    'Find where an identifier is declared using Codetools. ' +
    'Returns declaration file, line, column and a short context snippet.',
    SCHEMA_GET_SYMBOL_DECLARATION, MCP_ANN_RO));
  Tools.Add(MakeTool('code_get_unit_interface',
    'Return only the interface section of a Pascal unit ' +
    '(everything above the implementation keyword).',
    SCHEMA_GET_UNIT_INTERFACE, MCP_ANN_RO));
  Tools.Add(MakeTool('code_get_identifier_info',
    'Return type, declaration location, and hint text for the identifier ' +
    'at a given file/line/col using Codetools FindSmartHint.',
    SCHEMA_GET_IDENTIFIER_CONTEXT, MCP_ANN_RO));
  Tools.Add(MakeTool('code_get_outline',
    'Return the structural outline of a Pascal unit: uses clauses, type ' +
    'names, class members, and top-level routines with their line numbers. ' +
    'Does not include method bodies.',
    SCHEMA_GET_CODE_OUTLINE, MCP_ANN_RO));
  Tools.Add(MakeTool('code_find_references',
    'Find every reference to the identifier at the given declaration position ' +
    'across all project files.',
    SCHEMA_FIND_ALL_REFERENCES, MCP_ANN_RO));
  Tools.Add(MakeTool('code_rename_identifier',
    'Rename the identifier at (file, line, col), its declaration or any ' +
    'reference, in all project files, as the IDE''s Rename Identifier does. ' +
    'Changed files are opened in editors and left unsaved, so Ctrl+Z undoes ' +
    'the rename per file; auto_save=true saves them. dry_run=true lists the ' +
    'references (file, line, col, line_text) without changing anything. ' +
    'Unit names are refused (rename the file instead). .lfm files are not ' +
    'changed.',
    SCHEMA_RENAME_IDENTIFIER, MCP_ANN_WRITE));
  Tools.Add(MakeTool('code_goto_declaration',
    'Find where an identifier is declared and jump the editor cursor there. ' +
    'Opens the declaration file if needed.',
    SCHEMA_GOTO_DECLARATION, MCP_ANN_RO));
  Tools.Add(MakeTool('project_search',
    'Search for a text substring (case-insensitive) across the project''s source ' +
    'files, or across a directory such as a package''s sources. Open files are ' +
    'searched in the editor, unsaved changes included. Returns file, line and ' +
    'line text, at most 500 matches.',
    SCHEMA_SEARCH_IN_PROJECT, MCP_ANN_RO));
  Tools.Add(MakeTool('project_list_todos',
    'List TODO / FIXME items in the project''s source files, as the IDE''s ToDo ' +
    'List shows them ({ TODO ...}, {#todo ...}, // TODO, FIXME). Returns file, ' +
    'line, kind and the comment text.',
    SCHEMA_LIST_TODOS, MCP_ANN_RO));
  Tools.Add(MakeTool('project_create_unit',
    'Create a new Pascal unit file on disk, add it to the active project, ' +
    'and open it in the editor. Provide content or receive a blank unit skeleton.',
    SCHEMA_CREATE_UNIT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('code_add_uses',
    'Add a unit to the uses clause of a Pascal file using Codetools. ' +
    'Edit lands in the editor buffer (Ctrl+Z works); use auto_save=true or ' +
    'editor_save to persist to disk. ' +
    'Set in_interface=false to target the implementation uses clause.',
    SCHEMA_ADD_UNIT_TO_USES, MCP_ANN_WRITE_IDEM));
  Tools.Add(MakeTool('code_insert_in_procedure',
    'Insert text at the start of a named procedure or function body (immediately ' +
    'after begin), located via CodeTools AST. No string matching — robust to ' +
    'whitespace and formatting changes. Uses the editor undo stack (Ctrl+Z works).',
    SCHEMA_INSERT_IN_PROCEDURE, MCP_ANN_WRITE));
  Tools.Add(MakeTool('code_replace_procedure_body',
    'Replace the entire body of a named procedure or function (everything between ' +
    'begin and end) with new_body, located via CodeTools AST. No string matching. ' +
    'Uses the editor undo stack (Ctrl+Z works).',
    SCHEMA_REPLACE_PROCEDURE_BODY, MCP_ANN_WRITE));
  Tools.Add(MakeTool('code_add_to_class',
    'Append a declaration to a named section of a class (public, private, ' +
    'protected, or published), located via CodeTools AST. No string matching. ' +
    'Uses the editor undo stack (Ctrl+Z works).',
    SCHEMA_ADD_TO_CLASS_SECTION, MCP_ANN_WRITE));
  Tools.Add(MakeTool('code_complete',
    'Code completion as the IDE''s Ctrl+Shift+C does it, at (file, line, col), ' +
    'without its dialogs. What it completes depends on where the position is: ' +
    'inside a class declaration, everything missing in that class at once ' +
    '(bodies for declared methods, a field and setter for a property such as ' +
    '"property Size: Integer read FSize write SetSize;", declarations for ' +
    'method bodies without one); on a forward procedure header, its body; on ' +
    'an undeclared identifier in a body, a local variable for it ("x := 5", ' +
    '"for x in List", or an argument of a call); on an event assignment ' +
    '("OnClick := @Clicked"), the method; on a call to an undeclared ' +
    'procedure, the procedure; inside a method body with no declaration, the ' +
    'declaration. New methods go in the default class section. Returns the ' +
    'changed lines as hunks (line numbers in the new text) and the position ' +
    'the IDE would jump to. Edits land in the editor buffers (Ctrl+Z works); ' +
    'use auto_save=true or editor_save to persist to disk.',
    SCHEMA_COMPLETE_CODE, MCP_ANN_WRITE));
  Tools.Add(MakeTool('code_get_procedure_ast',
    'Return a procedure''s local variables and its block-level control flow ' +
    '(if, for, while, try, case, ...) with line ranges, for use with ' +
    'editor_replace_range.',
    SCHEMA_GET_AST_PARTIAL, MCP_ANN_RO));
end;

{ True if CodeTools last failed because it could not find a unit or an
  include file.  Compared with the resource strings, so a translated IDE
  matches too. }
function CodeToolsMissedFile: Boolean;

  function StartsWithStem(const Template: string): Boolean;
  var
    Stem : string;
  begin
    Stem := Copy(Template, 1, Pos('%', Template) - 1);
    Result := (Stem <> '') and (Pos(Stem, CodeToolBoss.ErrorMessage) = 1);
  end;

begin
  Result := StartsWithStem(ctsIncludeFileNotFound) or StartsWithStem(ctsUnitNotFound);
end;

{ A file created outside the IDE (by the assistant's shell, say) while the
  IDE is in the background is missing from its file caches: the IDE renews
  them when its window is activated, which never happens then.  So a tool
  that failed for a missing unit or include file renews them as activation
  does and runs once more.  A tool stops at the CodeTools error before it
  edits anything, so running it again is safe. }
function DispatchCodeToolsTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
begin
  { CodeTools read their own copy of a file, which the IDE updates from the
    editors only when one of its commands starts: without this, tools saw
    the file as before unsaved edits (outline line numbers, declarations).
    If the IDE is busy the copies stay; code_complete refuses on its own. }
  if Assigned(LazarusIDE) and (Copy(Name, 1, 5) = 'code_') then
    LazarusIDE.BeginCodeTools;
  CodeToolBoss.ClearError;
  Result := DoDispatchCodeTools(Name, Ctx);
  if Result and Ctx.Error and CodeToolsMissedFile then
  begin
    InvalidateFileStateCache;
    CodeToolBoss.DirectoryCachePool.IncreaseFileTimeStamp;
    CodeToolBoss.ClearError;
    Ctx.Error := False;
    Ctx.Result := '';
    DoDispatchCodeTools(Name, Ctx);
  end;
end;

initialization
  RegisterMcpGroup(@DispatchCodeToolsTool);
  RegisterMcpSchemas(@RegisterCodeToolsSchemas);

end.
