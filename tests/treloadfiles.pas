{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TReloadFiles;

{ TTestReloadFiles — a file an agent changed on disk with its own tools is
  reloaded into its open editor when the next tool call arrives, and an editor
  with unsaved changes is never touched (McpReloadChangedFiles).  The text is
  read back with editor_read_file, which prefers the editor buffer.
  Requires a running MCP server. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, THttpHelper;

type
  TTestReloadFiles = class(TTestCase)
  private
    FDir  : string;
    FFile : string;
    procedure WriteDisk(const AText: string);
    function Buffer: string;
    procedure WaitForReview;
    function Waiting: Integer;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestUnmodifiedEditorFollowsDisk;
    procedure TestUnsavedEditSurvives;
    procedure TestSameTextIsNoReview;
    procedure TestRapidSecondWriteIsSeen;
    procedure TestWaitingFileIsReported;
    procedure TestClosedEditorEndsReview;
    procedure TestClosedEditorLeavesTheWindow;
    procedure TestRebuildRefusesUnsavedEditors;
  end;

implementation

uses
  Classes, SysUtils, FileUtil, fpjson, jsonparser;

procedure TTestReloadFiles.SetUp;
begin
  FDir  := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'mcpreload' + PathDelim +
           TestName + PathDelim;
  FFile := FDir + 'sample.txt';
  ForceDirectories(FDir);
  WriteDisk('one' + LineEnding + 'two' + LineEnding + 'three');
  CallToolText('editor_open', '{"file":' + JsonStr(FFile) + '}', []);
end;

procedure TTestReloadFiles.TearDown;
begin
  CallToolText('editor_close', '{"file":' + JsonStr(FFile) + '}', []);
  DeleteDirectory(FDir, False);
  RemoveDir(ExcludeTrailingPathDelimiter(ExtractFileDir(ExcludeTrailingPathDelimiter(FDir))));
end;

procedure TTestReloadFiles.WriteDisk(const AText: string);
var
  SL : TStringList;
begin
  SL := TStringList.Create;
  try
    SL.Text := AText;
    SL.SaveToFile(FFile);
  finally
    SL.Free;
  end;
end;

function TTestReloadFiles.Buffer: string;
var
  T : string;
  J : TJSONData;
begin
  T := CallToolText('editor_read_file', '{"file":' + JsonStr(FFile) + '}', []);
  J := GetJSON(T);
  try
    Result := TJSONObject(J).Get('content', '');
    if TJSONObject(J).Get('source', '') <> 'editor' then
      Result := 'not from the editor: ' + T;
  finally
    J.Free;
  end;
end;

procedure TTestReloadFiles.TestUnmodifiedEditorFollowsDisk;
begin
  { the file's age has a resolution of two seconds on some file systems }
  Sleep(2100);
  WriteDisk('one' + LineEnding + 'CHANGED ON DISK' + LineEnding + 'three');
  CheckTrue(Pos('CHANGED ON DISK', Buffer) > 0,
    'the editor shows what the agent wrote to the file');
end;

procedure TTestReloadFiles.TestSameTextIsNoReview;
var
  T : string;
begin
  { the user typed an edit; an agent writes the very same text to the file: the editor
    and the disk agree, so there is nothing to review (the editor's final empty line
    after the last line break is not a difference) }
  T := CallToolText('editor_edit_text', '{"file":' + JsonStr(FFile) +
    ',"old_text":"two","new_text":"SAME"}', []);
  CheckTrue(Pos('replaced', T) > 0, T);
  Sleep(2100);
  WriteDisk('one' + LineEnding + 'SAME' + LineEnding + 'three');
  T := CallToolText('editor_read_file', '{"file":' + JsonStr(FFile) + '}', []);
  CheckTrue(Pos('SAME', T) > 0, T);
  CheckTrue(Pos('changed on disk', T) = 0, 'no review was opened: ' + T);
end;

procedure TTestReloadFiles.TestUnsavedEditSurvives;
var
  T : string;
begin
  T := CallToolText('editor_edit_text', '{"file":' + JsonStr(FFile) +
    ',"old_text":"two","new_text":"UNSAVED EDIT"}', []);
  CheckTrue(Pos('replaced', T) > 0, T);
  Sleep(2100);
  WriteDisk('one' + LineEnding + 'two' + LineEnding + 'CHANGED ON DISK');
  T := Buffer;
  CheckTrue(Pos('UNSAVED EDIT', T) > 0, 'the unsaved edit is still there: ' + T);
  CheckTrue(Pos('CHANGED ON DISK', T) = 0, 'and the file on disk was not loaded over it');
end;

{ The unsaved edit and the agent's write meet: the next tool result must name the file, the
  editor keeps its text, and (policy "ask", the default) nothing lands beside the file. }
procedure TTestReloadFiles.WaitForReview;
var
  T : string;
begin
  T := CallToolText('editor_edit_text', '{"file":' + JsonStr(FFile) +
    ',"old_text":"two","new_text":"UNSAVED EDIT"}', []);
  CheckTrue(Pos('replaced', T) > 0, T);
  Sleep(2100);
  WriteDisk('one' + LineEnding + 'two' + LineEnding + 'CHANGED ON DISK');
  T := CallToolText('editor_read_file', '{"file":' + JsonStr(FFile) + '}', []);
  if (Pos('.agent', T) > 0) or (Pos('took your version', T) > 0) then
    Ignore('the IDE is set to another conflict policy than "ask"');
  CheckTrue(Pos('sample.txt changed on disk', T) > 0, 'the result names the file: ' + T);
  CheckTrue(Pos('asked to review', T) > 0, 'and says the user is asked: ' + T);
  CheckTrue(Pos('UNSAVED EDIT', Buffer) > 0, 'the unsaved edit is still there');
  CheckFalse(FileExists(FFile + '.agent'), 'nothing was saved beside the file');
end;

{ The number in the review window's caption ("Review: 3 file(s) waiting"); 0 when no such
  window is shown. }
function TTestReloadFiles.Waiting: Integer;
var
  T    : string;
  P, N : Integer;
begin
  Result := 0;
  { docked, the caption is on a child of the main window; floating, on a window of its own }
  T := CallToolText('project_get_windows', '{"ide":true,"window":"Lazarus IDE"}', []);
  P := Pos('Review: ', T);
  if P = 0 then
  begin
    T := CallToolText('project_get_windows', '{"ide":true,"window":"waiting"}', []);
    P := Pos('Review: ', T);
  end;
  if P = 0 then Exit;
  N := P + Length('Review: ');
  while (N <= Length(T)) and (T[N] in ['0'..'9']) do Inc(N);
  Result := StrToIntDef(Copy(T, P + Length('Review: '), N - P - Length('Review: ')), 0);
end;

{ The review window lists the waiting file, and no longer once its editor is closed. }
procedure TTestReloadFiles.TestClosedEditorLeavesTheWindow;
var
  Before : Integer;
begin
  Before := Waiting;
  WaitForReview;
  Sleep(300);
  CheckEquals(Before + 1, Waiting, 'the file waits in the review window');
  CallToolText('editor_close', '{"file":' + JsonStr(FFile) + '}', []);
  Sleep(300);
  CheckEquals(Before, Waiting, 'its editor is closed: nothing waits for it any more');
end;

{ An agent writes a file twice within two seconds (DOS time, which the file age used to
  be, cannot tell the writes apart): the editor must show the second text. }
procedure TTestReloadFiles.TestRapidSecondWriteIsSeen;
begin
  Buffer;                                    { the pass notes the file: its state is seen }
  WriteDisk('one' + LineEnding + 'FIRST' + LineEnding + 'three');
  CheckTrue(Pos('FIRST', Buffer) > 0, 'the first write');
  WriteDisk('one' + LineEnding + 'SECOND' + LineEnding + 'three');
  CheckTrue(Pos('SECOND', Buffer) > 0, 'the second write, right behind the first one');
end;

procedure TTestReloadFiles.TestWaitingFileIsReported;
begin
  WaitForReview;
end;

{ Closing the editor of a file that waits ends its review; the same file can wait again
  (the same path is used on every run of the suite). }
procedure TTestReloadFiles.TestClosedEditorEndsReview;
begin
  WaitForReview;
  CallToolText('editor_close', '{"file":' + JsonStr(FFile) + '}', []);
  WriteDisk('one' + LineEnding + 'two' + LineEnding + 'three');
  CallToolText('editor_open', '{"file":' + JsonStr(FFile) + '}', []);
  CheckTrue(Pos('CHANGED ON DISK', Buffer) = 0, 'reopened: the text is the file''s');
  WaitForReview;
end;

{ ide_rebuild closes every editor without asking, so it must refuse while one holds unsaved
  text, and change nothing.  save_unsaved=false is passed on purpose: a plugin without this
  guard rejects the unknown parameter instead of rebuilding the IDE under the test. }
procedure TTestReloadFiles.TestRebuildRefusesUnsavedEditors;
var
  T : string;
begin
  T := CallToolText('editor_edit_text', '{"file":' + JsonStr(FFile) +
    ',"old_text":"two","new_text":"UNSAVED EDIT"}', []);
  CheckTrue(Pos('replaced', T) > 0, T);
  T := CallToolText('ide_rebuild', '{"save_unsaved":false}', []);
  CheckTrue(Pos('not_started', T) > 0, 'refused: ' + T);
  CheckTrue(Pos('sample.txt', T) > 0, 'names the file: ' + T);
  T := Buffer;
  CheckTrue(Pos('UNSAVED EDIT', T) > 0, 'the editor still holds its text: ' + T);
end;

initialization
  RegisterTest(TTestReloadFiles);
end.
