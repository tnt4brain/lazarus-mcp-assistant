#!/usr/bin/env instantfpc
{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
{$mode objfpc}{$H+}
{ wait_for_restart.pas — poll the Lazarus MCP server until it responds.
  Use after calling ide_rebuild, when the MCP transport is broken.

  Usage:  instantfpc wait_for_restart.pas [timeout_seconds] [settings_file]
            [--relaunch=<lazarus executable>] [--pcp=<config dir>] [--grace=<seconds>]
  Default timeout: 180 s.  settings_file is mcpassistantoptions.xml in the
  IDE's primary config directory; ide_rebuild's poll_command passes it, since
  the default guess below is wrong when Lazarus runs with --pcp.

  --relaunch: startlazarus.exe has been seen alive with no IDE after a rebuild
  (FR.md).  When the server does not answer, no lazarus process exists and no
  build tool runs for --grace seconds (default 45; a rebuild always has one of
  them), the IDE is started from that executable (with --pcp=<config dir> if
  given) and the wait goes on.  Without --relaunch the script only waits. }
program WaitForRestart;

uses
  SysUtils, StrUtils, Classes, Process, fphttpclient;

{ Returns the platform-specific path to mcpassistantoptions.xml }
function ConfigPath: string;
begin
{$IFDEF WINDOWS}
  Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('LOCALAPPDATA'))
          + 'lazarus' + PathDelim + 'mcpassistantoptions.xml';
{$ELSE}
  Result := IncludeTrailingPathDelimiter(GetUserDir)
          + '.lazarus' + PathDelim + 'mcpassistantoptions.xml';
{$ENDIF}
end;

{ Extracts AttrName="value" from a chunk of XML text. }
function ExtractAttr(const XML, AttrName: string): string;
var
  Key  : string;
  P, Q : Integer;
begin
  Result := '';
  Key := AttrName + '="';
  P   := Pos(Key, XML);
  if P = 0 then Exit;
  P   := P + Length(Key);
  Q   := PosEx('"', XML, P);
  if Q = 0 then Exit;
  Result := Copy(XML, P, Q - P);
end;

{ Names of the running processes, lowercase, one per line: the image names on
  Windows (tasklist), the command names elsewhere (ps). }
function ProcessNames: string;
{$IFNDEF WINDOWS}
var
  SL : TStringList;
  I  : Integer;
{$ENDIF}
begin
  Result := '';
  {$IFDEF WINDOWS}
  if not RunCommand('tasklist', ['/NH', '/FO', 'CSV'], Result) then Exit;
  Result := LowerCase(StringReplace(Result, '"', '', [rfReplaceAll]));
  {$ELSE}
  if not RunCommand('ps', ['-A', '-o', 'stat=,comm='], Result) then Exit;
  { a finished process nobody has collected yet (Z) is not running }
  SL := TStringList.Create;
  try
    SL.Text := LowerCase(Result);
    Result := '';
    for I := 0 to SL.Count - 1 do
      if (Trim(SL[I]) <> '') and (Trim(SL[I])[1] <> 'z') then
        Result := Result + Trim(Copy(Trim(SL[I]), Pos(' ', Trim(SL[I])) + 1, MaxInt)) + LineEnding;
  finally
    SL.Free;
  end;
  {$ENDIF}
end;

{ Does the process list hold a line starting with Name? }
function HasProcess(const List, Name: string): Boolean;
var
  SL : TStringList;
  I  : Integer;
begin
  Result := False;
  SL := TStringList.Create;
  try
    SL.Text := List;
    for I := 0 to SL.Count - 1 do
      if (Pos(Name, Trim(SL[I])) = 1) and
         ((Length(Trim(SL[I])) = Length(Name)) or (Trim(SL[I])[Length(Name) + 1] in [',', '.', ' '])) then
        Exit(True);
  finally
    SL.Free;
  end;
end;

{ The IDE is gone and nothing is building it: a rebuild always has a compiler,
  make or the linker running. }
function NothingRuns: Boolean;
var
  L : string;
  N : string;
