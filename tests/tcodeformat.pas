{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TCodeFormat;

{ TTestCodeFormat — code_format (JEDI Code Format) against the running IDE.
  Each test works on a copy of tests/fixtures/fixtureformat.pas in a temp
  folder; the copy is reverted, closed and deleted afterwards.  The checks
  hold for JCF's default settings and for the usual changes to them (they
  look at the indentation and spacing of Messy, not at capitalisation).
  Requires a running MCP server. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, THttpHelper;

type
  TTestCodeFormat = class(TTestCase)
  private
    FDir  : string;
    FUnit : string;
    function RunFormat(const AExtra: string = ''): string;
    function Disk: string;
    function Buffer: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestWholeFile;
    procedure TestLineRange;
    procedure TestParseError;
    procedure TestRefusals;
    procedure TestAutoSave;
    procedure TestIncludeFile;
    procedure TestTrailingLines;
  end;

implementation

uses
  Classes, SysUtils, FileUtil, fpjson, jsonparser;

const
  { lines of procedure Messy in fixtureformat.pas }
  MessyFirst = 19;
  MessyLast  = 25;
  Formatted  = 'for i := 1 to 3 do';

function IsError(const T: string): Boolean;
begin
  Result := (Pos('TOOL ERROR', T) = 1) or (Pos('RPC ERROR', T) = 1) or (Pos('HTTP ', T) = 1);
end;

procedure TTestCodeFormat.SetUp;
begin
  { a folder per test: the IDE caches files by name }
  FDir  := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'mcpcodeformat' + PathDelim +
           TestName + PathDelim;
  FUnit := FDir + 'fixtureformat.pas';
  ForceDirectories(FDir);
  CopyFile(ExtractFilePath(ExpandFileName(ParamStr(0))) + 'fixtures' + PathDelim +
           'fixtureformat.pas', FUnit);
end;

procedure TTestCodeFormat.TearDown;
begin
  CallToolText('editor_revert', '{"file":' + JsonStr(FUnit) + '}', []);
  CallToolText('editor_close', '{"file":' + JsonStr(FUnit) + '}', []);
  DeleteDirectory(FDir, False);
  RemoveDir(ExcludeTrailingPathDelimiter(ExtractFileDir(ExcludeTrailingPathDelimiter(FDir))));
end;

function TTestCodeFormat.RunFormat(const AExtra: string): string;
begin
  Result := CallToolText('code_format', '{"file":' + JsonStr(FUnit) + AExtra + '}', []);
end;

function TTestCodeFormat.Disk: string;
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

{ The editor's text with the platform's line ends, unsaved changes included. }
function TTestCodeFormat.Buffer: string;
var
  T : string;
  J : TJSONData;
begin
  T := CallToolText('editor_read_file', '{"path":' + JsonStr(FUnit) + '}', []);
  J := GetJSON(T);
  try
    Result := AdjustLineBreaks(TJSONObject(J).Get('content', ''));
    if TJSONObject(J).Get('source', '') <> 'editor' then
      Result := 'not from the editor: ' + T;
  finally
    J.Free;
  end;
end;

procedure TTestCodeFormat.TestWholeFile;
var
  Before, T, Formatted1 : string;
begin
  Before := Disk;
  T := RunFormat;
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"changed" : true', T) > 0, 'changed: ' + T);
  Formatted1 := Buffer;
  CheckTrue(Pos(Formatted, Formatted1) > 0, 'formatted in the editor: ' + Formatted1);
  CheckEquals(Before, Disk, 'not on disk');
  { what the editor holds is what JCF produced: formatting it again changes nothing }
  T := RunFormat;
  CheckTrue(Pos('"changed" : false', T) > 0, 'second run: ' + T);
  CheckEquals(Formatted1, Buffer, 'buffer unchanged by the second run');
end;

procedure TTestCodeFormat.TestLineRange;
var
  T, Buf : string;
begin
  T := RunFormat(Format(',"start_line":%d,"end_line":%d', [MessyFirst, MessyLast]));
  CheckFalse(IsError(T), T);
  Buf := Buffer;
  CheckTrue(Pos(Formatted, Buf) > 0, 'range formatted: ' + Buf);
  CheckTrue(Pos('function Twice(A: Integer): Integer;', Buf) > 0, 'outside the range kept: ' + Buf);
  CheckEquals(0, Pos('}end;', Buf), 'no JCF marker left: ' + Buf);
  CheckTrue(Pos('writeln(''one'');' + LineEnding + 'end;' + LineEnding,
    StringReplace(Buf, ' ', '', [rfReplaceAll])) > 0, 'end of Messy kept: ' + Buf);
end;

procedure TTestCodeFormat.TestParseError;
var
  SL     : TStringList;
  T, Buf : string;
begin
  SL := TStringList.Create;
  try
    SL.Text := 'unit FixtureFormat;' + LineEnding + 'interface' + LineEnding +
      'implementation' + LineEnding + 'procedure P;' + LineEnding +
      'begin if then end;' + LineEnding + 'end.';
    SL.SaveToFile(FUnit);
  finally
    SL.Free;
  end;
  T := RunFormat;
  CheckTrue(Pos('could not format', T) > 0, 'parse error: ' + T);
  Buf := Buffer;
  CheckTrue(Pos('begin if then end;', Buf) > 0, 'nothing changed: ' + Buf);
end;

procedure TTestCodeFormat.TestRefusals;
var
  T : string;
begin
  T := CallToolText('code_format', '{"file":' + JsonStr(FDir + 'notes.txt') + '}', []);
  CheckTrue(Pos('Not a Pascal source', T) > 0, 'not Pascal: ' + T);
  { an error, not the IDE's modal "File not found" }
  T := CallToolText('code_format', '{"file":' + JsonStr(FDir + 'missing.pas') + '}', []);
  CheckTrue(Pos('File not found', T) > 0, 'missing file: ' + T);
  T := RunFormat(',"start_line":5');
  CheckTrue(Pos('must both be given', T) > 0, 'half a range: ' + T);
  T := RunFormat(',"start_line":1,"end_line":999');
  CheckTrue(Pos('past the end', T) > 0, 'past the end: ' + T);
end;

procedure TTestCodeFormat.TestAutoSave;
var
  T : string;
begin
  T := RunFormat(',"auto_save":true');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"saved" : true', T) > 0, 'saved: ' + T);
  CheckTrue(Pos(Formatted, Disk) > 0, 'on disk');
end;

{ Writes AText to a new file in the test's folder; returns its path. }
function WriteFixture(const ADir, AName, AText: string): string;
var
  SL : TStringList;
begin
  Result := ADir + AName;
  SL := TStringList.Create;
  try
    SL.Text := AText;
    SL.SaveToFile(Result);
  finally
    SL.Free;
  end;
end;

{ An include file is formatted inside a fake unit, as the IDE does. }
procedure TTestCodeFormat.TestIncludeFile;
var
  F, T, Args : string;
begin
  F := WriteFixture(FDir, 'fixtureinc.inc', 'procedure IncProc;' + LineEnding +
    'var i:integer;' + LineEnding + 'begin' + LineEnding +
    'for i:=1 to 2 do writeln(i);' + LineEnding + 'end;');
  Args := '{"file":' + JsonStr(F) + '}';
  try
    T := CallToolText('code_format', Args, []);
    CheckFalse(IsError(T), T);
    CheckTrue(Pos('for i := 1 to 2 do', T) > 0, 'formatted: ' + T);
    T := CallToolText('code_format', Args, []);
    CheckTrue(Pos('"changed" : false', T) > 0, 'second run: ' + T);
  finally
    CallToolText('editor_revert', '{"file":' + JsonStr(F) + '}', []);
    CallToolText('editor_close', '{"file":' + JsonStr(F) + '}', []);
  end;
end;

{ Blank lines after "end." are removed: the hunk at the end of the file. }
procedure TTestCodeFormat.TestTrailingLines;
var
  T : string;
begin
  { spaced as JCF spaces it, so the only other change is writeln's line }
  WriteFixture(FDir, 'fixtureformat.pas', 'unit FixtureFormat;' + LineEnding +
    LineEnding + 'interface' + LineEnding + LineEnding + 'implementation' +
    LineEnding + LineEnding + 'procedure P;' + LineEnding + 'begin' + LineEnding +
    'writeln( 1 );' + LineEnding + 'end;' + LineEnding + LineEnding + 'end.' +
    LineEnding + LineEnding + LineEnding + LineEnding);
  T := RunFormat;
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"removed_lines" : 3, "added_lines" : 0', T) > 0, 'blank lines removed: ' + T);
  T := RunFormat;
  CheckTrue(Pos('"changed" : false', T) > 0, 'second run: ' + T);
end;

end.
