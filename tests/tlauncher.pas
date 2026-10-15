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

initialization
  RegisterTest(TTestLauncher);
end.