begin
  L := ProcessNames;
  if L = '' then Exit(False);   { no list: do not guess }
  for N in ['lazarus', 'lazbuild', 'make', 'fpc', 'ppcx64', 'ppc386', 'ppcarm', 'ppca64',
            'ppcrossx64', 'ld', 'as', 'windres', 'gdb'] do
    if HasProcess(L, N) then Exit(False);
  Result := True;
end;

var
  CFG           : string;
  Timeout       : Integer;
  Elapsed       : Integer = 0;
  XML, Token    : string;
  Port          : Integer;
  URL           : string;
  Body, Resp    : TStringStream;
  Client        : TFPHTTPClient;
  SL            : TStringList;
  I             : Integer;
  Relaunch      : string = '';
  PcpDir        : string = '';
  Grace         : Integer = 45;
  Quiet         : Integer = 0;   { seconds nothing has run }
  Launched      : Boolean = False;
  Proc          : TProcess;
begin
  Timeout := 180;
  CFG     := '';
  { a number is the timeout, anything else the settings file }
  for I := 1 to ParamCount do
    if StrToIntDef(ParamStr(I), -1) >= 0 then
      Timeout := StrToInt(ParamStr(I))
    else if Pos('--relaunch=', ParamStr(I)) = 1 then
      Relaunch := Copy(ParamStr(I), Length('--relaunch=') + 1, MaxInt)
    else if Pos('--pcp=', ParamStr(I)) = 1 then
      PcpDir := Copy(ParamStr(I), Length('--pcp=') + 1, MaxInt)
    else if Pos('--grace=', ParamStr(I)) = 1 then
      Grace := StrToIntDef(Copy(ParamStr(I), Length('--grace=') + 1, MaxInt), 45)
    else if ParamStr(I) <> '' then
      CFG := ParamStr(I);
  if CFG = '' then
    CFG := ConfigPath;
  if not FileExists(CFG) then
  begin
    WriteLn('ERROR: settings not found at ', CFG);
    Halt(1);
  end;

  WriteLn('Waiting for MCP server (timeout ', Timeout, 's)...');

  while Elapsed < Timeout do
  begin
    Sleep(5000);
    Elapsed := Elapsed + 5;

    { the IDE is not there and nothing builds it: start it }
    if (Relaunch <> '') and not Launched then
    begin
      if NothingRuns then Inc(Quiet, 5) else Quiet := 0;
      if Quiet >= Grace then
      begin
        WriteLn(Format('No lazarus process and no build for %ds: starting %s', [Quiet, Relaunch]));
        Proc := TProcess.Create(nil);
        try
          Proc.Executable := Relaunch;
          if PcpDir <> '' then Proc.Parameters.Add('--pcp=' + PcpDir);
          Proc.CurrentDirectory := ExtractFilePath(Relaunch);
          Proc.Execute;
          Launched := True;
        finally
          Proc.Free;
        end;
      end;
    end;

    { Re-read settings every iteration — port may change after restart }
    SL := TStringList.Create;
    try
      SL.LoadFromFile(CFG);
      XML := SL.Text;
    finally
      SL.Free;
    end;

    Port  := StrToIntDef(ExtractAttr(XML, 'Port'), 0);
    Token := ExtractAttr(XML, 'Token');
    if (Port = 0) or (Token = '') then Continue;

    URL  := Format('http://127.0.0.1:%d/mcp', [Port]);
    Body := TStringStream.Create(
      '{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
      '"params":{"name":"ide_ping","arguments":{}}}');
    Resp := TStringStream.Create('');
    Client := TFPHTTPClient.Create(nil);
    try
      Client.AddHeader('Authorization', 'Bearer ' + Token);
      Client.AddHeader('Content-Type',  'application/json');
      Client.RequestBody := Body;
      try
        Client.Post(URL, Resp);
        if Pos('ok', Resp.DataString) > 0 then
        begin
          WriteLn(Format('MCP server is up on port %d (%ds elapsed).',
                         [Port, Elapsed]));
          Halt(0);
        end;
      except
        { connection refused or timeout — keep polling }
      end;
    finally
      Client.RequestBody := nil;
      Client.Free;
      Body.Free;
      Resp.Free;
    end;
  end;

  WriteLn(Format('ERROR: MCP server did not respond within %ds.', [Timeout]));
  Halt(1);
end.
