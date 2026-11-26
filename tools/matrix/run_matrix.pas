{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
{$mode objfpc}{$H+}
program run_matrix;

{ Runs the plugin's test suite on every Lazarus version of the matrix and prints one table.

    instantfpc tools/matrix/run_matrix.pas [windows|linux|all|summary]      (from anywhere in the repo)

  For the commit that is checked out:
    Windows (each WIN_NAMES entry): a copy of HEAD (git archive) is built into that Lazarus's IDE
      with lazbuild --build-ide=, the IDE is started with the test hooks and the fixture project, the
      full suite runs (hooks off in the test program), then the progress suite alone (hooks on), then
      the IDE is closed and the project files the IDE rewrote are restored.
    Linux: not in the repository.  LINUX_DRIVER in matrix.conf is a command that runs the suite on
      the Linux machines of LINUX_VERSIONS while the Windows runs go on, and leaves
      tools/matrix/out/linux<V>.full.txt and linux<V>.prog.txt (the output of the test program, full
      run and progress suite) for each version; it exits with 0 when it ran.  Without it there are
      no Linux rows.
  Results go to tools/matrix/out/.  "summary" only prints the table of the last run.  Exit code 1 if
  anything failed or is missing.  MATRIX_ALLOW_DIRTY=1 allows uncommitted changes (HEAD is what is
  tested on Windows).

  Settings: tools/matrix/matrix.conf (NAME=value lines, see matrix.conf.example). }

uses
  Windows, Classes, SysUtils, Process, fphttpclient;

var
  Conf    : TStringList;
  Repo    : string;       { repository root, native separators }
  OutDir  : string;
  Bad     : Boolean = False;
  IdeHandle : THandle = 0;   { the IDE of the Windows run in progress }

function Cfg(const AKey: string): string;
begin
  Result := Conf.Values[AKey];
end;

function FindExe(const AName: string): string;
begin
  if (Pos('\', AName) > 0) or (Pos('/', AName) > 0) then Exit(AName);
  Result := FileSearch(AName + '.exe', GetEnvironmentVariable('PATH'));
  if Result = '' then Result := AName;
end;

{ The environment of this process with changes: 'K=V' sets, '-K' removes. }
function MakeEnv(const AMods: array of string): TStringList;
var
  I, J : Integer;
  M, Nm : string;
begin
  Result := TStringList.Create;
  for I := 1 to GetEnvironmentVariableCount do Result.Add(GetEnvironmentString(I));
  for M in AMods do
  begin
    if M = '' then Continue;
    if M[1] = '-' then
    begin
      J := Result.IndexOfName(Copy(M, 2, MaxInt));
      if J >= 0 then Result.Delete(J);
    end
    else
    begin
      Nm := Copy(M, 1, Pos('=', M) - 1);
      J := Result.IndexOfName(Nm);
      if J >= 0 then Result[J] := M else Result.Add(M);
    end;
  end;
end;

{ Runs a program to its end (or ATimeoutSec: then it is killed), returns the exit code; what it
  wrote (both streams) is in AOutput and, when AOutFile is not empty, in that file. }
function Run(const AExe: string; const AArgs: array of string; const ADir: string;
  const AMods: array of string; ATimeoutSec: Integer; const AOutFile: string;
  out AOutput: string): Integer;
var
  P   : TProcess;
  E   : TStringList;
  S   : TMemoryStream;
  Buf : array[0..16383] of Byte;
  N   : Integer;
  T0  : TDateTime;
  A   : string;
begin
  P := TProcess.Create(nil);
  E := MakeEnv(AMods);
  S := TMemoryStream.Create;
  try
    P.Executable := FindExe(AExe);
    for A in AArgs do P.Parameters.Add(A);
    if ADir <> '' then P.CurrentDirectory := ADir;
    P.Environment.Assign(E);
    P.Options := [poUsePipes, poStderrToOutput, poNoConsole];
    P.Execute;
    T0 := Now;
    repeat
      N := P.Output.NumBytesAvailable;
      if N > 0 then
      begin
        if N > SizeOf(Buf) then N := SizeOf(Buf);
        N := P.Output.Read(Buf, N);
        S.Write(Buf, N);
      end
      else if P.Running then Sleep(50);
      if (ATimeoutSec > 0) and P.Running and (Now - T0 > ATimeoutSec / 86400) then P.Terminate(1);
    until (not P.Running) and (P.Output.NumBytesAvailable = 0);
    Result := P.ExitStatus;
    SetString(AOutput, PChar(S.Memory), S.Size);
    if AOutFile <> '' then S.SaveToFile(AOutFile);
  finally
    S.Free;
    E.Free;
    P.Free;
  end;
end;

function RunQ(const AExe: string; const AArgs: array of string; const ADir, AOutFile: string): Integer;
var
  Dummy: string;
begin
  Result := Run(AExe, AArgs, ADir, [], 0, AOutFile, Dummy);
end;

function Git(const AArgs: array of string; out AOutput: string): Integer;
begin
  Result := Run('git', AArgs, Repo, [], 120, '', AOutput);
  AOutput := Trim(AOutput);
end;

function Say(const AText: string): string;
begin
  WriteLn(AText);
  Flush(Output);
  Result := AText;
end;

function Fail(const AText: string): Boolean;
begin
  WriteLn(ErrOutput, AText);
  Bad := True;
  Result := False;
end;

{ ── Windows ──────────────────────────────────────────────────────────────── }

procedure KillIde(const ALazDir: string);
var
  Dummy: string;
begin
  if IdeHandle <> 0 then
  begin
    TerminateProcess(IdeHandle, 0);
    CloseHandle(IdeHandle);
    IdeHandle := 0;
  end;
  { any IDE of that Lazarus folder that is left over; never the one the user works in }
  Run('powershell', ['-NoProfile', '-Command',
    'Get-Process lazarus -ErrorAction SilentlyContinue | Where-Object { $_.Path -like ''*' +
    ExtractFileName(ExcludeTrailingPathDelimiter(ALazDir)) + '*'' } | Stop-Process -Force'],
    '', [], 60, '', Dummy);
  Sleep(3000);
end;

function PortUp(APort: string): Boolean;
var
  C: TFPHTTPClient;
begin
  Result := False;
  C := TFPHTTPClient.Create(nil);
  try
    C.IOTimeout := 3000;
    try
      C.Get('http://127.0.0.1:' + APort + '/mcp');
      Result := True;
    except
      on EHTTPClient do Result := True;    { any answer: the server is there }
      on Exception do Result := False;
    end;
  finally
    C.Free;
  end;
end;

const
  HIDDEN_DESKTOP = 'mcpmatrix';

var
  GHideDesktop : THandle = 0;

{ The hidden desktop, made once; 0 when Windows refuses (the run then goes on the user's desktop,
  with MATRIX_VISIBLE=1 it does so on purpose). }
function HideDesktop: THandle;
begin
  if (GHideDesktop = 0) and (GetEnvironmentVariable('MATRIX_VISIBLE') = '') then
    GHideDesktop := CreateDesktop(HIDDEN_DESKTOP, nil, nil, 0, GENERIC_ALL, nil);
  Result := GHideDesktop;
end;

{ Starts the IDE with AEnv as its environment.  The IDE, and the programs it starts (windowee, the
  debuggee), get a desktop of their own: their windows never appear on the user's screen and never
  take the focus from whoever is typing.  (TProcess.Desktop does nothing in FPC 3.2.2: the call is
  made here.) }
function StartIde(const AExe: string; const AArgs: array of string; AEnv: TStrings): Boolean;
var
  SI    : TStartupInfoA;
  PI    : TProcessInformation;
  Cmd, Block, Desk, A : string;
  I     : Integer;
begin
  Cmd := '"' + AExe + '"';
  for A in AArgs do Cmd := Cmd + ' "' + A + '"';
  Block := '';
  for I := 0 to AEnv.Count - 1 do Block := Block + AEnv[I] + #0;
  Block := Block + #0;
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  Desk := '';
  if HideDesktop <> 0 then
  begin
    Desk := 'winsta0\' + HIDDEN_DESKTOP;
    SI.lpDesktop := PChar(Desk);
  end;
  UniqueString(Cmd);
  Result := CreateProcessA(PChar(AExe), PChar(Cmd), nil, nil, False, 0, @Block[1], nil, SI, PI);
  if Result then
  begin
    CloseHandle(PI.hThread);
    IdeHandle := PI.hProcess;
  end;
end;

var
  GDeskWindows : Integer = 0;

function CountWindow(AWnd: HWND; ALParam: LPARAM): WINBOOL; stdcall;
begin
  Inc(GDeskWindows);
  Result := True;
end;

{ How many windows are on the hidden desktop: the proof that the IDE is there. }
function HiddenDesktopWindows: Integer;
begin
  GDeskWindows := 0;
  if GHideDesktop <> 0 then EnumDesktopWindows(GHideDesktop, @CountWindow, 0);
  Result := GDeskWindows;
end;

function WinOne(const AName: string): Boolean;
var
  Laz, Pcp, Port, W, Opt, Dummy, Tar : string;
  I : Integer;
  Up : Boolean;
  Args : TStringList;
begin
  Result := False;
  Laz  := ExcludeTrailingPathDelimiter(Cfg('WIN_' + AName + '_LAZ'));
  Pcp  := Cfg('WIN_' + AName + '_PCP');
  Port := Cfg('WIN_' + AName + '_PORT');
  W    := OutDir + 'pl' + AName;
  Opt  := Pcp + '\mcpassistantoptions.xml';
  Git(['rev-parse', '--short', 'HEAD'], Dummy);
  Say('== Windows ' + AName + ': refresh the copy of ' + Dummy);
  KillIde(Laz);
  if DirectoryExists(W) then
  begin
    RunQ('cmd', ['/c', 'rd', '/s', '/q', W], '', '');
    if DirectoryExists(W) then Exit(Fail('cannot remove ' + W + ' (a process holds it)'));
  end;
  ForceDirectories(W);
  Tar := OutDir + 'pl' + AName + '.tar';
  Git(['archive', '-o', Tar, 'HEAD'], Dummy);
  RunQ('tar', ['-xf', Tar, '-C', W], '', '');
  DeleteFile(Tar);
  { the IDE with the plugin: add the package, then build }
  if (RunQ(Laz + '\lazbuild.exe', ['--pcp=' + Pcp, '--lazarusdir=' + Laz, '--add-package', 'src\lazmcpassistant.lpk'],
        W, OutDir + 'win' + AName + '.build.log') <> 0) or
     (RunQ(Laz + '\lazbuild.exe', ['--pcp=' + Pcp, '--lazarusdir=' + Laz, '--build-ide='],
        W, OutDir + 'win' + AName + '.build2.log') <> 0) then
    Exit(Fail('IDE build failed, see ' + OutDir + 'win' + AName + '.build*.log'));
  Say('== Windows ' + AName + ': IDE built, starting it');
  Args := MakeEnv(['MCP_TEST_HOOKS=1']);
  try
    if not StartIde(Laz + '\lazarus.exe',
         ['--pcp=' + Pcp, '--no-splash-screen', '--force-new-instance',
          Repo + '\tests\windowee\mcpwindowee.lpi'], Args) then
      Exit(Fail('could not start ' + Laz + '\lazarus.exe (error ' + IntToStr(GetLastError) + ')'));
  finally
    Args.Free;
  end;
  Up := False;
  for I := 1 to 60 do
  begin
    Up := PortUp(Port);
    if Up then Break;
    Sleep(5000);
  end;
  if not Up then
  begin
    KillIde(Laz);
    Exit(Fail('the IDE''s server did not come up on port ' + Port));
  end;
  Sleep(25000);
  if GHideDesktop = 0 then
    Say('== Windows ' + AName + ': on the user''s desktop')
  else
    Say('== Windows ' + AName + ': ' + IntToStr(HiddenDesktopWindows) + ' windows on the hidden desktop');
  Say('== Windows ' + AName + ': full suite');
  Run(Repo + '\tests\mcpserver_tests.exe', ['--all', '--format=plain'], Repo + '\tests',
    ['-MCP_TEST_HOOKS', 'MCP_OPTIONS_FILE=' + Opt, 'MCP_DEBUG_TESTS=1'], 1500,
    OutDir + 'win' + AName + '.full.txt', Dummy);
  Say('== Windows ' + AName + ': progress suite');
  Run(Repo + '\tests\mcpserver_tests.exe', ['--suite=TTestProgress', '--format=plain'], Repo + '\tests',
    ['MCP_TEST_HOOKS=1', 'MCP_OPTIONS_FILE=' + Opt, 'MCP_DEBUG_TESTS=1'], 600,
    OutDir + 'win' + AName + '.prog.txt', Dummy);
  KillIde(Laz);
  { a newer IDE rewrites these when it opens or closes them }
  Git(['checkout', '--', 'tests/windowee', 'tests/debuggee', 'tests/fixtures'], Dummy);
  Result := True;
end;

procedure Windows;
var
  Names : TStringList;
  N, Dummy : string;
begin
  Say('== building the test program');
  if RunQ(Cfg('MAIN_LAZBUILD'), ['--pcp=' + Cfg('MAIN_PCP'), 'tests\mcpserver_tests.lpi'], Repo,
       OutDir + 'testbuild.log') <> 0 then
  begin
    Fail('the test program did not build, see ' + OutDir + 'testbuild.log');
    Exit;
  end;
  Names := TStringList.Create;
  try
    Names.Delimiter := ' ';
    Names.StrictDelimiter := True;
    Names.DelimitedText := Cfg('WIN_NAMES');
    for N in Names do
      if N <> '' then WinOne(N);
  finally
    Names.Free;
  end;
  Dummy := '';
end;

{ ── Linux ────────────────────────────────────────────────────────────────── }

{ How a Linux machine is reached is the maintainer's own business and not in the repository:
  LINUX_DRIVER in matrix.conf is a command (run from the repository root, in parallel with the Windows
  runs) that, for each version of LINUX_VERSIONS, writes tools\matrix\out\linux<V>.full.txt and
  linux<V>.prog.txt, and exits with 0 when it ran.  Its output goes to tools\matrix\out\linux.log. }

var
  LinuxProc : TProcess = nil;

function LinuxVersions: TStringList;
begin
  Result := TStringList.Create;
  Result.Delimiter := ' ';
  Result.StrictDelimiter := True;
  Result.DelimitedText := Cfg('LINUX_VERSIONS');
end;

function LinuxStart(AAskedFor: Boolean): Boolean;
var
  V     : string;
  Batch : TStringList;
begin
  Result := False;
  if Cfg('LINUX_DRIVER') = '' then
  begin
    if AAskedFor then
      Exit(Fail('no LINUX_DRIVER in tools\matrix\matrix.conf: there is no Linux run (see docs/testing.md)'));
    Say('== Linux: no LINUX_DRIVER in matrix.conf, Windows only');
    Exit(True);
  end;
  { results of an earlier run must not pass for this one's }
  for V in LinuxVersions do
    if V <> '' then
    begin
      DeleteFile(OutDir + 'linux' + V + '.full.txt');
      DeleteFile(OutDir + 'linux' + V + '.prog.txt');
    end;
  { the command goes through a batch file: its redirection needs no quoting then }
  Batch := TStringList.Create;
  try
    Batch.Add('@' + Cfg('LINUX_DRIVER') + ' > "' + OutDir + 'linux.log" 2>&1');
    Batch.SaveToFile(OutDir + 'linux_driver.cmd');
  finally
    Batch.Free;
  end;
  LinuxProc := TProcess.Create(nil);
  LinuxProc.Executable := 'cmd.exe';
  LinuxProc.Parameters.Add('/c');
  LinuxProc.Parameters.Add(OutDir + 'linux_driver.cmd');
  LinuxProc.CurrentDirectory := Repo;
  LinuxProc.Options := [poNoConsole];
  LinuxProc.ShowWindow := swoHide;
  try
    LinuxProc.Execute;
  except
    on E: Exception do
      Exit(Fail('the Linux driver did not start: ' + E.Message));
  end;
  Say('== Linux driver started (its output: tools\matrix\out\linux.log)');
  Result := True;
end;

procedure LinuxWait;
var
  L : TStringList;
begin
  if LinuxProc = nil then Exit;
  LinuxProc.WaitOnExit;
  if FileExists(OutDir + 'linux.log') then
  begin
    L := TStringList.Create;
    try
      L.LoadFromFile(OutDir + 'linux.log');
      WriteLn(L.Text);
    finally
      L.Free;
    end;
  end;
  if LinuxProc.ExitStatus <> 0 then
    Fail('the Linux driver ended with exit code ' + IntToStr(LinuxProc.ExitStatus));
  FreeAndNil(LinuxProc);
end;

{ ── The table ────────────────────────────────────────────────────────────── }

{ The number at the end of the first line that starts with APrefix, '-' when there is none. }
function CountOf(const AFile, APrefix: string): string;
var
  L    : TStringList;
  I, J : Integer;
  S    : string;
begin
  Result := '-';
  if not FileExists(AFile) then Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(AFile);
    for I := 0 to L.Count - 1 do
    begin
      S := Trim(L[I]);
      if Pos(APrefix, S) <> 1 then Continue;
      J := Length(S);
      while (J > 0) and (S[J] in ['0'..'9']) do Dec(J);
      if J < Length(S) then Result := Copy(S, J + 1, MaxInt);
      Exit;
    end;
  finally
    L.Free;
  end;
end;

procedure Row(const ALabel, AFull, AProg: string);
var
  T, E, F, PT, PE, PF : string;
begin
  T  := CountOf(AFull, 'Number of run tests');
  E  := CountOf(AFull, 'Number of errors');
  F  := CountOf(AFull, 'Number of failures');
  PT := CountOf(AProg, 'Number of run tests');
  PE := CountOf(AProg, 'Number of errors');
  PF := CountOf(AProg, 'Number of failures');
  WriteLn(Format('%-14s %6s %6s %6s   %4s %4s %4s', [ALabel, T, E, F, PT, PE, PF]));
  if (T = '-') or (PT = '-') or (E <> '0') or (F <> '0') or (PE <> '0') or (PF <> '0') then Bad := True;
end;

function Usual(const ALine: string): Boolean;
const
  Words: array[0..8] of string = ('opt-in', 'opm', 'instantfpc', 'mcp_consent', 'mcp_fpc',
    'mcp_test_hooks', 'installing packages', 'no second thread', 'xx');
var
  W, Low : string;
begin
  Low := LowerCase(ALine);
  Result := False;
  for W in Words do
    if Pos(W, Low) > 0 then Exit(True);
end;

procedure Summary;
var
  Ns, Vs, Files : TStringList;
  N, V, Hash : string;
  SR : TSearchRec;
  L  : TStringList;
  I  : Integer;
begin
  Git(['rev-parse', '--short', 'HEAD'], Hash);
  WriteLn('commit ', Hash);
  WriteLn(Format('%-14s %6s %6s %6s   %4s %4s %4s', ['', 'tests', 'errors', 'fails', 'prog', 'errs', 'fails']));
  Ns := TStringList.Create;
  Ns.Delimiter := ' ';
  Ns.StrictDelimiter := True;
  Ns.DelimitedText := Cfg('WIN_NAMES');
  for N in Ns do
    if N <> '' then Row('Windows ' + N, OutDir + 'win' + N + '.full.txt', OutDir + 'win' + N + '.prog.txt');
  Ns.Free;
  Vs := LinuxVersions;
  for V in Vs do
    if V <> '' then Row('Linux ' + V, OutDir + 'linux' + V + '.full.txt', OutDir + 'linux' + V + '.prog.txt');
  Vs.Free;
  WriteLn('-- failed or ignored tests that are not the usual opt-in ones:');
  Files := TStringList.Create;
  try
    if FindFirst(OutDir + '*.txt', faAnyFile, SR) = 0 then
    begin
      repeat
        Files.Add(SR.Name);
      until FindNext(SR) <> 0;
      FindClose(SR);
    end;
    Files.Sort;
    for N in Files do
    begin
      L := TStringList.Create;
      try
        L.LoadFromFile(OutDir + N);
        for I := 0 to L.Count - 1 do
          if (Pos('Message:', Trim(L[I])) = 1) and not Usual(L[I]) then
            WriteLn(N, ': ', Copy(Trim(L[I]), 1, 220));
      finally
        L.Free;
      end;
    end;
  finally
    Files.Free;
  end;
end;

{ ── Main ─────────────────────────────────────────────────────────────────── }

var
  What, Top : string;
begin
  What := ParamStr(1);
  if What = '' then What := 'all';
  Repo := '';
  if Run('git', ['rev-parse', '--show-toplevel'], GetCurrentDir, [], 30, '', Top) <> 0 then
  begin
    WriteLn(ErrOutput, 'run it from inside the repository');
    Halt(2);
  end;
  Repo := StringReplace(Trim(Top), '/', '\', [rfReplaceAll]);
  OutDir := Repo + '\tools\matrix\out\';
  ForceDirectories(OutDir);
  Conf := TStringList.Create;
  if not FileExists(Repo + '\tools\matrix\matrix.conf') then
  begin
    WriteLn(ErrOutput, 'no tools\matrix\matrix.conf: copy matrix.conf.example and adjust it');
    Halt(2);
  end;
  Conf.LoadFromFile(Repo + '\tools\matrix\matrix.conf');
  { the test program is built from the working tree and the IDEs from HEAD: both must be the same }
  if (What <> 'summary') and (GetEnvironmentVariable('MATRIX_ALLOW_DIRTY') = '') then
    if Git(['diff', '--quiet'], Top) <> 0 then
    begin
      WriteLn(ErrOutput, 'uncommitted changes in tracked files: commit first (the matrix tests HEAD), or set MATRIX_ALLOW_DIRTY=1');
      Halt(2);
    end;
  if What = 'windows' then Windows
  else if What = 'linux' then begin if LinuxStart(True) then LinuxWait; end
  else if What = 'all' then
  begin
    if LinuxStart(False) then begin Windows; LinuxWait; end;
  end
  else if What <> 'summary' then
  begin
    WriteLn(ErrOutput, 'usage: run_matrix.pas [windows|linux|all|summary]');
    Halt(2);
  end;
  Summary;
  if Bad then Halt(1);
end.
