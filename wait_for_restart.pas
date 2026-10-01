#!/usr/bin/env instantfpc
{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
{$mode objfpc}{$H+}
{ wait_for_restart.pas — poll the Lazarus MCP server until it responds.
  Use after calling rebuild_ide, when the MCP transport is broken.

  Usage:  instantfpc wait_for_restart.pas [timeout_seconds]
  Default timeout: 180 s }
program WaitForRestart;

uses
  SysUtils, StrUtils, Classes, fphttpclient;

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
begin
  Timeout := 180;
  if ParamCount >= 1 then
    Timeout := StrToIntDef(ParamStr(1), 180);

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
      '"params":{"name":"ping","arguments":{}}}');
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
