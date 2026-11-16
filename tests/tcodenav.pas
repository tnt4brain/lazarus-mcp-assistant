{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TCodeNav;

{ TTestCodeNav — code_find_descendants, code_find_overrides, code_unit_dependencies,
  code_find_unused and code_extract_method on a few files in a temp folder of their own.
  Requires a running MCP server. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, THttpHelper;

type
  TTestCodeNav = class(TTestCase)
  private
    FDir : string;
    function Call(const ATool, AArgs: string): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestDescendantsTree;
    procedure TestDescendantsDirectOnly;
    procedure TestInterfaceImplementers;
    procedure TestOverrides;
    procedure TestUnitUses;
    procedure TestUnused;
    procedure TestExtractDryRun;
    procedure TestExtract;
    procedure TestExtractBadName;
    procedure TestMoveUnitPlan;
    procedure TestMoveUnitCycle;
  end;

implementation

uses
  Classes, SysUtils, FileUtil;

const
  BaseUnit =
    'unit baseu;' + LineEnding +                          { 1 }
    '{$mode objfpc}{$H+}' + LineEnding +                  { 2 }
    'interface' + LineEnding +                            { 3 }
    'type' + LineEnding +                                 { 4 }
    '  IGreeter = interface' + LineEnding +               { 5 }
    '    procedure Greet;' + LineEnding +                 { 6 }
    '  end;' + LineEnding +                               { 7 }
    '  TBase = class' + LineEnding +                      { 8 }
    '  public' + LineEnding +                             { 9 }
    '    procedure Speak; virtual;' + LineEnding +        { 10 }
    '  end;' + LineEnding +                               { 11 }
    'implementation' + LineEnding +                       { 12 }
    'procedure TBase.Speak;' + LineEnding +               { 13 }
    'begin' + LineEnding +                                { 14 }
    'end;' + LineEnding +                                 { 15 }
    'end.' + LineEnding;

  KidsUnit =
    'unit kidsu;' + LineEnding +                          { 1 }
    '{$mode objfpc}{$H+}' + LineEnding +                  { 2 }
    'interface' + LineEnding +                            { 3 }
    'uses baseu;' + LineEnding +                          { 4 }
    'type' + LineEnding +                                 { 5 }
    '  TKid = class(TBase)' + LineEnding +                { 6 }
    '    procedure Speak; override;' + LineEnding +       { 7 }
    '  end;' + LineEnding +                               { 8 }
    '  TGrandKid = class(TKid)' + LineEnding +            { 9 }
    '    procedure Speak; override;' + LineEnding +       { 10 }
    '  end;' + LineEnding +                               { 11 }
    '  TThing = class(TObject, IGreeter)' + LineEnding +  { 12 }
    '    procedure Greet;' + LineEnding +                 { 13 }
    '  end;' + LineEnding +                               { 14 }
    'implementation' + LineEnding +                       { 15 }
    'procedure TKid.Speak; begin end;' + LineEnding +
    'procedure TGrandKid.Speak; begin end;' + LineEnding +
    'procedure TThing.Greet; begin end;' + LineEnding +
    'end.' + LineEnding;

  UnusedUnit =
    'unit unusedu;' + LineEnding +                        { 1 }
    '{$mode objfpc}{$H+}' + LineEnding +                  { 2 }
    'interface' + LineEnding +                            { 3 }
    'type' + LineEnding +                                 { 4 }
    '  TWorker = class' + LineEnding +                    { 5 }
    '  private' + LineEnding +                            { 6 }
    '    FUnusedField: Integer;' + LineEnding +           { 7 }
    '    procedure NeverCalled;' + LineEnding +           { 8 }
    '    procedure Helper;' + LineEnding +                { 9 }
    '  public' + LineEnding +                             { 10 }
    '    procedure Work;' + LineEnding +                  { 11 }
    '  end;' + LineEnding +                               { 12 }
    'implementation' + LineEnding +                       { 13 }
    'procedure TWorker.NeverCalled; begin end;' + LineEnding +
    'procedure TWorker.Helper; begin end;' + LineEnding +
    'procedure TWorker.Work; begin Helper; end;' + LineEnding +
    'end.' + LineEnding;

  ExtractUnit =
    'unit extractu;' + LineEnding +                       { 1 }
    '{$mode objfpc}{$H+}' + LineEnding +                  { 2 }
    'interface' + LineEnding +                            { 3 }
    'procedure Run;' + LineEnding +                       { 4 }
    'implementation' + LineEnding +                       { 5 }
    'procedure Run;' + LineEnding +                       { 6 }
    'var' + LineEnding +                                  { 7 }
    '  I: Integer;' + LineEnding +                        { 8 }
    'begin' + LineEnding +                                { 9 }
    '  I := 1;' + LineEnding +                            { 10 }
    '  I := I + 2;' + LineEnding +                        { 11 }
    '  WriteLn(I);' + LineEnding +                        { 12 }
    'end;' + LineEnding +                                 { 13 }
    'end.' + LineEnding;

function PkgText(const AName: string; const AUnits: array of string): string;
var
  I : Integer;
begin
  Result := '<?xml version="1.0" encoding="UTF-8"?>' + LineEnding +
    '<CONFIG><Package Version="5"><Name Value="' + AName + '"/>' +
    '<Type Value="RunAndDesignTime"/><Files Count="' + IntToStr(Length(AUnits)) + '">';
  for I := 0 to High(AUnits) do
    Result := Result + '<Item' + IntToStr(I + 1) + '><Filename Value="' + AUnits[I] + '.pas"/>' +
      '<IsPartOfPackage Value="True"/><UnitName Value="' + AUnits[I] + '"/></Item' + IntToStr(I + 1) + '>';
  Result := Result + '</Files><RequiredPkgs Count="1"><Item1><PackageName Value="FCL"/></Item1></RequiredPkgs>' +
    '<UsageOptions><UnitPath Value="$(PkgOutDir)"/></UsageOptions>' +
    '<PublishOptions><Version Value="2"/></PublishOptions></Package></CONFIG>' + LineEnding;
end;

procedure Save(const AFile, AText: string);
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

function IsError(const T: string): Boolean;
begin
  Result := (Pos('TOOL ERROR', T) = 1) or (Pos('RPC ERROR', T) = 1) or (Pos('HTTP ', T) = 1);
end;

procedure TTestCodeNav.SetUp;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'mcpcodenav' + PathDelim +
          TestName + PathDelim;
  ForceDirectories(FDir);
  Save(FDir + 'baseu.pas', BaseUnit);
  Save(FDir + 'kidsu.pas', KidsUnit);
  Save(FDir + 'unusedu.pas', UnusedUnit);
  Save(FDir + 'extractu.pas', ExtractUnit);
end;

procedure TTestCodeNav.TearDown;
begin
  CallToolText('editor_close', '{"file":' + JsonStr(FDir + 'extractu.pas') + '}', []);
  DeleteDirectory(FDir, False);
  RemoveDir(ExcludeTrailingPathDelimiter(ExtractFileDir(ExcludeTrailingPathDelimiter(FDir))));
end;

function TTestCodeNav.Call(const ATool, AArgs: string): string;
begin
  Result := CallToolText(ATool, AArgs, []);
end;

procedure TTestCodeNav.TestDescendantsTree;
var
  T : string;
begin
  T := Call('code_find_descendants', '{"file":' + JsonStr(FDir + 'baseu.pas') +
    ',"line":8,"col":3,"search_dir":' + JsonStr(FDir) + '}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"TKid"', T) > 0, 'direct child: ' + T);
  CheckTrue(Pos('"TGrandKid"', T) > 0, 'grandchild: ' + T);
  CheckTrue(Pos('"TThing"', T) = 0, 'not a descendant of TBase: ' + T);
end;

procedure TTestCodeNav.TestDescendantsDirectOnly;
var
  T : string;
begin
  T := Call('code_find_descendants', '{"file":' + JsonStr(FDir + 'baseu.pas') +
    ',"line":8,"col":3,"direct_only":true,"search_dir":' + JsonStr(FDir) + '}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"TKid"', T) > 0, T);
  CheckTrue(Pos('"TGrandKid"', T) = 0, 'only the direct children: ' + T);
