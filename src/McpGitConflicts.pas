{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpGitConflicts;

{ Resolving a git conflict in the review window (ADR-028, section 3).

  When git_merge, git_rebase, git_rebase_continue or a squash merge stops on a conflict,
  every conflicted text file gets a page in the review window of ADR-025: the left pane
  is stage 2 (what the current side has), the right pane stage 3, the base stage 1,
  read from the index, never from the marker text.  "Resolve (write and stage)" writes
  the result to the file in the line ending the file has and runs `git add`; "Leave
  unresolved" changes nothing.  A file that is not a text merge (one side deleted it, a
  symlink, a submodule, binary, very large) gets no page and is listed under
  needs_decision, to settle with git_resolve.

  Main thread. }

{$mode objfpc}{$H+}

interface

uses
  fpjson, McpToolsGitRemote;

{ Opens the pages for the unmerged files of the repository.  AKind: merge, rebase or
  squash (what stopped).  The answer is the "review" member of the tool result:
  window, files, needs_decision (each: file, reason). }
function ShowConflicts(const G: TGit; const AKind: string): TJSONObject;

{ Removes the pages of files that are not unmerged any more (resolved with git_add or
  git_resolve, merged, rebased or aborted).  Cheap when no page is open. }
procedure SyncConflicts(const G: TGit);

implementation

uses
  Classes, SysUtils, Forms, LazFileUtils, IDEExternToolIntf,
  McpDiff, McpConflictFiles, McpMessages, McpReviewView;

const
  MAX_TEXT_BYTES = 1024 * 1024;     { a page diffs three copies in memory }

type
  TEntry = class
    G        : TGit;           { Dir is the top of the work tree }
    Rel      : string;         { as git lists it: relative to the top, with / }
    Abs      : string;
    Snapshot : string;         { the file as it was when the page was opened }
  end;

  TOwner = class
  private
    FDropLater : TStringList;
    procedure DropPending(Data: PtrInt);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Done(const AFile: string; AApplied: Boolean; const ANewText: string);
  end;

var
  GEntries : TList  = nil;
  GOwner   : TOwner = nil;

function ReadAll(const AName: string; out AText: string): Boolean;
var
  S : TFileStream;
begin
  Result := False;
  AText := '';
  try
    S := TFileStream.Create(AName, fmOpenRead or fmShareDenyNone);
    try
      SetLength(AText, S.Size);
      if S.Size > 0 then
        S.ReadBuffer(AText[1], S.Size);
      Result := True;
    finally
      S.Free;
    end;
  except
    on E: EStreamError do ;
    on E: EInOutError do ;
  end;
end;

function WriteAll(const AName, AText: string): Boolean;
var
  S : TFileStream;
begin
  Result := False;
  try
    S := TFileStream.Create(AName, fmCreate);
    try
      if AText <> '' then
        S.WriteBuffer(AText[1], Length(AText));
      Result := True;
    finally
      S.Free;
    end;
  except
    on E: EStreamError do ;
    on E: EInOutError do ;
  end;
end;

function TopOf(const G: TGit): string;
begin
  Result := QueryText(G, ['rev-parse', '--show-toplevel']);
  if Result = '' then
    Result := G.Dir;
  Result := ExpandFileName(Result);
end;

function Unmerged(const G: TGit): TConflictStagesArray;
var
  Output : string;
begin
  if Query(G, ['ls-files', '-u', '-z', '--full-name'], Output) then
    Result := ParseUnmerged(Output)
  else
    Result := nil;
end;

function FindEntry(const AAbs: string): TEntry;
var
  I : Integer;
begin
  if GEntries <> nil then
    for I := 0 to GEntries.Count - 1 do
      if SameFileName(TEntry(GEntries[I]).Abs, AAbs) then
        Exit(TEntry(GEntries[I]));
  Result := nil;
end;

procedure RemoveEntry(AEntry: TEntry);
begin
  GEntries.Remove(AEntry);
  AEntry.Free;
end;

{ The titles of the two panes.  In a rebase git's "ours" is what is rebased onto and
  "theirs" the commit being replayed, so the titles say what each side is. }
