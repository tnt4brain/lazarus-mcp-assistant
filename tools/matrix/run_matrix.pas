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
    Linux (each LINUX_VERSIONS entry): linrun.sh is put on the box and run there, one version after
      the other, while the Windows runs go on.  The tree must have been sent first (git_serve start,
      then on the box, in /root/mcp-code: git fetch mcp && git reset --hard refs/remotes/mcp/snapshot);
      the script compares the sources of HEAD with the box's and stops if they differ.
  Results go to tools/matrix/out/.  "summary" only prints the table of the last run.  Exit code 1 if
  anything failed or is missing.  MATRIX_ALLOW_DIRTY=1 allows uncommitted changes (HEAD is what is
  tested on Windows; the Linux comparison then says whether the box has the working tree or not).

  Settings: tools/matrix/matrix.conf (NAME=value lines, see matrix.conf.example). }

uses
  Classes, SysUtils, Process, fphttpclient, base64, sha1;

var
  Conf    : TStringList;
  Repo    : string;       { repository root, native separators }
  OutDir  : string;
  Bad     : Boolean = False;
  IdeProc : TProcess = nil;

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
  if Assigned(IdeProc) then
  begin
    if IdeProc.Running then IdeProc.Terminate(0);
    FreeAndNil(IdeProc);
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
  IdeProc := TProcess.Create(nil);
  IdeProc.Executable := Laz + '\lazarus.exe';
  IdeProc.Parameters.Add('--pcp=' + Pcp);
  IdeProc.Parameters.Add('--no-splash-screen');
  IdeProc.Parameters.Add('--force-new-instance');
  IdeProc.Parameters.Add(Repo + '\tests\windowee\mcpwindowee.lpi');
  Args := MakeEnv(['MCP_TEST_HOOKS=1']);
  try
    IdeProc.Environment.Assign(Args);
  finally
    Args.Free;
  end;
  IdeProc.Options := [poNoConsole];
  IdeProc.Execute;
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

{ The script runs in the container: it goes over as base64, so no quoting can go wrong. }
function Lx(const AScript: string; ATimeoutMs: Integer = 60000): string;
var
  C: TFPHTTPClient;
  B: string;
