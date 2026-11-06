{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TToolLog;

{ mcp-tools.log (ADR-022): the canonical form and hash of the arguments, the
  redaction, and the file (records, rotation, switch-off after failed writes).
  Standalone, no IDE. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser, fpcunit, testregistry, McpToolLog;

type
  TTestToolLog = class(TTestCase)
  private
    FDir : string;
    function  Obj(const AJson: string): TJSONObject;
    function  Canon(const AJson: string): string;
    function  HashOf(const AJson: string): string;
    function  Lines: TStringList;
    function  Line(AIndex: Integer): TJSONObject;
    function  Caller: TMcpLogCaller;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestKeysAreSortedAndCompact;
    procedure TestKeyOrderDoesNotChangeTheHash;
    procedure TestNoArgumentsHashLikeAnEmptyObject;
    procedure TestSlashAndBackslashDiffer;
    procedure TestControlCharactersAreEscaped;
    procedure TestNumbersAndBooleans;
    procedure TestSecretKeysAreRedactedAtAnyDepth;
    procedure TestChangedSecretLeavesTheHashAlone;
    procedure TestUrlUserInfoAndQuerySecretsAreRemoved;
    procedure TestArgKeysAreSortedAsReceived;
    procedure TestOffWritesNothing;
    procedure TestBeginAndEndLines;
    procedure TestEndOfAFailedCallCarriesACutError;
    procedure TestNonUtf8ErrorTextStaysValidJson;
    procedure TestSeqIdsIncrease;
    procedure TestRotation;
    procedure TestSwitchedOffAfterFailedWrites;
    procedure TestStartAndSessionRecords;
  end;

implementation

procedure TTestToolLog.SetUp;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'mcptoollog-' +
          IntToStr(GetTickCount64) + '-' + IntToStr(Random(100000));
  ForceDirectories(FDir);
  McpToolLogSetMaxBytes(MCP_TOOL_LOG_MAX);
  McpToolLogSetDir(FDir);
  McpToolLogSetProject('');
  McpToolLogSetEnabled(True);
end;

procedure TTestToolLog.TearDown;
var
  SR : TSearchRec;
begin
  McpToolLogSetEnabled(False);
  if FindFirst(IncludeTrailingPathDelimiter(FDir) + '*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') then
        DeleteFile(IncludeTrailingPathDelimiter(FDir) + SR.Name);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  RemoveDir(FDir);
end;

function TTestToolLog.Obj(const AJson: string): TJSONObject;
begin
  Result := TJSONObject(GetJSON(AJson));
end;

function TTestToolLog.Canon(const AJson: string): string;
var
  O : TJSONObject;
begin
  O := Obj(AJson);
  try
    Result := McpCanonicalJson(O);
  finally
    O.Free;
  end;
end;

function TTestToolLog.HashOf(const AJson: string): string;
var
  O : TJSONObject;
begin
  O := Obj(AJson);
  try
    Result := McpArgsPrint(O).Hash;
  finally
    O.Free;
  end;
end;

function TTestToolLog.Lines: TStringList;
begin
  Result := TStringList.Create;
  if FileExists(McpToolLogPath) then Result.LoadFromFile(McpToolLogPath);
end;

function TTestToolLog.Line(AIndex: Integer): TJSONObject;
var
  L : TStringList;
begin
  L := Lines;
  try
    AssertTrue('line ' + IntToStr(AIndex) + ' exists', AIndex < L.Count);
    Result := TJSONObject(GetJSON(L[AIndex]));
  finally
    L.Free;
  end;
end;

function TTestToolLog.Caller: TMcpLogCaller;
begin
  Result.Client  := 'claude-code 2.1';
  Result.Token   := 'laptop';
  Result.Session := 'd97f7ac2';
end;

procedure TTestToolLog.TestKeysAreSortedAndCompact;
begin
  CheckEquals('{"a":1,"b":{"x":true,"y":null},"c":[2,"z"]}',
    Canon('{ "c": [2, "z"], "b": {"y": null, "x": true}, "a": 1 }'));
end;

procedure TTestToolLog.TestKeyOrderDoesNotChangeTheHash;
begin
  CheckEquals(HashOf('{"file":"a.pas","line":3}'), HashOf('{"line":3,"file":"a.pas"}'));
  CheckNotEquals(HashOf('{"file":"a.pas","line":3}'), HashOf('{"file":"a.pas","line":4}'));
  CheckEquals(12, Length(HashOf('{"file":"a.pas"}')), 'twelve digits');
end;

procedure TTestToolLog.TestNoArgumentsHashLikeAnEmptyObject;
var
  P : TMcpArgsPrint;
begin
  P := McpArgsPrint(nil);
  CheckEquals(HashOf('{}'), P.Hash);
  CheckEquals(0, Length(P.Keys));
end;

procedure TTestToolLog.TestSlashAndBackslashDiffer;
begin
  { different inputs are different inputs: no path normalization }
  CheckNotEquals(HashOf('{"file":"D:/x/f.pas"}'), HashOf('{"file":"D:\\x\\f.pas"}'));
end;

procedure TTestToolLog.TestControlCharactersAreEscaped;
begin
  CheckEquals('{"s":"a\u000ab\u0009c\"d\\e"}', Canon('{"s":"a\nb\tc\"d\\e"}'));
end;

procedure TTestToolLog.TestNumbersAndBooleans;
begin
  CheckEquals('{"a":-5,"b":false,"c":12345678901,"d":0.5}',
    Canon('{"d":0.5,"c":12345678901,"b":false,"a":-5}'));
end;

procedure TTestToolLog.TestSecretKeysAreRedactedAtAnyDepth;
begin
  CheckEquals('{"env":{"API_TOKEN":"<redacted>","PATH":"x"},"list":[{"Password":"<redacted>"}],"mykey":"<redacted>"}',
    Canon('{"mykey":"s1","env":{"PATH":"x","API_TOKEN":"s2"},"list":[{"Password":"s3"}]}'));
end;

procedure TTestToolLog.TestChangedSecretLeavesTheHashAlone;
begin
  CheckEquals(HashOf('{"user":"u","password":"one"}'), HashOf('{"user":"u","password":"two"}'));
  CheckNotEquals(HashOf('{"user":"u","password":"one"}'), HashOf('{"user":"v","password":"one"}'));
end;

procedure TTestToolLog.TestUrlUserInfoAndQuerySecretsAreRemoved;
begin
  CheckEquals('{"u":"https://example.org/p?a=1&access_token=<redacted>&b=2"}',
    Canon('{"u":"https://example.org/p?a=1&access_token=abc&b=2"}'));
  CheckEquals('{"u":"https://example.org/repo.git"}',
    Canon('{"u":"https://me:pw@example.org/repo.git"}'));
  CheckEquals('{"s":"not a url: user@host"}', Canon('{"s":"not a url: user@host"}'));
end;

procedure TTestToolLog.TestArgKeysAreSortedAsReceived;
var
  O : TJSONObject;
  P : TMcpArgsPrint;
begin
  O := Obj('{"zeta":1,"alpha":2,"password":"x"}');
  try
    P := McpArgsPrint(O);
  finally
    O.Free;
  end;
  CheckEquals(3, Length(P.Keys));
  CheckEquals('alpha', P.Keys[0]);
  CheckEquals('password', P.Keys[1], 'names are not secrets');
  CheckEquals('zeta', P.Keys[2]);
end;

procedure TTestToolLog.TestOffWritesNothing;
var
  P : TMcpArgsPrint;
begin
  McpToolLogSetEnabled(False);
  P := McpArgsPrint(nil);
  CheckEquals(0, McpToolLogBegin('ide_ping', Caller));
  McpToolLogEnd(0, 'ide_ping', Caller, 1, True, '', P);
  CheckFalse(FileExists(McpToolLogPath), 'no file');
end;

procedure TTestToolLog.TestBeginAndEndLines;
var
  Seq : LongInt;
  P   : TMcpArgsPrint;
  O   : TJSONObject;
begin
  McpToolLogSetProject('app.lpi');
  O := Obj('{"clean":true}');
  try
    P := McpArgsPrint(O);
  finally
    O.Free;
  end;
  Seq := McpToolLogBegin('project_build', Caller);
  CheckTrue(Seq > 0, 'seq');
  McpToolLogEnd(Seq, 'project_build', Caller, 8120, True, '', P);
  O := Line(0);
  try
    CheckEquals('begin', O.Get('event', ''));
    CheckEquals(Seq, O.Get('seq_id', 0));
    CheckEquals('project_build', O.Get('tool', ''));
    CheckEquals('laptop', O.Objects['caller'].Get('token', ''));
    CheckEquals('claude-code 2.1', O.Objects['caller'].Get('client', ''));
    CheckEquals(24, Length(O.Get('timestamp', '')), 'ISO 8601 UTC with milliseconds');
    CheckEquals('Z', Copy(O.Get('timestamp', ''), 24, 1));
  finally
    O.Free;
  end;
  O := Line(1);
  try
    CheckEquals('end', O.Get('event', ''));
    CheckEquals(Seq, O.Get('seq_id', 0));
    CheckEquals(8120, O.Get('duration_ms', 0));
    CheckTrue(O.Objects['response'].Get('success', False));
    CheckEquals(-1, O.Objects['response'].IndexOfName('error'), 'no text on success');
    CheckEquals('app.lpi', O.Get('project', ''));
    CheckEquals('clean', O.Arrays['arg_keys'].Strings[0]);
    CheckEquals(P.Hash, O.Get('args_hash', ''));
  finally
    O.Free;
  end;
end;

procedure TTestToolLog.TestEndOfAFailedCallCarriesACutError;
var
  Seq : LongInt;
  O   : TJSONObject;
  Err : string;
begin
  Seq := McpToolLogBegin('editor_open', Caller);
  McpToolLogEnd(Seq, 'editor_open', Caller, 5, False, StringOfChar('x', 1000), McpArgsPrint(nil));
  O := Line(1);
  try
    CheckFalse(O.Objects['response'].Get('success', True));
    Err := O.Objects['response'].Get('error', '');
    CheckTrue((Length(Err) > 300) and (Length(Err) <= 303), 'cut to 300 plus a marker');
    CheckEquals('...', Copy(Err, Length(Err) - 2, 3));
  finally
    O.Free;
  end;
end;

procedure TTestToolLog.TestNonUtf8ErrorTextStaysValidJson;
var
  Seq : LongInt;
  O   : TJSONObject;
begin
  Seq := McpToolLogBegin('editor_open', Caller);
  { a Windows message in a single-byte code page: bytes that are not UTF-8 }
  McpToolLogEnd(Seq, 'editor_open', Caller, 5, False, 'File ' + #$CF#$F0#$E8 + ' not found',
    McpArgsPrint(nil));
  O := Line(1);   { GetJSON raises if the line is not valid JSON }
  try
    CheckEquals('File ??? not found', O.Objects['response'].Get('error', ''));
  finally
    O.Free;
  end;
end;

procedure TTestToolLog.TestSeqIdsIncrease;
var
  A, B : LongInt;
begin
  A := McpToolLogBegin('a', Caller);
  B := McpToolLogBegin('b', Caller);
  CheckTrue(B > A, 'increasing');
end;

procedure TTestToolLog.TestRotation;
var
  I : Integer;
  P : string;
begin
  McpToolLogSetMaxBytes(2000);
  P := McpToolLogPath;
  for I := 1 to 60 do
    McpToolLogEnd(McpToolLogBegin('t', Caller), 't', Caller, 1, True, '', McpArgsPrint(nil));
  CheckTrue(FileExists(P), 'current file');
  CheckTrue(FileExists(P + '.1'), '.1');
  CheckTrue(FileExists(P + '.2'), '.2');
  CheckTrue(FileExists(P + '.3'), '.3');
  CheckFalse(FileExists(P + '.4'), 'nothing beyond .3');
end;

procedure TTestToolLog.TestSwitchedOffAfterFailedWrites;
var
  I : Integer;
begin
  { a folder that is not there: every write fails }
  McpToolLogSetDir(IncludeTrailingPathDelimiter(FDir) + 'missing' + PathDelim + 'deeper');
  CheckTrue(McpToolLogEnabled, 'on before the failures');
  for I := 1 to MCP_TOOL_LOG_FAILURES do
    McpToolLogBegin('t', Caller);
  CheckFalse(McpToolLogEnabled, 'off after five failed writes');
  McpToolLogSetEnabled(True);
  CheckTrue(McpToolLogEnabled, 'switching it on again clears that');
end;

procedure TTestToolLog.TestStartAndSessionRecords;
var
  O : TJSONObject;
begin
  McpToolLogStart('1.1', 'Lazarus 4.0', 'FPC 3.2.2', 'Win64');
  McpToolLogSession(Caller, '2025-06-18', '2025-11-25');
  O := Line(0);
  try
    CheckEquals('start', O.Get('event', ''));
    CheckEquals(MCP_TOOL_LOG_FORMAT, O.Get('log_format', 0));
    CheckEquals(6, Length(O.Get('utc_offset', '')), 'offset like +03:00');
  finally
    O.Free;
  end;
  O := Line(1);
  try
    CheckEquals('session', O.Get('event', ''));
    CheckEquals('2025-11-25', O.Get('protocol_asked', ''));
  finally
    O.Free;
  end;
end;

initialization
  RegisterTest(TTestToolLog);
end.