procedure SideTitles(const G: TGit; const AKind: string; out ALeft, ARight: string);
var
  Subject : string;

  function Commit(const ARev: string): string;
  begin
    Result := QueryText(G, ['log', '-1', '--format=%h %s', ARev, '--']);
  end;

begin
  case AKind of
    'rebase':
    begin
      Subject := Commit('HEAD');
      ALeft := 'Upstream: ' + Subject;
      Subject := Commit('REBASE_HEAD');
      if Subject = '' then
        Subject := 'the commit being replayed';
      ARight := 'Your commit: ' + Subject;
    end;
  else
    Subject := CurrentBranch(G);
    if Subject = '' then
      Subject := 'HEAD';
    ALeft := 'Ours: ' + Subject;
    Subject := Commit('MERGE_HEAD');
    if Subject = '' then
      Subject := 'the merged ref';
    ARight := 'Theirs: ' + Subject;
  end;
end;

procedure AddUndecided(AList: TJSONArray; const AFile, AReason: string);
var
  Obj : TJSONObject;
begin
  Obj := TJSONObject.Create;
  Obj.Add('file', AFile);
  Obj.Add('reason', AReason);
  AList.Add(Obj);
end;

function ShowConflicts(const G: TGit; const AKind: string): TJSONObject;
var
  Top      : TGit;
  Stages   : TConflictStagesArray;
  Item     : TConflictStages;
  Entry    : TEntry;
  Shown    : TJSONArray;
  Undecided: TJSONArray;
  Left, Right, Reason : string;
  Blobs    : array[1..3] of string;
  Stage    : Integer;
  Old      : TEntry;
begin
  Result    := TJSONObject.Create;
  Shown     := TJSONArray.Create;
  Undecided := TJSONArray.Create;
  Result.Add('window', 'Review');
  Result.Add('files', Shown);
  Result.Add('needs_decision', Undecided);
  if GEntries = nil then GEntries := TList.Create;
  if GOwner = nil then GOwner := TOwner.Create;

  Top     := G;
  Top.Dir := TopOf(G);
  Stages  := Unmerged(Top);
  SideTitles(Top, AKind, Left, Right);
  McpReviewRoot := Top.Dir;

  for Item in Stages do
  begin
    Reason := NotTextReason(Item);
    if Reason = '' then
      for Stage := 1 to 3 do
      begin
        Blobs[Stage] := '';
        if not Item.Has[Stage] then Continue;
        if not Query(Top, ['show', ':' + IntToStr(Stage) + ':' + Item.Path], Blobs[Stage]) then
          Reason := 'could not read stage ' + IntToStr(Stage) + ' of the index'
        else if LooksBinary(Blobs[Stage]) then
          Reason := 'a binary file'
        else if Length(Blobs[Stage]) > MAX_TEXT_BYTES then
          Reason := 'too large for the window';
        if Reason <> '' then Break;
      end;
    if Reason = '' then
    begin
      Entry := TEntry.Create;
      Entry.G   := Top;
      Entry.Rel := Item.Path;
      Entry.Abs := ExpandFileName(IncludeTrailingPathDelimiter(Top.Dir) +
        StringReplace(Item.Path, '/', PathDelim, [rfReplaceAll]));
      if not ReadAll(Entry.Abs, Entry.Snapshot) then
      begin
        Reason := 'the file could not be read';
        Entry.Free;
      end
      else
      begin
        Old := FindEntry(Entry.Abs);
        if Old <> nil then RemoveEntry(Old);        { a rebase stopped again: new stages }
        GEntries.Add(Entry);
        try
          McpReviewShow(Entry.Abs, Left, Right, LinesOf(Blobs[2]), LinesOf(Blobs[3]),
            LinesOf(Blobs[1]), Item.Has[1], @GOwner.Done, True);
          Shown.Add(Item.Path);
        except
          on E: Exception do
          begin
            RemoveEntry(Entry);
            Reason := 'the window failed: ' + E.Message;
          end;
        end;
      end;
    end;
    if Reason <> '' then
      AddUndecided(Undecided, Item.Path, Reason);
  end;
  if Shown.Count > 0 then
    McpAddMessage(mluImportant, Format('Git conflict: %d file(s) wait in the Review window',
      [Shown.Count]));
