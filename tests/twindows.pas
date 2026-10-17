{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TWindows;

{ TTestWindows — project_get_windows on tests/windowee/mcpwindowee.lpi, and
  project_set_settings' widgetset on that project (Windows only), and TTestProjectRuns, the
  generated-program tests that run on every platform.

  Opt-in like the debugger tests, because they switch the IDE's project:
  MCP_DEBUG_TESTS=1 opens the fixture with project_open and reopens the
  previous project afterwards.  The fixture program is started with
  project_run or debug_run and killed after each test. }

{$mode objfpc}{$H+}

interface

uses
  Classes, fpcunit, testregistry, testdecorator, THttpHelper;

type
  TWindoweeSetup = class(TTestSetup)
  protected
    procedure OneTimeSetup; override;
    procedure OneTimeTearDown; override;
  end;

  TTestWindows = class(TTestCase)
  private
    function WaitForWindow: string;
    procedure KillFixture;
  protected
    procedure TearDown; override;
  published
    procedure TestWidgetset;
    procedure TestNoWindow;
    procedure TestTree;
    procedure TestImage;
    procedure TestPaused;
  end;

  { Generated programs in a temp folder, on every platform: run output, debugger
    start-up and project files.  The fixture only parks the IDE's project. }
  TTestProjectRuns = class(TTestCase)
  protected
    procedure TearDown; override;
  published
    procedure TestOpenProgramWithoutProject;
    procedure TestDebugPreflightAndExit;
    procedure TestRunOutput;
    procedure TestRunInput;
    procedure TestDebugRunOfBrokenProgram;
    procedure TestProjectFilesAndFormCreate;
    procedure TestAttach;
  end;

function WindoweeLpi: string;

implementation

uses
  SysUtils, DateUtils, Math, base64, fpjson, jsonparser, FileUtil, LazFileUtils;

var
  GSess        : string;
  GPrevProject : string;   { reopened by OneTimeTearDown; '' = leave as is }

function WindoweeLpi: string;
begin
  Result := ExtractFilePath(ExpandFileName(ParamStr(0))) +
            'windowee' + PathDelim + 'mcpwindowee.lpi';
end;

function WindoweeExe: string;
begin
  Result := ChangeFileExt(WindoweeLpi, '.exe');
end;

function Call(const ATool, AArgs: string): string;
begin
  Result := CallToolText(ATool, AArgs, ['Mcp-Session-Id: ' + GSess]);
end;

function IsError(const T: string): Boolean;
begin
  Result := (Pos('TOOL ERROR', T) = 1) or (Pos('RPC ERROR', T) = 1) or (Pos('HTTP ', T) = 1);
end;

function JPath(const T, APath: string): string;
var
  D, V : TJSONData;
begin
  Result := '';
  if IsError(T) then Exit;
  D := GetJSON(T);
  try
    V := D.FindPath(APath);
    if Assigned(V) and not (V.JSONType in [jtObject, jtArray, jtNull]) then
      Result := V.AsString;
  finally
    D.Free;
  end;
end;

function FileText(const AFile: string): string;
var
  S : TStringStream;
begin
  S := TStringStream.Create('');
  try
    S.LoadFromFile(AFile);
    Result := S.DataString;
  finally
    S.Free;
  end;
end;

function MarkLine(const AName: string): Integer;
var
  SL : TStringList;
  I  : Integer;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(ChangeFileExt(WindoweeLpi, '.lpr'));
    for I := 0 to SL.Count - 1 do
      if Pos('MARK:' + AName, SL[I]) > 0 then
        Exit(I + 1);
  finally
    SL.Free;
  end;
  raise Exception.Create('marker not found: ' + AName);
end;

{ ── Suite setup ──────────────────────────────────────────────────────────── }

procedure TWindoweeSetup.OneTimeSetup;
var
  T : string;
begin
  GSess := McpNewSession;
  GPrevProject := JPath(Call('project_get_settings', '{}'), 'project_file');
  if SameFileName(ExpandFileName(GPrevProject), WindoweeLpi) then
  begin
    GPrevProject := '';
    Exit;
  end;
  T := Call('project_open', '{"file_path":' + JsonStr(WindoweeLpi) + '}');
  if IsError(T) then
    raise Exception.Create('Could not open the fixture project: ' + T);
end;

procedure TWindoweeSetup.OneTimeTearDown;
var
  T : string;
  I : Integer;
begin
  { breakpoint changes mark the project modified; saving it leaves the
    .lpi as it was, and a modified project would block project_open }
  Call('project_set_settings', '{}');
  if GPrevProject = '' then Exit;
  { the last test's debug session may still be going down }
  for I := 1 to 20 do
  begin
    T := Call('project_open', '{"file_path":' + JsonStr(GPrevProject) + '}');
    if Pos('busy', T) = 0 then Break;
    Sleep(500);
  end;
  if IsError(T) then
    raise Exception.Create('Could not reopen ' + GPrevProject + ': ' + T);
end;

{ ── Helpers ──────────────────────────────────────────────────────────────── }

{ The tree once the form is up. }
function TTestWindows.WaitForWindow: string;
var
  Until_ : TDateTime;
begin
  Until_ := IncSecond(Now, 60);
  repeat
    Result := Call('project_get_windows', '{}');
    if Pos('Push me', Result) > 0 then Exit;
    Sleep(300);
  until Now > Until_;
  Fail('the fixture''s window did not appear: ' + Result);
end;

procedure TTestWindows.KillFixture;
var
  Until_ : TDateTime;
begin
  Call('debug_stop', '{}');
  if Pos('No visible window', Call('project_get_windows', '{}')) > 0 then Exit;
  ExecuteProcess('taskkill', '/F /IM ' + ExtractFileName(WindoweeExe), []);
  Until_ := IncSecond(Now, 10);
  while (Pos('No visible window', Call('project_get_windows', '{}')) = 0) and (Now < Until_) do
    Sleep(200);
end;

procedure TTestWindows.TearDown;
var
  T : string;
begin
  KillFixture;
  T := Call('debug_list_breakpoints', '{}');
  if Pos('mcpwindowee.lpr', T) > 0 then
    Call('debug_remove_breakpoint', '{"file":' +
      JsonStr(ChangeFileExt(WindoweeLpi, '.lpr')) + ',"line":' + IntToStr(MarkLine('tick')) + '}');
end;

procedure TTestProjectRuns.TearDown;
begin
  Call('debug_stop', '{}');
end;


{ ── Tests ────────────────────────────────────────────────────────────────── }

{ Set in the build-mode matrix as the IDE does, reported back, and removed
  again without a trace: the .lpi ends byte-identical. }
procedure TTestWindows.TestWidgetset;
var
  Before, T : string;
begin
  Before := FileText(WindoweeLpi);
  T := Call('project_set_settings', '{"widgetset":"QT5"}');
  CheckFalse(IsError(T), T);
  CheckEquals('qt5', JPath(T, 'widgetset'), T);
  CheckEquals('qt5', JPath(T, 'widgetset_override'), T);
  CheckTrue(Pos('MacroName="LCLWidgetType" Value="qt5"', FileText(WindoweeLpi)) > 0,
    'in the .lpi: ' + FileText(WindoweeLpi));
  CheckEquals('qt5', JPath(Call('project_get_settings', '{}'), 'widgetset'), 'get_settings');

  T := Call('project_set_settings', '{"widgetset":"winui3","target_os":"linux"}');
  CheckTrue(IsError(T) and (Pos('Unknown widgetset', T) > 0), T);
  T := Call('project_get_settings', '{}');
  CheckEquals('qt5', JPath(T, 'widgetset'), 'unchanged: ' + T);
  CheckEquals('', JPath(T, 'target_os'), 'nothing else changed: ' + T);

  T := Call('project_set_settings', '{"widgetset":"default"}');
  CheckFalse(IsError(T), T);
  CheckEquals('', JPath(T, 'widgetset_override'), T);
  CheckEquals('win32', JPath(T, 'widgetset'), T);
  CheckEquals(Before, FileText(WindoweeLpi), '.lpi restored');
end;

procedure TTestWindows.TestNoWindow;
var
  T : string;
begin
  T := Call('project_get_windows', '{}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('No visible window of', T) > 0, T);
end;

{ Windowed controls with their text; the TLabel has no window. }
procedure TTestWindows.TestTree;
var
  T : string;
begin
  T := Call('project_run', '{"wait_seconds":0}');
  CheckEquals('True', JPath(T, 'success'), T);
  T := WaitForWindow;
  CheckTrue(Pos('Window "MCP Windowee" 200,200 ', T) > 0, 'form: ' + T);
  CheckTrue(Pos(#10'  Button "Push me" 16,16 96x28', T) > 0, 'button: ' + T);
  CheckTrue(Pos('  Edit "edit text" 16,56 ', T) > 0, 'edit: ' + T);
  CheckEquals(0, Pos('a label', T), 'no label: ' + T);
  CheckEquals(0, Pos('not answering', T), 'answers: ' + T);
  T := Call('project_get_windows', '{"window":"no such caption"}');
  CheckTrue(Pos('No visible window', T) > 0, 'filtered: ' + T);
end;

{ An image content block after the text: a PNG no larger than max_size. }
procedure TTestWindows.TestImage;
var
  R       : THttpResult;
  D       : TJSONData;
  Content : TJSONArray;
  Png     : string;
  W, H    : Integer;
begin
  CheckEquals('True', JPath(Call('project_run', '{"wait_seconds":0}'), 'success'));
  WaitForWindow;
  R := McpRequest('POST', '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{' +
    '"name":"project_get_windows","arguments":{"image":true,"max_size":100}}}',
    ['Mcp-Session-Id: ' + GSess], nil);
  CheckEquals(200, R.Code, R.Body);
  D := GetJSON(R.Body);
  try
    Content := TJSONObject(D).Objects['result'].Arrays['content'];
    CheckEquals(2, Content.Count, 'text and one image: ' + Copy(R.Body, 1, 300));
    CheckEquals('text', TJSONObject(Content[0]).Get('type', ''));
    CheckEquals('image', TJSONObject(Content[1]).Get('type', ''));
    CheckEquals('image/png', TJSONObject(Content[1]).Get('mimeType', ''));
    Png := DecodeStringBase64(TJSONObject(Content[1]).Get('data', ''));
  finally
    D.Free;
  end;
  CheckEquals(#137'PNG', Copy(Png, 1, 4), 'PNG signature');
  { IHDR: width and height, big-endian, at offsets 16 and 20 }
  W := (Ord(Png[17]) shl 24) or (Ord(Png[18]) shl 16) or (Ord(Png[19]) shl 8) or Ord(Png[20]);
  H := (Ord(Png[21]) shl 24) or (Ord(Png[22]) shl 16) or (Ord(Png[23]) shl 8) or Ord(Png[24]);
  CheckEquals(100, Max(W, H), Format('scaled to max_size: %dx%d', [W, H]));
  CheckTrue(Min(W, H) > 20, Format('aspect kept: %dx%d', [W, H]));
end;

{ Paused in the debugger the program answers no messages; the tool must not
  wait for it. }
procedure TTestWindows.TestPaused;
var
  T     : string;
  Start : TDateTime;
begin
  T := Call('debug_set_breakpoint', '{"file":' + JsonStr(ChangeFileExt(WindoweeLpi, '.lpr')) +
    ',"line":' + IntToStr(MarkLine('tick')) + '}');
  CheckFalse(IsError(T), T);
  T := Call('debug_run', '{}');
  CheckEquals('paused', JPath(T, 'state'), T);
  Start := Now;
  T := Call('project_get_windows', '{"image":true}');
  CheckTrue(MilliSecondsBetween(Now, Start) < 5000,
    Format('took %d ms', [MilliSecondsBetween(Now, Start)]));
  CheckTrue(Pos('not answering', T) > 0, T);
  CheckTrue(Pos('Button "Push me"', T) > 0, 'tree still read: ' + T);
  CheckTrue(Pos('copied from the screen', T) > 0, T);
end;


{ A program with only a .lpr: project_open writes the .lpi next to it, and the
  project builds with the IDE; project_get_settings names the compiler }
procedure TTestProjectRuns.TestOpenProgramWithoutProject;
var
  Dir, Lpr, Lpi, T : string;
  SL               : TStringList;
  I                : Integer;
begin
  Dir := GetTempDir(False) + 'mcpbareprog' + PathDelim;
  ForceDirectories(Dir);
  Lpr := Dir + 'bare.lpr';
  Lpi := Dir + 'bare.lpi';
  SL := TStringList.Create;
  try
    SL.Text := 'program bare;' + LineEnding + 'begin' + LineEnding +
               '  WriteLn(1);' + LineEnding + 'end.' + LineEnding;
    SL.SaveToFile(Lpr);
  finally
    SL.Free;
  end;
  Call('debug_stop', '{}');
  Call('project_set_settings', '{}');  { saves a project the breakpoints modified }
  try
    { the previous test's program may still be going down }
    for I := 1 to 20 do
    begin
      T := Call('project_open', '{"file":' + JsonStr(Lpr) + '}');
      if Pos('busy', T) = 0 then Break;
      Sleep(500);
    end;
    CheckFalse(IsError(T), T);
    CheckTrue(Pos('"created_project_file" : true', T) > 0, 'wrote the .lpi: ' + T);
    CheckTrue(FileExists(Lpi), '.lpi next to the .lpr');
    T := Call('project_get_settings', '{}');
    CheckTrue(SameFileName(Lpi, JPath(T, 'project_file')), 'it is the active project: ' + T);
    CheckTrue(JPath(T, 'compiler') <> '', 'compiler named: ' + T);
    CheckTrue(JPath(T, 'fpc_version') <> '', 'FPC version named: ' + T);
    T := Call('project_build', '{}');
    CheckTrue(Pos('"success" : true', T) > 0, 'builds: ' + T);
    T := Call('project_open', '{"file":' + JsonStr(Lpr) + '}');
    CheckTrue(Pos('"already_open":true', T) > 0, 'second open: ' + T);
  finally
    Call('project_open', '{"file":' + JsonStr(WindoweeLpi) + '}');
    DeleteDirectory(Dir, False);
  end;
end;


{ debug_run on a project without DWARF info is refused before the IDE asks in a
  dialog; once it has, a program that ends at once says so, with its exit code }
procedure TTestProjectRuns.TestDebugPreflightAndExit;
var
  Dir, Lpr, T : string;
  SL          : TStringList;
  I           : Integer;
begin
  Dir := GetTempDir(False) + 'mcpexitprog' + PathDelim;
  ForceDirectories(Dir);
  Lpr := Dir + 'quits.lpr';
  SL := TStringList.Create;
  try
    SL.Text := 'program quits;' + LineEnding + 'begin' + LineEnding +
               '  Halt(3);' + LineEnding + 'end.' + LineEnding;
    SL.SaveToFile(Lpr);
  finally
    SL.Free;
  end;
  Call('debug_stop', '{}');
  Call('project_set_settings', '{}');
  try
    for I := 1 to 20 do
    begin
      T := Call('project_open', '{"file":' + JsonStr(Lpr) + '}');
      if Pos('busy', T) = 0 then Break;
      Sleep(500);
    end;
    CheckFalse(IsError(T), T);
    T := Call('project_set_settings', '{"debug_info":"none"}');
    CheckEquals('none', JPath(T, 'debug_info'), T);
    T := Call('debug_run', '{}');
    CheckTrue(IsError(T), 'refused, no dialog: ' + T);
    CheckTrue(Pos('debug_info', T) > 0, 'names the setting: ' + T);
    T := Call('project_set_settings', '{"debug_info":"bogus"}');
    CheckTrue(Pos('debug_info must be', T) > 0, T);
    T := Call('project_set_settings', '{"debug_info":"dwarf3"}');
    CheckEquals('dwarf3', JPath(T, 'debug_info'), T);
    T := Call('project_build', '{}');
    CheckTrue(Pos('"success" : true', T) > 0, 'builds: ' + T);
    T := Call('debug_run', '{"timeout_s":30}');
    CheckFalse(IsError(T), T);
    CheckEquals('exited', JPath(T, 'reason'), T);
    CheckEquals('3', JPath(T, 'exit_code'), T);
  finally
    Call('debug_stop', '{}');
    Call('project_open', '{"file":' + JsonStr(WindoweeLpi) + '}');
    DeleteDirectory(Dir, False);
  end;
end;

{ project_run answers with the output and the exit code (ADR-016), and a program that
  keeps running is read and stopped with project_run_output. }
procedure TTestProjectRuns.TestRunOutput;
var
  Dir, Lpr, T : string;
  SL          : TStringList;
  I           : Integer;
begin
  Dir := GetTempDir(False) + 'mcprunprog' + PathDelim;
  ForceDirectories(Dir);
  Lpr := Dir + 'runner.lpr';
  SL := TStringList.Create;
  try
    SL.Text :=
      'program runner;' + LineEnding +
      '{$mode objfpc}{$H+}' + LineEnding +
      'uses SysUtils;' + LineEnding +
      'begin' + LineEnding +
      '  WriteLn(''hello '', ParamStr(1), '' in '', ExtractFileName(ExcludeTrailingPathDelimiter(GetCurrentDir)));' + LineEnding +
      '  Flush(Output);' + LineEnding +
      '  WriteLn(StdErr, ''oops'');' + LineEnding +
      '  Flush(StdErr);' + LineEnding +
      '  if ParamStr(1) = ''wait'' then Sleep(60000);' + LineEnding +
      '  Halt(3);' + LineEnding +
      'end.' + LineEnding;
    SL.SaveToFile(Lpr);
  finally
    SL.Free;
  end;
  Call('debug_stop', '{}');
  Call('project_set_settings', '{}');
  try
    for I := 1 to 20 do
    begin
      T := Call('project_open', '{"file":' + JsonStr(Lpr) + '}');
      if Pos('busy', T) = 0 then Break;
      Sleep(500);
    end;
    CheckFalse(IsError(T), T);

    T := Call('project_run', '{"args":"quick","wait_seconds":30}');
    CheckFalse(IsError(T), T);
    CheckEquals('True', JPath(T, 'success'), T);
    CheckEquals('False', JPath(T, 'running'), T);
    CheckEquals('3', JPath(T, 'exit_code'), T);
    CheckTrue(Pos('hello quick in mcprunprog', JPath(T, 'stdout')) = 1, 'stdout: ' + T);
    CheckTrue(Pos('oops', JPath(T, 'stderr')) = 1, 'stderr: ' + T);
    T := Call('project_run_output', '{}');
    CheckEquals('3', JPath(T, 'exit_code'), 'kept after the end: ' + T);
    CheckEquals('', JPath(T, 'stdout'), 'already handed out: ' + T);

    T := Call('project_run', '{"args":"wait","wait_seconds":2}');
    CheckEquals('True', JPath(T, 'success'), T);
    CheckEquals('True', JPath(T, 'running'), T);
    CheckEquals('', JPath(T, 'exit_code'), 'no exit code yet: ' + T);
    CheckTrue(Pos('hello wait', JPath(T, 'stdout')) = 1, 'output so far: ' + T);
    T := Call('project_run', '{"wait_seconds":0}');
    CheckTrue(IsError(T) and (Pos('still running', T) > 0), 'one at a time: ' + T);
    T := Call('project_run_output', '{"stop":true}');
    CheckFalse(IsError(T), T);
    CheckEquals('False', JPath(T, 'running'), T);
    {$IFDEF UNIX}
    CheckEquals('137', JPath(T, 'exit_code'), 'killed: ' + T);
    {$ELSE}
    CheckEquals('1', JPath(T, 'exit_code'), T);
    {$ENDIF}
  finally
    Call('project_run_output', '{"stop":true}');
    Call('project_open', '{"file":' + JsonStr(WindoweeLpi) + '}');
    DeleteDirectory(Dir, False);
  end;
end;

{ Input for a running program: stdin text at the start, closed stdin by default, and
  project_run_input for a conversation (ADR-016). }
procedure TTestProjectRuns.TestRunInput;
var
  Dir, Lpr, T : string;
  SL          : TStringList;
  I           : Integer;
begin
  Dir := GetTempDir(False) + 'mcpinputprog' + PathDelim;
  ForceDirectories(Dir);
  Lpr := Dir + 'echoer.lpr';
  SL := TStringList.Create;
  try
    SL.Text :=
      'program echoer;' + LineEnding +
      '{$mode objfpc}{$H+}' + LineEnding +
      'var L: string;' + LineEnding +
      'begin' + LineEnding +
      '  while not EOF do begin' + LineEnding +
      '    ReadLn(L);' + LineEnding +
      '    WriteLn(''got '', L);' + LineEnding +
      '    Flush(Output);' + LineEnding +
      '  end;' + LineEnding +
      '  WriteLn(''eof'');' + LineEnding +
      '  Halt(5);' + LineEnding +
      'end.' + LineEnding;
    SL.SaveToFile(Lpr);
  finally
    SL.Free;
  end;
  Call('debug_stop', '{}');
  Call('project_set_settings', '{}');
  try
    for I := 1 to 20 do
    begin
      T := Call('project_open', '{"file":' + JsonStr(Lpr) + '}');
      if Pos('busy', T) = 0 then Break;
      Sleep(500);
    end;
    CheckFalse(IsError(T), T);

    T := Call('project_run', '{"wait_seconds":30}');
    CheckEquals('5', JPath(T, 'exit_code'), 'stdin closed by default: ' + T);
    CheckTrue(Pos('eof', JPath(T, 'stdout')) > 0, T);
    CheckTrue(IsError(Call('project_run_input', '{"text":"x"}')), 'the program has ended');

    T := Call('project_run', '{"stdin":"a\nb\n","wait_seconds":30}');
    CheckEquals('5', JPath(T, 'exit_code'), 'stdin text, then end of file: ' + T);
    CheckTrue((Pos('got a', JPath(T, 'stdout')) > 0) and (Pos('got b', JPath(T, 'stdout')) > 0) and
              (Pos('eof', JPath(T, 'stdout')) > 0), T);

    T := Call('project_run', '{"keep_stdin_open":true,"wait_seconds":2}');
    CheckEquals('True', JPath(T, 'running'), 'waits for input: ' + T);
    CheckEquals('True', JPath(T, 'stdin_open'), T);
    T := Call('project_run_input', '{"text":"hi\n","wait_seconds":10}');
    CheckFalse(IsError(T), T);
    CheckTrue(Pos('got hi', JPath(T, 'stdout')) > 0, 'the answer: ' + T);
    CheckEquals('True', JPath(T, 'running'), T);
    T := Call('project_run_input', '{"text":"one\ntwo\n","wait_seconds":10}');
    CheckTrue((Pos('got one', JPath(T, 'stdout')) > 0) and (Pos('got two', JPath(T, 'stdout')) > 0), T);
    CheckTrue(IsError(Call('project_run_input', '{}')), 'text or close');
    T := Call('project_run_input', '{"close":true,"wait_seconds":10}');
    CheckEquals('False', JPath(T, 'running'), 'end of input ends it: ' + T);
    CheckEquals('5', JPath(T, 'exit_code'), T);
    CheckTrue(Pos('eof', JPath(T, 'stdout')) > 0, T);
  finally
    Call('project_run_output', '{"stop":true}');
    Call('project_open', '{"file":' + JsonStr(WindoweeLpi) + '}');
    DeleteDirectory(Dir, False);
  end;
end;

{ A program that does not build: debug_run says so instead of answering "stopped". }
procedure TTestProjectRuns.TestDebugRunOfBrokenProgram;
var
  Dir, Lpr, T : string;
  SL          : TStringList;
  I           : Integer;
begin
  Dir := GetTempDir(False) + 'mcpbrokenprog' + PathDelim;
  ForceDirectories(Dir);
  Lpr := Dir + 'broken.lpr';
  SL := TStringList.Create;
  try
    SL.Text := 'program broken;' + LineEnding + 'begin' + LineEnding +
               '  NoSuchRoutine(1);' + LineEnding + 'end.' + LineEnding;
    SL.SaveToFile(Lpr);
  finally
    SL.Free;
  end;
  Call('debug_stop', '{}');
  Call('project_set_settings', '{}');
  try
    for I := 1 to 20 do
    begin
      T := Call('project_open', '{"file":' + JsonStr(Lpr) + '}');
      if Pos('busy', T) = 0 then Break;
      Sleep(500);
    end;
    CheckFalse(IsError(T), T);
    T := Call('debug_run', '{"timeout_s":30}');
    CheckTrue(IsError(T), 'an error, not a state: ' + T);
    CheckTrue(Pos('did not start', T) > 0, T);
    CheckTrue(Pos('project_get_compiler_errors', T) > 0, T);
  finally
    Call('debug_stop', '{}');
    Call('project_open', '{"file":' + JsonStr(WindoweeLpi) + '}');
    DeleteDirectory(Dir, False);
  end;
end;


{ project_add_file / project_remove_file, form_create and editor_get_active with a form
  open, on a generated LCL program (its .lpi is written by project_open). }
procedure TTestProjectRuns.TestProjectFilesAndFormCreate;
var
  Dir, Lpr, Extra, T : string;
  SL                 : TStringList;
  I                  : Integer;
begin
  Dir   := GetTempDir(False) + 'mcpfilesprog' + PathDelim;
  ForceDirectories(Dir);
  Lpr   := Dir + 'app.lpr';
  Extra := Dir + 'extra.pas';
  SL := TStringList.Create;
  try
    SL.Text := 'program app;' + LineEnding + '{$mode objfpc}{$H+}' + LineEnding +
               'uses Interfaces, Forms;' + LineEnding + 'begin' + LineEnding +
               '  Application.Initialize;' + LineEnding + 'end.' + LineEnding;
    SL.SaveToFile(Lpr);
    SL.Text := 'unit extra;' + LineEnding + '{$mode objfpc}{$H+}' + LineEnding +
               'interface' + LineEnding + 'implementation' + LineEnding + 'end.' + LineEnding;
    SL.SaveToFile(Extra);
  finally
    SL.Free;
  end;
  Call('debug_stop', '{}');
  Call('project_set_settings', '{}');
  try
    for I := 1 to 20 do
    begin
      T := Call('project_open', '{"file":' + JsonStr(Lpr) + '}');
      if Pos('busy', T) = 0 then Break;
      Sleep(500);
    end;
    CheckFalse(IsError(T), T);

    T := Call('project_add_file', '{"file":' + JsonStr(Extra) + '}');
    CheckFalse(IsError(T), 'add: ' + T);
    CheckTrue(Pos('extra.pas', LowerCase(Call('project_list_files', '{}'))) > 0, 'added');
    T := Call('project_remove_file', '{"file":' + JsonStr(Extra) + '}');
    CheckFalse(IsError(T), 'remove: ' + T);
    CheckEquals(0, Pos('extra.pas', LowerCase(Call('project_list_files', '{}'))), 'removed');
    CheckTrue(FileExists(Extra), 'the file itself stays on disk');

    T := Call('form_create', '{"unit_name":"UnitSecond","directory":' +
      JsonStr(ExcludeTrailingPathDelimiter(Dir)) + '}');
    CheckFalse(IsError(T), 'form_create: ' + T);
    CheckTrue(Pos('unitsecond.pas', LowerCase(Call('project_list_files', '{}'))) > 0,
      'the form unit is in the project');
    T := Call('editor_get_active', '{}');
    CheckFalse(IsError(T), 'editor_get_active with a form open: ' + T);
    CheckTrue(Pos('unitsecond', LowerCase(T)) > 0, T);
    Call('editor_save', '{"file":' + JsonStr(Dir + 'unitsecond.pas') + '}');
    CheckTrue(FileExists(Dir + 'unitsecond.pas') and FileExists(Dir + 'unitsecond.lfm'),
      'unit and form file written');
  finally
    Call('editor_revert', '{"file":' + JsonStr(Dir + 'unitsecond.pas') + '}');
    Call('editor_close', '{"file":' + JsonStr(Dir + 'unitsecond.pas') + '}');
    Call('project_set_settings', '{}');   { saves the project }
    Call('project_open', '{"file":' + JsonStr(WindoweeLpi) + '}');
    DeleteDirectory(Dir, False);
  end;
end;



{ debug_attach to a program project_run started (ADR-019): it stops in the debugger with
  its stack readable, detach lets it go on, a plain stop ends it, a wrong id is an error. }
procedure TTestProjectRuns.TestAttach;
var
  Dir, Lpr, T, Pid : string;
  SL               : TStringList;
  I                : Integer;
begin
  Dir := GetTempDir(False) + 'mcpattachprog' + PathDelim;
  ForceDirectories(Dir);
  Lpr := Dir + 'sleeper.lpr';
  SL := TStringList.Create;
  try
    SL.Text := 'program sleeper;' + LineEnding + '{$mode objfpc}{$H+}' + LineEnding +
               'uses SysUtils;' + LineEnding + 'begin' + LineEnding +
               '  Sleep(60000);' + LineEnding + 'end.' + LineEnding;
    SL.SaveToFile(Lpr);
  finally
    SL.Free;
  end;
  Call('debug_stop', '{}');
  Call('project_set_settings', '{}');
  try
    for I := 1 to 20 do
    begin
      T := Call('project_open', '{"file":' + JsonStr(Lpr) + '}');
      if Pos('busy', T) = 0 then Break;
      Sleep(500);
    end;
    CheckFalse(IsError(T), T);
    T := Call('project_set_settings', '{"debug_info":"dwarf3"}');
    CheckEquals('dwarf3', JPath(T, 'debug_info'), T);
    T := Call('project_build', '{}');
    CheckTrue(Pos('"success" : true', T) > 0, 'builds: ' + T);

    T := Call('debug_attach', '{"pid":999999,"timeout_s":5}');
    CheckTrue(IsError(T) and (Pos('did not attach', T) > 0), 'a wrong id: ' + T);
    CheckTrue(IsError(Call('debug_attach', '{}')), 'pid required');

    T := Call('project_run', '{"wait_seconds":0}');
    CheckEquals('True', JPath(T, 'success'), T);
    Pid := JPath(T, 'pid');
    CheckTrue(StrToIntDef(Pid, 0) > 0, 'pid: ' + T);
    Sleep(1000);

    T := Call('debug_attach', '{"pid":' + Pid + ',"timeout_s":5}');
    CheckFalse(IsError(T), 'attach: ' + T);
    CheckTrue((JPath(T, 'state') = 'paused') or (JPath(T, 'state') = 'running'), T);
    if JPath(T, 'state') = 'running' then
    begin
      T := Call('debug_pause', '{}');
      CheckEquals('paused', JPath(T, 'state'), 'pause: ' + T);
    end;
    T := Call('debug_get_call_stack', '{"max_frames":30}');
    CheckTrue(Pos('sleeper.lpr', LowerCase(T)) > 0, 'the program''s own frame: ' + T);
    CheckTrue(IsError(Call('debug_attach', '{"pid":' + Pid + '}')), 'one session at a time');

    T := Call('debug_stop', '{"detach":true}');
    CheckFalse(IsError(T), T);
    for I := 1 to 20 do
    begin
      if JPath(Call('debug_get_state', '{}'), 'state') = 'idle' then Break;
      Sleep(250);
    end;
    T := Call('project_run_output', '{"wait_seconds":0}');
    CheckEquals('True', JPath(T, 'running'), 'still running after detach: ' + T);

    T := Call('debug_attach', '{"pid":' + Pid + ',"timeout_s":5}');
    CheckFalse(IsError(T), 'attach again: ' + T);
    Call('debug_stop', '{}');
    T := Call('project_run_output', '{"wait_seconds":10}');
    CheckEquals('False', JPath(T, 'running'), 'a plain stop ends the program: ' + T);
  finally
    Call('debug_stop', '{}');
    Call('project_run_output', '{"stop":true}');
    Call('project_set_settings', '{}');
    Call('project_open', '{"file":' + JsonStr(WindoweeLpi) + '}');
    { the folder stays: the debugger opens its source in an editor, and deleting a file the
      IDE still holds raises a dialog that blocks it (Linux); the next run overwrites it }
  end;
end;
end.
