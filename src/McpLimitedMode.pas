{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpLimitedMode;

{ Limited mode (ADR-034, decision 5): the user lists folders in Options > MCP Assistant; with at
  least one, the tools write, create projects in, and read files only inside them (plus what an
  assistant needs to read: the open project, loaded packages, the Lazarus and FPC sources, the
  temp folder).  With none, nothing is limited.

  This limits the file access of the tools.  It does not limit what a program that a tool builds
  and runs does.

  Pure RTL + LazUtils: the IDE's part (which roots are readable) comes in through
  GMcpReadableRoots. }

{$mode objfpc}{$H+}

interface

uses
  Classes, fpjson;

type
  { fills the folders that may be read although they are not allowed folders }
  TMcpReadableRoots = procedure(AList: TStrings);

  { the folder a relative path is taken from: the open project's }
  TMcpBaseDir = function: string;

var
  GMcpReadableRoots : TMcpReadableRoots = nil;
  GMcpBaseDir       : TMcpBaseDir = nil;

{ A folder as the setting stores it: absolute, cleaned.  False (with the reason) for a relative
  path or a drive or file system root, which the user is told and which is left out. }
function McpLimitCleanFolder(const AInput: string; out AClean, AWhy: string): Boolean;

{ The allowed folders; each is cleaned, an entry that cannot be is dropped.  [] ends limited mode. }
procedure McpLimitSetFolders(const AFolders: array of string);
procedure McpLimitSetFoldersFrom(AList: TStrings);

function McpLimitedOn: Boolean;
function McpLimitFoldersText: string;       { 'D:\a, D:\b' }

{ APath (absolute) is an allowed folder or inside one, where it really is (links resolved) }
function McpInAllowedFolders(const APath: string): Boolean;

{ The tool's path arguments against limited mode: new places only inside the allowed folders,
  read paths inside them or in the readable roots.  Writes are not judged here (the writable
  roots are, see McpWritableRoots).  A relative path is taken from ABase.  True when limited
  mode is off. }
function McpLimitCheckUse(const ATool: string; AArgs: TJSONObject; const ABase: string;
  out AWhy: string): Boolean;

implementation

uses
  SysUtils, LazFileUtils, McpUtils, McpToolScope;

var
  GFolders : TStringList = nil;

function Folders: TStringList;
begin
  if GFolders = nil then GFolders := TStringList.Create;
  Result := GFolders;
end;

function McpLimitCleanFolder(const AInput: string; out AClean, AWhy: string): Boolean;
var
  S, Bare : string;
begin
  AClean := '';
  AWhy := '';
  S := Trim(AInput);
  if S = '' then
  begin
    AWhy := 'empty';
    Exit(False);
  end;
  if not FilenameIsAbsolute(S) then
  begin
    AWhy := 'not an absolute path: ' + S;
    Exit(False);
  end;
  Bare := ExcludeTrailingPathDelimiter(CleanAndExpandFilename(S));
  if (ExtractFilePath(Bare) = '') or (ExtractFilePath(Bare) = Bare) then
  begin
    AWhy := 'a drive or file system root would allow the whole disk: ' + S;
    Exit(False);
  end;
  AClean := Bare;
  Result := True;
end;

procedure McpLimitSetFolders(const AFolders: array of string);
var
  I : Integer;
  C, W : string;
begin
  Folders.Clear;
  for I := Low(AFolders) to High(AFolders) do
    if McpLimitCleanFolder(AFolders[I], C, W) and (Folders.IndexOf(C) < 0) then
      Folders.Add(C);
end;

procedure McpLimitSetFoldersFrom(AList: TStrings);
var
  A : array of string = nil;
  I : Integer;
begin
  SetLength(A, AList.Count);
  for I := 0 to AList.Count - 1 do A[I] := AList[I];
  McpLimitSetFolders(A);
end;

function McpLimitedOn: Boolean;
begin
  Result := (GFolders <> nil) and (GFolders.Count > 0);
end;

function McpLimitFoldersText: string;
var
  I : Integer;
begin
  Result := '';
  if GFolders = nil then Exit;
  for I := 0 to GFolders.Count - 1 do
  begin
    if I > 0 then Result := Result + ', ';
    Result := Result + GFolders[I];
  end;
end;

{ equal to, or inside, AFolder; both as they really are }
function InFolder(const APath, AFolder: string): Boolean;
var
  P, F : string;
begin
  P := ExcludeTrailingPathDelimiter(McpRealPath(APath));
  F := ExcludeTrailingPathDelimiter(McpRealPath(AFolder));
  Result := (CompareFilenames(P, F) = 0) or McpPathIsUnder(P, F);
end;

function McpInAllowedFolders(const APath: string): Boolean;
var
  I : Integer;
begin
  Result := False;
  if not FilenameIsAbsolute(APath) then Exit;
  if GFolders = nil then Exit;
  for I := 0 to GFolders.Count - 1 do
    if InFolder(APath, GFolders[I]) then Exit(True);
end;

function InReadable(const APath: string; AList: TStrings): Boolean;
var
  I : Integer;
begin
  Result := False;
  for I := 0 to AList.Count - 1 do
    if (AList[I] <> '') and FilenameIsAbsolute(AList[I]) and InFolder(APath, AList[I]) then
      Exit(True);
end;

function McpLimitCheckUse(const ATool: string; AArgs: TJSONObject; const ABase: string;
  out AWhy: string): Boolean;
var
  K       : Integer;
  P       : TMcpToolPath;
  V, Abs  : string;
  Node    : TJSONData;
  Extra   : TStringList;
  Allowed : Boolean;
begin
  AWhy := '';
  if not McpLimitedOn then Exit(True);
  if AArgs = nil then Exit(True);
  Extra := nil;
  try
    K := 0;
    while McpToolPathFor(ATool, K, P) do
    begin
      Inc(K);
      if not (P.Use in [puRead, puNewPlace]) then Continue;
      Node := AArgs.Find(P.Arg);
      if not (Node is TJSONString) then Continue;
      V := Trim(Node.AsString);
      if V = '' then Continue;
      if FilenameIsAbsolute(V) then Abs := V
      else if ABase <> '' then Abs := ConcatPaths([ABase, V])
      else
      begin
        AWhy := 'Refused: limited mode is on and ' + P.Arg + ' of ' + ATool + ' is relative with ' +
          'no project open to take it from. Give an absolute path inside the allowed folders: ' +
          McpLimitFoldersText;
        Exit(False);
      end;
      Abs := CleanAndExpandFilename(Abs);
      Allowed := McpInAllowedFolders(Abs);
      if (not Allowed) and (P.Use = puRead) then
      begin
        if Extra = nil then
        begin
          Extra := TStringList.Create;
          if Assigned(GMcpReadableRoots) then GMcpReadableRoots(Extra);
        end;
        Allowed := InReadable(Abs, Extra);
      end;
      if not Allowed then
      begin
        AWhy := 'Refused: limited mode is on. ' + ATool + ' ' + P.Arg + ' = ' + V + ' is outside ' +
          'the allowed folders (' + McpLimitFoldersText + ')';
        if P.Use = puRead then
          AWhy := AWhy + ', the open project, the loaded packages, the Lazarus and FPC sources ' +
            'and the temp folder';
        AWhy := AWhy + '. The user sets them in Tools > Options > MCP Assistant.';
        Exit(False);
      end;
    end;
  finally
    Extra.Free;
  end;
  Result := True;
end;

finalization
  GFolders.Free;

end.
