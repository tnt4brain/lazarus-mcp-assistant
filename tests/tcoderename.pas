{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TCodeRename;

{ TTestCodeRename — code_rename_identifier against the running IDE.  Each
  test writes two units to a temp folder, not open in the IDE before:
  RenameA declares TFoo, RenameB uses it.  Neither is a project file, so a rename
  searches only the file it starts in and the declaring one: tests that
  rename both start in RenameB.  Both are reverted, closed and
  deleted afterwards.
  Requires a running MCP server. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, THttpHelper;

type
  TTestCodeRename = class(TTestCase)
  private
    FDir   : string;
    FUnitA : string;
    FUnitB : string;
    function Rename(const AFile: string; ALine, ACol: Integer;
      const AExtra: string): string;
    function Disk(const AFile: string): string;
    function Buffer(const AFile: string): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestDryRun;
    procedure TestRenameInEditors;
    procedure TestUnsavedEdits;
    procedure TestAutoSave;
    procedure TestRefusals;
  end;

implementation

uses
  Classes, SysUtils, FileUtil, fpjson, jsonparser;

const
  { positions in RenameB }
  LineVar    = 9;   {   F: TFoo; }
  ColVar     = 6;
  LineCreate = 11;  {   F := TFoo.Create; }
  ColCreate  = 8;

function IsError(const T: string): Boolean;
begin
  Result := (Pos('TOOL ERROR', T) = 1) or (Pos('RPC ERROR', T) = 1) or (Pos('HTTP ', T) = 1);
end;

procedure WriteText(const AFile, AText: string);
var
  SL : TStringList;
begin
  SL := TStringList.Create;
  try
    SL.Text := AText;
    SL.SaveToFile(AFile);
  finally
    SL.Free;
  end;
end;

procedure TTestCodeRename.SetUp;
begin
  { a folder per test: the IDE caches files by name }
  FDir   := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'mcpcoderename' + PathDelim +
            TestName + PathDelim;
  FUnitA := FDir + 'renamea.pas';
  FUnitB := FDir + 'renameb.pas';
  ForceDirectories(FDir);
  WriteText(FUnitA,
    'unit RenameA;' + LineEnding +
    '{$mode objfpc}{$H+}' + LineEnding +
    'interface' + LineEnding +
    'type' + LineEnding +
    '  TFoo = class' + LineEnding +
    '    procedure Run;' + LineEnding +
    '  end;' + LineEnding +
    'implementation' + LineEnding +
    'procedure TFoo.Run;' + LineEnding +
    'begin' + LineEnding +
    'end;' + LineEnding +
    'end.');
  WriteText(FUnitB,
    'unit RenameB;' + LineEnding +
    '{$mode objfpc}{$H+}' + LineEnding +
    'interface' + LineEnding +
    'uses RenameA;' + LineEnding +
    'procedure Go;' + LineEnding +
    'implementation' + LineEnding +
    'procedure Go;' + LineEnding +
    'var' + LineEnding +
    '  F: TFoo;' + LineEnding +
    'begin' + LineEnding +
    '  F := TFoo.Create;' + LineEnding +
    '  F.Run;' + LineEnding +
    '  F.Free;' + LineEnding +
    'end;' + LineEnding +
    'end.');
end;

procedure TTestCodeRename.TearDown;
var
  F : string;
begin
  for F in [FUnitA, FUnitB] do
  begin
    CallToolText('editor_revert', '{"file":' + JsonStr(F) + '}', []);
    CallToolText('editor_close', '{"file":' + JsonStr(F) + '}', []);
  end;
  DeleteDirectory(FDir, False);
  RemoveDir(ExcludeTrailingPathDelimiter(ExtractFileDir(ExcludeTrailingPathDelimiter(FDir))));
end;

function TTestCodeRename.Rename(const AFile: string; ALine, ACol: Integer;
  const AExtra: string): string;
begin
  Result := CallToolText('code_rename_identifier', '{"file":' + JsonStr(AFile) +
    ',"line":' + IntToStr(ALine) + ',"col":' + IntToStr(ACol) + AExtra + '}', []);
end;

function TTestCodeRename.Disk(const AFile: string): string;
var
  SL : TStringList;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(AFile);
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

{ The editor's text, unsaved changes included. }
function TTestCodeRename.Buffer(const AFile: string): string;
var
  T : string;
  J : TJSONData;
begin
  T := CallToolText('editor_read_file', '{"file":' + JsonStr(AFile) + '}', []);
  J := GetJSON(T);
  try
    Result := TJSONObject(J).Get('content', '');
    if TJSONObject(J).Get('source', '') <> 'editor' then
      Result := 'not from the editor: ' + T;
  finally
    J.Free;
  end;
end;

{ From a reference in RenameB: the declaration in RenameA is found, all four
  references are listed with their text, and nothing changes or opens. }
procedure TTestCodeRename.TestDryRun;
var
  T    : string;
  J    : TJSONData;
  Refs : TJSONArray;
  I, InA : Integer;
begin
  T := Rename(FUnitB, LineCreate, ColCreate, ',"dry_run":true');
  CheckFalse(IsError(T), T);
  J := GetJSON(T);
  try
    CheckEquals('TFoo', TJSONObject(J).Get('identifier', ''), T);
    Refs := TJSONObject(J).Arrays['references'];
    CheckEquals(4, Refs.Count, 'references: ' + T);
    InA := 0;
    for I := 0 to Refs.Count - 1 do
    begin
      CheckTrue(Pos('TFoo', TJSONObject(Refs[I]).Get('line_text', '')) > 0, 'line text: ' + T);
      if SameFileName(TJSONObject(Refs[I]).Get('file', ''), FUnitA) then Inc(InA);
    end;
    CheckEquals(2, InA, 'two in the declaring unit: ' + T);
    CheckNull(TJSONObject(J).Find('renamed_to'), 'not renamed: ' + T);
  finally
    J.Free;
  end;
  T := CallToolText('editor_list_open', '{}', []);
  CheckEquals(0, Pos('renamea.pas', LowerCase(T)), 'nothing opened: ' + T);
  CheckEquals(0, Pos('renameb.pas', LowerCase(T)), 'nothing opened: ' + T);
end;

{ The rename lands in editors, unsaved; files not open before are opened. }
procedure TTestCodeRename.TestRenameInEditors;
var
  DiskA, DiskB, T : string;
  J : TJSONData;
begin
  DiskA := Disk(FUnitA);
  DiskB := Disk(FUnitB);
  T := Rename(FUnitB, LineVar, ColVar, ',"new_name":"TBar"');
  CheckFalse(IsError(T), T);
  J := GetJSON(T);
  try
    CheckEquals('TBar', TJSONObject(J).Get('renamed_to', ''), T);
    CheckEquals(2, TJSONObject(J).Arrays['files_changed'].Count, 'both changed: ' + T);
    CheckEquals(2, TJSONObject(J).Arrays['files_opened'].Count, 'both opened: ' + T);
    CheckFalse(TJSONObject(J).Get('saved', True), 'not saved: ' + T);
  finally
    J.Free;
  end;
  T := Buffer(FUnitA);
  CheckTrue(Pos('TBar = class', T) > 0, 'declaration renamed: ' + T);
  CheckTrue(Pos('procedure TBar.Run;', T) > 0, 'method renamed: ' + T);
  CheckEquals(0, Pos('TFoo', T), 'none left in A: ' + T);
  T := Buffer(FUnitB);
  CheckTrue(Pos('F := TBar.Create;', T) > 0, 'use renamed: ' + T);
  CheckEquals(0, Pos('TFoo', T), 'none left in B: ' + T);
  CheckEquals(DiskA, Disk(FUnitA), 'A not on disk');
  CheckEquals(DiskB, Disk(FUnitB), 'B not on disk');
end;

{ An unsaved new use of TFoo in the editor is renamed too, and nothing is
  saved on the way (the tool used to save every editor first). }
procedure TTestCodeRename.TestUnsavedEdits;
var
  DiskB, T : string;
begin
  DiskB := Disk(FUnitB);
  T := CallToolText('editor_edit_text', '{"file":' + JsonStr(FUnitB) +
    ',"old_string":"  F.Free;","new_string":"  F.Free;\n  F := TFoo(nil);"}', []);
  CheckFalse(IsError(T), T);
  T := Rename(FUnitB, LineVar, ColVar, ',"new_name":"TBar"');
  CheckFalse(IsError(T), T);
  T := Buffer(FUnitB);
  CheckTrue(Pos('F := TBar(nil);', T) > 0, 'unsaved use renamed: ' + T);
  CheckEquals(0, Pos('TFoo', T), 'none left: ' + T);
  CheckEquals(DiskB, Disk(FUnitB), 'nothing saved');
end;

procedure TTestCodeRename.TestAutoSave;
var
  T : string;
begin
  T := Rename(FUnitB, LineVar, ColVar, ',"new_name":"TBar","auto_save":true');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"saved" : true', T) > 0, 'saved: ' + T);
  CheckTrue(Pos('TBar = class', Disk(FUnitA)) > 0, 'A on disk');
  CheckTrue(Pos('F := TBar.Create;', Disk(FUnitB)) > 0, 'B on disk');
end;

procedure TTestCodeRename.TestRefusals;
var
  DiskA, T : string;
begin
  DiskA := Disk(FUnitA);
  T := Rename(FUnitB, 4, 7, ',"new_name":"RenameC"');
  CheckTrue(Pos('unit name', T) > 0, 'unit name: ' + T);
  T := Rename(FUnitA, 5, 3, ',"new_name":"1Bad"');
  CheckTrue(Pos('must be a Pascal identifier', T) > 0, 'invalid name: ' + T);
  T := Rename(FUnitA, 5, 3, '');
  CheckTrue(Pos('must be a Pascal identifier', T) > 0, 'no name: ' + T);
  T := Rename(FUnitA, 5, 3, ',"new_name":"TFoo"');
  CheckTrue(Pos('already named', T) > 0, 'same name: ' + T);
  CheckEquals(DiskA, Disk(FUnitA), 'unchanged');
end;

end.
