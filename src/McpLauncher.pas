{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpLauncher;

{ Starts Claude Code in a terminal window.

  Windows: claude runs directly in a new console (poNewConsole).
  Linux/macOS: poNewConsole does nothing there, so a shell script is written
  that runs claude, and a terminal emulator is started to run the script
  (`sh <script>`, so the script needs no exec bit).  Claude gets the system
  prompt from the server itself (initialize's instructions), so none is
  passed here.

  Script and terminal command generation are plain RTL code that compiles on
  every platform; only McpLaunchClaude chooses the branch. }

{$mode objfpc}{$H+}

interface

uses
  {$IFDEF WINDOWS}Registry,{$ENDIF}
  Classes, SysUtils, Process;

type
  TMcpLaunchRequest = record
    ClaudeExe       : string;   { '' = claude on PATH }
    WorkDir         : string;
    McpConfigPath   : string;
    ExtraArgs       : string;   { space-separated }
    TerminalCommand : string;   { Unix: '' = auto-detect; e.g. 'kitty -e' }
    WinTerminal     : string;   { Windows: one of the MCP_TERM_* ids; '' = default }
    WinCustom       : string;   { Windows, MCP_TERM_CUSTOM: exe plus argument template }
  end;

const
  { Windows terminal choices (stored in the settings file as these ids) }
  MCP_TERM_DEFAULT    = 'default';     { claude.exe in a new console }
  MCP_TERM_CMD        = 'cmd';
  MCP_TERM_POWERSHELL = 'powershell';  { pwsh.exe when installed }
  MCP_TERM_WT         = 'wt';
  MCP_TERM_GITBASH    = 'gitbash';
  MCP_TERM_CUSTOM     = 'custom';

{ Windows: script for cmd.exe (CRLF, UTF-8 code page) that cds and runs claude }
function McpBuildCmdScript(const AReq: TMcpLaunchRequest;
  const AClaudeExe: string): string;

{ Windows: PowerShell script (UTF-8 with BOM, so non-ASCII paths survive) }
function McpBuildPs1Script(const AReq: TMcpLaunchRequest;
  const AClaudeExe: string): string;

{ Windows: the sh script for Git Bash, with C:\x written as /c/x }
function McpBuildGitBashScript(const AReq: TMcpLaunchRequest;
  const AClaudeExe: string): string;

{ 'C:\Program Files\Git' -> '/c/Program Files/Git'; other text only gets / }
function McpWinToBashPath(const APath: string): string;

{ The argv (exe first) of a custom terminal template.  Placeholders: cmd in braces
  (as a whole argument: cmd.exe, /c and the script, as three arguments;
  inside a longer argument: the same text on one line), dir and script in braces.
  Arguments may be "double quoted".  False for an empty template. }
function McpCustomTerminalArgs(const ATemplate, AScript, ADir: string;
  AArgs: TStrings): Boolean;

{ The argv that opens the chosen terminal for a script already written.
  AHost: the terminal's exe (wt.exe, pwsh.exe, ...; unused for cmd/custom);
  AScript: the .cmd, .ps1 or .sh that matches AChoice.  False when AChoice
  needs an exe and AHost is empty. }
function McpWindowsTerminalArgs(const AChoice, AHost, AScript, ADir, ACustom: string;
  AArgs: TStrings): Boolean;

{ Windows: the exe for a choice ('' = not installed).  cmd needs no search. }
function McpFindWindowsTerminal(const AChoice: string): string;

{ 'S' quoted for sh: every ' becomes '\'' }
function McpShellQuote(const S: string): string;

{ sh script that cds to AWorkDir and execs claude }
function McpBuildLaunchScript(const AReq: TMcpLaunchRequest;
  const AClaudeExe: string): string;

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
  const AClaudeExe: string): string;
var
  Extra : TStringList;
  Cmd   : string;
  I     : Integer;
begin
  Cmd := 'exec ' + McpShellQuote(AClaudeExe) +
         ' --mcp-config ' + McpShellQuote(AReq.McpConfigPath) +
         ' --strict-mcp-config';
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

{ ---- Windows terminals ---- }

function CmdQuote(const S: string): string;
begin
  { inside "..." cmd keeps & | ^ < > literal; % is still expanded }
  Result := '"' + StringReplace(StringReplace(S, '%', '%%', [rfReplaceAll]),
                                '"', '""', [rfReplaceAll]) + '"';
end;

function PsQuote(const S: string): string;
begin
  Result := '''' + StringReplace(S, '''', '''''', [rfReplaceAll]) + '''';
end;

function McpBuildCmdScript(const AReq: TMcpLaunchRequest;
  const AClaudeExe: string): string;
var
  Extra : TStringList;
  Cmd   : string;
  I     : Integer;
begin
  Cmd := CmdQuote(AClaudeExe) + ' --mcp-config ' + CmdQuote(AReq.McpConfigPath) +
         ' --strict-mcp-config';
  Extra := TStringList.Create;
  try
    SplitArgs(AReq.ExtraArgs, Extra);
    for I := 0 to Extra.Count - 1 do
      Cmd := Cmd + ' ' + CmdQuote(Extra[I]);
  finally
    Extra.Free;
  end;
  Result := '@echo off' + #13#10 +
            'chcp 65001 >nul' + #13#10 +
            'rem written by the Lazarus MCP Assistant (Launch MCP Assistant)' + #13#10;
  if AReq.WorkDir <> '' then
    Result := Result + 'cd /d ' + CmdQuote(AReq.WorkDir) + #13#10 +
              'if errorlevel 1 exit /b 1' + #13#10;
  Result := Result + Cmd + #13#10;
end;

function McpBuildPs1Script(const AReq: TMcpLaunchRequest;
  const AClaudeExe: string): string;
var
  Extra : TStringList;
  Cmd   : string;
  I     : Integer;
begin
  Cmd := '& ' + PsQuote(AClaudeExe) + ' ''--mcp-config'' ' +
         PsQuote(AReq.McpConfigPath) + ' ''--strict-mcp-config''';
  Extra := TStringList.Create;
  try
    SplitArgs(AReq.ExtraArgs, Extra);
    for I := 0 to Extra.Count - 1 do
      Cmd := Cmd + ' ' + PsQuote(Extra[I]);
  finally
    Extra.Free;
  end;
  Result := #$EF#$BB#$BF +
            '# written by the Lazarus MCP Assistant (Launch MCP Assistant)' + #13#10;
  if AReq.WorkDir <> '' then
    Result := Result + 'Set-Location -LiteralPath ' + PsQuote(AReq.WorkDir) +
              ' -ErrorAction Stop' + #13#10;
  Result := Result + Cmd + #13#10;
end;

function McpWinToBashPath(const APath: string): string;
begin
  Result := StringReplace(APath, '\', '/', [rfReplaceAll]);
  if (Length(Result) >= 2) and (Result[2] = ':') and
     (UpCase(Result[1]) in ['A'..'Z']) and
     ((Length(Result) = 2) or (Result[3] = '/')) then
    Result := '/' + LowerCase(Result[1]) + Copy(Result, 3, MaxInt);
end;

function McpBuildGitBashScript(const AReq: TMcpLaunchRequest;
  const AClaudeExe: string): string;
var
  R : TMcpLaunchRequest;
begin
  R := AReq;
  R.WorkDir       := McpWinToBashPath(AReq.WorkDir);
  R.McpConfigPath := McpWinToBashPath(AReq.McpConfigPath);
  Result := McpBuildLaunchScript(R, McpWinToBashPath(AClaudeExe));
end;

function McpCustomTerminalArgs(const ATemplate, AScript, ADir: string;
  AArgs: TStrings): Boolean;
var
  I, N  : Integer;
  Tok   : string;
  InQ   : Boolean;
  Toks  : TStringList;
  Cur   : string;
  Has   : Boolean;

  procedure Flush;
  begin
    if Has then Toks.Add(Cur);
    Cur := '';
    Has := False;
  end;

begin
  AArgs.Clear;
  Toks := TStringList.Create;
  try
    { split on blanks outside "..." }
    Cur := '';
    Has := False;
    InQ := False;
    for I := 1 to Length(ATemplate) do
      if ATemplate[I] = '"' then
      begin
        InQ := not InQ;
        Has := True;
      end
      else if (ATemplate[I] in [' ', #9]) and not InQ then
        Flush
      else
      begin
        Cur := Cur + ATemplate[I];
        Has := True;
      end;
    Flush;
    if Toks.Count = 0 then Exit(False);
    N := Toks.Count;
    for I := 0 to N - 1 do
    begin
      Tok := Toks[I];
      if (Tok = '{cmd}') and (I > 0) then
      begin
        AArgs.Add('cmd.exe');
        AArgs.Add('/c');
        AArgs.Add(AScript);
      end
      else
      begin
        Tok := StringReplace(Tok, '{cmd}', 'cmd.exe /c ' + CmdQuote(AScript), [rfReplaceAll]);
        Tok := StringReplace(Tok, '{script}', AScript, [rfReplaceAll]);
        Tok := StringReplace(Tok, '{dir}', ADir, [rfReplaceAll]);
        AArgs.Add(Tok);
      end;
    end;
    Result := AArgs[0] <> '';
  finally
    Toks.Free;
  end;
end;

function McpWindowsTerminalArgs(const AChoice, AHost, AScript, ADir, ACustom: string;
  AArgs: TStrings): Boolean;
begin
  AArgs.Clear;
  Result := True;
  if AChoice = MCP_TERM_CUSTOM then
    Exit(McpCustomTerminalArgs(ACustom, AScript, ADir, AArgs));
  if AChoice = MCP_TERM_CMD then
  begin
    if AHost <> '' then AArgs.Add(AHost) else AArgs.Add('cmd.exe');
    AArgs.Add('/k');
    AArgs.Add(AScript);
    Exit;
  end;
  if AHost = '' then Exit(False);
  AArgs.Add(AHost);
  if AChoice = MCP_TERM_POWERSHELL then
  begin
    AArgs.Add('-NoExit');
    AArgs.Add('-ExecutionPolicy');
    AArgs.Add('Bypass');
    AArgs.Add('-File');
    AArgs.Add(AScript);
  end
  else if AChoice = MCP_TERM_WT then
  begin
    if ADir <> '' then
    begin
      AArgs.Add('-d');
      AArgs.Add(ADir);
    end;
    AArgs.Add('cmd.exe');
    AArgs.Add('/c');
    AArgs.Add(AScript);
  end
  else if AChoice = MCP_TERM_GITBASH then
  begin
    AArgs.Add('--login');
    AArgs.Add(McpWinToBashPath(AScript));
  end
  else
  begin
    AArgs.Clear;
    Result := False;
  end;
end;

function FirstExisting(const ACandidates: array of string): string;
var
  I : Integer;
begin
  for I := Low(ACandidates) to High(ACandidates) do
    if (ACandidates[I] <> '') and FileExists(ACandidates[I]) then
      Exit(ACandidates[I]);
  Result := '';
end;

function EnvDir(const AVar, ASub: string): string;
begin
  Result := GetEnvironmentVariable(AVar);
  if Result <> '' then
    Result := IncludeTrailingPathDelimiter(Result) + ASub;
end;

{$IFDEF WINDOWS}
function GitForWindowsRoot: string;
var
  Reg : TRegistry;
  I   : Integer;
begin
  Result := '';
  for I := 0 to 1 do
  begin
    Reg := TRegistry.Create(KEY_READ or KEY_WOW64_64KEY);
    try
      if I = 0 then Reg.RootKey := HKEY_LOCAL_MACHINE
      else Reg.RootKey := HKEY_CURRENT_USER;
      if Reg.OpenKeyReadOnly('SOFTWARE\GitForWindows') and
         Reg.ValueExists('InstallPath') then
        Result := Reg.ReadString('InstallPath');
    finally
      Reg.Free;
    end;
    if Result <> '' then Exit;
  end;
end;
{$ENDIF}

function McpFindWindowsTerminal(const AChoice: string): string;
var
  Path : string;
  Root : string;
begin
  Result := '';
  Path := GetEnvironmentVariable('PATH');
  if AChoice = MCP_TERM_CMD then
    Result := FirstExisting([GetEnvironmentVariable('ComSpec'),
                             EnvDir('SystemRoot', 'System32\cmd.exe')])
  else if AChoice = MCP_TERM_POWERSHELL then
  begin
    Result := FirstExisting([EnvDir('ProgramFiles', 'PowerShell\7\pwsh.exe'),
                             ExeSearch('pwsh.exe', Path)]);
    if Result = '' then
      Result := FirstExisting([ExeSearch('powershell.exe', Path),
        EnvDir('SystemRoot', 'System32\WindowsPowerShell\v1.0\powershell.exe')]);
  end
  else if AChoice = MCP_TERM_WT then
    { an App Execution Alias: ExeSearch may not see it, so look there first }
    Result := FirstExisting([EnvDir('LOCALAPPDATA', 'Microsoft\WindowsApps\wt.exe'),
                             ExeSearch('wt.exe', Path)])
  else if AChoice = MCP_TERM_GITBASH then
  begin
    {$IFDEF WINDOWS}
    Root := GitForWindowsRoot;
    if Root <> '' then
      Root := IncludeTrailingPathDelimiter(Root) + 'bin\bash.exe';
    {$ELSE}
    Root := '';
    {$ENDIF}
    Result := FirstExisting([Root,
                             EnvDir('ProgramFiles', 'Git\bin\bash.exe'),
                             EnvDir('ProgramW6432', 'Git\bin\bash.exe'),
                             EnvDir('LOCALAPPDATA', 'Programs\Git\bin\bash.exe')]);
  end;
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
  Script    : string;
  Argv      : TStringList;
  I         : Integer;
  {$IFDEF WINDOWS}
  Host, Body, Ext : string;
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
    if (AReq.WinTerminal = '') or (AReq.WinTerminal = MCP_TERM_DEFAULT) then
    begin
      Proc.Executable := ClaudeExe;
      Proc.Parameters.Add('--mcp-config');
      Proc.Parameters.Add(AReq.McpConfigPath);
      Proc.Parameters.Add('--strict-mcp-config');
      SplitArgs(AReq.ExtraArgs, Proc.Parameters);
      Proc.Options := [poNewConsole];
    end
    else
    begin
      { the host runs a generated script: no nested quoting }
      Host := McpFindWindowsTerminal(AReq.WinTerminal);
      if (Host = '') and (AReq.WinTerminal <> MCP_TERM_CUSTOM) then
        Exit('The terminal "' + AReq.WinTerminal + '" is not installed. ' +
             'Choose another in Tools > Options > MCP Assistant.');
      if AReq.WinTerminal = MCP_TERM_POWERSHELL then
      begin
        Ext := '.ps1';
        Body := McpBuildPs1Script(AReq, ClaudeExe);
      end
      else if AReq.WinTerminal = MCP_TERM_GITBASH then
      begin
        Ext := '.sh';
        Body := McpBuildGitBashScript(AReq, ClaudeExe);
      end
      else
      begin
        Ext := '.cmd';
        Body := McpBuildCmdScript(AReq, ClaudeExe);
      end;
      Script := IncludeTrailingPathDelimiter(GetTempDir) + 'lazarus-mcp-launch' + Ext;
      if not WriteTextFile(Script, Body) then
        Exit('Could not write ' + Script);
      Argv := TStringList.Create;
      try
        if not McpWindowsTerminalArgs(AReq.WinTerminal, Host, Script,
             AReq.WorkDir, AReq.WinCustom, Argv) then
          Exit('The custom terminal is empty. Enter it in Tools > Options > ' +
               'MCP Assistant, e.g. myterm.exe --cwd {dir} -- {cmd}');
        Proc.Executable := Argv[0];
        for I := 1 to Argv.Count - 1 do
          Proc.Parameters.Add(Argv[I]);
      finally
        Argv.Free;
      end;
      if (AReq.WinTerminal = MCP_TERM_CMD) or (AReq.WinTerminal = MCP_TERM_POWERSHELL) or
         (AReq.WinTerminal = MCP_TERM_GITBASH) then
        Proc.Options := [poNewConsole];
    end;
    if AReq.WorkDir <> '' then
      Proc.CurrentDirectory := AReq.WorkDir;
    {$ELSE}
    Script := IncludeTrailingPathDelimiter(GetTempDir) + 'lazarus-mcp-launch.sh';
    if not WriteTextFile(Script, McpBuildLaunchScript(AReq, ClaudeExe)) then
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