begin
  B := EncodeStringBase64(StringReplace(AScript, #13, '', [rfReplaceAll]) + #10);
  C := TFPHTTPClient.Create(nil);
  try
    C.IOTimeout := ATimeoutMs;
    C.AddHeader('Content-Type', 'application/json');
    C.RequestBody := TStringStream.Create('{"command":"echo ' + B + ' | base64 -d | podman exec -i ' +
      Cfg('LINUX_CONTAINER') + ' bash"}');
    try
      Result := C.Post(Cfg('LINUX_EXECUTOR'));
    finally
      C.RequestBody.Free;
    end;
  finally
    C.Free;
  end;
end;

function CompareBytes(List: TStringList; I, J: Integer): Integer;
begin
  Result := CompareStr(List[I], List[J]);
end;

{ SHA-1 over the sources (sorted by name, carriage returns left out): the box computes the same. }
function SourceHash: string;
var
  Names : TStringList;
  Ctx   : TSHA1Context;
  Dig   : TSHA1Digest;
  S     : TFileStream;
  Buf   : array of Byte;
  Clean : array of Byte;
  I, J, N, K : Integer;
  Text  : string;
begin
  Git(['ls-files', 'src/*.pas', 'tests/*.pas', 'src/*.lpk'], Text);
  Names := TStringList.Create;
  try
    Names.Text := StringReplace(Text, #13, '', [rfReplaceAll]);
    Names.CustomSort(@CompareBytes);
    SHA1Init(Ctx);
    for I := 0 to Names.Count - 1 do
    begin
      if Names[I] = '' then Continue;
      S := TFileStream.Create(Repo + '\' + StringReplace(Names[I], '/', '\', [rfReplaceAll]), fmOpenRead or fmShareDenyNone);
      try
        N := S.Size;
        SetLength(Buf, N);
        SetLength(Clean, N);
        if N > 0 then S.ReadBuffer(Buf[0], N);
      finally
        S.Free;
      end;
      K := 0;
      for J := 0 to N - 1 do
        if Buf[J] <> 13 then begin Clean[K] := Buf[J]; Inc(K); end;
      if K > 0 then SHA1Update(Ctx, Clean[0], K);
    end;
    SHA1Final(Ctx, Dig);
    Result := LowerCase(SHA1Print(Dig));
  finally
    Names.Free;
  end;
end;

function LinuxVersions: TStringList;
begin
  Result := TStringList.Create;
  Result.Delimiter := ' ';
  Result.StrictDelimiter := True;
  Result.DelimitedText := Cfg('LINUX_VERSIONS');
end;

function LinuxStart: Boolean;
var
  Mine, Theirs, Dummy, Script, List, V : string;
  Vs : TStringList;
  F  : TStringList;
begin
  Result := False;
  if GetEnvironmentVariable('MATRIX_ALLOW_DIRTY') = '' then
    if Git(['diff', '--quiet'], Dummy) <> 0 then
      Exit(Fail('uncommitted changes in tracked files: commit first (the matrix tests HEAD), or set MATRIX_ALLOW_DIRTY=1'));
  Mine := SourceHash;
  Theirs := Trim(Lx('cd /root/mcp-code && git ls-files ''src/*.pas'' ''tests/*.pas'' ''src/*.lpk'' | LC_ALL=C sort | ' +
    'xargs -d ''\n'' cat | tr -d ''\r'' | sha1sum | cut -c1-40'));
  if Mine <> Theirs then
    Exit(Fail('the sources on the box (' + Theirs + ') are not these (' + Mine + '): git_serve start, then on the box' + LineEnding +
      '  cd /root/mcp-code && git fetch mcp && git reset --hard refs/remotes/mcp/snapshot'));
  F := TStringList.Create;
  try
    F.LoadFromFile(Repo + '\tools\matrix\linrun.sh');
    Script := StringReplace(F.Text, #13, '', [rfReplaceAll]);
  finally
    F.Free;
  end;
  Lx('echo ' + EncodeStringBase64(Script) + ' | base64 -d > /root/linrun.sh && chmod +x /root/linrun.sh; ' +
     'rm -f /root/jx*.done');
  Vs := LinuxVersions;
  try
    List := '';
    for V in Vs do
      if V <> '' then List := List + ' /root/linrun.sh ' + V + ';';
  finally
    Vs.Free;
  end;
  Lx('(setsid nohup sh -c ''' + List + ''' </dev/null >/root/linall.log 2>&1 &); sleep 1; echo started');
  Say('== Linux started: ' + Cfg('LINUX_VERSIONS'));
  Result := True;
end;

procedure LinuxWait;
var
  Vs : TStringList;
  V  : string;
  I  : Integer;
  Done : Boolean;

  procedure Save(const AFile, AText: string);
  var
    L: TStringList;
  begin
    L := TStringList.Create;
    try
      L.Text := AText;
      L.SaveToFile(AFile);
    finally
      L.Free;
    end;
  end;

begin
  Vs := LinuxVersions;
  try
    for V in Vs do
    begin
      if V = '' then Continue;
      Done := False;
      for I := 1 to 300 do
      begin
        if Trim(Lx('cat /root/jx' + V + '.done 2>/dev/null', 30000)) <> '' then begin Done := True; Break; end;
        Sleep(20000);
      end;
      if not Done then Fail('Linux ' + V + ' did not finish');
      Save(OutDir + 'linux' + V + '.full.txt', Lx('cat /root/tx' + V + '.txt', 120000));
      Save(OutDir + 'linux' + V + '.prog.txt', Lx('cat /root/tp' + V + '.txt', 60000));
      Say('== Linux ' + V + ': ' + Trim(Lx('cat /root/jx' + V + '.done', 30000)));
    end;
  finally
    Vs.Free;
  end;
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
  if What = 'windows' then Windows
  else if What = 'linux' then begin if LinuxStart then LinuxWait; end
  else if What = 'all' then
  begin
    if LinuxStart then begin Windows; LinuxWait; end;
  end
  else if What <> 'summary' then
  begin
    WriteLn(ErrOutput, 'usage: run_matrix.pas [windows|linux|all|summary]');
    Halt(2);
  end;
  Summary;
  if Bad then Halt(1);
end.
