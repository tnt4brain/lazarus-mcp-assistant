{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsEditor;

{ Editor / navigation tools: editor_get_active, editor_read_file, project_list_files,
  editor_list_open, editor_get_cursor, editor_get_selection, editor_edit_text,
  editor_replace_range, editor_set_cursor, editor_save, editor_close, editor_revert,
  editor_open. }

{$mode objfpc}{$H+}

interface

implementation

uses
  Classes, SysUtils, StrUtils,
  LazIDEIntf, SrcEditorIntf, ProjectIntf, LazFileUtils, Controls,
  fpjson,
  McpToolContext, McpToolHelpers;

{ ── Schema constants ─────────────────────────────────────────────────────── }

const
  SCHEMA_GET_ACTIVE_FILE =
    '{"type":"object","properties":{}}';

  SCHEMA_GET_FILE_CONTENT =
    '{"type":"object","properties":{"file":{"type":"string",' +
    '"description":"Absolute path to the file"}},' +
    '"required":["file"]}';

  SCHEMA_GET_PROJECT_FILES =
    '{"type":"object","properties":{}}';

  SCHEMA_GET_OPEN_EDITORS =
    '{"type":"object","properties":{}}';

  SCHEMA_GET_CURSOR_POSITION =
    '{"type":"object","properties":{}}';

  SCHEMA_GET_SELECTED_TEXT =
    '{"type":"object","properties":{}}';

  SCHEMA_SET_CURSOR_POSITION =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path to the file; omit to use the active editor"},' +
    '"line":{"type":"integer","description":"Line number (1-based)"},' +
    '"col":{"type":"integer","description":"Column number (1-based)"}},' +
    '"required":["line","col"]}';

  SCHEMA_REPLACE_TEXT =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path to the file; omit to edit the active editor"},' +
    '"start_line":{"type":"integer","description":"Start line (1-based, inclusive)"},' +
    '"start_col":{"type":"integer","description":"Start column (1-based, inclusive)"},' +
    '"end_line":{"type":"integer","description":"End line (1-based, exclusive)"},' +
    '"end_col":{"type":"integer","description":"End column (1-based, exclusive)"},' +
    '"new_text":{"type":"string","description":"Replacement text; empty string to delete the range"}},' +
    '"required":["start_line","start_col","end_line","end_col","new_text"]}';

  SCHEMA_EDIT_TEXT =
    '{"type":"object","properties":{' +
    '"old_string":{"type":"string","description":"Exact text to find and replace (must be unique unless replace_all=true)"},' +
    '"new_string":{"type":"string","description":"Replacement text; empty string to delete the match"},' +
    '"file":{"type":"string","description":"Absolute path to the file; omit to edit the active editor"},' +
    '"replace_all":{"type":"boolean","description":"Replace all occurrences (default false — fails if >1 match)"},' +
    '"auto_save":{"type":"boolean","description":"Also save to disk (default false)"}},' +
    '"required":["old_string","new_string"]}';

  SCHEMA_SAVE_FILE =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path of the file to save; omit to save the active editor"}}}';

  SCHEMA_CLOSE_FILE =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path of the file to close; omit to close the active editor"}}}';

  SCHEMA_REVERT_FILE =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path of the file to revert; omit to revert the active editor"}}}';

  SCHEMA_OPEN_FILE =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path to the file to open in the editor"}},' +
    '"required":["file"]}';

  SCHEMA_EDIT_AT_POSITION =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path to the file; omit for active editor"},' +
    '"line":{"type":"integer","description":"1-based line number of the edit point"},' +
    '"col":{"type":"integer","description":"1-based column number of the edit point"},' +
    '"delete_len":{"type":"integer","description":"Number of characters to delete forward from (line,col); 0 for pure insert"},' +
    '"insert_text":{"type":"string","description":"Text to insert at (line,col) after deletion; empty string for pure delete"},' +
    '"auto_save":{"type":"boolean","description":"Also save to disk (default false)"}},' +
    '"required":["line","col","delete_len","insert_text"]}';

{ ── Dispatch ─────────────────────────────────────────────────────────────── }

function DispatchEditorTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  Ed           : TSourceEditorInterface;
  Obj          : TJSONObject;
  Files        : TJSONArray;
  Proj         : TLazProject;
  SyncFilePath : string;
  SyncFileNames: TStringList;
  PasName      : string;
  SyncNewX     : Integer;
  SyncNewY     : Integer;
  SyncTopLine  : Integer;
  SyncDeclPt   : TPoint;
  SyncOldStr   : string;
  SyncNewName  : string;
  SyncReplAll  : Boolean;
  SyncAutoSave : Boolean;
  SyncText     : string;
  SyncMatchPositions: TList;
  SyncPos      : Integer;
  SyncMatchLine: Integer;
  SyncMatchCol : Integer;
  SyncEndLine  : Integer;
  SyncEndCol   : Integer;
  StartLine    : Integer;
  StartCol     : Integer;
  EndLine      : Integer;
  EndCol       : Integer;
  AlreadyOpen  : Boolean;
  I            : Integer;
  J            : Integer;
begin
  Result := False;

  if Name = 'editor_get_active' then
  begin
    Result := True;
    Ed := SourceEditorManagerIntf.ActiveEditor;
    if not Assigned(Ed) then
    begin
      Ctx.Error := True; Ctx.Result := 'No active editor'; Exit;
    end;
    if CompareFileExt(Ed.FileName, '.lfm', False) = 0 then
    begin
      PasName := ChangeFileExt(Ed.FileName, '.pas');
      Obj := TJSONObject.Create;
      try
        Obj.Add('note', 'The active editor is a form file. ' +
                        'Both the form definition and its Pascal unit are provided.');
        Obj.Add('form_filename', Ed.FileName);
        Obj.Add('form_content',  StringReplace(Ed.Lines.Text, #13#10, #10, [rfReplaceAll]));
        for I := 0 to SourceEditorManagerIntf.SourceEditorCount - 1 do
          if CompareFilenames(SourceEditorManagerIntf.SourceEditors[I].FileName,
                              PasName) = 0 then
          begin
            Obj.Add('unit_filename', PasName);
            Obj.Add('unit_content',
                    StringReplace(SourceEditorManagerIntf.SourceEditors[I].Lines.Text, #13#10, #10, [rfReplaceAll]));
            Break;
          end;
        Ctx.Result := Obj.AsJSON;
      finally
        Obj.Free;
      end;
      Exit;
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('filename',    Ed.FileName);
      Obj.Add('content',     StringReplace(Ed.Lines.Text, #13#10, #10, [rfReplaceAll]));
      Obj.Add('cursor_line', Ed.CursorTextXY.Y);
      Obj.Add('cursor_col',  Ed.CursorTextXY.X);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'editor_read_file' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('file', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'file required'; Exit;
    end;
    SyncFilePath := Ctx.Params.Get('file', '');
    Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(SyncFilePath);
    if Assigned(Ed) then
    begin
      Obj := TJSONObject.Create;
      try
        Obj.Add('path',    SyncFilePath);
        Obj.Add('content', StringReplace(Ed.Lines.Text, #13#10, #10, [rfReplaceAll]));
        Obj.Add('source',  'editor');
        Ctx.Result := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    end
    else
    begin
      SyncFileNames := TStringList.Create;
      try
        try
          SyncFileNames.LoadFromFile(SyncFilePath);
          Obj := TJSONObject.Create;
          try
            Obj.Add('path',    SyncFilePath);
            Obj.Add('content', StringReplace(SyncFileNames.Text, #13#10, #10, [rfReplaceAll]));
            Obj.Add('source',  'disk');
            Ctx.Result := Obj.AsJSON;
          finally
            Obj.Free;
          end;
        except
          on E: Exception do
          begin
            Ctx.Error  := True;
            Ctx.Result := 'Error reading file: ' + E.Message;
          end;
        end;
      finally
        SyncFileNames.Free;
      end;
    end;
  end

  else if Name = 'project_list_files' then
  begin
    Result := True;
    Files := TJSONArray.Create;
    try
      if Assigned(LazarusIDE) then
      begin
        Proj := LazarusIDE.ActiveProject;
        if Assigned(Proj) then
          for I := 0 to Proj.FileCount - 1 do
            if Proj.Files[I].IsPartOfProject then
              Files.Add(Proj.Files[I].Filename);
      end;
      Ctx.Result := Files.AsJSON;
    finally
      Files.Free;
    end;
  end

  else if Name = 'editor_list_open' then
  begin
    Result := True;
    Files := TJSONArray.Create;
    try
      for I := 0 to SourceEditorManagerIntf.SourceEditorCount - 1 do
        Files.Add(SourceEditorManagerIntf.SourceEditors[I].FileName);
      Ctx.Result := Files.AsJSON;
    finally
      Files.Free;
    end;
  end

  else if Name = 'editor_get_cursor' then
  begin
    Result := True;
    Ed := SourceEditorManagerIntf.ActiveEditor;
    if not Assigned(Ed) then
    begin
      Ctx.Error := True; Ctx.Result := 'No active editor'; Exit;
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('file', Ed.FileName);
      Obj.Add('line', Ed.CursorTextXY.Y);
      Obj.Add('col',  Ed.CursorTextXY.X);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'editor_get_selection' then
  begin
    Result := True;
    Ed := SourceEditorManagerIntf.ActiveEditor;
    if not Assigned(Ed) then
    begin
      Ctx.Error := True; Ctx.Result := 'No active editor'; Exit;
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('file', Ed.FileName);
      if Ed.SelectionAvailable then
      begin
        Obj.Add('text',       Ed.Selection);
        Obj.Add('start_line', Ed.BlockBegin.Y);
        Obj.Add('start_col',  Ed.BlockBegin.X);
        Obj.Add('end_line',   Ed.BlockEnd.Y);
        Obj.Add('end_col',    Ed.BlockEnd.X);
      end
      else
      begin
        Obj.Add('text', '');
        Obj.Add('note', 'No text selected');
      end;
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'editor_set_cursor' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) then
    begin
      Ctx.Error := True; Ctx.Result := 'line and col required'; Exit;
    end;
    SyncNewY := Ctx.Params.Get('line', 0);
    SyncNewX := Ctx.Params.Get('col',  0);
    if (SyncNewY < 1) or (SyncNewX < 1) then
    begin
      Ctx.Error := True; Ctx.Result := 'line and col must be >= 1'; Exit;
    end;
    SyncFilePath := Ctx.Params.Get('file', '');
    if SyncFilePath <> '' then
    begin
      SyncDeclPt := Point(SyncNewX, SyncNewY);
      if LazarusIDE.DoOpenFileAndJumpToPos(SyncFilePath, SyncDeclPt,
           SyncNewY, -1, -1, [ofOnlyIfExists, ofRegularFile]) <> mrOK then
      begin
        Ctx.Error := True; Ctx.Result := 'Could not open: ' + SyncFilePath; Exit;
      end;
      Ed := SourceEditorManagerIntf.ActiveEditor;
    end
    else
    begin
      Ed := SourceEditorManagerIntf.ActiveEditor;
      if not Assigned(Ed) then
      begin
        Ctx.Error := True; Ctx.Result := 'No active editor'; Exit;
      end;
      Ed.CursorTextXY := Point(SyncNewX, SyncNewY);
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('file', Ed.FileName);
      Obj.Add('line', SyncNewY);
      Obj.Add('col',  SyncNewX);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'editor_replace_range' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) then
    begin
      Ctx.Error := True; Ctx.Result := 'start_line, start_col, end_line, end_col, new_text required'; Exit;
    end;
    StartLine := Ctx.Params.Get('start_line', 0);
    StartCol  := Ctx.Params.Get('start_col',  0);
    EndLine   := Ctx.Params.Get('end_line',   0);
    EndCol    := Ctx.Params.Get('end_col',    0);
    if (StartLine < 1) or (StartCol < 1) or (EndLine < 1) or (EndCol < 1) then
    begin
      Ctx.Error := True; Ctx.Result := 'start_line, start_col, end_line, end_col must be >= 1'; Exit;
    end;
    SyncFilePath := Ctx.Params.Get('file', '');
    if SyncFilePath <> '' then
    begin
      Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(SyncFilePath);
      if not Assigned(Ed) then
      begin
        if LazarusIDE.DoOpenEditorFile(SyncFilePath, -1, -1,
             [ofOnlyIfExists, ofRegularFile]) <> mrOK then
        begin
          Ctx.Error := True; Ctx.Result := 'Could not open: ' + SyncFilePath; Exit;
        end;
        Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(SyncFilePath);
      end;
    end
    else
      Ed := SourceEditorManagerIntf.ActiveEditor;
    if not Assigned(Ed) then
    begin
      Ctx.Error := True; Ctx.Result := 'No active editor'; Exit;
    end;
    SyncNewName := Ctx.Params.Get('new_text', '');
    Ed.ReplaceText(Point(StartCol, StartLine), Point(EndCol, EndLine), SyncNewName);
    Obj := TJSONObject.Create;
    try
      Obj.Add('file',     Ed.FileName);
      Obj.Add('replaced', True);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'editor_edit_text' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) then
    begin
      Ctx.Error := True; Ctx.Result := 'old_string and new_string required'; Exit;
    end;
    SyncOldStr   := Ctx.Params.Get('old_string',  '');
    SyncNewName  := Ctx.Params.Get('new_string',  '');
    SyncReplAll  := Ctx.Params.Get('replace_all', False);
    SyncAutoSave := Ctx.Params.Get('auto_save',   False);
    if SyncOldStr = '' then
    begin
      Ctx.Error := True; Ctx.Result := 'old_string must not be empty'; Exit;
    end;
    SyncFilePath := Ctx.Params.Get('file', '');
    if SyncFilePath <> '' then
    begin
      Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(SyncFilePath);
      if not Assigned(Ed) then
      begin
        if LazarusIDE.DoOpenEditorFile(SyncFilePath, -1, -1,
             [ofOnlyIfExists, ofRegularFile]) <> mrOK then
        begin
          Ctx.Error := True; Ctx.Result := 'Could not open: ' + SyncFilePath; Exit;
        end;
        Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(SyncFilePath);
      end;
    end
    else
      Ed := SourceEditorManagerIntf.ActiveEditor;
    if not Assigned(Ed) then
    begin
      Ctx.Error := True; Ctx.Result := 'No active editor'; Exit;
    end;
    SyncText := StringReplace(Ed.Lines.Text, #13#10, #10, [rfReplaceAll]);
    SyncMatchPositions := TList.Create;
    try
      SyncPos := 1;
      repeat
        SyncPos := PosEx(SyncOldStr, SyncText, SyncPos);
        if SyncPos > 0 then
        begin
          SyncMatchPositions.Add(Pointer(PtrInt(SyncPos)));
          SyncPos := SyncPos + Length(SyncOldStr);
        end;
      until SyncPos = 0;
      if SyncMatchPositions.Count = 0 then
      begin
        Ctx.Error  := True;
        Ctx.Result := 'old_string not found in ' + Ed.FileName;
        Exit;
      end;
      if (SyncMatchPositions.Count > 1) and not SyncReplAll then
      begin
        Ctx.Error  := True;
        Ctx.Result := 'old_string matches ' + IntToStr(SyncMatchPositions.Count) +
          ' times; pass replace_all=true to replace all, or narrow old_string';
        Exit;
      end;
      for I := SyncMatchPositions.Count - 1 downto 0 do
      begin
        SyncPos := PtrInt(SyncMatchPositions[I]);
        McpOffsetToLineCol(SyncText, SyncPos, SyncMatchLine, SyncMatchCol);
        McpOffsetToLineCol(SyncText, SyncPos + Length(SyncOldStr), SyncEndLine, SyncEndCol);
        Ed.ReplaceText(Point(SyncMatchCol, SyncMatchLine),
                       Point(SyncEndCol,   SyncEndLine), SyncNewName);
      end;
      if SyncAutoSave then
        LazarusIDE.DoSaveEditorFile(Ed.FileName, []);
      Obj := TJSONObject.Create;
      try
        Obj.Add('file',     Ed.FileName);
        Obj.Add('replaced', SyncMatchPositions.Count);
        if SyncAutoSave then Obj.Add('saved', True);
        Ctx.Result := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    finally
      SyncMatchPositions.Free;
    end;
  end

  else if Name = 'editor_save' then
  begin
    Result := True;
    SyncFilePath := '';
    if Assigned(Ctx.Params) then
      SyncFilePath := Ctx.Params.Get('file', '');
    if SyncFilePath <> '' then
    begin
      if LazarusIDE.DoSaveEditorFile(SyncFilePath, []) <> mrOK then
      begin
        Ctx.Error := True; Ctx.Result := 'Save failed: ' + SyncFilePath; Exit;
      end;
    end
    else
    begin
      Ed := SourceEditorManagerIntf.ActiveEditor;
      if not Assigned(Ed) then
      begin
        Ctx.Error := True; Ctx.Result := 'No active editor'; Exit;
      end;
      if LazarusIDE.DoSaveEditorFile(Ed, []) <> mrOK then
      begin
        Ctx.Error := True; Ctx.Result := 'Save failed'; Exit;
      end;
      SyncFilePath := Ed.FileName;
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('file',  SyncFilePath);
      Obj.Add('saved', True);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'editor_close' then
  begin
    Result := True;
    SyncFilePath := '';
    if Assigned(Ctx.Params) then
      SyncFilePath := Ctx.Params.Get('file', '');
    if SyncFilePath <> '' then
    begin
      if LazarusIDE.DoCloseEditorFile(SyncFilePath, [cfQuiet]) <> mrOK then
      begin
        Ctx.Error := True; Ctx.Result := 'Close failed: ' + SyncFilePath; Exit;
      end;
    end
    else
    begin
      Ed := SourceEditorManagerIntf.ActiveEditor;
      if not Assigned(Ed) then
      begin
        Ctx.Error := True; Ctx.Result := 'No active editor'; Exit;
      end;
      SyncFilePath := Ed.FileName;
      if LazarusIDE.DoCloseEditorFile(Ed, [cfQuiet]) <> mrOK then
      begin
        Ctx.Error := True; Ctx.Result := 'Close failed'; Exit;
      end;
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('file',   SyncFilePath);
      Obj.Add('closed', True);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'editor_revert' then
  begin
    Result := True;
    SyncFilePath := '';
    if Assigned(Ctx.Params) then
      SyncFilePath := Ctx.Params.Get('file', '');
    if SyncFilePath = '' then
    begin
      Ed := SourceEditorManagerIntf.ActiveEditor;
      if not Assigned(Ed) then
      begin
        Ctx.Error := True; Ctx.Result := 'No active editor'; Exit;
      end;
      SyncFilePath := Ed.FileName;
    end;
    if LazarusIDE.DoRevertEditorFile(SyncFilePath) <> mrOK then
    begin
      Ctx.Error := True; Ctx.Result := 'Revert failed: ' + SyncFilePath; Exit;
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('file',     SyncFilePath);
      Obj.Add('reverted', True);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'editor_open' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('file', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'file required'; Exit;
    end;
    SyncFilePath := Ctx.Params.Get('file', '');
    AlreadyOpen  := Assigned(
      SourceEditorManagerIntf.SourceEditorIntfWithFilename(SyncFilePath));
    LazarusIDE.DoOpenEditorFile(SyncFilePath, -1, -1, [ofOnlyIfExists, ofRegularFile]);
    Obj := TJSONObject.Create;
    try
      Obj.Add('file',         SyncFilePath);
      Obj.Add('already_open', AlreadyOpen);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'editor_edit_at_position' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) then
    begin
      Ctx.Error := True; Ctx.Result := 'line, col, delete_len, insert_text required'; Exit;
    end;
    StartLine    := Ctx.Params.Get('line',        0);
    StartCol     := Ctx.Params.Get('col',         0);
    SyncPos      := Ctx.Params.Get('delete_len',  0);  { reuse SyncPos for delete_len }
    SyncNewName  := Ctx.Params.Get('insert_text', '');
    SyncAutoSave := Ctx.Params.Get('auto_save',   False);
    if (StartLine < 1) or (StartCol < 1) then
    begin
      Ctx.Error := True; Ctx.Result := 'line and col must be >= 1'; Exit;
    end;
    if SyncPos < 0 then
    begin
      Ctx.Error := True; Ctx.Result := 'delete_len must be >= 0'; Exit;
    end;
    SyncFilePath := Ctx.Params.Get('file', '');
    if SyncFilePath <> '' then
    begin
      Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(SyncFilePath);
      if not Assigned(Ed) then
      begin
        if LazarusIDE.DoOpenEditorFile(SyncFilePath, -1, -1,
             [ofOnlyIfExists, ofRegularFile]) <> mrOK then
        begin
          Ctx.Error := True; Ctx.Result := 'Could not open: ' + SyncFilePath; Exit;
        end;
        Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(SyncFilePath);
      end;
    end
    else
      Ed := SourceEditorManagerIntf.ActiveEditor;
    if not Assigned(Ed) then
    begin
      Ctx.Error := True; Ctx.Result := 'No active editor'; Exit;
    end;
    { Compute end point: walk to start offset, advance delete_len chars, convert back }
    SyncText := StringReplace(Ed.Lines.Text, #13#10, #10, [rfReplaceAll]);
    I := 1;
    J := 1; { current line during walk }
    while (I <= Length(SyncText)) and (J < StartLine) do
    begin
      if SyncText[I] = #10 then Inc(J);
      Inc(I);
    end;
    Inc(I, StartCol - 1);  { I is now the 1-based offset of (StartLine, StartCol) }
    McpOffsetToLineCol(SyncText, I + SyncPos, SyncEndLine, SyncEndCol);
    Ed.ReplaceText(Point(StartCol, StartLine),
                   Point(SyncEndCol, SyncEndLine), SyncNewName);
    if SyncAutoSave then
      LazarusIDE.DoSaveEditorFile(Ed.FileName, []);
    Obj := TJSONObject.Create;
    try
      Obj.Add('file',     Ed.FileName);
      Obj.Add('line',     StartLine);
      Obj.Add('col',      StartCol);
      Obj.Add('deleted',  SyncPos);
      Obj.Add('inserted', Length(SyncNewName));
      if SyncAutoSave then Obj.Add('saved', True);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end;
end;

{ ── Schema registration ──────────────────────────────────────────────────── }

procedure RegisterEditorSchemas(Tools: TJSONArray);
begin
  Tools.Add(MakeTool('editor_get_active',
    'Return the active editor file name and its current buffer content.',
    SCHEMA_GET_ACTIVE_FILE, MCP_ANN_RO));
  Tools.Add(MakeTool('editor_read_file',
    'Read the content of any file by its absolute path. ' +
    'Prefers the live editor buffer (shows unsaved changes) over disk.',
    SCHEMA_GET_FILE_CONTENT, MCP_ANN_RO));
  Tools.Add(MakeTool('project_list_files',
    'Return the list of source files in the active project.',
    SCHEMA_GET_PROJECT_FILES, MCP_ANN_RO));
  Tools.Add(MakeTool('editor_list_open',
    'Return the list of all currently open editor tabs (file names).',
    SCHEMA_GET_OPEN_EDITORS, MCP_ANN_RO));
  Tools.Add(MakeTool('editor_get_cursor',
    'Return the current cursor position (file, line, col) in the active editor.',
    SCHEMA_GET_CURSOR_POSITION, MCP_ANN_RO));
  Tools.Add(MakeTool('editor_get_selection',
    'Return the currently selected text and its range in the active editor.',
    SCHEMA_GET_SELECTED_TEXT, MCP_ANN_RO));
  Tools.Add(MakeTool('editor_set_cursor',
    'Move the cursor to a specific line and column in the editor. ' +
    'Opens the file first if it is not already open. ' +
    'Omit file to move the cursor in the currently active editor.',
    SCHEMA_SET_CURSOR_POSITION, MCP_ANN_RO));
  Tools.Add(MakeTool('editor_replace_range',
    'Replace a range of text in the editor buffer. ' +
    'The edit is recorded in the editor''s undo history (Ctrl+Z works). ' +
    'Use an empty range (start = end) to insert text. ' +
    'Use empty new_text to delete the range. ' +
    'Opens the file first if it is not already open.',
    SCHEMA_REPLACE_TEXT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('editor_edit_text',
    'Replace old_string with new_string in the editor buffer (opens the file if ' +
    'needed; Ctrl+Z works). Prefer this over editor_replace_range: no stale line numbers.',
    SCHEMA_EDIT_TEXT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('editor_save',
    'Save the editor buffer to disk. Omit file to save the active editor.',
    SCHEMA_SAVE_FILE, MCP_ANN_WRITE_IDEM));
  Tools.Add(MakeTool('editor_close',
    'Close an editor tab. Omit file to close the active editor. ' +
    'Unsaved changes are discarded quietly.',
    SCHEMA_CLOSE_FILE, MCP_ANN_DEST_IDEM));
  Tools.Add(MakeTool('editor_revert',
    'Discard unsaved editor changes and reload the file from disk. ' +
    'Omit file to revert the active editor.',
    SCHEMA_REVERT_FILE, MCP_ANN_DEST_IDEM));
  Tools.Add(MakeTool('editor_open',
    'Open a file in the IDE editor and make it the active tab, ' +
    'without moving the cursor. Returns {"file":..., "already_open":bool}.',
    SCHEMA_OPEN_FILE, MCP_ANN_RO));
  Tools.Add(MakeTool('editor_edit_at_position',
    'Replace delete_len characters at (line, col) with insert_text, using ' +
    'coordinates from code_get_outline, code_find_declaration or ' +
    'code_get_procedure_ast. Ctrl+Z works.',
    SCHEMA_EDIT_AT_POSITION, MCP_ANN_WRITE));
end;

initialization
  RegisterMcpGroup(@DispatchEditorTool);
  RegisterMcpSchemas(@RegisterEditorSchemas);

end.