end;

procedure SyncConflicts(const G: TGit);
var
  Top    : TGit;
  Stages : TConflictStagesArray;
  Item   : TConflictStages;
  Entry  : TEntry;
  I      : Integer;
  Still  : Boolean;
begin
  if (GEntries = nil) or (GEntries.Count = 0) then Exit;
  Top     := G;
  Top.Dir := TopOf(G);
  Stages  := Unmerged(Top);
  for I := GEntries.Count - 1 downto 0 do
  begin
    Entry := TEntry(GEntries[I]);
    if not SameFileName(Entry.G.Dir, Top.Dir) then Continue;
    Still := False;
    for Item in Stages do
      if Item.Path = Entry.Rel then
      begin
        Still := True;
        Break;
      end;
    if Still then Continue;
    McpReviewDrop(Entry.Abs);
    RemoveEntry(Entry);
  end;
end;

{ ── What the buttons do ──────────────────────────────────────────────────── }

constructor TOwner.Create;
begin
  inherited Create;
  FDropLater := TStringList.Create;
end;

destructor TOwner.Destroy;
begin
  FDropLater.Free;
  inherited Destroy;
end;

{ A page cannot be removed while one of its buttons is still running. }
{ QueueAsyncCall fixes the signature; Data is not needed here }
{$PUSH}{$WARN 5024 OFF}
procedure TOwner.DropPending(Data: PtrInt);
var
  Name : string;
begin
  for Name in FDropLater do
    McpReviewDrop(Name);
  FDropLater.Clear;
end;
{$POP}

procedure TOwner.Done(const AFile: string; AApplied: Boolean; const ANewText: string);
var
  Entry    : TEntry;
  Current, Output, Eol, Name : string;
  Final    : Boolean;
  Stages   : TConflictStagesArray;
  Item     : TConflictStages;
  Open     : Boolean;
begin
  Entry := FindEntry(AFile);
  if Entry = nil then Exit;
  Name := ExtractFileName(Entry.Abs);
  try
    if not AApplied then
    begin
      McpAddMessage(mluProgress, 'Git conflict: ' + Name + ' left unresolved');
      Exit;
    end;

    { settled meanwhile by someone else (the assistant edited it, or git_add ran): nothing
      is written over that }
    Open := False;
    Stages := Unmerged(Entry.G);
    for Item in Stages do
      if Item.Path = Entry.Rel then
        Open := True;
    if (not Open) or not ReadAll(Entry.Abs, Current) or (Current <> Entry.Snapshot) then
    begin
      McpAddMessage(mluImportant, 'Git conflict: ' + Name + ' changed meanwhile; nothing was written');
      FDropLater.Add(Entry.Abs);
      Application.QueueAsyncCall(@DropPending, 0);
      Exit;
    end;

    Eol := EolOf(Entry.Snapshot);
    SplitLines(Entry.Snapshot, Final);
    if not WriteAll(Entry.Abs, WithEol(ANewText, Eol, Final)) then
    begin
      McpAddMessage(mluImportant, 'Git conflict: ' + Name + ' could not be written');
      Exit;
    end;
    if not Query(Entry.G, ['add', '--', Entry.Rel], Output) then
    begin
      McpAddMessage(mluImportant, 'Git conflict: git add failed for ' + Name + ': ' + Trim(Output));
      Exit;
    end;
    McpAddMessage(mluProgress, 'Git conflict: ' + Name + ' resolved and staged');
  finally
    { the page is answered either way; a later git_status shows what is left }
    if FindEntry(AFile) = Entry then
      RemoveEntry(Entry);
  end;
end;

finalization
  GOwner.Free;
  if GEntries <> nil then
  begin
    while GEntries.Count > 0 do
      RemoveEntry(TEntry(GEntries[GEntries.Count - 1]));
    GEntries.Free;
  end;

end.
