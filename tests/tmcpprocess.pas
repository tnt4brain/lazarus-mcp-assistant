{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TMcpProcess;

{ McpRunCapture (McpProcess.pas): exit code, merged output, standard input, environment,
  timeout, a program that is not there, and output larger than a pipe holds. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, McpProcess;

type
  TTestRunCapture = class(TTestCase)
  private
    { the system shell: the program and the arguments that run a command line }
    procedure Shell(const ACommand: string; out AExe: string; out AArgs: TStringArray);
  published
    procedure TestOutputAndExitCode;
    procedure TestExitCodeIsReturned;
    procedure TestStderrIsMerged;
    procedure TestInputReachesTheChild;
    procedure TestEnvironmentIsSetAndOursKept;
    procedure TestTimeoutStopsTheChild;
    procedure TestMissingProgram;
    procedure TestOutputLargerThanAPipe;
    procedure TestWorkDir;
  end;

implementation

procedure TTestRunCapture.Shell(const ACommand: string; out AExe: string;
  out AArgs: TStringArray);
begin
  AArgs := nil;
  {$IFDEF WINDOWS}
  AExe := GetEnvironmentVariable('ComSpec');
  if AExe = '' then AExe := 'cmd.exe';
  McpAddArg(AArgs, '/c');
  {$ELSE}
  AExe := '/bin/sh';
  McpAddArg(AArgs, '-c');
  {$ENDIF}
  McpAddArg(AArgs, ACommand);
end;

procedure TTestRunCapture.TestOutputAndExitCode;
var
  Exe, Got : string;
  Args     : TStringArray;
  Code     : Integer;
begin
  Shell('echo hello', Exe, Args);
  AssertTrue('ended', McpRunCapture(Exe, Args, '', Got, Code) = reExited);
  AssertEquals('exit code', 0, Code);
  AssertEquals('output', 'hello', Trim(Got));
end;

procedure TTestRunCapture.TestExitCodeIsReturned;
var
  Exe, Got : string;
  Args     : TStringArray;
  Code     : Integer;
begin
  Shell('exit 7', Exe, Args);
  AssertTrue('ended', McpRunCapture(Exe, Args, '', Got, Code) = reExited);
  AssertEquals('exit code', 7, Code);
end;

procedure TTestRunCapture.TestStderrIsMerged;
var
  Exe, Got : string;
  Args     : TStringArray;
  Code     : Integer;
begin
  Shell('echo to_err 1>&2', Exe, Args);
  AssertTrue('ended', McpRunCapture(Exe, Args, '', Got, Code) = reExited);
  AssertTrue('stderr text is in the output: ' + Got, Pos('to_err', Got) > 0);
end;

procedure TTestRunCapture.TestInputReachesTheChild;
var
  Exe, Got : string;
  Args     : TStringArray;
  Code     : Integer;
begin
  {$IFDEF WINDOWS}
  Shell('findstr "^"', Exe, Args);
  {$ELSE}
  Shell('cat', Exe, Args);
  {$ENDIF}
  AssertTrue('ended', McpRunCapture(Exe, Args, '', Got, Code, 0, 'from stdin') = reExited);
  AssertTrue('input echoed: ' + Got, Pos('from stdin', Got) > 0);
end;

procedure TTestRunCapture.TestEnvironmentIsSetAndOursKept;
var
  Exe, Got : string;
  Args     : TStringArray;
  Env      : TStringArray;
  Code     : Integer;
begin
  Env := nil;
  McpAddArg(Env, 'MCP_RUN_TEST=first');
  McpAddArg(Env, 'MCP_RUN_TEST=second');   { the same name again: replaced, not doubled }
  {$IFDEF WINDOWS}
  Shell('echo %MCP_RUN_TEST% %PATH%', Exe, Args);
  {$ELSE}
  Shell('echo $MCP_RUN_TEST $PATH', Exe, Args);
  {$ENDIF}
  AssertTrue('ended', McpRunCapture(Exe, Args, '', Got, Code, 0, '', Env) = reExited);
  AssertTrue('the value is set: ' + Got, Pos('second', Got) > 0);
  AssertTrue('and only once: ' + Got, Pos('first', Got) = 0);
  AssertTrue('our own PATH is still there: ' + Got, Length(Trim(Got)) > Length('second'));
end;

procedure TTestRunCapture.TestTimeoutStopsTheChild;
var
  Exe, Got : string;
  Args     : TStringArray;
  Code     : Integer;
  Started  : QWord;
begin
  {$IFDEF WINDOWS}
  Shell('ping -n 30 127.0.0.1', Exe, Args);
  {$ELSE}
  Shell('sleep 30', Exe, Args);
  {$ENDIF}
  Started := GetTickCount64;
  AssertTrue('timed out', McpRunCapture(Exe, Args, '', Got, Code, 500) = reTimedOut);
  AssertTrue('stopped well before the child ended', GetTickCount64 - Started < 15000);
end;

procedure TTestRunCapture.TestMissingProgram;
var
  Got  : string;
  Code : Integer;
begin
  AssertTrue('not started',
    McpRunCapture('definitely_no_such_program_mcp', [], '', Got, Code) = reNotStarted);
  AssertTrue('says why', Got <> '');
end;

procedure TTestRunCapture.TestOutputLargerThanAPipe;
var
  Exe, Got : string;
  Args     : TStringArray;
  Code     : Integer;
begin
  { 20000 lines of about 10 bytes: far more than a pipe holds, so a reader that
    waits for the child to end first would deadlock }
  {$IFDEF WINDOWS}
  Shell('for /l %i in (1,1,20000) do @echo line%i', Exe, Args);
  {$ELSE}
  Shell('i=1; while [ $i -le 20000 ]; do echo line$i; i=$((i+1)); done', Exe, Args);
  {$ENDIF}
  AssertTrue('ended', McpRunCapture(Exe, Args, '', Got, Code, 60000) = reExited);
  AssertTrue('first line', Pos('line1' + LineEnding, Got) > 0);
  AssertTrue('last line, nothing lost', Pos('line20000', Got) > 0);
end;

procedure TTestRunCapture.TestWorkDir;
var
  Exe, Got : string;
  Args     : TStringArray;
  Code     : Integer;
  Dir      : string;
begin
  Dir := ExcludeTrailingPathDelimiter(GetTempDir(False));
  {$IFDEF WINDOWS}
  Shell('cd', Exe, Args);
  {$ELSE}
  Shell('pwd', Exe, Args);
  {$ENDIF}
  AssertTrue('ended', McpRunCapture(Exe, Args, Dir, Got, Code) = reExited);
  AssertEquals('directory', LowerCase(Dir), LowerCase(Trim(Got)));
end;

initialization
  RegisterTest(TTestRunCapture);
end.
