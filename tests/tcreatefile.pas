{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TCreateFile;

{ TTestCreateFile — editor_create_file: a new file on the machine the IDE runs on, only inside the
  project, a package or the temp folder, never in .git, no overwrite unless asked.
  Requires a running MCP server. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, THttpHelper;

type
  TTestCreateFile = class(TTestCase)
  private
    FRoot : string;
    function Call(const AArgs: string): string;
    function Path(const ARel: string): string;
    function ReadAll(const AFile: string): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestCreatesInNewFolders;
    procedure TestEmptyFile;
    procedure TestExistingFileRefusedUnlessOverwrite;
    procedure TestOverwriteRefusedWhileOpen;
    procedure TestOutsideTheAllowedFoldersRefused;
    procedure TestDotDotCannotEscape;
    procedure TestGitFolderRefused;
    procedure TestDirectoryRefused;
  end;

implementation

uses
  Classes, SysUtils, FileUtil;

function IsError(const T: string): Boolean;
begin
  Result := (Pos('TOOL ERROR', T) = 1) or (Pos('RPC ERROR', T) = 1) or (Pos('HTTP ', T) = 1);
end;

procedure TTestCreateFile.SetUp;
begin
  FRoot := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'mcpcreate' + PathDelim +
           TestName + PathDelim;
end;

procedure TTestCreateFile.TearDown;
begin
  DeleteDirectory(ExcludeTrailingPathDelimiter(FRoot), False);
  RemoveDir(ExcludeTrailingPathDelimiter(FRoot));
  RemoveDir(ExcludeTrailingPathDelimiter(ExtractFileDir(ExcludeTrailingPathDelimiter(FRoot))));
end;

function TTestCreateFile.Call(const AArgs: string): string;
begin
  Result := CallToolText('editor_create_file', AArgs, []);
end;

function TTestCreateFile.Path(const ARel: string): string;
begin
  Result := FRoot + ARel;
end;

function TTestCreateFile.ReadAll(const AFile: string): string;
var
  SL : TStringList;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(AFile);
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

procedure TTestCreateFile.TestCreatesInNewFolders;
var
  T, F : string;
begin
  F := Path('sub' + PathDelim + 'deeper' + PathDelim + 'a.txt');
  T := Call('{"file":' + JsonStr(F) + ',"text":"one\ntwo\r\nthree"}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"created":true', T) > 0, T);
  CheckTrue(Pos('"opened":true', T) > 0, 'opened in the editor: ' + T);
  CheckEquals('one' + LineEnding + 'two' + LineEnding + 'three' + LineEnding, ReadAll(F));
  CallToolText('editor_close', '{"file":' + JsonStr(F) + '}', []);
end;

procedure TTestCreateFile.TestEmptyFile;
var
  T, F : string;
begin
  F := Path('empty.txt');
  T := Call('{"file":' + JsonStr(F) + ',"open":false}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"bytes":0', T) > 0, T);
  CheckTrue(Pos('"opened":false', T) > 0, T);
  CheckTrue(FileExists(F));
end;

procedure TTestCreateFile.TestExistingFileRefusedUnlessOverwrite;
var
  T, F : string;
begin
  F := Path('a.txt');
  CheckFalse(IsError(Call('{"file":' + JsonStr(F) + ',"text":"first","open":false}')));
  T := Call('{"file":' + JsonStr(F) + ',"text":"second","open":false}');
  CheckTrue(IsError(T), T);
  CheckTrue(Pos('already exists', T) > 0, T);
  CheckEquals('first' + LineEnding, ReadAll(F), 'untouched after the refusal');
  T := Call('{"file":' + JsonStr(F) + ',"text":"second","overwrite":true,"open":false}');
  CheckFalse(IsError(T), T);
  CheckTrue(Pos('"replaced":true', T) > 0, T);
  CheckEquals('second' + LineEnding, ReadAll(F));
end;

procedure TTestCreateFile.TestOverwriteRefusedWhileOpen;
var
  T, F : string;
begin
  F := Path('open.txt');
  CheckFalse(IsError(Call('{"file":' + JsonStr(F) + ',"text":"first"}')));
  T := Call('{"file":' + JsonStr(F) + ',"text":"second","overwrite":true}');
  CheckTrue(IsError(T), T);
  CheckTrue(Pos('open in an editor', T) > 0, T);
  CheckEquals('first' + LineEnding, ReadAll(F));
  CallToolText('editor_close', '{"file":' + JsonStr(F) + '}', []);
end;

procedure TTestCreateFile.TestOutsideTheAllowedFoldersRefused;
var
  T, F : string;
begin
  F := IncludeTrailingPathDelimiter(GetUserDir) + 'mcp_must_not_exist.txt';
  T := Call('{"file":' + JsonStr(F) + ',"text":"x","open":false}');
  CheckTrue(IsError(T), T);
  CheckTrue(Pos('Refused', T) > 0, T);
  CheckFalse(FileExists(F), 'nothing was written');
end;

procedure TTestCreateFile.TestDotDotCannotEscape;
var
  T, F : string;
begin
  F := FRoot + '..' + PathDelim + '..' + PathDelim + '..' + PathDelim + 'mcp_escape.txt';
  T := Call('{"file":' + JsonStr(F) + ',"text":"x","open":false}');
  CheckTrue(IsError(T), T);
  CheckTrue(Pos('Refused', T) > 0, T);
  CheckFalse(FileExists(ExpandFileName(F)), 'nothing was written');
end;

procedure TTestCreateFile.TestGitFolderRefused;
var
  T, F : string;
begin
  F := Path('repo' + PathDelim + '.git' + PathDelim + 'hooks' + PathDelim + 'pre-push');
  T := Call('{"file":' + JsonStr(F) + ',"text":"#!/bin/sh","open":false}');
  CheckTrue(IsError(T), T);
  CheckTrue(Pos('.git', T) > 0, T);
  CheckFalse(FileExists(F), 'nothing was written');
  CheckFalse(DirectoryExists(Path('repo')), 'not even the folder');
end;

procedure TTestCreateFile.TestDirectoryRefused;
var
  T : string;
begin
  ForceDirectories(FRoot + 'adir');
  T := Call('{"file":' + JsonStr(FRoot + 'adir') + ',"text":"x","open":false}');
  CheckTrue(IsError(T), T);
  CheckTrue(Pos('directory', T) > 0, T);
end;

initialization
  RegisterTest(TTestCreateFile);

end.
