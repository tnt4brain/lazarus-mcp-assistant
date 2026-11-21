{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TLimitedMode;

{ TTestLimitedMode - limited mode (ADR-034 decision 5): off when no folder is set, new places and
  reads judged against the allowed folders, the setting stored and restored.  Pure: no IDE. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, fpjson, jsonparser, McpLimitedMode, McpToolContext,
  McpSettingsFile;

type
  TTestLimitedMode = class(TTestCase)
  private
    FAllowed  : string;
    FOutside  : string;
    FReadable : string;
    function Args(const AJson: string): TJSONObject;
    function Check(const ATool, AJson: string; out AWhy: string): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestOffByDefault;
    procedure TestCleanFolder;
    procedure TestNewPlacesInsideOnly;
    procedure TestReadsInsideAllowedOrReadable;
    procedure TestRelativePathUsesTheProject;
    procedure TestWritersAreNotJudgedHere;
    procedure TestRefusalNamesTheFolders;
    procedure TestEverythingWithPathIsGuardedWhenLimited;
    procedure TestSettingsRoundTrip;
  end;

implementation

uses
  McpToolScope;

var
  GReadable : string;

procedure ReadableHook(AList: TStrings);
begin
  AList.Add(GReadable);
end;

function BaseHook: string;
begin
  Result := GReadable;
end;

procedure TTestLimitedMode.SetUp;
var
  Root : string;
begin
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'mcplimited' + PathDelim + TestName + PathDelim;
  FAllowed  := Root + 'allowed';
  FOutside  := Root + 'outside';
  FReadable := Root + 'readable';
  ForceDirectories(FAllowed);
  ForceDirectories(FOutside);
  ForceDirectories(FReadable);
  GReadable := FReadable;
  GMcpReadableRoots := @ReadableHook;
  GMcpBaseDir := @BaseHook;
  McpLimitSetFolders([]);
end;

procedure TTestLimitedMode.TearDown;
begin
  McpLimitSetFolders([]);
  GMcpReadableRoots := nil;
  GMcpBaseDir := nil;
  RemoveDir(FAllowed);
  RemoveDir(FOutside);
  RemoveDir(FReadable);
  RemoveDir(ExtractFileDir(FAllowed));
  RemoveDir(ExtractFileDir(ExtractFileDir(FAllowed)));
end;

function TTestLimitedMode.Args(const AJson: string): TJSONObject;
begin
  Result := TJSONObject(GetJSON(AJson));
end;

function TTestLimitedMode.Check(const ATool, AJson: string; out AWhy: string): Boolean;
var
  A : TJSONObject;
begin
  A := Args(AJson);
  try
    Result := McpLimitCheckUse(ATool, A, GReadable, AWhy);
  finally
    A.Free;
  end;
end;

function Q(const S: string): string;
begin
  { JSON string with backslashes escaped }
  Result := '"' + StringReplace(S, '\', '\\', [rfReplaceAll]) + '"';
end;

procedure TTestLimitedMode.TestOffByDefault;
var
  W : string;
begin
  CheckFalse(McpLimitedOn, 'off');
  CheckTrue(Check('project_open', '{"file":' + Q(FOutside + PathDelim + 'p.lpi') + '}', W), 'off: ' + W);
  CheckTrue(Check('editor_read_file', '{"file":' + Q(FOutside + PathDelim + 'a.pas') + '}', W), W);
end;

procedure TTestLimitedMode.TestCleanFolder;
var
  C, W : string;
begin
  CheckTrue(McpLimitCleanFolder(FAllowed + PathDelim + '..' + PathDelim + 'allowed' + PathDelim, C, W), W);
  CheckEquals(ExcludeTrailingPathDelimiter(FAllowed), C, 'cleaned, no trailing separator');
  CheckFalse(McpLimitCleanFolder('relative' + PathDelim + 'dir', C, W), 'relative');
  CheckTrue(Pos('absolute', W) > 0, W);
  CheckFalse(McpLimitCleanFolder('', C, W), 'empty');
  {$IFDEF WINDOWS}
  CheckFalse(McpLimitCleanFolder('C:\', C, W), 'drive root');
  CheckTrue(Pos('root', W) > 0, W);
  {$ELSE}
  CheckFalse(McpLimitCleanFolder('/', C, W), 'file system root');
  CheckTrue(McpLimitCleanFolder('/home', C, W), 'a top-level folder is fine');
  {$ENDIF}
  McpLimitSetFolders(['relative', FAllowed]);
  CheckTrue(McpLimitedOn, 'the good entry stays');
  McpLimitSetFolders(['relative']);
  CheckFalse(McpLimitedOn, 'nothing usable: off, not "everything refused"');
end;

procedure TTestLimitedMode.TestNewPlacesInsideOnly;
var
  W : string;
  T, K : string;
begin
  McpLimitSetFolders([FAllowed]);
  CheckTrue(McpLimitedOn);
  CheckTrue(Check('project_open', '{"file":' + Q(FAllowed + PathDelim + 'p.lpi') + '}', W), W);
  CheckFalse(Check('project_open', '{"file":' + Q(FOutside + PathDelim + 'p.lpi') + '}', W), 'outside');
  CheckTrue(Check('project_create', '{"project_dir":' + Q(FAllowed + PathDelim + 'new') + '}', W), W);
  CheckFalse(Check('project_create', '{"project_dir":' + Q(FOutside + PathDelim + 'new') + '}', W));
  CheckFalse(Check('git_clone', '{"target_dir":' + Q(FOutside) + '}', W));
  CheckTrue(Check('git_clone', '{"target_dir":' + Q(FAllowed) + '}', W), W);
  CheckFalse(Check('git_init', '{"work_dir":' + Q(FOutside) + '}', W));
  CheckFalse(Check('package_open', '{"lpk_path":' + Q(FOutside + PathDelim + 'x.lpk') + '}', W));
  CheckFalse(Check('project_add_package', '{"lpk_path":' + Q(FOutside + PathDelim + 'x.lpk') + '}', W));
  { the folder itself is inside }
  CheckTrue(Check('git_init', '{"work_dir":' + Q(FAllowed) + '}', W), W);
  { ".." does not get out }
  T := FAllowed + PathDelim + '..' + PathDelim + 'outside';
  CheckFalse(Check('git_init', '{"work_dir":' + Q(T) + '}', W), 'dotdot');
  K := 'project_create';
  CheckTrue(K <> '');
end;

procedure TTestLimitedMode.TestReadsInsideAllowedOrReadable;
var
  W : string;
begin
  McpLimitSetFolders([FAllowed]);
  CheckTrue(Check('editor_read_file', '{"file":' + Q(FAllowed + PathDelim + 'a.pas') + '}', W), W);
  CheckTrue(Check('editor_read_file', '{"file":' + Q(FReadable + PathDelim + 'a.pas') + '}', W),
    'readable root (the project, packages, Lazarus): ' + W);
  CheckFalse(Check('editor_read_file', '{"file":' + Q(FOutside + PathDelim + 'a.pas') + '}', W), 'outside');
  CheckFalse(Check('project_search', '{"query":"x","directory":' + Q(FOutside) + '}', W));
  CheckFalse(Check('git_log', '{"work_dir":' + Q(FOutside) + '}', W));
  CheckTrue(Check('git_log', '{}', W), 'no path: the project');
  CheckTrue(Check('git_log', '{"work_dir":""}', W), 'empty path: the project');
end;

procedure TTestLimitedMode.TestRelativePathUsesTheProject;
var
  W : string;
begin
  McpLimitSetFolders([FAllowed]);
  { the base (the project, here the readable folder) holds a.pas }
  CheckTrue(Check('editor_read_file', '{"file":"a.pas"}', W), W);
  CheckFalse(Check('editor_read_file', '{"file":' + Q('..' + PathDelim + 'outside' + PathDelim + 'a.pas') + '}', W),
    'a relative path cannot walk out: ' + W);
end;

procedure TTestLimitedMode.TestWritersAreNotJudgedHere;
var
  W : string;
begin
  McpLimitSetFolders([FAllowed]);
  { the writable roots judge a file a tool changes (McpWritableRoots); this check is reads and new places }
  CheckTrue(Check('code_format', '{"file":' + Q(FOutside + PathDelim + 'a.pas') + '}', W), W);
  CheckTrue(Check('git_commit', '{"work_dir":' + Q(FOutside) + '}', W), W);
end;

procedure TTestLimitedMode.TestRefusalNamesTheFolders;
var
  W : string;
begin
  McpLimitSetFolders([FAllowed]);
  CheckFalse(Check('git_clone', '{"target_dir":' + Q(FOutside) + '}', W));
  CheckTrue(Pos('limited mode', W) > 0, W);
  CheckTrue(Pos(FAllowed, W) > 0, 'names the allowed folder: ' + W);
  CheckTrue(Pos('Options', W) > 0, 'says who changes it: ' + W);
  CheckFalse(Check('editor_read_file', '{"file":' + Q(FOutside + PathDelim + 'a.pas') + '}', W));
  CheckTrue(Pos('temp', W) > 0, 'a read refusal names what else is readable: ' + W);
end;

procedure TTestLimitedMode.TestEverythingWithPathIsGuardedWhenLimited;
var
  I : Integer;
  P : TMcpToolPath;
begin
  McpLimitSetFolders([]);
  CheckFalse(McpToolIsWriteGuarded('editor_read_file'), 'off: reads are not asked');
  McpLimitSetFolders([FAllowed]);
  for I := 0 to McpToolPathCount - 1 do
  begin
    P := McpToolPathAt(I);
    CheckTrue(McpToolIsWriteGuarded(P.Tool), P.Tool + ' is checked when limited');
  end;
  CheckFalse(McpToolIsWriteGuarded('ide_ping'), 'a tool with no path is not');
end;

procedure TTestLimitedMode.TestSettingsRoundTrip;
var
  S : TMcpIdeSettings;
  F : string;
begin
  F := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'mcplimited_opts_' + IntToStr(GetProcessID) + '.xml';
  S := TMcpIdeSettings.Create;
  try
    S.LoadSettings(F);
    CheckEquals(0, S.AllowedFolders.Count, 'default: empty = off');
    S.AllowedFolders.Add(FAllowed);
    S.AllowedFolders.Add(FOutside);
    S.SaveSettings;
  finally
    S.Free;
  end;
  S := TMcpIdeSettings.Create;
  try
    S.LoadSettings(F);
    CheckEquals(2, S.AllowedFolders.Count);
    CheckEquals(FAllowed, S.AllowedFolders[0]);
    CheckEquals(FOutside, S.AllowedFolders[1]);
    S.AllowedFolders.Clear;
    S.SaveSettings;
  finally
    S.Free;
  end;
  S := TMcpIdeSettings.Create;
  try
    S.LoadSettings(F);
    CheckEquals(0, S.AllowedFolders.Count, 'cleared stays cleared');
  finally
    S.Free;
    DeleteFile(F);
  end;
end;

initialization
  RegisterTest(TTestLimitedMode);

end.
