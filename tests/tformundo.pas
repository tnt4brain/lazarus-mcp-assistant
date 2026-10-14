{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TFormUndo;

{ TTestFormUndo — form_undo / form_redo and what the form_* tools record in
  the designer's undo list (ADR-014), against the running IDE.  Each test
  works on a copy of tests/fixtures/fixtureform.* in a temp folder; the copy
  is reverted, closed and deleted afterwards.
  Requires a running MCP server. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, THttpHelper;

type
  TTestFormUndo = class(TTestCase)
  private
    FDir  : string;
    FUnit : string;
    function Call(const ATool, AExtra: string): string;
    function Lfm(const AComp: string = ''): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestNothingToUndo;
    procedure TestPropertiesAreOneStep;
    procedure TestAddAndDelete;
    procedure TestSnapshotKeepsReferences;
    procedure TestSnapshotNestedControl;
    procedure TestSnapshotWithRename;
    procedure TestAnchorSideKept;
    procedure TestAnchorSideSet;
    procedure TestCreateEventHandler;
    procedure TestMenu;
    procedure TestFormItselfNotUndoable;
  end;

implementation

uses
  Classes, SysUtils, FileUtil;

function IsError(const T: string): Boolean;
begin
  Result := (Pos('TOOL ERROR', T) = 1) or (Pos('RPC ERROR', T) = 1) or (Pos('HTTP ', T) = 1);
end;

procedure TTestFormUndo.SetUp;
var
  Src : string;
begin
  Src   := ExtractFilePath(ExpandFileName(ParamStr(0))) + 'fixtures' + PathDelim;
  { a folder per test: the IDE caches files by name, and a copy reused under
    the same path could be read from its cache }
  FDir  := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'mcpformundo' + PathDelim +
           TestName + PathDelim;
  FUnit := FDir + 'fixtureform.pas';
  ForceDirectories(FDir);
  CopyFile(Src + 'fixtureform.pas', FUnit);
  CopyFile(Src + 'fixtureform.lfm', FDir + 'fixtureform.lfm');
end;

procedure TTestFormUndo.TearDown;
begin
  CallToolText('editor_revert', '{"file_path":' + JsonStr(FUnit) + '}', []);
  CallToolText('editor_close', '{"file":' + JsonStr(FUnit) + '}', []);
  DeleteDirectory(FDir, False);
  RemoveDir(ExcludeTrailingPathDelimiter(ExtractFileDir(ExcludeTrailingPathDelimiter(FDir))));
end;

function TTestFormUndo.Call(const ATool, AExtra: string): string;
begin
  Result := CallToolText(ATool, '{"form_file":' + JsonStr(FUnit) + AExtra + '}', []);
end;

function TTestFormUndo.Lfm(const AComp: string): string;
begin
  if AComp = '' then
    Result := Call('form_get_lfm', '')
  else
    Result := Call('form_get_lfm', ',"component_name":' + JsonStr(AComp));
  CheckFalse(IsError(Result), Result);
end;

procedure TTestFormUndo.TestNothingToUndo;
var
  T : string;
begin
  T := Call('form_undo', '');
  CheckTrue(IsError(T), 'a fresh form has nothing to undo: ' + T);
  CheckTrue(Pos('nothing to undo', T) > 0, T);
  CheckTrue(Pos('"can_redo" : false', T) > 0, T);
end;

procedure TTestFormUndo.TestPropertiesAreOneStep;
var
  T : string;
begin
  T := Call('form_set_properties', ',"component_name":"btnOK","properties":' +
            '{"Caption":"Go","Left":20,"Visible":false,"Name":"btnGo"}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"undoable" : true', T) > 0, T);
  T := Call('form_undo', '');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"can_undo" : false', T) > 0, 'one call is one step: ' + T);
  T := Lfm;
  CheckTrue(Pos('object btnOK: TButton', T) > 0, 'renamed back: ' + T);
  CheckTrue(Pos('Caption = ''OK''', T) > 0, T);
  CheckTrue(Pos('Left = 8', T) > 0, T);
  CheckEquals(0, Pos('Visible = False', T), T);
  CheckTrue(Pos('OnClick = btnOKClick', T) > 0, 'handler renamed back: ' + T);
  T := Call('form_redo', '');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('object btnGo: TButton', Lfm) > 0, 'redone');
end;

procedure TTestFormUndo.TestAddAndDelete;
var
  T : string;
begin
  T := Call('form_add_component', ',"class_name":"TLabel","name":"lblX","properties":{"Caption":"X"}');
  CheckFalse(IsError(T), T);
  Call('form_undo', '');
  CheckEquals(0, Pos('lblX', Lfm), 'add undone');
  Call('form_redo', '');
  CheckTrue(Pos('Caption = ''X''', Lfm('lblX')) > 0, 'add redone with its properties');

  T := Call('form_delete_component', ',"component_name":"btnOK"');
  CheckFalse(IsError(T), T);
  T := Call('form_undo', '');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('OnClick = btnOKClick', Lfm('btnOK')) > 0, 'delete undone, event kept');
