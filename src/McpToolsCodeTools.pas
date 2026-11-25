{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsCodeTools;

{ Codetools / search tools: code_find_declaration, code_get_unit_interface,
  code_get_identifier_info, code_get_outline, code_find_references, code_rename_identifier,
  project_search, project_create_unit, code_add_uses,
  code_insert_in_procedure, code_replace_procedure_body, code_add_to_class, code_complete,
  code_get_procedure_ast, code_edit_statement.
  All edit tools work through the editor buffer with an optional auto_save flag. }

{$mode objfpc}{$H+}

interface

uses
  Classes, fpjson, CodeCache;

{ CodeToolBoss.LoadFile that also finds a file created since the IDE last
  looked at its directory: the IDE's file caches still say it does not exist,
  so on failure they are invalidated and the load is tried once more.
  Main thread. }
function McpLoadCode(const AFileName: string; AUpdateFromDisk: Boolean): TCodeBuffer;

{ The files a search over Code's project (or package, by package_name or lpk_path in
  Params) covers, plus the scopes "also", search_dir and max_files ask for, as
  code_find_references takes them.  X/Y is the identifier searched for (the extra files
  are those that mention it).  Main thread. }
function McpScopeFiles(Params: TJSONObject; Code: TCodeBuffer; X, Y: Integer;
  Files: TStringList; out Used, Truncated: Boolean; out Searched: Integer;
  out Err: string): Boolean;

implementation

uses
  SysUtils, StrUtils, LCLVersion,
  LazIDEIntf, SrcEditorIntf, ProjectIntf, PackageIntf, MacroIntf, LazFileUtils, FileUtil,
  CodeToolManager, CodeTree, AVL_Tree, SourceChanger, CodeToolsStrConsts,
  BasicCodeTools,
  Controls,
  jsonparser,
  McpToolContext, McpToolHelpers, McpLineDiff, McpStatements, McpStatementEdit;

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
  Item : string;
  Found : TStringList;
  Arr   : TJSONArray;
begin
  Found := FindAllFiles(ADir, AMask, True);
  Arr   := TJSONArray.Create;
  try
    for Item in Found do
      Arr.Add(Item);
    Result := Arr.AsJSON;
  finally
    Arr.Free;
    Found.Free;
  end;
end;

{ ── Schema constants ─────────────────────────────────────────────────────── }

