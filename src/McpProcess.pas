{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpProcess;

{ Run a program to the end and return what it printed: the one place that starts a
  child, writes its standard input, drains its output without a deadlock, stops it
  after a timeout and reports why it ended.  Used by the git tools, lazbuild, the
  test runner, the curl download and the git hash lookup.

  Not for a child whose output is wanted while it runs (McpRunProgram, the git_serve
  upload-pack relay) or one that must outlive the call (McpLauncher).

  Pure RTL: no IDE and no LCL, so tests/tprocess.pas runs without the IDE. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TMcpRunEnd = (
    reExited,       { the program ran and ended; AExitCode is its exit code }
    reTimedOut,     { stopped after ATimeoutMs; the output is what it had printed }
    reNotStarted    { the program could not be started; AOutput says why }
  );

{ Runs AExe with AArgs (one argument each, no shell) in AWorkDir (empty: ours).

  Standard output and standard error arrive merged in AOutput, as bytes, unchanged.
  The window is hidden and no console is created, so nothing takes the focus.

  AInput, if any, is written to the child's standard input, which is then closed.
  It is written before the output is read, so it must be small (a commit message,
  a request body): a child that prints more than a pipe holds before it has read
  everything would wait for us.

  AEnv holds NAME=value entries put on top of our own environment for this child
  only; a name that is already set is replaced, never doubled.

  ATimeoutMs = 0 waits for ever.  Otherwise the child is terminated when it has run
  that long. }
function McpRunCapture(const AExe: string; const AArgs: array of string;
  const AWorkDir: string; out AOutput: string; out AExitCode: Integer;
  ATimeoutMs: QWord = 0; const AInput: string = '';
  const AEnv: TStringArray = nil): TMcpRunEnd;

{ Appends one argument to a list built for McpRunCapture. }
procedure McpAddArg(var AArgs: TStringArray; const AArg: string);

implementation

uses
  Classes, Process;

procedure McpAddArg(var AArgs: TStringArray; const AArg: string);
begin
  SetLength(AArgs, Length(AArgs) + 1);
  AArgs[High(AArgs)] := AArg;
end;

function McpRunCapture(const AExe: string; const AArgs: array of string;
  const AWorkDir: string; out AOutput: string; out AExitCode: Integer;
  ATimeoutMs: QWord; const AInput: string; const AEnv: TStringArray): TMcpRunEnd;
var
  Proc    : TProcess;
  Got     : TStringStream;
  Buf     : array[0..4095] of Byte;
  Started : QWord;
  I       : Integer;

  { Everything the child has printed so far; never blocks. }
  procedure Drain;
  var
    N : Integer;
  begin
    repeat
      N := Proc.Output.NumBytesAvailable;
      if N <= 0 then Exit;
      if N > SizeOf(Buf) then N := SizeOf(Buf);
      N := Proc.Output.Read(Buf, N);
      if N <= 0 then Exit;
      Got.WriteBuffer(Buf, N);
    until False;
  end;

begin
  AOutput   := '';
  AExitCode := -1;
  Result    := reExited;
  Buf[0]    := 0;
  Proc      := TProcess.Create(nil);
  Got       := TStringStream.Create('');
  try
    Proc.Executable := AExe;
    for I := 0 to High(AArgs) do
      Proc.Parameters.Add(AArgs[I]);
    Proc.Options    := [poUsePipes, poStdErrToOutput, poNoConsole];
    Proc.ShowWindow := swoHide;
    if AWorkDir <> '' then
      Proc.CurrentDirectory := AWorkDir;
    if Length(AEnv) > 0 then
    begin
      { a non-empty Environment replaces ours, so it starts as a copy of it }
      for I := 1 to GetEnvironmentVariableCount do
        Proc.Environment.Add(GetEnvironmentString(I));
      for I := 0 to High(AEnv) do
        if Pos('=', AEnv[I]) > 1 then
          Proc.Environment.Values[Copy(AEnv[I], 1, Pos('=', AEnv[I]) - 1)] :=
            Copy(AEnv[I], Pos('=', AEnv[I]) + 1, MaxInt);
    end;

    try
      Proc.Execute;
    except
      on E: Exception do
      begin
        AOutput := E.Message;
        Exit(reNotStarted);
      end;
    end;

    try
      if AInput <> '' then
        Proc.Input.Write(AInput[1], Length(AInput));
      Proc.CloseInput;
    except
      on EStreamError do ;   { the child ended without reading it all; its output says why }
    end;

    Started := GetTickCount64;
    while Proc.Running do
    begin
      Drain;
      if (ATimeoutMs > 0) and (GetTickCount64 - Started > ATimeoutMs) then
      begin
        Result := reTimedOut;
        Proc.Terminate(1);
        Break;
      end;
      Sleep(10);
    end;
    Proc.WaitOnExit;
    Drain;
    AExitCode := Proc.ExitCode;
    AOutput   := Got.DataString;
  finally
    Got.Free;
    Proc.Free;
  end;
end;

end.