end;

procedure TTestFormUndo.TestSnapshotKeepsReferences;
var
  T : string;
begin
  T := Call('form_add_component', ',"class_name":"TLabel","name":"lblRef",' +
            '"properties":{"FocusControl":"btnOK"}');
  CheckFalse(IsError(T), T);
  { Font.Color cannot be undone entry by entry: btnOK is replaced as a whole }
  T := Call('form_set_properties', ',"component_name":"btnOK","properties":' +
            '{"Font.Color":"clRed","Caption":"Go"}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"undoable" : true', T) > 0, T);
  T := Call('form_undo', '');
  CheckFalse(IsError(T), T);
  T := Lfm('btnOK');
  CheckEquals(0, Pos('Font.Color', T), 'Font.Color undone: ' + T);
  CheckTrue(Pos('Caption = ''OK''', T) > 0, T);
  CheckTrue(Pos('TabOrder = 0', T) > 0, 'back in its place: ' + T);
  CheckTrue(Pos('FocusControl = btnOK', Lfm('lblRef')) > 0,
            'the label''s reference to the replaced button is back');
end;

procedure TTestFormUndo.TestSnapshotNestedControl;
var
  T : string;
begin
  Call('form_add_component', ',"class_name":"TPanel","name":"pnlA","left":90,"top":8,"width":140,"height":100');
  Call('form_add_component', ',"class_name":"TPanel","name":"pnlB","parent_name":"pnlA","left":4,"top":4,"width":120,"height":80');
  T := Call('form_add_component', ',"class_name":"TButton","name":"btnIn","parent_name":"pnlB","left":6,"top":5');
  CheckFalse(IsError(T), T);
  T := Call('form_set_properties', ',"component_name":"btnIn","properties":{"Font.Color":"clRed"}');
  CheckTrue(Pos('"undoable" : true', T) > 0, T);
  T := Call('form_undo', '');
  CheckFalse(IsError(T), T);
  T := Call('form_list_components', '');
  CheckTrue(Pos('"name" : "btnIn", "class" : "TButton", "parent" : "pnlB", "left" : 6, "top" : 5', T) > 0,
            'back in its panel, at its place: ' + T);
end;

procedure TTestFormUndo.TestSnapshotWithRename;
var
  T : string;
begin
  Call('form_add_component', ',"class_name":"TLabel","name":"lblRef","properties":{"FocusControl":"btnOK"}');
  T := Call('form_set_properties', ',"component_name":"btnOK","properties":' +
            '{"Font.Color":"clRed","Name":"btnGo"}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"component_name_now" : "btnGo"', T) > 0, T);
  T := Call('form_undo', '');
  CheckFalse(IsError(T), T);
  T := Lfm('btnOK');
  CheckTrue(Pos('OnClick = btnOKClick', T) > 0, 'name and handler back: ' + T);
  CheckEquals(0, Pos('Font.Color', T), T);
  CheckTrue(Pos('FocusControl = btnOK', Lfm('lblRef')) > 0, 'reference kept');
  T := Call('form_redo', '');
  CheckFalse(IsError(T), T);
  T := Lfm('btnGo');
  CheckTrue(Pos('Font.Color = clRed', T) > 0, 'redone: ' + T);
  CheckTrue(Pos('OnClick = btnGoClick', T) > 0, T);
  CheckTrue(Pos('FocusControl = btnGo', Lfm('lblRef')) > 0, 'reference follows');
end;

procedure TTestFormUndo.TestAnchorSideKept;
{ AnchorSide* cannot be set with form_set_properties (the IDE hides it from
  property editors), so the label is written into the copy before it opens. }
var
  SL : TStringList;
  T  : string;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(FDir + 'fixtureform.lfm');
    SL.Insert(SL.Count - 1, '  object lblAnch: TLabel');
    SL.Insert(SL.Count - 1, '    AnchorSideTop.Control = btnOK');
    SL.Insert(SL.Count - 1, '    AnchorSideTop.Side = asrBottom');
    SL.Insert(SL.Count - 1, '    Left = 8');
    SL.Insert(SL.Count - 1, '    Height = 15');
    SL.Insert(SL.Count - 1, '    Top = 33');
    SL.Insert(SL.Count - 1, '    Width = 40');
    SL.Insert(SL.Count - 1, '    Caption = ''anch''');
    SL.Insert(SL.Count - 1, '  end');
    SL.SaveToFile(FDir + 'fixtureform.lfm');
    SL.LoadFromFile(FUnit);
    SL.Text := StringReplace(SL.Text, '    btnOK: TButton;',
      '    btnOK: TButton;' + LineEnding + '    lblAnch: TLabel;', []);
    SL.SaveToFile(FUnit);
  finally
    SL.Free;
  end;
  CheckTrue(Pos('AnchorSideTop.Control = btnOK', Lfm('lblAnch')) > 0, 'seeded');
  T := Call('form_delete_component', ',"component_name":"btnOK"');
  CheckFalse(IsError(T), T);
  CheckEquals(0, Pos('AnchorSideTop.Control', Lfm('lblAnch')), 'cleared by the delete');
  T := Call('form_undo', '');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('AnchorSideTop.Control = btnOK', Lfm('lblAnch')) > 0, 'anchor back');
