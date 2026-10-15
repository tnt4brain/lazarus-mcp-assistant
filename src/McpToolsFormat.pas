{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsFormat;

{ code_format: formats a Pascal file, or some of its lines, with JEDI Code
  Format, as its Source > JEDI Code Format menu does, with the same settings
  (jcfbase is linked into the IDE once, so its settings objects are the ones
  the user edits in Tools > Options > JEDI Code Format).

  The menu commands work on the active editor and may ask for confirmation;
  this runs JCF's TConverter on the editor's text instead and applies only the
  lines that changed, in one undo block (one Ctrl+Z).  Main thread. }

{$mode objfpc}{$H+}

interface

implementation

uses
  Classes, SysUtils, Types,
  LazIDEIntf, SrcEditorIntf, LazFileUtils, Controls,
  fpjson,
  Converter, ConvertTypes, JcfRegistrySettings,
  McpToolContext, McpLineDiff;

const
  SCHEMA_FORMAT =
    '{"type":"object","properties":{' +
    '"file":{"type":"string","description":"Absolute path of a .pas, .pp, .lpr, .dpr or .inc file"},' +
    '"start_line":{"type":"integer","description":"First line to format (1-based); omit with end_line for the whole file"},' +
    '"end_line":{"type":"integer","description":"Last line to format (1-based)"},' +
    '"auto_save":{"type":"boolean","description":"Also save to disk (default false)"}},' +
    '"required":["file"]}';

type
  { JCF's callbacks are methods: collects its messages and finds include files. }
  TJcfSink = class
  public
    Messages : TJSONArray;
    Errors   : string;
    constructor Create;
    procedure OnMessage(const psUnit, psMessage: string;
      const peMessageType: TStatusMessageType; const piY, piX: Integer);
    procedure OnIncludeFile(Sender: TObject; AIncludeFileName: string;
      var AFileContentOrErrorMessage: string; var AFileReaded: Boolean);
  end;

constructor TJcfSink.Create;
begin
  inherited Create;
  Messages := TJSONArray.Create;
end;

procedure TJcfSink.OnMessage(const psUnit, psMessage: string;
  const peMessageType: TStatusMessageType; const piY, piX: Integer);
const
  Kinds: array[TStatusMessageType] of string =
    ('error', 'error', 'parse error', 'warning', 'summary', 'progress');
var
  M : TJSONObject;
begin
  if (Trim(psMessage) = '') or (peMessageType in [mtFinalSummary, mtProgress]) then
    Exit;
  M := TJSONObject.Create;
  M.Add('kind', Kinds[peMessageType]);
  M.Add('message', Trim(psMessage));
  if piY > 0 then
  begin
    M.Add('line', piY);
    if piX > 0 then M.Add('col', piX);
  end;
  Messages.Add(M);
  if peMessageType in [mtException, mtInputError, mtParseError] then
  begin
    if Errors <> '' then Errors := Errors + '; ';
    Errors := Errors + Trim(psMessage);
    if piY > 0 then
      Errors := Errors + Format(' (line %d, col %d)', [piY, piX]);
  end;
end;

{ As the JCF IDE plugin does it: next to the unit, then by absolute name, then
  in the project's include paths; an open editor's text wins over the disk. }
procedure TJcfSink.OnIncludeFile(Sender: TObject; AIncludeFileName: string;
  var AFileContentOrErrorMessage: string; var AFileReaded: Boolean);
var
  F  : string;
  Ed : TSourceEditorInterface;
  SL : TStringList;
begin
  F := '';
  if ExtractFilePath(AIncludeFileName) = '' then
    F := ExtractFilePath(TConverter(Sender).FileName) + AIncludeFileName
  else if FilenameIsAbsolute(AIncludeFileName) then
    F := AIncludeFileName;
  if (F = '') or ((SourceEditorManagerIntf.SourceEditorIntfWithFilename(F) = nil) and
                  not FileExists(F)) then
  begin
    F := '';
    if Assigned(LazarusIDE.ActiveProject) then
      F := LazarusIDE.FindSourceFile(AIncludeFileName,
        LazarusIDE.ActiveProject.Directory, [fsfSearchForProject, fsfUseIncludePaths]);
  end;
  AFileReaded := False;
  if F = '' then
  begin
    AFileContentOrErrorMessage := ' Include file not found: ' + AIncludeFileName;
    Exit;
  end;
  Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(F);
  if Assigned(Ed) then
    AFileContentOrErrorMessage := Ed.GetText(False)
  else
  begin
    SL := TStringList.Create;
    try
      SL.LoadFromFile(F);
      AFileContentOrErrorMessage := SL.Text;
    finally
      SL.Free;
    end;
  end;
  AFileReaded := True;
end;

{ 1-based index of the first character of line ALine (1-based) in S. }
function LineStartIndex(const S: string; ALine: Integer): Integer;
var
  L : Integer;
begin
  Result := 1;
  L := 1;
  while (L < ALine) and (Result <= Length(S)) do
  begin
    if S[Result] = #10 then Inc(L)
    else if S[Result] = #13 then
    begin
      Inc(L);
      if (Result < Length(S)) and (S[Result + 1] = #10) then Inc(Result);
    end;
    Inc(Result);
  end;
end;

procedure DoFormat(var Ctx: TMcpToolCall);
const
  Allowed: array[0..4] of string = ('.pas', '.pp', '.lpr', '.dpr', '.inc');
var
  FilePath, Ext, Src     : string;
  StartLine, EndLine     : Integer;
  AutoSave, IsInc, Ok    : Boolean;
  Ed                     : TSourceEditorInterface;
  Conv                   : TConverter;
  Sink                   : TJcfSink;
  OldTree                : TShowParseTreeOption;
  A, B, Part             : TStringList;
  Hunks                  : TLineHunks;
  Obj                    : TJSONObject;
  I, StartIdx, EndIdx    : Integer;
begin
  if not Assigned(Ctx.Params) then
  begin
    Ctx.Error := True; Ctx.Result := 'Missing params'; Exit;
  end;
  FilePath  := Ctx.Params.Get('file', '');
  StartLine := Ctx.Params.Get('start_line', 0);
  EndLine   := Ctx.Params.Get('end_line', 0);
  AutoSave  := Ctx.Params.Get('auto_save', False);
  if FilePath = '' then
  begin
    Ctx.Error := True; Ctx.Result := 'file required'; Exit;
  end;
  Ext := LowerCase(ExtractFileExt(FilePath));
  Ok := False;
  for I := Low(Allowed) to High(Allowed) do
    if Ext = Allowed[I] then Ok := True;
  if not Ok then
  begin
    Ctx.Error := True;
    Ctx.Result := 'Not a Pascal source (.pas, .pp, .lpr, .dpr, .inc): ' + FilePath;
    Exit;
  end;
  IsInc := Ext = '.inc';
  if (StartLine <> 0) or (EndLine <> 0) then
  begin
    if IsInc then
    begin
      Ctx.Error := True;
      Ctx.Result := 'An include file is formatted whole: omit start_line and end_line';
      Exit;
    end;
    if (StartLine < 1) or (EndLine < StartLine) then
    begin
      Ctx.Error := True;
      Ctx.Result := 'start_line and end_line must both be given, 1 <= start_line <= end_line';
      Exit;
    end;
  end;
  Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(FilePath);
  if Ed = nil then
  begin
    { opening a missing file shows the IDE's modal "File not found" }
    if not FileExists(FilePath) then
    begin
      Ctx.Error := True; Ctx.Result := 'File not found: ' + FilePath; Exit;
    end;
    if LazarusIDE.DoOpenEditorFile(FilePath, -1, -1,
         [ofOnlyIfExists, ofRegularFile, ofDoNotActivateSourceEditor]) <> mrOK then
    begin
      Ctx.Error := True; Ctx.Result := 'Could not open: ' + FilePath; Exit;
    end;
    Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(FilePath);
  end;
  if Ed.ReadOnly then
  begin
    Ctx.Error := True; Ctx.Result := 'The editor is read-only: ' + FilePath; Exit;
  end;
  if EndLine > Ed.Lines.Count then
  begin
    Ctx.Error := True;
    Ctx.Result := Format('end_line %d is past the end of the file (%d lines)',
                         [EndLine, Ed.Lines.Count]);
    Exit;
  end;

  Src := Ed.GetText(False);
  Sink := TJcfSink.Create;
  Conv := TConverter.Create;
  A := TStringList.Create;
  B := TStringList.Create;
  { a parse tree window on error or always is a user setting for the menu
    commands; never here }
  OldTree := GetRegSettings.ShowParseTreeOption;
  try
    GetRegSettings.ShowParseTreeOption := eShowNever;
    Conv.InputCode     := Src;
    Conv.FileName      := FilePath;
    Conv.GuiMessages   := False;
    Conv.OnStatusMessage := @Sink.OnMessage;
    Conv.OnIncludeFile := @Sink.OnIncludeFile;
    if IsInc then
      Conv.ConvertUsingFakeUnit
    else if StartLine > 0 then
    begin
      StartIdx := LineStartIndex(Src, StartLine);
      EndIdx := LineStartIndex(Src, EndLine + 1) - 1;
      if EndIdx > Length(Src) then EndIdx := Length(Src);
      if EndIdx < StartIdx then EndIdx := StartIdx;
      { only the formatted lines, as the IDE's Format Selection does: with
        the whole text JCF's splice keeps the closing brace of its end marker }
      Conv.ConvertPart(StartIdx, EndIdx, True);
    end
    else
      Conv.Convert;
    if Conv.ConvertError then
    begin
      Ctx.Error := True;
      if Sink.Errors <> '' then
        Ctx.Result := 'JEDI Code Format could not format it: ' + Sink.Errors
      else
        Ctx.Result := 'JEDI Code Format could not format it';
      Exit;
    end;
    A.Assign(Ed.Lines);
    if StartLine > 0 then
    begin
      Part := TStringList.Create;
      try
        Part.Text := TrimRight(Conv.OutputCode);
        for I := 0 to StartLine - 2 do B.Add(A[I]);
        B.AddStrings(Part);
        for I := EndLine to A.Count - 1 do B.Add(A[I]);
      finally
        Part.Free;
      end;
    end
    else
      B.Text := Conv.OutputCode;
    Hunks := ComputeLineHunks(A, B);
    if Length(Hunks) > 0 then
    begin
      ApplyLineHunks(Ed, A, B, Hunks);
      { the editor must now hold JCF's output exactly; if not, put the
        original back the same way and say so }
      Part := TStringList.Create;
      try
        Part.Assign(Ed.Lines);
        if not Part.Equals(B) then
        begin
          ApplyLineHunks(Ed, Part, A, ComputeLineHunks(Part, A));
          Ctx.Error := True;
          Ctx.Result := 'Internal error: the formatted text did not apply cleanly; ' +
                        'the editor was put back as it was';
          Exit;
        end;
      finally
        Part.Free;
      end;
    end;
    if AutoSave and (Length(Hunks) > 0) then
      LazarusIDE.DoSaveEditorFile(FilePath, []);
    Obj := TJSONObject.Create;
    try
      Obj.Add('file', FilePath);
      Obj.Add('changed', Length(Hunks) > 0);
      Obj.Add('changes', LineHunksJSON(A, B, Hunks));
      if Sink.Messages.Count > 0 then
      begin
        Obj.Add('messages', Sink.Messages);
        Sink.Messages := nil;
      end;
      Obj.Add('saved', AutoSave and (Length(Hunks) > 0));
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  finally
    GetRegSettings.ShowParseTreeOption := OldTree;
    A.Free;
    B.Free;
    Conv.Free;
    Sink.Messages.Free;
    Sink.Free;
  end;
end;

function DispatchFormatTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
begin
  Result := Name = 'code_format';
  if Result then DoFormat(Ctx);
end;

procedure RegisterFormatSchemas(Tools: TJSONArray);
begin
  Tools.Add(MakeTool('code_format',
    'Format a Pascal file, or the lines start_line..end_line, with JEDI Code ' +
    'Format, using the settings in Tools > Options > JEDI Code Format (what ' +
    'Source > JEDI Code Format does, without its dialogs). Only the lines that ' +
    'change are replaced, in one undo step (Ctrl+Z works). Returns the changed ' +
    'lines as hunks (past 64 KB of text the rest is counted in a last ' +
    'omitted_hunks entry: read the file) and JCF''s warnings. JCF can wrap long ' +
    'lines differently on a second run. Code JCF cannot parse is an error and ' +
    'nothing changes. Use auto_save=true or editor_save to persist to disk.',
    SCHEMA_FORMAT, MCP_ANN_WRITE));
end;

initialization
  RegisterMcpGroup(@DispatchFormatTool);
  RegisterMcpSchemas(@RegisterFormatSchemas);

end.
