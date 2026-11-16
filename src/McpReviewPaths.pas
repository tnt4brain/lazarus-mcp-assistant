{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpReviewPaths;

{ ADR-025: the file tree of the review window.  Pure string work, no IDE: a file name
  becomes the folder names and file name below the project root, or, for a file outside
  it, the one entry "the full path". }

{$mode objfpc}{$H+}

interface

uses
  Classes;

type
  TPathParts = array of string;

{ AFile's folders and its name relative to ARoot ("src", "units", "a.pas").  A file
  that is not below ARoot (or an empty ARoot) comes back as ONE part, the whole path,
  and AOutside is True.  Either slash is accepted; the case is ignored on Windows. }
function ReviewPathParts(const AFile, ARoot: string; out AOutside: Boolean): TPathParts;

{ The sentence for the model about the files of one reload pass whose editors hold unsaved
  edits: those waiting for the user's review (AAsk), those where the editor kept its text
  and the disk version went to name.ext.agent (AKept), those where the editor took the
  disk text (ATaken).  Every file is named; '' when there is none. }
function ReviewNoticeText(AAsk, AKept, ATaken: TStrings): string;

{ A stamp of a file's state on disk: modification time to the millisecond and size, '' when
  there is no such file.  Not FileAge: that is DOS time, two seconds, and a second write
  within the same two seconds (an agent fixing its own file) looked like no change at all. }
function McpFileStamp(const AFile: string): string;

implementation

uses
  SysUtils;

function McpFileStamp(const AFile: string): string;
var
  DT : TDateTime;
  SR : TSearchRec;
begin
  Result := '';
  if not FileAge(AFile, DT) then Exit;
  if FindFirst(AFile, faAnyFile, SR) <> 0 then Exit;
  try
    Result := IntToStr(Round(DT * 86400000)) + ':' + IntToStr(SR.Size);
  finally
    FindClose(SR);
  end;
end;

function NamesOf(AList: TStrings): string;
var
  I: Integer;
begin
  Result := '';
  if AList = nil then Exit;
  for I := 0 to AList.Count - 1 do
  begin
    if I > 0 then Result := Result + ', ';
    Result := Result + AList[I];
  end;
end;

function ReviewNoticeText(AAsk, AKept, ATaken: TStrings): string;
begin
  Result := '';
  if (AAsk <> nil) and (AAsk.Count > 0) then
    Result := Result + NamesOf(AAsk) + ' changed on disk while the IDE holds unsaved ' +
      'edits in it, so it was not loaded: the user is asked to review it. ';
  if (AKept <> nil) and (AKept.Count > 0) then
    Result := Result + NamesOf(AKept) + ' changed on disk while the IDE holds unsaved ' +
      'edits in it: by the user''s setting the editor kept its text and your version was ' +
      'saved as name.ext.agent beside the file. ';
  if (ATaken <> nil) and (ATaken.Count > 0) then
    Result := Result + NamesOf(ATaken) + ' changed on disk while the IDE held unsaved ' +
      'edits in it: by the user''s setting the editor took your version (Ctrl+Z undoes it). ';
  if Result <> '' then Result := Result + 'Write files through the editor_* tools.';
end;

function Slashes(const S: string): string;
var
  I: Integer;
begin
  Result := S;
  for I := 1 to Length(Result) do
    if Result[I] = '\' then Result[I] := '/';
end;

function SamePrefix(const S, Prefix: string): Boolean;
begin
  if Length(S) < Length(Prefix) then Exit(False);
  {$IFDEF WINDOWS}
  Result := LowerCase(Copy(S, 1, Length(Prefix))) = LowerCase(Prefix);
  {$ELSE}
  Result := Copy(S, 1, Length(Prefix)) = Prefix;
  {$ENDIF}
end;

function ReviewPathParts(const AFile, ARoot: string; out AOutside: Boolean): TPathParts;
var
  F, R, Rest: string;
  I, Start, N: Integer;
begin
  Result := nil;
  F := Slashes(AFile);
  R := Slashes(ARoot);
  if (R <> '') and (R[Length(R)] <> '/') then R := R + '/';
  AOutside := (R = '') or (not SamePrefix(F, R)) or (Length(F) = Length(R));
  if AOutside then
  begin
    SetLength(Result, 1);
    Result[0] := AFile;
    Exit;
  end;
  Rest := Copy(F, Length(R) + 1, Length(F));
  N := 0;
  Start := 1;
  for I := 1 to Length(Rest) + 1 do
    if (I > Length(Rest)) or (Rest[I] = '/') then
    begin
      if I > Start then
      begin
        SetLength(Result, N + 1);
        Result[N] := Copy(Rest, Start, I - Start);
        Inc(N);
      end;
      Start := I + 1;
    end;
end;

end.