end;

procedure TTestFormUndo.TestAnchorSideSet;
{ Regression: AnchorSide* is hidden from the Object Inspector's editors, and
  form_set_properties answered "property not found: AnchorSideTop". }
var
  T : string;
begin
  Call('form_add_component', ',"class_name":"TLabel","name":"lblB","left":8,"top":60');
  T := Call('form_set_properties', ',"component_name":"lblB","properties":' +
            '{"AnchorSideTop.Control":"btnOK","AnchorSideTop.Side":"asrBottom","BorderSpacing.Top":6}');
  CheckFalse(IsError(T), T);
  CheckEquals(0, Pos('"error"', T), T);
  CheckTrue(Pos('"undoable" : true', T) > 0, T);
  T := Lfm('lblB');
  CheckTrue(Pos('AnchorSideTop.Control = btnOK', T) > 0, T);
  CheckTrue(Pos('AnchorSideTop.Side = asrBottom', T) > 0, T);
  T := Call('form_undo', '');
  CheckFalse(IsError(T), T);
  CheckEquals(0, Pos('AnchorSideTop', Lfm('lblB')), 'undone');
end;

procedure TTestFormUndo.TestCreateEventHandler;
{ Regression: it always failed with "Failed to create handler". }
var
  T : string;
begin
  T := Call('form_create_event_handler', ',"component_name":"btnOK","event_name":"OnEnter"');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"status" : "created"', T) > 0, T);
  CheckTrue(Pos('"handler_name" : "btnOKEnter"', T) > 0, T);
  CheckTrue(Pos('OnEnter = btnOKEnter', Lfm('btnOK')) > 0, 'assigned');
  T := CallToolText('editor_read_file', '{"path":' + JsonStr(FUnit) + '}', []);
  CheckTrue(Pos('procedure TFixtureForm.btnOKEnter(Sender: TObject);', T) > 0, 'stub in the source: ' + T);
  T := Call('form_create_event_handler', ',"component_name":"btnOK","event_name":"OnEnter"');
  CheckTrue(Pos('"status" : "existing"', T) > 0, 'second call shows it: ' + T);
  T := Call('form_undo', '');
  CheckFalse(IsError(T), T);
  CheckEquals(0, Pos('OnEnter', Lfm('btnOK')), 'undo unassigns the event');
end;

procedure TTestFormUndo.TestMenu;
var
  T : string;
begin
  Call('form_add_component', ',"class_name":"TMainMenu","name":"mm"');
  Call('form_add_menu_item', ',"parent_name":"mm","caption":"&File","name":"miFile"');
  T := Call('form_set_properties', ',"component_name":"FixtureForm","properties":{"Menu":"mm"}');
  CheckFalse(IsError(T), T);
  T := Call('form_add_menu_item', ',"parent_name":"miFile","caption":"&Open","name":"miOpen"');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"undoable" : true', T) > 0, T);
  T := Call('form_undo', '');
  CheckFalse(IsError(T), T);
  T := Lfm;
  CheckEquals(0, Pos('miOpen', T), 'menu item add undone: ' + T);
  CheckTrue(Pos('object miFile: TMenuItem', T) > 0, T);
  CheckTrue(Pos('Menu = mm', T) > 0, 'the form still shows the replaced menu: ' + T);
end;

procedure TTestFormUndo.TestFormItselfNotUndoable;
var
  T : string;
begin
  T := Call('form_set_properties', ',"component_name":"FixtureForm","properties":' +
            '{"Font.Color":"clBlue","Caption":"C"}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"undoable" : false', T) > 0, 'the form cannot be replaced: ' + T);
  T := Call('form_undo', '');
  CheckFalse(IsError(T), T);
  T := Lfm;
  CheckTrue(Pos('Caption = ''Fixture''', T) > 0, 'Caption undone: ' + T);
  CheckTrue(Pos('Font.Color = clBlue', T) > 0, 'Font.Color stays: ' + T);
end;

end.
