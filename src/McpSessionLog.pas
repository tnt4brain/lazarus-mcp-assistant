{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpSessionLog;

{ A short trail of how MCP sessions come and go: initialize (who, which
  protocol, whether it still carried an old session id), requests refused with
  404 because their session id is unknown (after an IDE restart, ADR-012), DELETE,
  server start.  Appended to mcp-sessions.log in the IDE's config folder; the
  file stays below about 200 KB.  For working out why a client gave up on the
  server after a restart: it says what the client sent and what we answered.
  Thread-safe; the log never raises. }

{$mode objfpc}{$H+}

interface

{ The folder to write to; call once, on the main thread. }
procedure McpSetSessionLogDir(const ADir: string);

procedure McpLogSession(const AMsg: string);

{ The first 8 characters of a session id, for log lines and messages. }
function McpShortId(const AId: string): string;

implementation

uses
  Classes, SysUtils, SyncObjs;

const
  LOG_NAME = 'mcp-sessions.log';
  MAX_SIZE = 200 * 1024;

var
  GLock : TCriticalSection;
  GPath : string = '';

procedure McpSetSessionLogDir(const ADir: string);
begin
  if ADir = '' then Exit;
  GLock.Enter;
  try
    GPath := IncludeTrailingPathDelimiter(ADir) + LOG_NAME;
  finally
    GLock.Leave;
  end;
end;

function McpShortId(const AId: string): string;
begin
  Result := Copy(AId, 1, 8);
end;

function FileSizeOf(const AName: string): Int64;
var
  S : TFileStream;
begin
  Result := 0;
  try
    S := TFileStream.Create(AName, fmOpenRead or fmShareDenyNone);
    try
      Result := S.Size;
    finally
      S.Free;
    end;
  except
  end;
end;

procedure McpLogSession(const AMsg: string);
var
  F  : TextFile;
  SL : TStringList;
  Line : string;
begin
  GLock.Enter;
  try
    if GPath = '' then Exit;
    try
      Line := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + ' ' + AMsg;
      if FileExists(GPath) then
      begin
        { keep the newer half when it gets big }
        if FileSizeOf(GPath) > MAX_SIZE then
        begin
          SL := TStringList.Create;
          try
            SL.LoadFromFile(GPath);
            while SL.Count > 0 do
              if Length(SL.Text) > MAX_SIZE div 2 then SL.Delete(0) else Break;
            SL.SaveToFile(GPath);
          finally
            SL.Free;
          end;
        end;
        AssignFile(F, GPath);
        Append(F);
      end
      else
      begin
        AssignFile(F, GPath);
        Rewrite(F);
      end;
      try
        WriteLn(F, Line);
      finally
        CloseFile(F);
      end;
    except
      { a log must not break a request }
    end;
  finally
    GLock.Leave;
  end;
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  GLock.Free;

end.
