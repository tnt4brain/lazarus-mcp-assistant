{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TCodeComplete;

{ TTestCodeComplete — code_complete (the IDE's Ctrl+Shift+C) against the
  running IDE.  Each test works on a copy of tests/fixtures/fixturecomplete.pas
  in a temp folder, not open in the IDE before; the copy is reverted, closed
  and deleted afterwards.
  Requires a running MCP server. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, THttpHelper;

type
  TTestCodeComplete = class(TTestCase)
  private
    FDir  : string;
    FUnit : string;
    function Complete(ALine, ACol: Integer; const AExtra: string = ''): string;
    function Disk: string;
    function Buffer: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestClass;
    procedure TestLocalVariable;
    procedure TestForwardProcedure;
    procedure TestNothingToComplete;
    procedure TestAutoSave;
    procedure TestUnsavedEdits;
    procedure TestLargeUnit;
    procedure TestIncludeCreatedLater;
  end;

implementation

uses
  Classes, SysUtils, FileUtil, fpjson, jsonparser;

const
  { positions in fixturecomplete.pas }
  LineProperty = 16;  { property Size: Integer read FSize write SetSize; }
  LineForward  = 20;  { procedure ForwardOnly(const S: string); }
  LineCounter  = 26;  {   Counter := 5; }

function IsError(const T: string): Boolean;
begin
  Result := (Pos('TOOL ERROR', T) = 1) or (Pos('RPC ERROR', T) = 1) or (Pos('HTTP ', T) = 1);
end;

procedure TTestCodeComplete.SetUp;
begin
  { a folder per test: the IDE caches files by name }
  FDir  := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'mcpcodecomplete' + PathDelim +
           TestName + PathDelim;
  FUnit := FDir + 'fixturecomplete.pas';
  ForceDirectories(FDir);
  CopyFile(ExtractFilePath(ExpandFileName(ParamStr(0))) + 'fixtures' + PathDelim +
           'fixturecomplete.pas', FUnit);
end;

procedure TTestCodeComplete.TearDown;
begin
  CallToolText('editor_revert', '{"file":' + JsonStr(FUnit) + '}', []);
  CallToolText('editor_close', '{"file":' + JsonStr(FUnit) + '}', []);
  DeleteDirectory(FDir, False);
  RemoveDir(ExcludeTrailingPathDelimiter(ExtractFileDir(ExcludeTrailingPathDelimiter(FDir))));
end;

function TTestCodeComplete.Complete(ALine, ACol: Integer; const AExtra: string): string;
begin
  Result := CallToolText('code_complete', '{"file":' + JsonStr(FUnit) +
    ',"line":' + IntToStr(ALine) + ',"col":' + IntToStr(ACol) + AExtra + '}', []);
end;

function TTestCodeComplete.Disk: string;
var
  SL : TStringList;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(FUnit);
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

{ The editor's text, unsaved changes included. }
function TTestCodeComplete.Buffer: string;
var
  T : string;
  J : TJSONData;
begin
  T := CallToolText('editor_read_file', '{"path":' + JsonStr(FUnit) + '}', []);
  J := GetJSON(T);
  try
    Result := TJSONObject(J).Get('content', '');
    if TJSONObject(J).Get('source', '') <> 'editor' then
      Result := 'not from the editor: ' + T;
  finally
    J.Free;
  end;
end;

procedure TTestCodeComplete.TestClass;
var
  Before, T, Added, AllAdded : string;
  J      : TJSONData;
  Hunks  : TJSONArray;
  I      : Integer;
begin
  Before := Disk;
  T := Complete(LineProperty, 10);
  CheckFalse(IsError(T), T);
  J := GetJSON(T);
  try
    Hunks := TJSONObject(J).Arrays['changes'];
    CheckTrue(Hunks.Count >= 2, 'the class and the bodies are separate hunks: ' + T);
    AllAdded := '';
    for I := 0 to Hunks.Count - 1 do
    begin
      Added := TJSONObject(Hunks[I]).Get('added', '');
      AllAdded := AllAdded + Added;
      { moved down past the unchanged lines: the bodies end with their own
        end; and do not start with the one before them }
      if Pos('TCompleteMe.NoBodyYet', Added) > 0 then
        CheckFalse(Pos('end;', TrimLeft(Added)) = 1, 'hunk aligned: ' + Added);
    end;
    CheckTrue(Pos('FSize: Integer;', AllAdded) > 0, 'field: ' + T);
    CheckTrue(Pos('procedure SetSize(AValue: Integer);', AllAdded) > 0, 'setter declared: ' + T);
    CheckTrue(Pos('procedure TCompleteMe.SetSize(AValue: Integer);', AllAdded) > 0, 'setter body: ' + T);
    CheckTrue(Pos('procedure TCompleteMe.NoBodyYet(A: Integer);', AllAdded) > 0, 'method body: ' + T);
    CheckNotNull(TJSONObject(J).Find('new_position'), 'jump target: ' + T);
    CheckFalse(TJSONObject(J).Get('saved', True), 'not saved: ' + T);
  finally
    J.Free;
  end;
  CheckTrue(Pos('procedure TCompleteMe.NoBodyYet(A: Integer);', Buffer) > 0, 'in the editor');
  CheckEquals(Before, Disk, 'not on disk');
end;

procedure TTestCodeComplete.TestLocalVariable;
var
  T : string;
begin
  T := Complete(LineCounter, 4);
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('Counter: Integer;', T) > 0, 'local variable: ' + T);
  CheckTrue(Pos('var' + LineEnding + '  Counter: Integer;', AdjustLineBreaks(Buffer)) > 0,
    'declared in the procedure');
end;

procedure TTestCodeComplete.TestForwardProcedure;
var
  T : string;
begin
  T := Complete(LineForward, 12);
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('procedure ForwardOnly(const S: string);' + LineEnding + 'begin',
    AdjustLineBreaks(Buffer)) > 0, 'body added: ' + T);
end;

procedure TTestCodeComplete.TestNothingToComplete;
var
  Before, T : string;
begin
  Before := Disk;
  T := Complete(1, 1);
  CheckTrue(Pos('Nothing to complete at 1:1', T) > 0, 'nothing: ' + T);
  T := Complete(999, 1);
  CheckTrue(Pos('past the end', T) > 0, 'past the end: ' + T);
  { an error, not the IDE's modal "File not found" }
  T := CallToolText('code_complete', '{"file":' + JsonStr(FDir + 'missing.pas') +
    ',"line":1,"col":1}', []);
  CheckTrue(Pos('File not found', T) > 0, 'missing file: ' + T);
  CheckEquals(AdjustLineBreaks(Before), AdjustLineBreaks(Buffer), 'buffer unchanged');
end;

procedure TTestCodeComplete.TestAutoSave;
var
  T : string;
begin
  T := Complete(LineCounter, 4, ',"auto_save":true');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"saved" : true', T) > 0, 'saved: ' + T);
  CheckTrue(Pos('Counter: Integer;', Disk) > 0, 'on disk');
end;

{ The usual sequence: a declaration added in the editor, not saved, then
  completed.  The completion must see the editor's text and leave the disk. }
procedure TTestCodeComplete.TestUnsavedEdits;
var
  T : string;
begin
  T := CallToolText('code_add_to_class', '{"file":' + JsonStr(FUnit) +
    ',"class_name":"TCompleteMe","text":"    procedure Added;"}', []);
  CheckFalse(IsError(T), T);
  T := Complete(LineProperty, 10);
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('procedure TCompleteMe.Added;', Buffer) > 0, 'body of the unsaved declaration: ' + T);
  CheckEquals(0, Pos('Added', Disk), 'nothing saved');
end;

{ A class with 600 methods and one new declaration: the declaration's part
  and the new body, 5000 lines apart, are two hunks, not one span. }
procedure TTestCodeComplete.TestLargeUnit;
var
  SL : TStringList;
  I  : Integer;
  T  : string;
  J  : TJSONData;
begin
  SL := TStringList.Create;
  try
    SL.Add('unit FixtureComplete;');
    SL.Add('{$mode objfpc}{$H+}');
    SL.Add('interface');
    SL.Add('type');
    SL.Add('  TBig = class');
    SL.Add('  public');
    for I := 1 to 600 do SL.Add(Format('    procedure M%d(A: Integer);', [I]));
    SL.Add('    procedure Missing(const S: string);');
    SL.Add('  end;');
    SL.Add('implementation');
    for I := 1 to 600 do
    begin
      SL.Add(Format('procedure TBig.M%d(A: Integer);', [I]));
      SL.Add('var');
      SL.Add('  X: Integer;');
      SL.Add('begin');
      SL.Add(Format('  X := A + %d;', [I]));
      SL.Add('  if X > 0 then');
      SL.Add('    X := 0;');
      SL.Add('end;');
      SL.Add('');
    end;
    SL.Add('end.');
    SL.SaveToFile(FUnit);
  finally
    SL.Free;
  end;
  T := Complete(7, 5);
  CheckFalse(IsError(T), T);
  J := GetJSON(T);
  try
    CheckTrue(TJSONObject(J).Arrays['changes'].Count <= 2, 'separate hunks: ' + T);
    CheckTrue(Pos('procedure TBig.Missing(const S: string);', T) > 0, 'body: ' + T);
    CheckEquals(0, Pos('X := A + 300', T), 'unchanged lines not reported: ' + Copy(T, 1, 500));
  finally
    J.Free;
  end;
end;

{ An include file created after CodeTools looked at its folder, as the
  assistant's shell creates them while the IDE is in the background: the
  IDE's caches still say it is missing until the tool renews them. }
procedure TTestCodeComplete.TestIncludeCreatedLater;
var
  SL : TStringList;
  T  : string;
begin
  SL := TStringList.Create;
  try
    SL.Text := 'unit FixtureComplete;' + LineEnding + '{$mode objfpc}{$H+}' + LineEnding +
      'interface' + LineEnding + 'implementation' + LineEnding +
      '{$I fixturelate.inc}' + LineEnding + 'procedure UsesALocal;' + LineEnding +
      'begin' + LineEnding + '  Counter := 5;' + LineEnding + 'end;' + LineEnding + 'end.';
    SL.SaveToFile(FUnit);
    T := Complete(8, 4);
    CheckTrue(Pos('include file not found', T) > 0, 'missing at first: ' + T);
    SL.Text := '// created later';
    SL.SaveToFile(FDir + 'fixturelate.inc');
  finally
    SL.Free;
  end;
  T := Complete(8, 4);
  CheckFalse(IsError(T), 'found once created: ' + T);
  CheckTrue(Pos('Counter: Integer;', T) > 0, 'completed: ' + T);
end;

end.
