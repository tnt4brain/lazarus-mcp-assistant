{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TLauncher;

{ TTestLauncher — the Linux/macOS launch path of McpLauncher: sh quoting,
  the generated script and the terminal command line.  Plain string code, so
  it runs on every platform.  No running server required. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TTestLauncher = class(TTestCase)
  published
    procedure TestQuotePlain;
    procedure TestQuoteEmpty;
    procedure TestQuoteApostrophe;
    procedure TestScriptShape;
    procedure TestScriptWithoutWorkDir;
    procedure TestScriptQuotesExtraArgs;
    procedure TestTerminalConfigured;
    procedure TestTerminalMac;
    procedure TestTerminalNoneFound;
    procedure TestTerminalAutoDetectOrder;
    procedure TestWinToBashPath;
    procedure TestCmdScript;
    procedure TestPs1Script;
    procedure TestGitBashScript;
    procedure TestWinArgsCmd;
    procedure TestWinArgsPowerShell;
    procedure TestWinArgsWt;
    procedure TestWinArgsGitBash;
    procedure TestWinArgsNeedHost;
    procedure TestCustomTemplate;
    procedure TestCustomTemplateEmbedded;
    procedure TestCustomTemplateEmpty;
  end;

implementation

uses
  {$IFDEF UNIX}BaseUnix,{$ENDIF}
  Classes, SysUtils, McpLauncher;

function Req(const AWorkDir, AExtra: string): TMcpLaunchRequest;
begin
  Result := Default(TMcpLaunchRequest);
  Result.WorkDir       := AWorkDir;
  Result.McpConfigPath := '/tmp/mcp config.json';
  Result.ExtraArgs     := AExtra;
end;

procedure TTestLauncher.TestQuotePlain;
begin
  CheckEquals('''abc def''', McpShellQuote('abc def'));
end;

procedure TTestLauncher.TestQuoteEmpty;
begin
  CheckEquals('''''', McpShellQuote(''));
end;

procedure TTestLauncher.TestQuoteApostrophe;
begin
  { it's -> 'it'\''s' }
  CheckEquals('''it''\''''s''', McpShellQuote('it''s'));
end;

procedure TTestLauncher.TestScriptShape;
var
  S : string;
begin
  S := McpBuildLaunchScript(Req('/home/me/my proj', ''), '/usr/bin/claude');
  CheckEquals(1, Pos('#!/bin/sh'#10, S), 'shebang first');
  CheckTrue(Pos('cd ''/home/me/my proj'' || exit 1'#10, S) > 0, 'cd to the work dir: ' + S);
  CheckTrue(Pos('exec ''/usr/bin/claude'' --mcp-config ''/tmp/mcp config.json'' ' +
    '--strict-mcp-config'#10, S) > 0, 'claude command line: ' + S);
  { the prompt comes from the server's instructions now }
  CheckEquals(0, Pos('--append-system-prompt', S), 'no prompt passed: ' + S);
  CheckEquals(#10, S[Length(S)], 'ends with a newline');
end;

procedure TTestLauncher.TestScriptWithoutWorkDir;
begin
  CheckEquals(0, Pos('cd ', McpBuildLaunchScript(Req('', ''), 'claude')),
    'no cd without a work dir');
end;

procedure TTestLauncher.TestScriptQuotesExtraArgs;
var
  S : string;
begin
  S := McpBuildLaunchScript(Req('', '--model  opus --name it''s'), 'claude');
  CheckTrue(Pos('--strict-mcp-config ''--model'' ''opus'' ''--name'' ''it''\''''s''' + #10, S) > 0,
    'each extra argument quoted on its own: ' + S);
end;

procedure TTestLauncher.TestTerminalConfigured;
var
  L : TStringList;
begin
  L := TStringList.Create;
  try
    CheckTrue(McpTerminalArgs('kitty  -e', '/tmp/s.sh', '', False, L));
    CheckEquals('kitty|-e|sh|/tmp/s.sh', StringReplace(Trim(L.Text), LineEnding, '|', [rfReplaceAll]));
  finally
    L.Free;
  end;
end;

procedure TTestLauncher.TestTerminalMac;
var
  L : TStringList;
begin
  L := TStringList.Create;
  try
    CheckTrue(McpTerminalArgs('', '/tmp/a "b".sh', '', True, L));
    CheckEquals(5, L.Count);
    CheckEquals('osascript', L[0]);
    { sh-quoted, then escaped for the AppleScript string literal }
    CheckEquals('tell application "Terminal" to do script "sh ''/tmp/a \"b\".sh''"', L[2]);
    CheckEquals('tell application "Terminal" to activate', L[4]);
  finally
    L.Free;
  end;
end;

procedure TTestLauncher.TestTerminalNoneFound;
var
  L : TStringList;
begin
  L := TStringList.Create;
  try
    L.Add('stale');
    CheckFalse(McpTerminalArgs('', '/tmp/s.sh',
      IncludeTrailingPathDelimiter(GetTempDir) + 'no-such-dir-mcp', False, L));
    CheckEquals(0, L.Count, 'list cleared');
  finally
    L.Free;
  end;
end;

procedure TTestLauncher.TestTerminalAutoDetectOrder;
var
  Dir : string;
  L   : TStringList;

  procedure Touch(const AName: string);
  begin
    with TFileStream.Create(Dir + AName, fmCreate) do Free;
    {$IFDEF UNIX}FpChmod(Dir + AName, &755);{$ENDIF}
  end;

begin
  Dir := IncludeTrailingPathDelimiter(GetTempDir) + 'mcp-term-test' + PathDelim;
  ForceDirectories(Dir);
  L := TStringList.Create;
  try
    { xterm is last in the list, gnome-terminal second: gnome-terminal wins }
    Touch('xterm');
    Touch('gnome-terminal');
    CheckTrue(McpTerminalArgs('', '/tmp/s.sh', ExcludeTrailingPathDelimiter(Dir), False, L));
    CheckEquals(4, L.Count);
    CheckEquals('gnome-terminal', ExtractFileName(L[0]));
    CheckEquals('--', L[1]);
    CheckEquals('sh', L[2]);
    CheckEquals('/tmp/s.sh', L[3]);
  finally
    L.Free;
    DeleteFile(Dir + 'xterm');
    DeleteFile(Dir + 'gnome-terminal');
    RemoveDir(Dir);
  end;
end;


function Join(L: TStrings): string;
begin
  Result := StringReplace(Trim(L.Text), LineEnding, '|', [rfReplaceAll]);
end;

function WinReq: TMcpLaunchRequest;
begin
  Result := Default(TMcpLaunchRequest);
  Result.WorkDir       := 'D:\Program Files\my proj';
  Result.McpConfigPath := 'C:\Users\Jo Doe\100%\mcp.json';
  Result.ExtraArgs     := '--model opus';
end;

procedure TTestLauncher.TestWinToBashPath;
begin
  CheckEquals('/c/Program Files/Git/bin/bash.exe',
    McpWinToBashPath('C:\Program Files\Git\bin\bash.exe'));
  CheckEquals('/d', McpWinToBashPath('D:'));
  CheckEquals('rel/dir', McpWinToBashPath('rel\dir'));
  CheckEquals('/tmp/x', McpWinToBashPath('/tmp/x'));
  CheckEquals('', McpWinToBashPath(''));
end;

procedure TTestLauncher.TestCmdScript;
var
  S : string;
begin
  S := McpBuildCmdScript(WinReq, 'C:\Tools\claude.exe');
  CheckTrue(Pos('cd /d "D:\Program Files\my proj"'#13#10'if errorlevel 1 exit /b 1'#13#10, S) > 0, S);
  CheckTrue(Pos('"C:\Tools\claude.exe" --mcp-config "C:\Users\Jo Doe\100%%\mcp.json" ' +
    '--strict-mcp-config "--model" "opus"'#13#10, S) > 0, 'percent doubled: ' + S);
  CheckEquals(0, Pos(#10, StringReplace(S, #13#10, '', [rfReplaceAll])), 'CRLF only');
  CheckEquals(0, Pos('cd /d', McpBuildCmdScript(Req('', ''), 'claude')), 'no cd without a work dir');
end;

procedure TTestLauncher.TestPs1Script;
var
  S : string;
  R : TMcpLaunchRequest;
begin
  R := WinReq;
  R.WorkDir := 'D:\it''s here';
  S := McpBuildPs1Script(R, 'C:\Tools\claude.exe');
  CheckEquals(1, Pos(#$EF#$BB#$BF, S), 'UTF-8 BOM first');
  CheckTrue(Pos('Set-Location -LiteralPath ''D:\it''''s here'' -ErrorAction Stop'#13#10, S) > 0, S);
  CheckTrue(Pos('& ''C:\Tools\claude.exe'' ''--mcp-config'' ''C:\Users\Jo Doe\100%\mcp.json'' ' +
    '''--strict-mcp-config'' ''--model'' ''opus'''#13#10, S) > 0, S);
end;

procedure TTestLauncher.TestGitBashScript;
var
  S : string;
begin
  S := McpBuildGitBashScript(WinReq, 'C:\Tools\claude.exe');
  CheckTrue(Pos('cd ''/d/Program Files/my proj'' || exit 1'#10, S) > 0, S);
  CheckTrue(Pos('exec ''/c/Tools/claude.exe'' --mcp-config ''/c/Users/Jo Doe/100%/mcp.json'' ' +
    '--strict-mcp-config ''--model'' ''opus'''#10, S) > 0, S);
end;

procedure TTestLauncher.TestWinArgsCmd;
var
  L : TStringList;
begin
  L := TStringList.Create;
  try
    CheckTrue(McpWindowsTerminalArgs('cmd', 'C:\Windows\System32\cmd.exe', 'C:\t\s.cmd', 'D:\p', '', L));
    CheckEquals('C:\Windows\System32\cmd.exe|/k|C:\t\s.cmd', Join(L));
  finally
    L.Free;
  end;
end;

procedure TTestLauncher.TestWinArgsPowerShell;
var
  L : TStringList;
begin
  L := TStringList.Create;
  try
    CheckTrue(McpWindowsTerminalArgs('powershell', 'C:\PS\pwsh.exe', 'C:\t\s.ps1', 'D:\p', '', L));
    CheckEquals('C:\PS\pwsh.exe|-NoExit|-ExecutionPolicy|Bypass|-File|C:\t\s.ps1', Join(L));
  finally
    L.Free;
  end;
end;

procedure TTestLauncher.TestWinArgsWt;
var
  L : TStringList;
begin
  L := TStringList.Create;
  try
    CheckTrue(McpWindowsTerminalArgs('wt', 'C:\wt.exe', 'C:\t\s.cmd', 'D:\my proj', '', L));
    CheckEquals('C:\wt.exe|-d|D:\my proj|cmd.exe|/c|C:\t\s.cmd', Join(L));
    CheckTrue(McpWindowsTerminalArgs('wt', 'C:\wt.exe', 'C:\t\s.cmd', '', '', L));
    CheckEquals('C:\wt.exe|cmd.exe|/c|C:\t\s.cmd', Join(L), 'no -d without a directory');
  finally
    L.Free;
  end;
end;

procedure TTestLauncher.TestWinArgsGitBash;
var
  L : TStringList;
begin
  L := TStringList.Create;
  try
    CheckTrue(McpWindowsTerminalArgs('gitbash', 'C:\Git\bin\bash.exe', 'C:\t\s.sh', 'D:\p', '', L));
    CheckEquals('C:\Git\bin\bash.exe|--login|/c/t/s.sh', Join(L));
  finally
    L.Free;
  end;
end;

procedure TTestLauncher.TestWinArgsNeedHost;
var
  L : TStringList;
begin
  L := TStringList.Create;
  try
    CheckFalse(McpWindowsTerminalArgs('wt', '', 'C:\s.cmd', '', '', L));
    CheckFalse(McpWindowsTerminalArgs('default', 'x.exe', 'C:\s.cmd', '', '', L));
    CheckFalse(McpWindowsTerminalArgs('bogus', 'x.exe', 'C:\s.cmd', '', '', L));
    CheckEquals(0, L.Count);
  finally
    L.Free;
  end;
end;

procedure TTestLauncher.TestCustomTemplate;
var
  L : TStringList;
begin
  L := TStringList.Create;
  try
    CheckTrue(McpWindowsTerminalArgs('custom', '', 'C:\t\s.cmd', 'D:\my proj',
      'myterm.exe --cwd {dir} -- {cmd}', L));
    CheckEquals('myterm.exe|--cwd|D:\my proj|--|cmd.exe|/c|C:\t\s.cmd', Join(L),
      'a whole {cmd} argument is three arguments');
    CheckTrue(McpCustomTerminalArgs('"C:\Program Files\T\t.exe" -x {script}', 'C:\s.cmd', '', L));
    CheckEquals('C:\Program Files\T\t.exe|-x|C:\s.cmd', Join(L), 'quoted exe');
  finally
    L.Free;
  end;
end;

procedure TTestLauncher.TestCustomTemplateEmbedded;
var
  L : TStringList;
begin
  L := TStringList.Create;
  try
    CheckTrue(McpCustomTerminalArgs('t.exe --title=mcp --run={cmd} --at={dir}', 'C:\a b\s.cmd', 'D:\p', L));
    CheckEquals('t.exe|--title=mcp|--run=cmd.exe /c "C:\a b\s.cmd"|--at=D:\p', Join(L));
  finally
    L.Free;
  end;
end;

procedure TTestLauncher.TestCustomTemplateEmpty;
var
  L : TStringList;
begin
  L := TStringList.Create;
  try
    L.Add('stale');
    CheckFalse(McpCustomTerminalArgs('   ', 'C:\s.cmd', '', L));
    CheckEquals(0, L.Count);
    CheckFalse(McpWindowsTerminalArgs('custom', '', 'C:\s.cmd', '', '', L));
  finally
    L.Free;
  end;
end;

initialization
  RegisterTest(TTestLauncher);
end.