end;

procedure TTestCodeNav.TestInterfaceImplementers;
var
  T : string;
begin
  T := Call('code_find_descendants', '{"file":' + JsonStr(FDir + 'baseu.pas') +
    ',"line":5,"col":3,"search_dir":' + JsonStr(FDir) + '}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"TThing"', T) > 0, 'the implementer: ' + T);
end;

procedure TTestCodeNav.TestOverrides;
var
  T : string;
begin
  T := Call('code_find_overrides', '{"file":' + JsonStr(FDir + 'baseu.pas') +
    ',"line":10,"col":15,"search_dir":' + JsonStr(FDir) + '}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"TKid"', T) > 0, T);
  CheckTrue(Pos('"TGrandKid"', T) > 0, T);
  CheckTrue(Pos('"override"', T) > 0, T);
  CheckTrue(Pos('"TThing"', T) = 0, 'TThing has no Speak: ' + T);
end;

procedure TTestCodeNav.TestUnitUses;
var
  T : string;
begin
  T := Call('code_unit_dependencies', '{"file":' + JsonStr(FDir + 'kidsu.pas') + '}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"baseu"', T) > 0, 'kidsu uses baseu: ' + T);
  CheckTrue(Pos('uses_interface', T) > 0, T);
end;

procedure TTestCodeNav.TestUnused;
var
  T : string;