const
  { files of a package instead of the project's, for one call (no "active package": clients share the IDE) }
  PKG_SCOPE_PROPS =
    '"package_name":{"type":"string","description":"Use this loaded package''s files instead of the project''s"},' +
    '"lpk_path":{"type":"string","description":"Or the package''s .lpk, loaded for the call"}';

  SCHEMA_GET_SYMBOL_DECLARATION =
    '{"type":"object","properties":{' +
    '"symbol":{"type":"string","description":"Identifier name to look up"},' +
    '"file":{"type":"string","description":"Absolute path of the file containing the identifier"}' +
    ',"line":{"type":"integer","description":"Optional: line of a use of the name in file (1-based); with col, the declaration is resolved from that position"},"col":{"type":"integer","description":"Optional: column of that use (1-based)"},' +
    '"show":{"type":"boolean","description":"Also open the declaration file and jump the editor cursor there (default false: the user''s editor does not move)"}},' +
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
    '"line":{"type":"integer","description":"Line of the declaration (1-based), required here; if you only know a use of the name, get the declaration position from code_find_declaration first"},' +
    '"col":{"type":"integer","description":"Column of the declaration (1-based)"},' +
    '"also":{"type":"array","items":{"type":"string"},"description":"Also search other sources: same_folder (the file''s folder), lcl, components, rtl, fcl (FPC packages), packages (the packages loaded in the IDE). Only files that mention the name are parsed. The answer then is an object with references, extra_files_searched and truncated"},' +
    '"search_dir":{"type":"string","description":"Also search this folder and its subfolders"},' +
    '"max_files":{"type":"integer","description":"At most this many extra files that mention the name are searched (default 300; 0 searches none); the answer says truncated if there were more"},' +
    '"max_seconds":{"type":"number","description":"Stop searching more files after this many seconds (default 15; 0 = no limit); the IDE is busy meanwhile. The answer is then an object with truncated and files_not_searched"},' +
    PKG_SCOPE_PROPS + '},' +
    '"required":["file","line","col"]}';

  SCHEMA_RENAME_IDENTIFIER =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path to a file with the declaration or a reference"},' +
    '"line":{"type":"integer","description":"Line of the identifier (1-based)"},' +
    '"col":{"type":"integer","description":"Column of the identifier (1-based)"},' +
    '"new_name":{"type":"string","description":"New identifier name (not needed with dry_run)"},' +
    '"dry_run":{"type":"boolean","description":"List the references with their line text and change nothing (default false)"},' +
    '"auto_save":{"type":"boolean","description":"Save the changed files after renaming (default false: they stay unsaved, Ctrl+Z works)"},' +
    PKG_SCOPE_PROPS + '},' +
    '"required":["file","line","col"]}';

  SCHEMA_SEARCH_IN_PROJECT =
    '{"type":"object","properties":{' +
    '"query":{"type":"string","description":"Text or substring to search for (case-insensitive)"},' +
    '"directory":{"type":"string","description":"Search this folder and its subfolders ' +
    'instead of the project''s files, e.g. a package''s source folder"},' +
    '"mask":{"type":"string","description":"With directory: file masks, default ' +
    '*.pas;*.pp;*.inc;*.lpr;*.dpr;*.lfm"},' +
    PKG_SCOPE_PROPS + '},' +
    '"required":["query"]}';

  SCHEMA_LIST_TODOS =
    '{"type":"object","properties":{' +
    '"include_done":{"type":"boolean","description":"Also list DONE items (default false)"},' +
    PKG_SCOPE_PROPS + '}}';

  SCHEMA_CREATE_UNIT =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path for the new .pas file"},' +
    '"content":{"type":"string","description":"Full source content; omit for a blank unit skeleton"}},' +
    '"required":["file"]}';

  SCHEMA_ADD_UNIT_TO_USES =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path to the Pascal file to modify"},' +
    '"unit_name":{"type":"string","description":"Name of an existing unit to add to the uses clause (this tool creates no unit)"},' +
    '"in_interface":{"type":"boolean","description":"Add to interface uses (true, default) or implementation uses (false)"},' +
    '"auto_save":{"type":"boolean","description":"Also save to disk (default false)"}},' +
    '"required":["file","unit_name"]}';

  SCHEMA_INSERT_IN_PROCEDURE =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path"},' +
    '"proc_name":{"type":"string","description":"Procedure or function name, without class prefix"},' +
    '"class_name":{"type":"string","description":"Pascal class type that owns the method (not a form component class); omit for a standalone procedure"},' +
    '"line":{"type":"integer","description":"1-based. A line inside the routine you mean: needed when proc_name is overloaded or exists in several classes (the error lists them)"},' +
    '"text":{"type":"string","description":"Pascal text to insert at the start of the procedure body, immediately after begin"},' +
    '"auto_save":{"type":"boolean","description":"Also save to disk (default false)"}},' +
    '"required":["file","proc_name","text"]}';

  SCHEMA_REPLACE_PROCEDURE_BODY =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path"},' +
    '"proc_name":{"type":"string","description":"Procedure or function name, without class prefix"},' +
    '"class_name":{"type":"string","description":"Pascal class type that owns the method (not a form component class); omit for a standalone procedure"},' +
    '"line":{"type":"integer","description":"1-based. A line inside the routine you mean: needed when proc_name is overloaded or exists in several classes (the error lists them)"},' +
    '"new_body":{"type":"string","description":"New body content placed between begin and end; replaces everything currently there"},' +
    '"auto_save":{"type":"boolean","description":"Also save to disk (default false)"}},' +
    '"required":["file","proc_name","new_body"]}';

  SCHEMA_ADD_TO_CLASS_SECTION =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path"},' +
    '"class_name":{"type":"string","description":"Pascal class type to add the member to (e.g. TMyForm); not a component class"},' +
    '"section":{"type":"string","description":"Class section to append to: public (default), private, protected, or published"},' +
    '"text":{"type":"string","description":"Declaration text to append to the section"},' +
    '"auto_save":{"type":"boolean","description":"Also save to disk (default false)"}},' +
    '"required":["file","class_name","text"]}';

  SCHEMA_GET_AST_PARTIAL =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path"},' +
    '"proc_name":{"type":"string","description":"Procedure or function name to inspect (without class prefix)"},' +
    '"class_name":{"type":"string","description":"Pascal class type that owns the method (not a form component class); omit for standalone procedures"},' +
    '"line":{"type":"integer","description":"1-based line inside the procedure — alternative to proc_name; finds the enclosing scope"},' +
    '"col":{"type":"integer","description":"1-based column used together with line"},' +
    '"depth":{"type":"integer","description":"How many levels of statements to list (default 1: those of the body; deeper ones are counted as nested). Up to 10"}},' +
    '"required":["file"]}';

  SCHEMA_EDIT_STATEMENT =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path"},' +
    '"line":{"type":"integer","description":"1-based line of the statement, as code_get_procedure_ast reported it"},' +
    '"col":{"type":"integer","description":"1-based column of the statement, as reported; needed only when several statements start on that line"},' +
    '"action":{"type":"string","enum":["replace","delete","insert_before","insert_after","wrap"],"description":"replace: new text instead of the statement. delete: remove it (only where it is one of a list). insert_before / insert_after: new statements next to it (only where it is one of a list). wrap: put it inside another construct, see with"},' +
    '"with":{"type":"string","enum":["begin","try_finally","try_except","if","while","for","with"],"description":"For wrap: the construct"},' +
    '"text":{"type":"string","description":"replace/insert: the statement(s), without the indentation of the file (it is added). wrap: try_finally the cleanup, try_except the handler, if/while the condition, for the loop header such as I := 0 to 9, with the expression; not needed for begin"},' +
    '"auto_save":{"type":"boolean","description":"Also save to disk (default false)"}},' +
    '"required":["file","line","action"]}';

  SCHEMA_COMPLETE_CODE =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path"},' +
    '"line":{"type":"integer","description":"1-based line of the code to complete"},' +
    '"col":{"type":"integer","description":"1-based column on that line"},' +
    '"auto_save":{"type":"boolean","description":"Also save the changed files to disk (default false)"}},' +
    '"required":["file","line","col"]}';

{ ── Structural helpers ───────────────────────────────────────────────────── }

{ Line and column, in the file, of a position in CodeTools' cleaned source.  The two differ where
  the compiler skips code (conditional branches) or reads an include file, so TCodeBuffer.AbsoluteToLineCol
  on a node position is right in plain files only.  Falls back to it when the position is
  outside the scanned code or belongs to another buffer. }
procedure CleanToLineCol(Tool: TCodeTool; CodeBuf: TCodeBuffer; CleanPos: Integer;
  out ALine, ACol: Integer);
var
  XY : TCodeXYPosition;
begin
  if Assigned(Tool) and Tool.CleanPosToCaret(CleanPos, XY) and (XY.Code = CodeBuf) then
  begin
    ALine := XY.Y;
    ACol  := XY.X;
  end
  else
    CodeBuf.AbsoluteToLineCol(CleanPos, ALine, ACol);
end;

{ Extract qualified name from a ctnProcedure node's source line, lower-cased.
  E.g. 'TMyClass.DoSomething' or 'dosomething'. }
function ExtractProcNodeName(Tool: TCodeTool; CodeBuf: TCodeBuffer;
  Node: TCodeTreeNode): string;
var
  L, C, I : Integer;
  S       : string;
begin
  Result := '';
  CleanToLineCol(Tool, CodeBuf, Node.StartPos, L, C);
  S := Trim(CodeBuf.GetLine(L - 1, False));
  I := 1;
  while (I <= Length(S)) and not (S[I] in [' ', #9]) do Inc(I);
  S := Trim(Copy(S, I, MaxInt));
  I := 1;
  while (I <= Length(S)) and (S[I] in ['A'..'Z','a'..'z','0'..'9','_','.']) do Inc(I);
  Result := LowerCase(Copy(S, 1, I - 1));
end;

{ Find the begin..end block of a named procedure/function.
  Returns line numbers of begin and end (1-based).  When the name matches more than one
  routine (overloads, or the same method name in several classes) nothing is returned and
  Problem lists the candidates; PickLine (a line inside the one meant, 0 for none) narrows
  the matches.  Problem is empty when there is simply no such routine. }
function FindProcBodyLines(Tool: TCodeTool; CodeBuf: TCodeBuffer;
  const ProcName, ClassName: string; PickLine: Integer;
  out BeginLine, EndLine: Integer; out Problem: string): Boolean;
var
  Node, Child, BeginNode : TCodeTreeNode;
  NodeName, SearchKey, Header : string;
  C, ProcFrom, ProcTo, BL, EL : Integer;
  Found : TJSONArray;
  Item  : TJSONObject;
  Count : Integer;
begin
  Result    := False;
  BeginLine := 0;
  EndLine   := 0;
  Problem   := '';
  Count     := 0;
  if ClassName <> '' then
    SearchKey := LowerCase(ClassName + '.' + ProcName)
  else
    SearchKey := LowerCase(ProcName);
  Found := TJSONArray.Create;
  try
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
          NodeName := ExtractProcNodeName(Tool, CodeBuf, Node);
          if (NodeName = SearchKey) or
             ((ClassName = '') and
              (RightStr(NodeName, Length(SearchKey) + 1) = '.' + SearchKey)) then
          begin
            CleanToLineCol(Tool, CodeBuf, Node.StartPos, ProcFrom, C);
            CleanToLineCol(Tool, CodeBuf, Node.EndPos - 1, ProcTo, C);
            if (PickLine <= 0) or ((PickLine >= ProcFrom) and (PickLine <= ProcTo)) then
            begin
              CleanToLineCol(Tool, CodeBuf, BeginNode.StartPos, BL, C);
              CleanToLineCol(Tool, CodeBuf, BeginNode.EndPos - 1, EL, C);
              Header := Trim(CodeBuf.GetLine(ProcFrom - 1, False));
              Item := TJSONObject.Create;
              Item.Add('line', ProcFrom);
              Item.Add('header', Header);
              Found.Add(Item);
              Inc(Count);
              if Count = 1 then
              begin
                BeginLine := BL;
                EndLine   := EL;
              end;
            end;
          end;
        end;
      end;
      Node := Node.Next;
    end;
    if Count = 1 then Result := True
    else if Count > 1 then
    begin
      BeginLine := 0;
      EndLine   := 0;
      Problem := 'Ambiguous: "' + ProcName + '" matches ' + IntToStr(Count) + ' routines; ' +
        'give class_name, or line (a line inside the one you mean). Candidates: ' + Found.AsJSON;
    end;
  finally
    Found.Free;
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
  Cand     : TCodeTreeNode;
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
        { The last section of that visibility: a class with no visibility keyword at its start has
          an implicit published section FIRST, and an explicit "published" comes later (1.8.2). }
        SectNode := nil;
        Cand := ClsNode.FirstChild;
        while Assigned(Cand) do
        begin
          if Cand.Desc = SectDesc then SectNode := Cand;
          Cand := Cand.NextBrother;
        end;
        if Assigned(SectNode) then
        begin
          if Assigned(SectNode.NextBrother) then
            CleanToLineCol(Tool, CodeBuf, SectNode.NextBrother.StartPos, InsertLine, C)
          else
            CleanToLineCol(Tool, CodeBuf, ClsNode.EndPos - 1, InsertLine, C);
          Exit(True);
        end;
      end;
    end;
    Node := Node.Next;
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
  Item : string;
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
      for Item in OtherFiles do
        LazarusIDE.DoSaveEditorFile(Item, []);
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('file', FilePath);
      Obj.Add('completed', Done);
      Obj.Add('changes', LineHunks(OldSrc, CodeBuf.Source));
      if OtherFiles.Count > 0 then
      begin
        Others := TJSONArray.Create;
        for Item in OtherFiles do Others.Add(Item);
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
  Ptr : Pointer;
  En : TJSONEnum;
  FilePath, NewName, Ident : string;
  Refused                  : string;
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

  TmpCtx.Params := Ctx.Params; TmpCtx.Result := ''; TmpCtx.Error := False;
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
    for En in FileListJ do
      FileNames.Add(En.Value.AsString);
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
    { all or nothing: a reference in a file that may not be changed (the RTL, the LCL, another
      project's sources) stops the rename before anything is touched }
    for Ptr in Bufs do
      if not McpCheckWritable(TCodeBuffer(Ptr).Filename, Refused) then
      begin
        Ctx.Error := True;
        Ctx.Result := 'Nothing was renamed. ' + Refused + ' (dry_run lists every reference.)';
        Exit;
      end;

    for I := 0 to SourceEditorManagerIntf.SourceEditorCount - 1 do
      OpenBefore.Add(SourceEditorManagerIntf.SourceEditors[I].FileName);
    OldOpen := LazarusIDE.OpenEditorsOnCodeToolChange;
    LazarusIDE.OpenEditorsOnCodeToolChange := True;
    try
      {$IF lcl_fullversion >= 4090000}
      { Lazarus 5.0 and development builds since 2025-01-02 (4.99, lcl_fullversion
        4990000) have no DottedIdents parameter: it is derived from the names
        inside (Lazarus commits ed2a217e45, f6b5cd0a9d). 4.8 is 4080000. }
      if not CodeToolBoss.RenameIdentifier(RefTree, Ident, NewName,
               DeclCode, @DeclPt) then
      {$ELSE}
      if not CodeToolBoss.RenameIdentifier(RefTree, Ident, NewName,
               DeclCode, @DeclPt, False) then
      {$ENDIF}
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

{ The indent for text added at the end of a class section (code_add_to_class): that of
  the last member above InsertLine, or the section keyword's plus two when the section
  is empty. }
function ClassMemberIndent(CodeBuf: TCodeBuffer; InsertLine: Integer): string;
var
  I     : Integer;
  Line, T : string;
begin
  Result := '    ';
  for I := InsertLine - 1 downto 1 do
  begin
    Line := CodeBuf.GetLine(I - 1, False);
    T := LowerCase(Trim(Line));
    if T = '' then Continue;
    Result := Copy(Line, 1, Length(Line) - Length(TrimLeft(Line)));
    if (T = 'public') or (T = 'private') or (T = 'protected') or (T = 'published') or
       (T = 'strict private') or (T = 'strict protected') or (T = 'automated') or
       (Copy(T, 1, 5) = 'type ') or (Copy(T, Length(T) - 4, 5) = 'class') then
      Result := Result + '  ';
    Exit;
  end;
end;

{ Text indented as the members it joins, unless the caller indented it already. }
function IndentMembers(const AText, AIndent: string): string;
var
  Item : string;
  Lines : TStringList;
  I     : Integer;
  Done  : Boolean;
begin
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    Done := False;
    for Item in Lines do
      if Trim(Item) <> '' then
      begin
        Done := (Item[1] in [' ', #9]);   { already indented: leave it }
        Break;
      end;
    if not Done then
      for I := 0 to Lines.Count - 1 do
        if Trim(Lines[I]) <> '' then
          Lines[I] := AIndent + Lines[I];
    Result := TrimRight(Lines.Text);
  finally
    Lines.Free;
  end;
end;

{ ── Declaration lookup ───────────────────────────────────────────────────── }

{ Where Symbol is declared, as seen from Code (code_find_declaration, also with
  show=true).  In order:
    1. at Line/Col, when the caller gives a position of a use;
    2. the unit's own interface (fast, but it never follows a uses clause and
       a program has no interface);
    3. at the file's own uses of the name, one after the other (comments and strings
       skipped): CodeTools resolves a use through the uses clauses, so TList is found in
       Classes, and a program works. }
function ResolveDeclaration(Code: TCodeBuffer; const Symbol: string; Line, Col: Integer;
  out NewCode: TCodeBuffer; out NewX, NewY, NewTopLine: Integer;
  out Why: string): Boolean;
var
  Src       : string;
  P, L, Tries, X, Y : Integer;
  BlockTop, BlockBottom : Integer;

  function WordAt(Pos: Integer): Boolean;
  begin
    Result := (Pos + Length(Symbol) - 1 <= L) and
              SameText(Copy(Src, Pos, Length(Symbol)), Symbol) and
              ((Pos = 1) or not (Src[Pos - 1] in ['A'..'Z', 'a'..'z', '0'..'9', '_'])) and
              ((Pos + Length(Symbol) > L) or
               not (Src[Pos + Length(Symbol)] in ['A'..'Z', 'a'..'z', '0'..'9', '_']));
  end;

begin
  Why := '';
  if (Line > 0) and (Col > 0) then
  begin
    Result := CodeToolBoss.FindDeclaration(Code, Col, Line, NewCode, NewX, NewY,
                NewTopLine, BlockTop, BlockBottom);
    if not Result then Why := CodeToolBoss.ErrorMessage;
    Exit;
  end;
  if CodeToolBoss.FindDeclarationInInterface(Code, Symbol, NewCode, NewX, NewY, NewTopLine) then
    Exit(True);
  Why := CodeToolBoss.ErrorMessage;
  Src := Code.Source;
  L := Length(Src);
  P := 1;
  Tries := 0;
  while (P <= L) and (Tries < 30) do
  begin
    case Src[P] of
      '{': begin
             while (P <= L) and (Src[P] <> '}') do Inc(P);
             Inc(P);
           end;
      '(': if (P < L) and (Src[P + 1] = '*') then
           begin
             P := PosEx('*)', Src, P + 2);
             if P = 0 then Break;
             Inc(P, 2);
           end else Inc(P);
      '/': if (P < L) and (Src[P + 1] = '/') then
           begin
             while (P <= L) and not (Src[P] in [#10, #13]) do Inc(P);
           end else Inc(P);
      '''': begin
              Inc(P);
              while (P <= L) and not (Src[P] in ['''', #10, #13]) do Inc(P);
              Inc(P);
            end;
    else
      if (Src[P] in ['A'..'Z', 'a'..'z', '_']) then
      begin
        if WordAt(P) then
        begin
          Inc(Tries);
          Code.AbsoluteToLineCol(P, Y, X);
          if CodeToolBoss.FindDeclaration(Code, X, Y, NewCode, NewX, NewY, NewTopLine,
               BlockTop, BlockBottom) then
            Exit(True);
          Why := CodeToolBoss.ErrorMessage;
        end;
        while (P <= L) and (Src[P] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) do Inc(P);
      end else
        Inc(P);
    end;
  end;
  if Tries = 0 then
    Why := 'the name is not used in this file; pass line and col of a use, ' +
           'or search from a file that uses it'
  else if Why = '' then
    Why := 'not found';
  Result := False;
end;

{ ── Extra search scopes for code_find_references ─────────────────────────── }

const
  IdentChars = ['A'..'Z', 'a'..'z', '0'..'9', '_'];
  DefaultMaxFiles = 300;

{ The source folder a name in "also" stands for ('' when unknown); Recursive tells
  whether its subfolders belong to it. }
function ExtraSourceRoot(const AName: string; Code: TCodeBuffer; out Recursive: Boolean): string;
var
  S: string;
begin
  Recursive := True;
  Result := '';
  if AName = 'same_folder' then
  begin
    Recursive := False;
    Exit(ExtractFilePath(Code.Filename));
  end;
  case AName of
    'lcl':        S := '$(LazarusDir)/lcl';
    'components': S := '$(LazarusDir)/components';
    'rtl':        S := '$(FPCSrcDir)/rtl';
    'fcl':        S := '$(FPCSrcDir)/packages';
  else
    Exit;
  end;
  if Assigned(IDEMacros) and IDEMacros.SubstituteMacros(S) then
    Result := SetDirSeparators(S);
end;

{ Does the file contain Ident as a whole word, ignoring case?  A text test only: it
  decides which files are worth handing to CodeTools, which then resolves each use. }
function FileHasWord(const AFile, LowIdent: string): Boolean;
var
  Stream : TFileStream;
  Text   : string = '';
  P, L   : Integer;
begin
  Result := False;
  try
    Stream := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Text, Stream.Size);
      if Length(Text) > 0 then Stream.ReadBuffer(Text[1], Length(Text));
    finally
      Stream.Free;
    end;
  except
    Exit;
  end;
  Text := LowerCase(Text);
  L := Length(LowIdent);
  P := Pos(LowIdent, Text);
  while P > 0 do
  begin
    if ((P = 1) or not (Text[P - 1] in IdentChars)) and
       ((P + L > Length(Text)) or not (Text[P + L] in IdentChars)) then
      Exit(True);
    P := PosEx(LowIdent, Text, P + 1);
  end;
end;

{ Adds to FileNames the files of the requested scopes (also, search_dir) that mention
  the identifier at X/Y of Code, at most max_files of them.  Used says whether any extra
  scope was asked for. }
function AddExtraFiles(Params: TJSONObject; Code: TCodeBuffer; X, Y: Integer;
  FileNames: TStringList; out Used, Truncated: Boolean; out Searched: Integer;
  out Err: string): Boolean;
var
  En : TJSONEnum;
  Item : string;
  Also      : TJSONArray;
  Roots     : TStringList;   { folder, '1' = recursive in Objects }
  Found     : TStringList;
  Seen      : TStringList;
  Line, Ident, Root : string;
  I, J, A, B, MaxFiles : Integer;
  Recursive : Boolean;
begin
  Result := True;
  Used := False;
  Truncated := False;
  Searched := 0;
  Err := '';
  Also := nil;
  if Assigned(Params.Find('also')) and (Params.Find('also') is TJSONArray) then
    Also := TJSONArray(Params.Find('also'));
  Roots := TStringList.Create;
  Seen := TStringList.Create;
  try
    if Assigned(Also) then
      for En in Also do
      begin
        Used := True;
        if En.Value.AsString = 'packages' then
        begin
          for J := 0 to PackageEditingInterface.GetPackageCount - 1 do
            if PackageEditingInterface.GetPackages(J).DirectoryExpanded <> '' then
              Roots.AddObject(PackageEditingInterface.GetPackages(J).DirectoryExpanded, TObject(PtrUInt(1)));
          Continue;
        end;
        Root := ExtraSourceRoot(En.Value.AsString, Code, Recursive);
        if Root = '' then
        begin
          Err := 'Unknown "also" scope ' + En.Value.AsString +
                 ' (same_folder, lcl, components, rtl, fcl, packages)';
          Exit(False);
        end;
        Roots.AddObject(Root, TObject(PtrUInt(Ord(Recursive))));
      end;
    if Params.Get('search_dir', '') <> '' then
    begin
      Used := True;
      Roots.AddObject(Params.Get('search_dir', ''), TObject(PtrUInt(1)));
    end;
    if not Used then Exit;

    { the identifier at the declaration }
    Line := Code.GetLine(Y - 1, False);
    A := X;
    while (A > 1) and (A <= Length(Line) + 1) and (Line[A - 1] in IdentChars) do Dec(A);
    B := X;
    while (B >= 1) and (B <= Length(Line)) and (Line[B] in IdentChars) do Inc(B);
    Ident := Copy(Line, A, B - A);
    if Ident = '' then Exit;   { FindReferences reports the missing identifier }
    Ident := LowerCase(Ident);

    MaxFiles := Params.Get('max_files', DefaultMaxFiles);
    Seen.Sorted := True;
    Seen.CaseSensitive := False;
    for Item in FileNames do
      Seen.Add(Item);
    for I := 0 to Roots.Count - 1 do
    begin
      if not DirectoryExists(Roots[I]) then Continue;
      Found := FindAllFiles(Roots[I], '*.pas;*.pp;*.lpr', PtrUInt(Roots.Objects[I]) <> 0);
      try
        for Item in Found do
        begin
          if Seen.IndexOf(Item) >= 0 then Continue;
          if not FileHasWord(Item, Ident) then Continue;
          if Searched >= MaxFiles then
          begin
            Truncated := True;
            Break;
          end;
          Seen.Add(Item);
          FileNames.Add(Item);
          Inc(Searched);
        end;
      finally
        Found.Free;
      end;
      if Truncated then Break;
    end;
  finally
    Seen.Free;
    Roots.Free;
  end;
end;

function McpScopeFiles(Params: TJSONObject; Code: TCodeBuffer; X, Y: Integer;
  Files: TStringList; out Used, Truncated: Boolean; out Searched: Integer;
  out Err: string): Boolean;
var
  En : TJSONEnum;
  Item : string;
  Ctx2    : TMcpToolCall;
  Handled : Boolean;
  List    : TJSONArray;
  HasSelf : Boolean;
begin
  Result := False;
  Used := False; Truncated := False; Searched := 0; Err := '';
  Ctx2.Params := Params; Ctx2.Result := ''; Ctx2.Error := False; Ctx2.StopServer := nil;
  McpDispatch('project_list_files', Ctx2, Handled);
  if Ctx2.Error then begin Err := Ctx2.Result; Exit; end;
  List := TJSONArray(GetJSON(Ctx2.Result));
  try
    for En in List do
      Files.Add(En.Value.AsString);
  finally
    List.Free;
  end;
  HasSelf := False;
  for Item in Files do
    if SameFileName(Item, Code.Filename) then HasSelf := True;
  if not HasSelf then Files.Add(Code.Filename);
  Result := AddExtraFiles(Params, Code, X, Y, Files, Used, Truncated, Searched, Err);
end;

const
  DefaultMaxSeconds : Double = 15;
  RefChunk          = 25;      { files per CodeTools call: the clock is read between calls }
  RefMaxResults     = 2000;

{ The references of the identifier at DeclPt of Code in Files, as JSON.  The files go to CodeTools
  RefChunk at a time, so that the time limit can stop the search between two calls.  A chunk
  CodeTools refuses (one file it cannot parse) is tried file by file; the files that fail are
  listed, not fatal.  The answer stays a plain array unless something has to be said besides the
  references (an extra scope was asked for, the search was cut short, a file failed). }
function McpFindReferences(Code: TCodeBuffer; DeclPt: TPoint; Files: TStringList;
  MaxSeconds: Double; ExtraUsed, ExtraTrunc: Boolean; ExtraCount: Integer;
  out Json, Err: string): Boolean;
var
  Refs, Failed : TJSONArray;
  Obj, F       : TJSONObject;
  Chunk, One   : TStringList;
  I, J, Left   : Integer;
  Started      : QWord;
  AnyOk, Cut   : Boolean;
  LastErr      : string;

  function RunChunk(AFiles: TStringList): Boolean;
  var
    Tree : TAVLTree;
    Node : TAVLTreeNode;
    Pos  : PCodeXYPosition;
    O    : TJSONObject;
  begin
    Tree := nil;
    Result := CodeToolBoss.FindReferencesInFiles(AFiles, Code, DeclPt, False, Tree);
    if Result then
    begin
      if Assigned(Tree) then
      begin
        Node := Tree.FindLowest;
        while Assigned(Node) do
        begin
          Pos := PCodeXYPosition(Node.Data);
          O := TJSONObject.Create;
          O.Add('file', Pos^.Code.Filename);
          O.Add('line', Pos^.Y);
          O.Add('col',  Pos^.X);
          Refs.Add(O);
          Node := Node.Successor;
        end;
      end;
    end
    else
      LastErr := CodeToolBoss.ErrorMessage;
    if Assigned(Tree) then
      CodeToolBoss.FreeTreeOfPCodeXYPosition(Tree);
  end;

begin
  Result := False;
  Json := ''; Err := '';
  Refs := TJSONArray.Create;
  Failed := TJSONArray.Create;
  Chunk := TStringList.Create;
  One := TStringList.Create;
  try
    Started := GetTickCount64;
    AnyOk := False; Cut := False; Left := 0; LastErr := '';
    I := 0;
    while I < Files.Count do
    begin
      Chunk.Clear;
      J := I + RefChunk;
      if J > Files.Count then J := Files.Count;
      while I + Chunk.Count < J do
        Chunk.Add(Files[I + Chunk.Count]);
      Inc(I, Chunk.Count);
      if RunChunk(Chunk) then
        AnyOk := True
      else
      begin
        for J := 0 to Chunk.Count - 1 do
        begin
          One.Clear;
          One.Add(Chunk[J]);
          if RunChunk(One) then
            AnyOk := True
          else
          begin
            F := TJSONObject.Create;
            F.Add('file', Chunk[J]);
            F.Add('error', LastErr);
            Failed.Add(F);
          end;
        end;
        if not AnyOk then
        begin
          { not one file could be searched: the position, not the files }
          Err := LastErr;
          if Err = '' then
            Err := 'no identifier at line ' + IntToStr(DeclPt.Y) + ', col ' + IntToStr(DeclPt.X);
          Exit;
        end;
      end;
      if (I < Files.Count) and
         ((Refs.Count >= RefMaxResults) or
          ((MaxSeconds > 0) and (GetTickCount64 - Started >= QWord(Round(MaxSeconds * 1000))))) then
      begin
        Cut := True;
        Left := Files.Count - I;
        Break;
      end;
    end;
    if ExtraUsed or ExtraTrunc or Cut or (Failed.Count > 0) then
    begin
      Obj := TJSONObject.Create;
      try
        Obj.Add('references', Refs); Refs := nil;
        if ExtraUsed then Obj.Add('extra_files_searched', ExtraCount);
        if ExtraTrunc or Cut then Obj.Add('truncated', True);
        if Cut then Obj.Add('files_not_searched', Left);
        if Failed.Count > 0 then begin Obj.Add('failed', Failed); Failed := nil; end;
        Json := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    end
    else
      Json := Refs.AsJSON;
    Result := True;
  finally
    One.Free; Chunk.Free;
    Failed.Free; Refs.Free;     { nil once they went into Obj }
  end;
end;

{ ── Dispatch ─────────────────────────────────────────────────────────────── }

{ The statements of the body whose begin block is BeginNode.  McpStatements has no scanner: the
  tokens are the atoms CodeTools reads, so comments, directives, conditional code and includes
  are the compiler's, each put at its line in the file.  Atoms that come from an include file
  are left out. }
function BodyStatements(Tool: TCodeTool; CodeBuf: TCodeBuffer;
  BeginNode: TCodeTreeNode): TStmtNode;
var
  Toks : TStmtTokens = nil;
  N    : Integer;
  XY   : TCodeXYPosition;
  Txt  : string;
  Ch   : Char;
  I    : Integer;
begin
  N := 0;
  Tool.MoveCursorToCleanPos(BeginNode.StartPos);
  repeat
    Tool.ReadNextAtom;
    if (Tool.CurPos.StartPos >= BeginNode.EndPos) or
       (Tool.CurPos.EndPos <= Tool.CurPos.StartPos) then Break;
    if not (Tool.CleanPosToCaret(Tool.CurPos.StartPos, XY) and (XY.Code = CodeBuf)) then Continue;
    Txt := Copy(Tool.Src, Tool.CurPos.StartPos, Tool.CurPos.EndPos - Tool.CurPos.StartPos);
    if N = Length(Toks) then SetLength(Toks, N * 2 + 64);
    Toks[N].Txt  := Txt;
    Toks[N].Up   := UpperCase(Txt);
    Toks[N].Line := XY.Y;
    Toks[N].Col  := XY.X;
    Toks[N].EndLine := XY.Y;
    Toks[N].EndCol  := XY.X + Length(Txt);
    for I := 1 to Length(Txt) do          { a token that runs over lines (a block comment is not one) }
      if Txt[I] = #10 then
      begin
        Inc(Toks[N].EndLine);
        Toks[N].EndCol := Length(Txt) - I + 1;
      end;
    Ch := Txt[1];
    if (Ch in ['A'..'Z', 'a'..'z', '_', '&']) or (Ch >= #128) then Toks[N].Kind := 0
    else if Ch in ['0'..'9', '$', '%', '#', ''''] then Toks[N].Kind := 2
    else Toks[N].Kind := 1;
    Inc(N);
  until False;
  Result := ParseStatementTokens(Toks, N);
end;

{ A statement as JSON; ADepth levels are listed, deeper ones only counted ("nested"). }
function StatementJson(N: TStmtNode; ADepth: Integer): TJSONObject;
var
  I    : Integer;
  Kids : TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.Add('kind', N.Kind);
  if N.Name <> '' then Result.Add('name', N.Name);
  Result.Add('line', N.Line);
  Result.Add('col', N.Col);
  if N.EndLine > N.Line then Result.Add('end_line', N.EndLine);
  if N.Role <> '' then Result.Add('role', N.Role);
  if N.ElseLine > 0 then Result.Add('else_line', N.ElseLine);
  if N.HandlerLine > 0 then Result.Add('handler_line', N.HandlerLine);
  if N.Children.Count > 0 then
    if ADepth > 1 then
    begin
      Kids := TJSONArray.Create;
      for I := 0 to N.Children.Count - 1 do
        Kids.Add(StatementJson(TStmtNode(N.Children[I]), ADepth - 1));
      Result.Add('children', Kids);
    end
    else
      Result.Add('nested', N.Children.Count);
end;

function StatementsJson(ARoot: TStmtNode; ADepth: Integer): TJSONArray;
var
  I : Integer;
begin
  Result := TJSONArray.Create;
  for I := 0 to ARoot.Children.Count - 1 do
    Result.Add(StatementJson(TStmtNode(ARoot.Children[I]), ADepth));
end;

{ The begin block of the routine whose body holds ALine, and the routine's name. }
function FindBeginBlockAtLine(Tool: TCodeTool; CodeBuf: TCodeBuffer; ALine: Integer;
  out BeginNode: TCodeTreeNode; out ProcName: string): Boolean;
var
  Node, Child : TCodeTreeNode;
  BL, EL, X   : Integer;
begin
  Result := False;
  BeginNode := nil;
  ProcName := '';
  Node := Tool.Tree.Root;
  while Assigned(Node) do
  begin
    if Node.Desc = ctnProcedure then
    begin
      Child := Node.FirstChild;
      while Assigned(Child) do
      begin
        if Child.Desc = ctnBeginBlock then
        begin
          CleanToLineCol(Tool, CodeBuf, Child.StartPos, BL, X);
          CleanToLineCol(Tool, CodeBuf, Child.EndPos - 1, EL, X);
          if (ALine >= BL) and (ALine <= EL) then
          begin
            BeginNode := Child;
            ProcName := ExtractProcNodeName(Tool, CodeBuf, Node);
            Exit(True);
          end;
        end;
        Child := Child.NextBrother;
      end;
    end;
    Node := Node.Next;
  end;
end;

{ code_edit_statement: one statement of a body, found by the line and column
  code_get_procedure_ast reported, replaced, deleted, wrapped or given a neighbour.  The text of
  the file around it is untouched (McpStatementEdit does the text work, and has no IDE). }
procedure DoEditStatement(var Ctx: TMcpToolCall);
var
  FilePath, Op, W, Text, ProcName, Why : string;
  Line, Col, I, Added                  : Integer;
  AutoSave                             : Boolean;
  CodeBuf                              : TCodeBuffer;
  Tool                                 : TCodeTool;
  BeginNode                            : TCodeTreeNode;
  Root                                 : TStmtNode;
  Lines                                : TStringList;
  Edit                                 : TStmtEdit;
  Ed                                   : TSourceEditorInterface;
  Obj                                  : TJSONObject;
begin
  if not Assigned(Ctx.Params) then
  begin
    Ctx.Error := True; Ctx.Result := 'Missing params'; Exit;
  end;
  FilePath := Ctx.Params.Get('file', '');
  Op       := Ctx.Params.Get('action', '');
  W        := Ctx.Params.Get('with', '');
  Text     := Ctx.Params.Get('text', '');
  Line     := Ctx.Params.Get('line', 0);
  Col      := Ctx.Params.Get('col', 0);
  AutoSave := Ctx.Params.Get('auto_save', False);
  if (FilePath = '') or (Op = '') or (Line < 1) then
  begin
    Ctx.Error := True; Ctx.Result := 'file, action and line required'; Exit;
  end;
  Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(FilePath);
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
  if not CodeToolBoss.Explore(CodeBuf, Tool, True, False) then
  begin
    Ctx.Error := True; Ctx.Result := 'Parse error: ' + CodeToolBoss.ErrorMessage; Exit;
  end;
  if not FindBeginBlockAtLine(Tool, CodeBuf, Line, BeginNode, ProcName) then
  begin
    Ctx.Error := True; Ctx.Result := 'No routine body contains line ' + IntToStr(Line); Exit;
  end;
  Root := BodyStatements(Tool, CodeBuf, BeginNode);
  try
    Lines := TStringList.Create;
    try
      for I := 0 to CodeBuf.LineCount - 1 do
        Lines.Add(CodeBuf.GetLine(I, False));
      Edit := EditStatement(Lines, Root, Line, Col, Op, W, Text);
    finally
      Lines.Free;
    end;
  finally
    Root.Free;
  end;
  if not Edit.Ok then
  begin
    Ctx.Error := True; Ctx.Result := Edit.Error; Exit;
  end;
  if not Assigned(Ed) then
  begin
    if not McpCheckFileToOpen(FilePath, Why) then
    begin
      Ctx.Error := True; Ctx.Result := Why; Exit;
    end;
    if LazarusIDE.DoOpenEditorFile(FilePath, -1, -1, [ofOnlyIfExists, ofRegularFile]) <> mrOK then
    begin
      Ctx.Error := True; Ctx.Result := 'Could not open: ' + FilePath; Exit;
    end;
    Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(FilePath);
  end;
  Ed.ReplaceText(Point(Edit.StartCol, Edit.StartLine), Point(Edit.EndCol, Edit.EndLine),
                 Edit.NewText);
  if AutoSave then LazarusIDE.DoSaveEditorFile(FilePath, []);
  Added := 0;
  for I := 1 to Length(Edit.NewText) do
    if Edit.NewText[I] = #10 then Inc(Added);
  Obj := TJSONObject.Create;
  try
    Obj.Add('file',      FilePath);
    Obj.Add('procedure', ProcName);
    Obj.Add('action',    LowerCase(Op));
    Obj.Add('line',      Edit.StartLine);
    Obj.Add('end_line',  Edit.StartLine + Added);
    if AutoSave then Obj.Add('saved', True);
    Ctx.Result := Obj.AsJSON;
  finally
    Obj.Free;
  end;
end;

function DoDispatchCodeTools(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  En : TJSONEnum;
  Item : string;
  Root       : TStmtNode;
  MaxDepth   : Integer;
  FilePath   : string;
  Symbol     : string;
  NewName    : string;
  Line       : Integer;
  CodeBuf    : TCodeBuffer;
  NewCode    : TCodeBuffer;
  NewX       : Integer;
  NewY       : Integer;
  NewTopLine : Integer;
  DeclPt     : TPoint;
  Snippet    : string;
  Why        : string;
  FoundSelf  : Boolean;
  ExtraUsed, ExtraTrunc : Boolean;
  ExtraCount : Integer;
  ExtraErr   : string;
  Tool       : TCodeTool;
  TreeNode   : TCodeTreeNode;
  Outline    : TJSONArray;
  Entry      : TJSONObject;
  FileListJ  : TJSONArray;
  FileNames  : TStringList;
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
  PF                   : TLazProjectFile;
  TmpCtx               : TMcpToolCall;
  TmpHandled           : Boolean;
begin
  Result := False;

  case Name of
    'code_get_unit_interface':
    begin
      Result := True;
      if not Assigned(Ctx.Params) or (Ctx.Params.Get('file', '') = '') then
      begin
        Ctx.Error := True; Ctx.Result := 'file argument required'; Exit;
      end;
      Ctx.Result := McpGetUnitInterface(Ctx.Params.Strings['file'], Ctx.Error);
    end;

    'project_search':
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
        TmpCtx.Params := Ctx.Params; TmpCtx.Result := ''; TmpCtx.Error := False;
        TmpCtx.StopServer := nil;
        McpDispatch('project_list_files', TmpCtx, TmpHandled);
        if TmpCtx.Error then
        begin
          Ctx.Error := True; Ctx.Result := TmpCtx.Result; Exit;
        end;
      end;
      Ctx.Result := McpDoSearchInProject(TmpCtx.Result,
        IfThen(Assigned(Ctx.Params), Ctx.Params.Get('query', ''), ''), @EditorLines);
    end;

    'project_list_todos':
    begin
      Result := True;
      TmpCtx.Params := Ctx.Params; TmpCtx.Result := ''; TmpCtx.Error := False;
      TmpCtx.StopServer := nil;
      McpDispatch('project_list_files', TmpCtx, TmpHandled);
      if TmpCtx.Error then
      begin
        Ctx.Error := True; Ctx.Result := TmpCtx.Result; Exit;
      end;
      Ctx.Result := McpDoListTodos(TmpCtx.Result,
        Assigned(Ctx.Params) and Ctx.Params.Get('include_done', False));
    end;

    'code_find_declaration':
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
      if ResolveDeclaration(CodeBuf, Symbol, Ctx.Params.Get('line', 0),
           Ctx.Params.Get('col', 0), NewCode, NewX, NewY, NewTopLine, Why) then
      begin
        if Ctx.Params.Get('show', False) then
        begin
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
        end;
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
        Ctx.Result := 'Declaration not found for: ' + Symbol + ' (' + Why + ')';
      end;
    end;

    'code_get_identifier_info':
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
    end;

    'code_get_outline':
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
            CleanToLineCol(Tool, CodeBuf, TreeNode.StartPos, NewY, NewX);
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
    end;

    'code_find_references':
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
      TmpCtx.Params := Ctx.Params; TmpCtx.Result := ''; TmpCtx.Error := False;
      TmpCtx.StopServer := nil;
      McpDispatch('project_list_files', TmpCtx, TmpHandled);
      if TmpCtx.Error then
      begin
        Ctx.Error := True; Ctx.Result := TmpCtx.Result; Exit;
      end;
      FileListJ := TJSONArray(GetJSON(TmpCtx.Result));
      FileNames := TStringList.Create;
      try
        for En in FileListJ do
          FileNames.Add(En.Value.AsString);
        { a file outside the project (or package) is still searched: its own references }
        FoundSelf := False;
        for Item in FileNames do
          if SameFileName(Item, CodeBuf.Filename) then FoundSelf := True;
        if not FoundSelf then FileNames.Add(CodeBuf.Filename);
        if not AddExtraFiles(Ctx.Params, CodeBuf, NewX, NewY, FileNames, ExtraUsed,
             ExtraTrunc, ExtraCount, ExtraErr) then
        begin
          Ctx.Error := True; Ctx.Result := ExtraErr; Exit;
        end;
        DeclPt := Point(NewX, NewY);
        if not McpFindReferences(CodeBuf, DeclPt, FileNames,
               Ctx.Params.Get('max_seconds', DefaultMaxSeconds),
               ExtraUsed, ExtraTrunc, ExtraCount, Ctx.Result, ExtraErr) then
        begin
          Ctx.Error  := True;
          Ctx.Result := 'FindReferences failed: ' + ExtraErr;
          Exit;
        end;
      finally
        FileNames.Free;
        FileListJ.Free;
      end;
    end;

    'code_rename_identifier':
    begin
      Result := True;
      DoRenameIdentifier(Ctx);
    end;

    'project_create_unit':
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
      if not McpCheckWritable(FilePath, Why) then
      begin
        Ctx.Error := True; Ctx.Result := Why; Exit;
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
      begin
        { a file added this way stays out of the project until it is marked }
        PF := Proj.CreateProjectFile(FilePath);
        Proj.AddFile(PF, False);
        PF.IsPartOfProject := True;
      end;
      LazarusIDE.DoOpenEditorFile(FilePath, -1, -1, [ofRegularFile]);
      Obj := TJSONObject.Create;
      try
        Obj.Add('filename', FilePath);
        Obj.Add('created',  True);
        Ctx.Result := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    end;

    'code_add_uses':
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
      { the editor's unsaved text goes to the code buffer without a disk write }
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
        { CodeTools asks the tree for the source type before it has built one: on a buffer it has not
          parsed yet that is a nil node and an access violation.  Parsing it first is enough (1.9.0). }
        CodeToolBoss.GetSourceType(CodeBuf, False);
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
      { Diff OrigSource vs NewSource to find the one changed range: the common start and the common
        end are left alone.  Usually an insertion; a unit that moves between the two uses clauses
        also deletes, which the range below covers. }
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
      { The old text CodeTools replaced: empty for a plain insertion.  It is not empty when the
        unit was already in the other uses clause and CodeTools moved it (an insertion in one place,
        a deletion in the other): then everything between the two is part of the change, and the
        editor must replace that range, not insert the whole span a second time (1.8.2). }
      CodeBuf.AbsoluteToLineCol(Length(PasName) - J + 1, DeclPt.Y, DeclPt.X);
      { Open editor if not already open }
      if not Assigned(Ed) then
      begin
        { its message is an out parameter, cleared on entry: not NewName, which holds the
          text to insert (code_add_uses) or the section (code_add_to_class) (1.8.2) }
        if not McpCheckFileToOpen(FilePath, Why) then
        begin
          Ctx.Error := True; Ctx.Result := Why; Exit;
        end;
        if LazarusIDE.DoOpenEditorFile(FilePath, -1, -1,
             [ofOnlyIfExists, ofRegularFile]) <> mrOK then
        begin
          Ctx.Error := True; Ctx.Result := 'Could not open: ' + FilePath; Exit;
        end;
        Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(FilePath);
      end;
      { Replace the changed range in the editor buffer — lands on undo stack, no disk write }
      Ed.ReplaceText(Point(NewX, NewY), DeclPt, NewName);
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
    end;

    'code_insert_in_procedure':
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
      Line     := Ctx.Params.Get('line', 0);
      if (FilePath = '') or (Symbol = '') then
      begin
        Ctx.Error := True; Ctx.Result := 'file and proc_name required'; Exit;
      end;
      Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(FilePath);
      { the editor's unsaved text goes to the code buffer without a disk write }
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
      if not CodeToolBoss.Explore(CodeBuf, Tool, True, False) then
      begin
        Ctx.Error := True; Ctx.Result := 'Parse error: ' + CodeToolBoss.ErrorMessage; Exit;
      end;
      if not FindProcBodyLines(Tool, CodeBuf, Symbol, NewName, Line, BeginLine, EndLine, Why) then
      begin
        Ctx.Error := True;
        if Why <> '' then Ctx.Result := Why else Ctx.Result := 'Procedure not found: ' + Symbol;
        Exit;
      end;
      if not Assigned(Ed) then
      begin
        { its message is an out parameter, cleared on entry: not NewName, which holds the
          text to insert (code_add_uses) or the section (code_add_to_class) (1.8.2) }
        if not McpCheckFileToOpen(FilePath, Why) then
        begin
          Ctx.Error := True; Ctx.Result := Why; Exit;
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
    end;

    'code_replace_procedure_body':
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
      Line     := Ctx.Params.Get('line', 0);
      if (FilePath = '') or (Symbol = '') then
      begin
        Ctx.Error := True; Ctx.Result := 'file and proc_name required'; Exit;
      end;
      Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(FilePath);
      { the editor's unsaved text goes to the code buffer without a disk write }
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
      if not CodeToolBoss.Explore(CodeBuf, Tool, True, False) then
      begin
        Ctx.Error := True; Ctx.Result := 'Parse error: ' + CodeToolBoss.ErrorMessage; Exit;
      end;
      if not FindProcBodyLines(Tool, CodeBuf, Symbol, NewName, Line, BeginLine, EndLine, Why) then
      begin
        Ctx.Error := True;
        if Why <> '' then Ctx.Result := Why else Ctx.Result := 'Procedure not found: ' + Symbol;
        Exit;
      end;
      if not Assigned(Ed) then
      begin
        { its message is an out parameter, cleared on entry: not NewName, which holds the
          text to insert (code_add_uses) or the section (code_add_to_class) (1.8.2) }
        if not McpCheckFileToOpen(FilePath, Why) then
        begin
          Ctx.Error := True; Ctx.Result := Why; Exit;
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
    end;

    'code_add_to_class':
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
      { the editor's unsaved text goes to the code buffer without a disk write }
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
        { its message is an out parameter, cleared on entry: not NewName, which holds the
          text to insert (code_add_uses) or the section (code_add_to_class) (1.8.2) }
        if not McpCheckFileToOpen(FilePath, Why) then
        begin
          Ctx.Error := True; Ctx.Result := Why; Exit;
        end;
        if LazarusIDE.DoOpenEditorFile(FilePath, -1, -1,
             [ofOnlyIfExists, ofRegularFile]) <> mrOK then
        begin
          Ctx.Error := True; Ctx.Result := 'Could not open: ' + FilePath; Exit;
        end;
        Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(FilePath);
      end;
      Snippet := StringReplace(Snippet, #13#10, #10, [rfReplaceAll]);
      Snippet := StringReplace(IndentMembers(Snippet, ClassMemberIndent(CodeBuf, InsertLine)),
                   LineEnding, #10, [rfReplaceAll]);
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
    end;

    'code_complete':
    begin
      Result := True;
      DoCompleteCode(Ctx);
    end;

    'code_edit_statement':
    begin
      Result := True;
      DoEditStatement(Ctx);
    end;

    'code_get_procedure_ast':
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
      MaxDepth := Ctx.Params.Get('depth',      1);
      if MaxDepth < 1 then MaxDepth := 1;
      if MaxDepth > 10 then MaxDepth := 10;
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
        if not FindProcBodyLines(Tool, CodeBuf, Symbol, NewName, NewY, BeginLine, EndLine, Why) then
        begin
          Ctx.Error := True;
          if Why <> '' then Ctx.Result := Why else Ctx.Result := 'Procedure not found: ' + Symbol;
          Exit;
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
                CleanToLineCol(Tool, CodeBuf, Child.StartPos, I, J);
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
                CleanToLineCol(Tool, CodeBuf, Child.StartPos,   I, J);
                CleanToLineCol(Tool, CodeBuf, Child.EndPos - 1, EndLine, J);
                if (NewY >= I) and (NewY <= EndLine) then
                begin
                  BeginNode := Child;
                  BeginLine := I;
                  Symbol    := ExtractProcNodeName(Tool, CodeBuf, TreeNode);
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
                  CleanToLineCol(Tool, CodeBuf, TreeNode.StartPos, I, J);
                  Entry := TJSONObject.Create;
                  Entry.Add('name', Tool.ExtractIdentifier(TreeNode.StartPos));
                  Why := Tool.ExtractDefinitionNodeType(TreeNode);
                  if Why <> '' then Entry.Add('type', Why);
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
        { The statements: CodeTools' tree ends at the begin block, so the body text is read by
          McpStatements }
        if Assigned(BeginNode) then
        begin
          Root := BodyStatements(Tool, CodeBuf, BeginNode);
          try
            Obj.Add('nodes', StatementsJson(Root, MaxDepth));
          finally
            Root.Free;
          end;
        end
        else
          Obj.Add('nodes', TJSONArray.Create);
        Ctx.Result := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    end;
  end;
end;

{ ── Schema registration ──────────────────────────────────────────────────── }

procedure RegisterCodeToolsSchemas(Tools: TJSONArray);
begin
  Tools.Add(MakeTool('code_find_declaration',
    'Find where an identifier is declared using Codetools. ' +
    'Returns declaration file, line, column and a short context snippet. Resolves through ' +
    'the unit''s uses clauses (a type from Classes or a sibling unit) from a use of the ' +
    'name in file, so it also works in a program (.lpr); line and col, both optional, pick a ' +
    'particular USE of the name. Only reports the place; show=true also opens the file and ' +
    'moves the editor cursor there.',
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
    'across all project files (or a package''s, with package_name or lpk_path) and the file itself. ' +
    'also and search_dir add folders or the LCL, RTL, FPC packages, components or loaded ' +
    'packages, e.g. to see how an API is used.',
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
    'and open it in the editor. Provide content or receive a blank unit skeleton. ' +
    'Only inside the project, a loaded package, the git working tree holding either, or the temp ' +
    'folder; an existing file is refused.',
    SCHEMA_CREATE_UNIT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('code_add_uses',
    'Add a unit to the uses clause of a Pascal file using Codetools. ' +
    'Edit lands in the editor buffer, not on disk (Ctrl+Z works); use auto_save=true or ' +
    'editor_save to persist to disk. ' +
    'Set in_interface=false to target the implementation uses clause.',
    SCHEMA_ADD_UNIT_TO_USES, MCP_ANN_WRITE_IDEM));
  Tools.Add(MakeTool('code_insert_in_procedure',
    'Insert text at the start of a named procedure or function body (immediately ' +
    'after begin), located via CodeTools AST. No string matching — robust to ' +
    'whitespace and formatting changes. Uses the editor undo stack (Ctrl+Z works). ' +
    'An overloaded name, or one that exists in several classes, is refused with the candidates; ' +
    'pass line (inside the one you mean) or class_name.',
    SCHEMA_INSERT_IN_PROCEDURE, MCP_ANN_WRITE));
  Tools.Add(MakeTool('code_replace_procedure_body',
    'Replace the entire body of a named procedure or function (everything between ' +
    'begin and end) with new_body, located via CodeTools AST. No string matching. ' +
    'Uses the editor undo stack (Ctrl+Z works). ' +
    'An overloaded name, or one that exists in several classes, is refused with the candidates; ' +
    'pass line (inside the one you mean) or class_name.',
    SCHEMA_REPLACE_PROCEDURE_BODY, MCP_ANN_WRITE));
  Tools.Add(MakeTool('code_add_to_class',
    'Append a declaration to a named section of a class (public, private, ' +
    'protected, or published), located via CodeTools AST. No string matching. ' +
    'Uses the editor undo stack (Ctrl+Z works).',
    SCHEMA_ADD_TO_CLASS_SECTION, MCP_ANN_WRITE));
  Tools.Add(MakeTool('code_complete',
    'Code completion as the IDE''s Ctrl+Shift+C does it, at (file, line, col), without its ' +
    'dialogs. By position: inside a class declaration, everything missing in that class at once ' +
    '(bodies for declared methods, a field and setter for "property Size: Integer read FSize ' +
    'write SetSize;", declarations for method bodies without one); on a forward procedure ' +
    'header, its body; on an undeclared identifier in a body ("x := 5", "for x in List", an ' +
    'argument), a local variable; on an event assignment ("OnClick := @Clicked") or a call to an ' +
    'undeclared procedure, that method or procedure; in a method body with no declaration, the ' +
    'declaration. New methods go in the default class section. Returns the changed lines as hunks ' +
    '(line numbers in the new text) and the position the IDE would jump to. Edits land in the ' +
    'editor buffers (Ctrl+Z works); auto_save=true or editor_save writes them to disk.',
    SCHEMA_COMPLETE_CODE, MCP_ANN_WRITE));
  Tools.Add(MakeTool('code_get_procedure_ast',
    'Return a routine''s local variables (name, type, line) and its statements as a tree: ' +
    'kind (begin, if, for, while, with, repeat, try_except, try_finally, case, of, on, else, ' +
    'assign, call, ...), name (the called routine or assigned variable), line, col, end_line, ' +
    'and for an if its else_line, for a try its handler_line. depth (default 1) says how many ' +
    'levels are listed; deeper ones show as "nested": n. For use with editor_replace_range. ' +
    'The body is read with the CodeTools scanner, so only the active {$IFDEF} branch is seen; an asm block is one node. ' +
    'To change one statement use code_edit_statement with its line and col. ' +
    'An overloaded name is refused with the candidates; pass line or class_name.',
    SCHEMA_GET_AST_PARTIAL, MCP_ANN_RO));
  Tools.Add(MakeTool('code_edit_statement',
    'Change ONE statement of a routine body without sending the body: take its line and col from ' +
    'code_get_procedure_ast, then replace it, delete it, insert statements before or after it, or ' +
    'wrap it in begin..end, try..finally, try..except, if, while, for or with. Only that statement''s ' +
    'text changes: the comments, directives and formatting around it stay. The text you send ' +
    'is indented like the statement, so write it without indentation. delete and insert need ' +
    'a statement that is one of a list (a begin block, a try part, a repeat, a case); the one ' +
    'statement of an if, a loop or a handler is refused with the reason (use replace, or wrap with begin). ' +
    'Positions of the statements after the edit change: read code_get_procedure_ast again. ' +
    'Uses the editor undo stack (Ctrl+Z works).',
    SCHEMA_EDIT_STATEMENT, MCP_ANN_WRITE));
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
