{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpLauncher;

{ Starts Claude Code in a terminal window.

  Windows: claude runs directly in a new console (poNewConsole).
  Linux/macOS: poNewConsole does nothing there, so a shell script is written
  that runs claude, and a terminal emulator is started to run the script
  (`sh <script>`, so the script needs no exec bit).  The system prompt is
  passed through a file because it is too long to put into a terminal's
  command line comfortably.

  Script and terminal command generation are plain RTL code that compiles on
  every platform; only McpLaunchClaude chooses the branch. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Process;

type
  TMcpLaunchRequest = record
    ClaudeExe       : string;   { '' = claude on PATH }
    WorkDir         : string;
    McpConfigPath   : string;
    SystemPrompt    : string;
    ExtraArgs       : string;   { space-separated }
    TerminalCommand : string;   { Unix: '' = auto-detect; e.g. 'kitty -e' }
  end;

{ 'S' quoted for sh: every ' becomes '\'' }
function McpShellQuote(const S: string): string;

{ sh script that cds to AWorkDir and execs claude; the prompt is read from
  APromptFile. }
function McpBuildLaunchScript(const AReq: TMcpLaunchRequest;
  const AClaudeExe, APromptFile: string): string;

{ argv that opens a terminal running `sh AScript`.  ACommand is the user's
  terminal setting ('' = auto-detect via APath); AMac selects Terminal.app.
  Returns False (and an empty list) when no terminal is found. }
function McpTerminalArgs(const ACommand, AScript, APath: string; AMac: Boolean;
  AArgs: TStrings): Boolean;

{ Launch; returns '' on success, else the error text. }
function McpLaunchClaude(const AReq: TMcpLaunchRequest): string;

implementation

const
  { tried in this order when no terminal command is configured }
  KnownTerminals : array[0..4, 0..1] of string = (
    ('x-terminal-emulator', '-e'),
    ('gnome-terminal',      '--'),
    ('konsole',             '-e'),
    ('xfce4-terminal',      '-x'),
    ('xterm',               '-e'));

function McpShellQuote(const S: string): string;
begin
  Result := '''' + StringReplace(S, '''', '''\''''', [rfReplaceAll]) + '''';
end;

procedure SplitArgs(const S: string; AList: TStrings);
var
  Parts : TStringList;
  I     : Integer;
begin
  Parts := TStringList.Create;
  try
    Parts.Delimiter       := ' ';
    Parts.StrictDelimiter := False;
    Parts.DelimitedText   := S;
    for I := 0 to Parts.Count - 1 do
      if Trim(Parts[I]) <> '' then
        AList.Add(Parts[I]);
  finally
    Parts.Free;
  end;
end;

function McpBuildLaunchScript(const AReq: TMcpLaunchRequest;
  const AClaudeExe, APromptFile: string): string;
var
  Extra : TStringList;
  Cmd   : string;
  I     : Integer;
begin
  Cmd := 'exec ' + McpShellQuote(AClaudeExe) +
         ' --mcp-config ' + McpShellQuote(AReq.McpConfigPath) +
         ' --strict-mcp-config' +
         ' --append-system-prompt "$(cat ' + McpShellQuote(APromptFile) + ')"';
  Extra := TStringList.Create;
  try
    SplitArgs(AReq.ExtraArgs, Extra);
    for I := 0 to Extra.Count - 1 do
      Cmd := Cmd + ' ' + McpShellQuote(Extra[I]);
  finally
    Extra.Free;
  end;
  Result := '#!/bin/sh' + #10 +
            '# written by the Lazarus MCP Assistant (Launch MCP Assistant)' + #10;
  if AReq.WorkDir <> '' then
    Result := Result + 'cd ' + McpShellQuote(AReq.WorkDir) + ' || exit 1' + #10;
  Result := Result + Cmd + #10;
end;

{ AppleScript string literal }
function AppleQuote(const S: string): string;
begin
  Result := '"' + StringReplace(StringReplace(S, '\', '\\', [rfReplaceAll]),
                                '"', '\"', [rfReplaceAll]) + '"';
end;

function McpTerminalArgs(const ACommand, AScript, APath: string; AMac: Boolean;
  AArgs: TStrings): Boolean;
var
  I   : Integer;
  Exe : string;
begin
  AArgs.Clear;
  if Trim(ACommand) <> '' then
  begin
    SplitArgs(ACommand, AArgs);
    AArgs.Add('sh');
    AArgs.Add(AScript);
    Exit(True);
  end;
  if AMac then
  begin
    AArgs.Add('osascript');
    AArgs.Add('-e');
    AArgs.Add('tell application "Terminal" to do script ' +
              AppleQuote('sh ' + McpShellQuote(AScript)));
    AArgs.Add('-e');
    AArgs.Add('tell application "Terminal" to activate');
    Exit(True);
  end;
  for I := Low(KnownTerminals) to High(KnownTerminals) do
  begin
    Exe := ExeSearch(KnownTerminals[I, 0], APath);
    if Exe <> '' then
    begin
      AArgs.Add(Exe);
      AArgs.Add(KnownTerminals[I, 1]);
      AArgs.Add('sh');
      AArgs.Add(AScript);
      Exit(True);
    end;
  end;
  Result := False;
end;

function WriteTextFile(const AFileName, AText: string): Boolean;
var
  F : TFileStream;
begin
  Result := False;
  try
    F := TFileStream.Create(AFileName, fmCreate);
    try
      if AText <> '' then
        F.WriteBuffer(AText[1], Length(AText));
      Result := True;
    finally
      F.Free;
    end;
  except
  end;
end;

function McpLaunchClaude(const AReq: TMcpLaunchRequest): string;
var
  Proc      : TProcess;
  ClaudeExe : string;
  {$IFNDEF WINDOWS}
  Script    : string;
  Prompt    : string;
  Argv      : TStringList;
  I         : Integer;
  {$ENDIF}
begin
  Result    := '';
  ClaudeExe := AReq.ClaudeExe;
  if ClaudeExe = '' then
  begin
    ClaudeExe := ExeSearch({$IFDEF WINDOWS}'claude.exe'{$ELSE}'claude'{$ENDIF},
                           GetEnvironmentVariable('PATH'));
    if ClaudeExe = '' then
      ClaudeExe := 'claude';
  end;
  Proc := TProcess.Create(nil);
  try
    Proc.InheritHandles := False;  { the MCP listening socket must not leak }
    {$IFDEF WINDOWS}
    Proc.Executable := ClaudeExe;
    Proc.Parameters.Add('--mcp-config');
    Proc.Parameters.Add(AReq.McpConfigPath);
    Proc.Parameters.Add('--strict-mcp-config');
    Proc.Parameters.Add('--append-system-prompt');
    Proc.Parameters.Add(AReq.SystemPrompt);
    SplitArgs(AReq.ExtraArgs, Proc.Parameters);
    Proc.Options := [poNewConsole];
    if AReq.WorkDir <> '' then
      Proc.CurrentDirectory := AReq.WorkDir;
    {$ELSE}
    Script := IncludeTrailingPathDelimiter(GetTempDir) + 'lazarus-mcp-launch.sh';
    Prompt := IncludeTrailingPathDelimiter(GetTempDir) + 'lazarus-mcp-prompt.md';
    if not WriteTextFile(Prompt, AReq.SystemPrompt) or
       not WriteTextFile(Script, McpBuildLaunchScript(AReq, ClaudeExe, Prompt)) then
      Exit('Could not write ' + Script);
    Argv := TStringList.Create;
    try
      if not McpTerminalArgs(AReq.TerminalCommand, Script,
           GetEnvironmentVariable('PATH'), {$IFDEF DARWIN}True{$ELSE}False{$ENDIF},
           Argv) then
        Exit('No terminal emulator found. Set one in Tools > Options > ' +
             'MCP Assistant (e.g. "gnome-terminal --" or "kitty -e").');
      Proc.Executable := Argv[0];
      for I := 1 to Argv.Count - 1 do
        Proc.Parameters.Add(Argv[I]);
    finally
      Argv.Free;
    end;
    {$ENDIF}
    try
      Proc.Execute;
    except
      on E: Exception do
        Result := 'Could not launch ' + Proc.Executable + ': ' + E.Message;
    end;
  finally
    Proc.Free;
  end;
end;

end.