begin
  T := Call('code_find_unused', '{"file":' + JsonStr(FDir + 'unusedu.pas') + '}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('TWorker.NeverCalled', T) > 0, 'never called: ' + T);
  CheckTrue(Pos('TWorker.FUnusedField', T) > 0, 'never used field: ' + T);
  CheckTrue(Pos('TWorker.Helper', T) = 0, 'Helper is called by Work: ' + T);
end;

procedure TTestCodeNav.TestExtractDryRun;
var
  T : string;
begin
  T := Call('code_extract_method', '{"file":' + JsonStr(FDir + 'extractu.pas') +
    ',"start_line":12,"start_col":3,"end_line":12,"end_col":14,"dry_run":true}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('method_possible', T) > 0, T);
end;

procedure TTestCodeNav.TestExtract;
var
  T : string;
begin
  T := Call('code_extract_method', '{"file":' + JsonStr(FDir + 'extractu.pas') +
    ',"start_line":12,"start_col":3,"end_line":12,"end_col":14,"name":"ShowIt","auto_save":true}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('ShowIt', T) > 0, T);
  T := CallToolText('editor_read_file', '{"file":' + JsonStr(FDir + 'extractu.pas') + '}', []);
  CheckTrue(Pos('procedure ShowIt', T) > 0, 'the new routine is in the unit: ' + T);
  CheckTrue(Pos('ShowIt(I)', T) > 0, 'and called: ' + T);
end;

procedure TTestCodeNav.TestExtractBadName;
var
  T : string;
begin
  T := Call('code_extract_method', '{"file":' + JsonStr(FDir + 'extractu.pas') +
    ',"start_line":12,"start_col":3,"end_line":12,"end_col":14,"name":"not valid"}');
  CheckTrue(IsError(T) or (Pos('valid identifier', T) > 0), T);
end;

{ a2 uses a1: moving a2 out of package A makes B require A }
procedure TTestCodeNav.TestMoveUnitPlan;
var
  T, N : string;
begin
  N := 'MovePlan';
  Save(FDir + 'a1.pas', 'unit a1;' + LineEnding + 'interface' + LineEnding + 'implementation' + LineEnding + 'end.');
  Save(FDir + 'a2.pas', 'unit a2;' + LineEnding + 'interface' + LineEnding + 'uses a1;' + LineEnding + 'implementation' + LineEnding + 'end.');
  Save(FDir + N + 'A.lpk', PkgText(N + 'A', ['a1', 'a2']));
  Save(FDir + N + 'B.lpk', PkgText(N + 'B', []));
  T := Call('package_move_unit', '{"file":' + JsonStr(FDir + 'a2.pas') + ',"from_package":' +
    JsonStr(FDir + N + 'A.lpk') + ',"to_package":' + JsonStr(FDir + N + 'B.lpk') + ',"dry_run":true}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos(N + 'B requires ' + N + 'A', T) > 0, 'B must require A: ' + T);
  CheckTrue(Pos(N + 'A requires', T) = 0, 'and not the other way: ' + T);
end;

{ a1 and a2 use each other: moving one of them would need a cycle between the packages }
procedure TTestCodeNav.TestMoveUnitCycle;
var
  T, N : string;
begin
  N := 'MoveCycle';
  Save(FDir + 'a1.pas', 'unit a1;' + LineEnding + 'interface' + LineEnding + 'implementation' + LineEnding + 'uses a2;' + LineEnding + 'end.');
  Save(FDir + 'a2.pas', 'unit a2;' + LineEnding + 'interface' + LineEnding + 'uses a1;' + LineEnding + 'implementation' + LineEnding + 'end.');
  Save(FDir + N + 'A.lpk', PkgText(N + 'A', ['a1', 'a2']));
  Save(FDir + N + 'B.lpk', PkgText(N + 'B', []));
  T := Call('package_move_unit', '{"file":' + JsonStr(FDir + 'a1.pas') + ',"from_package":' +
    JsonStr(FDir + N + 'A.lpk') + ',"to_package":' + JsonStr(FDir + N + 'B.lpk') + ',"dry_run":true}');
  CheckTrue(IsError(T) and (Pos('cycle', T) > 0), 'refused: ' + T);
end;

initialization
  RegisterTest(TTestCodeNav);
end.
