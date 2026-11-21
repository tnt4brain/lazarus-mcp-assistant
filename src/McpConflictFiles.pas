{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpConflictFiles;

{ The parts of resolving a git conflict in the review window (ADR-028, section 3) that
  need neither the IDE nor git: reading what `git ls-files -u -z` says, deciding which
  files are a text merge, the line ending of the file that is written back, and whether
  a result still holds a conflict block.  Pure RTL, so the test program compiles it. }

{$mode objfpc}{$H+}

interface

uses
  McpDiff;

type
  { One conflicted path: which of the three stages (1 common ancestor, 2 ours, 3 theirs)
    the index holds, and their file modes. }
  TConflictStages = record
    Path : string;
    Has  : array[1..3] of Boolean;
    Mode : array[1..3] of string;
  end;
  TConflictStagesArray = array of TConflictStages;

type
  { A conflict of a merge in the result the review window shows: where its lines are
    (Start, Len: lines of the result), whether the user has done something to them, and
    what the two sides have there. }
  TConflictSpan = record
    Start, Len   : Integer;
    Settled      : Boolean;
    Done         : array[0..1] of Boolean;   { a side's change here has been taken, put
                                                below or dropped: it is no longer offered }
    Took         : array[0..1] of Boolean;   { and its lines went into the result (not
                                                dropped): they now sit where the other
                                                side's change would go }
    Base         : TDiffLines;               { the common lines the conflict started as }
    Ours, Theirs : TDiffLines;
  end;
  TConflictSpans = array of TConflictSpan;

{ What the result starts as: every change only one side made is taken, and each conflict
  holds the common (base) lines, so that both sides stand against it and each can be taken
  or dropped.  Without a base (AHasBase false) it starts empty: the two texts are one
  conflict. }
function ConflictStart(const ABase, AMine, ATheirs: TDiffLines;
  AHasBase: Boolean): TDiffLines;

{ The conflicts of Merge3(Base, Mine, Theirs) as ConflictStart lays out the result: the
  base lines of a conflict.  Without a base the two texts are one conflict with no lines. }
function InitConflictSpans(const ABase, AMine, ATheirs: TDiffLines;
  AHasBase: Boolean): TConflictSpans;

{ The conflict a change of the result belongs to (AStart, ALen: its lines in the result; ALen
  = 0 a place between lines), or -1.  A change next to a conflict's lines counts as in it,
  as the arrows of the window do. }
function SpanOfHunk(const ASpans: TConflictSpans; AStart, ALen: Integer): Integer;

{ AStart..AStart+ALen of the result is replaced by ABLen lines (ALen = 0: lines inserted
  at AStart).  A conflict whose lines that touches is marked settled (ASettle) and grows or
  shrinks with it; one after it moves up or down.  AEdges: a change at the very edge of a
  conflict's lines belongs to it, which is right for an arrow and wrong for typing next to
  it.  A conflict with no lines (a side deleted them) is touched by a change at its place
  either way. }
procedure MoveConflictSpans(var ASpans: TConflictSpans; AStart, ALen, ABLen: Integer;
  ASettle, AEdges: Boolean);

function UnsettledSpans(const ASpans: TConflictSpans): Integer;

{ Decide a conflict again: its lines in AResult go back to the common lines, nothing is
  settled, no side has been dealt with, and the conflicts after it move to fit. }
procedure ResetConflict(var ASpans: TConflictSpans; AIndex: Integer; var AResult: TDiffLines);

{ AOutput of `git ls-files -u -z --full-name`: "<mode> <hash> <stage><TAB><path>", NUL
  after each.  One element per path, in the order git lists them. }
function ParseUnmerged(const AOutput: string): TConflictStagesArray;

{ '' when the file can be merged as text in the window (both sides exist and are regular
  files); else why not, with the stages that exist. }
function NotTextReason(const AEntry: TConflictStages): string;

{ A NUL byte in the first 8000 bytes: the test git itself uses. }
function LooksBinary(const ABlob: string): Boolean;

{ #13#10 when the first line of AText ends so, else #10. }
function EolOf(const AText: string): string;

{ A "<<<<<<<" line with a ">>>>>>>" line after it.  A "=======" alone is no sign: it
  underlines a title in Markdown. }
function HasConflictBlock(const ALines: TDiffLines): Boolean;

{ ANewText (any line ending) written with AEol, and AFinalNewline at its end. }
function WithEol(const ANewText, AEol: string; AFinalNewline: Boolean): string;

implementation

uses
  SysUtils;

function ConflictStart(const ABase, AMine, ATheirs: TDiffLines;
  AHasBase: Boolean): TDiffLines;
var
  Item : TMergeChunk;
  Part : TDiffLines;
  J, N : Integer;
begin
  Result := nil;
  if not AHasBase then Exit;
  N := 0;
  for Item in Merge3(ABase, AMine, ATheirs) do
  begin
    case Item.Kind of
      mkTheirs:   Part := Slice(ATheirs, Item.TheirStart, Item.TheirLen);
      mkConflict: Part := Slice(ABase, Item.BaseStart, Item.BaseLen);
    else
      Part := Slice(AMine, Item.MineStart, Item.MineLen);
    end;
    SetLength(Result, N + Length(Part));
    for J := 0 to High(Part) do
      Result[N + J] := Part[J];
    Inc(N, Length(Part));
  end;
end;

function SpanOfHunk(const ASpans: TConflictSpans; AStart, ALen: Integer): Integer;
var
  I, SStart, SEnd : Integer;
  Hit : Boolean;
begin
  for I := 0 to High(ASpans) do
  begin
    SStart := ASpans[I].Start;
    SEnd   := SStart + ASpans[I].Len;
    if ALen = 0 then
      Hit := (SStart <= AStart) and (AStart <= SEnd)
    else if SStart = SEnd then
      Hit := (AStart <= SStart) and (SStart <= AStart + ALen)
    else
      Hit := (AStart < SEnd) and (SStart < AStart + ALen);
    if Hit then Exit(I);
  end;
  Result := -1;
end;

function InitConflictSpans(const ABase, AMine, ATheirs: TDiffLines;
  AHasBase: Boolean): TConflictSpans;
var
  Item : TMergeChunk;
  N, K : Integer;
begin
  Result := nil;
  if AHasBase then
  begin
    N := 0;
    for Item in Merge3(ABase, AMine, ATheirs) do
      case Item.Kind of
        mkTheirs:
          Inc(N, Item.TheirLen);
        mkConflict:
        begin
          K := Length(Result);
          SetLength(Result, K + 1);
          Result[K].Start   := N;
          Result[K].Len     := Item.BaseLen;
          Result[K].Settled := False;
          Result[K].Done[0] := False;
          Result[K].Done[1] := False;
          Result[K].Took[0] := False;
          Result[K].Took[1] := False;
          Result[K].Base    := Slice(ABase, Item.BaseStart, Item.BaseLen);
          Result[K].Ours    := Slice(AMine, Item.MineStart, Item.MineLen);
          Result[K].Theirs  := Slice(ATheirs, Item.TheirStart, Item.TheirLen);
          Inc(N, Item.BaseLen);
        end;
      else
        Inc(N, Item.MineLen);
      end;
  end
  else if (Length(AMine) > 0) or (Length(ATheirs) > 0) then
  begin
    SetLength(Result, 1);
    Result[0].Start   := 0;
    Result[0].Len     := 0;
    Result[0].Settled := False;
    Result[0].Done[0] := False;
    Result[0].Done[1] := False;
    Result[0].Took[0] := False;
    Result[0].Took[1] := False;
    Result[0].Ours    := Copy(AMine, 0, Length(AMine));
    Result[0].Theirs  := Copy(ATheirs, 0, Length(ATheirs));
  end;
end;

procedure MoveConflictSpans(var ASpans: TConflictSpans; AStart, ALen, ABLen: Integer;
  ASettle, AEdges: Boolean);
var
  I, SStart, SEnd, AEnd, NewStart, NewEnd : Integer;
  Hit : Boolean;
begin
  AEnd := AStart + ALen;
  for I := 0 to High(ASpans) do
  begin
    SStart := ASpans[I].Start;
    SEnd   := SStart + ASpans[I].Len;
    if ALen = 0 then
    begin
      if SStart = SEnd then
        Hit := AStart = SStart
      else
        Hit := ((SStart < AStart) and (AStart < SEnd)) or
               (AEdges and ((AStart = SStart) or (AStart = SEnd)));
    end
    else if SStart = SEnd then
      Hit := ((AStart < SStart) and (SStart < AEnd)) or
             (AEdges and (SStart >= AStart) and (SStart <= AEnd))
    else
      Hit := (AStart < SEnd) and (SStart < AEnd);

    if Hit then
    begin
      NewStart := SStart;
      if AStart < NewStart then NewStart := AStart;
      NewEnd := SEnd;
      if AEnd > NewEnd then NewEnd := AEnd;
      NewEnd := NewEnd + ABLen - ALen;
      ASpans[I].Start := NewStart;
      ASpans[I].Len   := NewEnd - NewStart;
      if ASettle then ASpans[I].Settled := True;
    end
    else if SEnd > AStart then
      Inc(ASpans[I].Start, ABLen - ALen);          { it is after the change }
  end;
end;

function UnsettledSpans(const ASpans: TConflictSpans): Integer;
var
  I : Integer;
begin
  Result := 0;
  for I := 0 to High(ASpans) do
    if not ASpans[I].Settled then Inc(Result);
end;

procedure ResetConflict(var ASpans: TConflictSpans; AIndex: Integer; var AResult: TDiffLines);
var
  Fresh : TDiffLines;
  Head, Tail, I, J, N : Integer;
begin
  if (AIndex < 0) or (AIndex > High(ASpans)) then Exit;
  Head := ASpans[AIndex].Start;
  if Head > Length(AResult) then Head := Length(AResult);
  Tail := ASpans[AIndex].Start + ASpans[AIndex].Len;
  if Tail > Length(AResult) then Tail := Length(AResult);
  Fresh := nil;
  N := 0;
  SetLength(Fresh, Head + Length(ASpans[AIndex].Base) + (Length(AResult) - Tail));
  for I := 0 to Head - 1 do
  begin
    Fresh[N] := AResult[I];
    Inc(N);
  end;
  for J := 0 to High(ASpans[AIndex].Base) do
  begin
    Fresh[N] := ASpans[AIndex].Base[J];
    Inc(N);
  end;
  for I := Tail to High(AResult) do
  begin
    Fresh[N] := AResult[I];
    Inc(N);
  end;
  AResult := Fresh;
  for I := AIndex + 1 to High(ASpans) do
    Inc(ASpans[I].Start, Length(ASpans[AIndex].Base) - ASpans[AIndex].Len);
  ASpans[AIndex].Len     := Length(ASpans[AIndex].Base);
  ASpans[AIndex].Settled := False;
  ASpans[AIndex].Done[0] := False;
  ASpans[AIndex].Done[1] := False;
  ASpans[AIndex].Took[0] := False;
  ASpans[AIndex].Took[1] := False;
end;

function ParseUnmerged(const AOutput: string): TConflictStagesArray;
var
  Start, I, Tab, Stage, N, J : Integer;
  Entry, Head, Path : string;
begin
  Result := nil;
  N := 0;
  Start := 1;
  for I := 1 to Length(AOutput) + 1 do
  begin
    if (I <= Length(AOutput)) and (AOutput[I] <> #0) then Continue;
    Entry := Copy(AOutput, Start, I - Start);
    Start := I + 1;
    Tab := Pos(#9, Entry);
    if Tab = 0 then Continue;
    Head := Copy(Entry, 1, Tab - 1);
    Path := Copy(Entry, Tab + 1, MaxInt);
    { "<mode> <hash> <stage>" }
    J := Length(Head);
    while (J > 0) and (Head[J] <> ' ') do Dec(J);
    Stage := StrToIntDef(Copy(Head, J + 1, MaxInt), 0);
    if (Stage < 1) or (Stage > 3) then Continue;
    if (N = 0) or (Result[N - 1].Path <> Path) then
    begin
      SetLength(Result, N + 1);
      Result[N] := Default(TConflictStages);
      Result[N].Path := Path;
      Inc(N);
    end;
    Result[N - 1].Has[Stage] := True;
    Result[N - 1].Mode[Stage] := Copy(Head, 1, Pos(' ', Head) - 1);
  end;
end;

function NotTextReason(const AEntry: TConflictStages): string;
var
  Present : string;
  S       : Integer;
begin
  Result := '';
  Present := '';
  for S := 1 to 3 do
    if AEntry.Has[S] then
    begin
      if Present <> '' then Present := Present + ', ';
      Present := Present + IntToStr(S);
    end;
  if not (AEntry.Has[2] and AEntry.Has[3]) then
    Exit('one side deleted the file (stages in the index: ' + Present + '); decide with git_resolve');
  for S := 2 to 3 do
    case AEntry.Mode[S] of
      '120000': Exit('a symbolic link (stages in the index: ' + Present + '); decide with git_resolve');
      '160000': Exit('a submodule (stages in the index: ' + Present + '); decide with git_resolve');
    end;
end;

function LooksBinary(const ABlob: string): Boolean;
var
  I : Integer;
begin
  for I := 1 to Length(ABlob) do
  begin
    if I > 8000 then Break;
    if ABlob[I] = #0 then Exit(True);
  end;
  Result := False;
end;

function EolOf(const AText: string): string;
var
  P : Integer;
begin
  P := Pos(#10, AText);
  if (P > 1) and (AText[P - 1] = #13) then
    Result := #13#10
  else
    Result := #10;
end;

function HasConflictBlock(const ALines: TDiffLines): Boolean;
var
  I : Integer;
  Open : Boolean;
begin
  Open := False;
  for I := 0 to High(ALines) do
  begin
    if Copy(ALines[I], 1, 7) = '<<<<<<<' then
      Open := True
    else if Open and (Copy(ALines[I], 1, 7) = '>>>>>>>') then
      Exit(True);
  end;
  Result := False;
end;

function WithEol(const ANewText, AEol: string; AFinalNewline: Boolean): string;
var
  Lines : TDiffLines;
  Dummy : Boolean;
begin
  Lines  := SplitLines(ANewText, Dummy);
  Result := JoinLines(Lines, AEol, AFinalNewline);
end;

end.
