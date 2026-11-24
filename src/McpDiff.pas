{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpDiff;

{ Line diff and three-way merge for the review window (ADR-025).  Pure RTL:
  no IDE, no LCL, so tests/tdiff.pas runs without the IDE.

  A hunk is a changed region: lines AStart..AStart+ALen-1 of the first text are
  replaced by lines BStart..BStart+BLen-1 of the second (all 0-based; one of the
  lengths may be 0: a pure insertion or deletion).

  Merge3 compares two texts, "mine" and "theirs", with their common "base" and
  returns the whole text as a list of chunks: stable lines, a change made on one
  side only, a change made on both sides the same way, and conflicts. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TDiffLines = array of string;

  TDiffHunk = record
    AStart, ALen, BStart, BLen: Integer;
  end;
  TDiffHunks = array of TDiffHunk;

  TMergeKind = (mkStable, mkMine, mkTheirs, mkBoth, mkConflict);

  { The same stretch of the text in each version: line ranges, 0-based. }
  TMergeChunk = record
    Kind                : TMergeKind;
    BaseStart, BaseLen  : Integer;
    MineStart, MineLen  : Integer;
    TheirStart, TheirLen: Integer;
  end;
  TMergeChunks = array of TMergeChunk;

  { Two texts as side-by-side rows: the same number of rows on both sides, a filler
    row (empty, kind rkFiller) where one side has no line.  Without its fillers the left
    side is Mine and the right side is Theirs. }
  TDiffRowKind = (rkEqual, rkAdded, rkRemoved, rkChanged, rkFiller);
  TDiffRowKinds = array of TDiffRowKind;

  TAlignedRows = record
    Left, Right         : TDiffLines;
    LeftKind, RightKind : TDiffRowKinds;
    Hunks               : TDiffHunks;
    HunkRow             : array of Integer;   { the first row of each change }
  end;

{ Splits at LF or CRLF.  A final line ending does not make an empty last line;
  FinalNewline tells whether there was one.  An empty text has no lines. }
function SplitLines(const S: string; out FinalNewline: Boolean): TDiffLines;

{ The lines of S, for a caller that does not need to know about the final line ending. }
function LinesOf(const S: string): TDiffLines;
function JoinLines(const Lines: TDiffLines; const EOL: string;
  FinalNewline: Boolean): string;

{ The hunks that turn A into B, the smallest set of changed lines.  Lines common to both
  versions are matched by a longest common subsequence between the common head and tail,
  so edits far apart are separate hunks.  Where the part between them is too large for
  that table (a formatted unit of thousands of lines), lines that occur once in each
  version anchor it (patience diff) and each part between anchors is matched the same
  way; with no such line the whole part is one hunk.  A hunk that only adds or only
  removes lines is moved down as far as the unchanged lines after it allow, as git does:
  an inserted method then starts at its comment and ends with its own "end;", not with
  the one before it. }
function DiffLines(const A, B: TDiffLines): TDiffHunks;

{ The text A with the hunks that have Take[i] = True replaced by B's lines;
  the others stay as in A.  All taken gives B, none gives A. }
function ApplyHunks(const A, B: TDiffLines; const Hunks: TDiffHunks;
  const Take: array of Boolean): TDiffLines;

function Merge3(const Base, Mine, Theirs: TDiffLines): TMergeChunks;

function AlignRows(const Mine, Theirs: TDiffLines): TAlignedRows;

type
  { Three versions side by side: the editor's (L), the result being made (M) and the
    disk's (R), in common rows.  The result is the spine: each of its lines is one row,
    and the lines only L or R has get rows of their own (M a filler there).
    The kinds say how a row's line relates to the result: rkEqual same; rkChanged paired
    with a different line; rkAdded (L and R only) a line the result lacks; rkFiller no
    line.  The result's own row is rkChanged when it differs from, or is missing in, a
    side.  LeftHunks are the differences result -> editor, RightHunks result -> disk
    (A = the result's lines, B = the side's), with the first row of each. }
  TDiffRowArray = array of Integer;

  TAligned3 = record
    L, M, R             : TDiffLines;
    LK, MK, RK          : TDiffRowKinds;
    LeftHunks, RightHunks      : TDiffHunks;
    LeftHunkRow, RightHunkRow  : TDiffRowArray;
  end;

function AlignRows3(const Editor, Middle, Disk: TDiffLines): TAligned3;

{ Mine with every change only Theirs made applied.  A conflict keeps Mine's lines.
  Applied counts the changes taken from Theirs, Conflicts those left to decide. }
function MergeAuto(const Base, Mine, Theirs: TDiffLines;
  out Applied, Conflicts: Integer): TDiffLines;

type
  TLineFlags = array of Boolean;

{ The same, and which of Theirs' lines were taken (FromTheirs[i] for Theirs[i]), so the
  merge can be shown; LinesRemoved counts Mine's lines the applied changes replaced. }
function MergeAutoEx(const Base, Mine, Theirs: TDiffLines;
  out Applied, Conflicts: Integer; out FromTheirs: TLineFlags;
  out LinesRemoved: Integer): TDiffLines;

{ The lines of a chunk in one version. }
function Slice(const Lines: TDiffLines; AStart, ALen: Integer): TDiffLines;

{ The part of two changed lines that differs: what is left after their common start and
  end, widened to whole words (so "Hello" vs "Hallo" marks the word, not one letter).
  Columns are 1-based, the end is excluded; From = To means nothing on that side. }
procedure DifferingSpan(const A, B: string; out AFrom, ATo, BFrom, BTo: Integer);

implementation

uses Classes;

function SplitLines(const S: string; out FinalNewline: Boolean): TDiffLines;
var
  I, Start, N, L: Integer;
begin
  Result := nil;
  FinalNewline := False;
  L := Length(S);
  if L = 0 then Exit;
  N := 0;
  Start := 1;
  for I := 1 to L do
    if S[I] = #10 then
    begin
      SetLength(Result, N + 1);
      if (I > Start) and (S[I - 1] = #13) then
        Result[N] := Copy(S, Start, I - Start - 1)
      else
        Result[N] := Copy(S, Start, I - Start);
      Inc(N);
      Start := I + 1;
    end;
  if Start <= L then
  begin
    SetLength(Result, N + 1);
    Result[N] := Copy(S, Start, L - Start + 1);
  end
  else
    FinalNewline := True;
end;

function LinesOf(const S: string): TDiffLines;
var
  Dummy : Boolean;
begin
  Result := SplitLines(S, Dummy);
end;

function JoinLines(const Lines: TDiffLines; const EOL: string;
  FinalNewline: Boolean): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Lines) do
  begin
    if I > 0 then Result := Result + EOL;
    Result := Result + Lines[I];
  end;
  if FinalNewline and (Length(Lines) > 0) then Result := Result + EOL;
end;

function Slice(const Lines: TDiffLines; AStart, ALen: Integer): TDiffLines;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, ALen);
  for I := 0 to ALen - 1 do
    Result[I] := Lines[AStart + I];
end;

{ The lines A[Lo..Hi-1], sorted, each with its index; compared byte by byte, as the
  matching does. }
function LineIndex(const A: TDiffLines; Lo, Hi: Integer): TStringList;
var
  I : Integer;
begin
  Result := TStringList.Create;
  Result.CaseSensitive := True;
  Result.UseLocale := False;
  Result.Capacity := Hi - Lo;
  for I := Lo to Hi - 1 do
    Result.AddObject(A[I], TObject(PtrInt(I)));
  Result.Sorted := True;
end;

{ The index of S if it occurs exactly once in Index, otherwise -1. }
function UniqueAt(Index: TStringList; const S: string): Integer;
var
  X : Integer;
begin
  Result := -1;
  if not Index.Find(S, X) then Exit;
  if (X > 0) and (Index[X - 1] = S) then Exit;
  if (X < Index.Count - 1) and (Index[X + 1] = S) then Exit;
  Result := PtrInt(Index.Objects[X]);
end;

function DiffLines(const A, B: TDiffLines): TDiffHunks;
const
  MaxCells = 4000000;  { the largest table for one exact match }
var
  MA, MB : array of Integer;  { matched line pairs, increasing }
  MC     : Integer;
  K, Limit, PA, PB : Integer;

  procedure AddMatch(I, J: Integer);
  begin
    if MC = Length(MA) then
    begin
      SetLength(MA, 2 * MC + 64);
      SetLength(MB, 2 * MC + 64);
    end;
    MA[MC] := I;
    MB[MC] := J;
    Inc(MC);
  end;

  { Longest common subsequence of A[ALo..AHi-1] and B[BLo..BHi-1]. }
  procedure TableMatch(ALo, AHi, BLo, BHi: Integer);
  var
    N, M, I, J : Integer;
    L          : array of Integer = nil;

    function Cell(AI, AJ: Integer): Integer; inline;
    begin
      Result := L[AI * (M + 1) + AJ];
    end;

  begin
    N := AHi - ALo;
    M := BHi - BLo;
    SetLength(L, (N + 1) * (M + 1));
    for I := N - 1 downto 0 do
      for J := M - 1 downto 0 do
        if A[ALo + I] = B[BLo + J] then
          L[I * (M + 1) + J] := Cell(I + 1, J + 1) + 1
        else if Cell(I + 1, J) >= Cell(I, J + 1) then
          L[I * (M + 1) + J] := Cell(I + 1, J)
        else
          L[I * (M + 1) + J] := Cell(I, J + 1);
    I := 0;
    J := 0;
    while (I < N) and (J < M) do
      if A[ALo + I] = B[BLo + J] then
      begin
        AddMatch(ALo + I, BLo + J);
        Inc(I);
        Inc(J);
      end
      else if Cell(I + 1, J) >= Cell(I, J + 1) then
        Inc(I)
      else
        Inc(J);
  end;

  procedure Match(ALo, AHi, BLo, BHi: Integer); forward;

  { Lines that occur once in each range, in the longest run whose positions
    increase in both, with the parts between them matched recursively.
    False if there is no such line. }
  function AnchorMatch(ALo, AHi, BLo, BHi: Integer): Boolean;
  var
    InA, InB      : TStringList;
    I, J, X, Lo, Hi, Mid, Len : Integer;
    CandA, CandB  : array of Integer;
    Tails         : array of Integer = nil;
    Prev          : array of Integer = nil;
    Chain         : array of Integer = nil;
    PrevA, PrevB  : Integer;
  begin
    InA := LineIndex(A, ALo, AHi);
    InB := LineIndex(B, BLo, BHi);
    try
      CandA := nil;
      CandB := nil;
      for I := ALo to AHi - 1 do
        if (UniqueAt(InA, A[I]) = I) and (UniqueAt(InB, A[I]) >= 0) then
        begin
          J := UniqueAt(InB, A[I]);
          SetLength(CandA, Length(CandA) + 1);
          SetLength(CandB, Length(CandB) + 1);
          CandA[High(CandA)] := I;
          CandB[High(CandB)] := J;
        end;
    finally
      InA.Free;
      InB.Free;
    end;
    Result := Length(CandA) > 0;
    if not Result then Exit;
    { longest increasing run of CandB (patience sorting) }
    SetLength(Tails, Length(CandB));
    SetLength(Prev, Length(CandB));
    Len := 0;
    for X := 0 to High(CandB) do
    begin
      Lo := 0;
      Hi := Len;
      while Lo < Hi do
      begin
        Mid := (Lo + Hi) div 2;
        if CandB[Tails[Mid]] < CandB[X] then Lo := Mid + 1 else Hi := Mid;
      end;
      if Lo > 0 then Prev[X] := Tails[Lo - 1] else Prev[X] := -1;
      Tails[Lo] := X;
      if Lo = Len then Inc(Len);
    end;
    SetLength(Chain, Len);
    X := Tails[Len - 1];
    for I := Len - 1 downto 0 do
    begin
      Chain[I] := X;
      X := Prev[X];
    end;
    PrevA := ALo;
    PrevB := BLo;
    for I := 0 to Len - 1 do
    begin
      Match(PrevA, CandA[Chain[I]], PrevB, CandB[Chain[I]]);
      AddMatch(CandA[Chain[I]], CandB[Chain[I]]);
      PrevA := CandA[Chain[I]] + 1;
      PrevB := CandB[Chain[I]] + 1;
    end;
    Match(PrevA, AHi, PrevB, BHi);
  end;

  procedure Match(ALo, AHi, BLo, BHi: Integer);
  var
    Tail, X : Integer;
  begin
    while (ALo < AHi) and (BLo < BHi) and (A[ALo] = B[BLo]) do
    begin
      AddMatch(ALo, BLo);
      Inc(ALo);
      Inc(BLo);
    end;
    Tail := 0;
    while (Tail < AHi - ALo) and (Tail < BHi - BLo) and
          (A[AHi - 1 - Tail] = B[BHi - 1 - Tail]) do
      Inc(Tail);
    if (AHi - Tail > ALo) and (BHi - Tail > BLo) then
      if Int64(AHi - Tail - ALo + 1) * (BHi - Tail - BLo + 1) <= MaxCells then
        TableMatch(ALo, AHi - Tail, BLo, BHi - Tail)
      else
        AnchorMatch(ALo, AHi - Tail, BLo, BHi - Tail);  { none: one hunk }
    for X := Tail downto 1 do
      AddMatch(AHi - X, BHi - X);
  end;

  procedure AddHunk(AEnd, BEnd: Integer);
  begin
    if (AEnd <= PA) and (BEnd <= PB) then Exit;
    SetLength(Result, Length(Result) + 1);
    with Result[High(Result)] do
    begin
      AStart := PA; ALen := AEnd - PA;
      BStart := PB; BLen := BEnd - PB;
    end;
  end;

begin
  Result := nil;
  MC := 0;
  MA := nil;
  MB := nil;
  Match(0, Length(A), 0, Length(B));
  { the hunks are the gaps between matched lines }
  PA := 0;
  PB := 0;
  for K := 0 to MC - 1 do
  begin
    AddHunk(MA[K], MB[K]);
    PA := MA[K] + 1;
    PB := MB[K] + 1;
  end;
  AddHunk(Length(A), Length(B));
  { a hunk that only adds or only removes lines slides down as far as the lines after
    it allow, as git does }
  for K := 0 to High(Result) do
    with Result[K] do
      if ALen = 0 then
      begin
        if K < High(Result) then Limit := Result[K + 1].BStart else Limit := Length(B);
        while (BStart + BLen < Limit) and (B[BStart] = B[BStart + BLen]) do
        begin
          Inc(AStart); Inc(BStart);
        end;
      end
      else if BLen = 0 then
      begin
        if K < High(Result) then Limit := Result[K + 1].AStart else Limit := Length(A);
        while (AStart + ALen < Limit) and (A[AStart] = A[AStart + ALen]) do
        begin
          Inc(AStart); Inc(BStart);
        end;
      end;
end;

procedure AddLine(var R: TDiffLines; var N: Integer; const S: string);
begin
  if N >= Length(R) then SetLength(R, N * 2 + 16);
  R[N] := S;
  Inc(N);
end;

function ApplyHunks(const A, B: TDiffLines; const Hunks: TDiffHunks;
  const Take: array of Boolean): TDiffLines;
var
  H, I, J, N: Integer;
begin
  Result := nil;
  N := 0;
  I := 0;
  for H := 0 to High(Hunks) do
  begin
    while I < Hunks[H].AStart do
    begin
      AddLine(Result, N, A[I]);
      Inc(I);
    end;
    if (H <= High(Take)) and Take[H] then
      for J := Hunks[H].BStart to Hunks[H].BStart + Hunks[H].BLen - 1 do
        AddLine(Result, N, B[J])
    else
      for J := I to I + Hunks[H].ALen - 1 do
        AddLine(Result, N, A[J]);
    Inc(I, Hunks[H].ALen);
  end;
  while I < Length(A) do
  begin
    AddLine(Result, N, A[I]);
    Inc(I);
  end;
  SetLength(Result, N);
end;

function SameLines(const X: TDiffLines; XStart, XLen: Integer;
  const Y: TDiffLines; YStart, YLen: Integer): Boolean;
var
  I: Integer;
begin
  Result := XLen = YLen;
  if not Result then Exit;
  for I := 0 to XLen - 1 do
    if X[XStart + I] <> Y[YStart + I] then
      Exit(False);
end;

function Merge3(const Base, Mine, Theirs: TDiffLines): TMergeChunks;
var
  HM, HT        : TDiffHunks;
  I, J, Cnt     : Integer;
  Pos           : Integer;   { base lines done }
  DM, DT        : Integer;   { mine/theirs index minus base index, at Pos }
  RS, RE        : Integer;   { the region in base lines }
  Progress      : Boolean;
  MS, ME, TS, TE: Integer;
  MTook, TTook  : Boolean;

  procedure Add(AKind: TMergeKind; ABS, ABL, AMS, AML, ATS, ATL: Integer);
  begin
    SetLength(Result, Cnt + 1);
    Result[Cnt].Kind       := AKind;
    Result[Cnt].BaseStart  := ABS;
    Result[Cnt].BaseLen    := ABL;
    Result[Cnt].MineStart  := AMS;
    Result[Cnt].MineLen    := AML;
    Result[Cnt].TheirStart := ATS;
    Result[Cnt].TheirLen   := ATL;
    Inc(Cnt);
  end;

begin
  Result := nil;
  Cnt := 0;
  HM := DiffLines(Base, Mine);
  HT := DiffLines(Base, Theirs);
  I := 0;
  J := 0;
  Pos := 0;
  DM := 0;
  DT := 0;
  while (I < Length(HM)) or (J < Length(HT)) do
  begin
    if I >= Length(HM) then RS := HT[J].AStart
    else if J >= Length(HT) then RS := HM[I].AStart
    else if HM[I].AStart < HT[J].AStart then RS := HM[I].AStart
    else RS := HT[J].AStart;
    if RS > Pos then
      Add(mkStable, Pos, RS - Pos, Pos + DM, RS - Pos, Pos + DT, RS - Pos);
    { grow the region over every change that touches it, from either side }
    RE := RS;
    MS := RS + DM;
    TS := RS + DT;
    MTook := False;
    TTook := False;
    repeat
      Progress := False;
      if (I < Length(HM)) and (HM[I].AStart <= RE) then
      begin
        if HM[I].AStart + HM[I].ALen > RE then RE := HM[I].AStart + HM[I].ALen;
        Inc(DM, HM[I].BLen - HM[I].ALen);
        MTook := True;
        Inc(I);
        Progress := True;
      end;
      if (J < Length(HT)) and (HT[J].AStart <= RE) then
      begin
        if HT[J].AStart + HT[J].ALen > RE then RE := HT[J].AStart + HT[J].ALen;
        Inc(DT, HT[J].BLen - HT[J].ALen);
        TTook := True;
        Inc(J);
        Progress := True;
      end;
    until not Progress;
    ME := RE + DM;
    TE := RE + DT;
    if MTook and not TTook then
      Add(mkMine, RS, RE - RS, MS, ME - MS, TS, RE - RS)
    else if TTook and not MTook then
      Add(mkTheirs, RS, RE - RS, MS, RE - RS, TS, TE - TS)
    else if SameLines(Mine, MS, ME - MS, Theirs, TS, TE - TS) then
      Add(mkBoth, RS, RE - RS, MS, ME - MS, TS, TE - TS)
    else
      Add(mkConflict, RS, RE - RS, MS, ME - MS, TS, TE - TS);
    Pos := RE;
  end;
  if Pos < Length(Base) then
    Add(mkStable, Pos, Length(Base) - Pos, Pos + DM, Length(Base) - Pos,
        Pos + DT, Length(Base) - Pos);
end;

function MergeAuto(const Base, Mine, Theirs: TDiffLines;
  out Applied, Conflicts: Integer): TDiffLines;
var
  Flags   : TLineFlags;
  Removed : Integer;
begin
  Result := MergeAutoEx(Base, Mine, Theirs, Applied, Conflicts, Flags, Removed);
end;

function MergeAutoEx(const Base, Mine, Theirs: TDiffLines;
  out Applied, Conflicts: Integer; out FromTheirs: TLineFlags;
  out LinesRemoved: Integer): TDiffLines;
var
  Item : TMergeChunk;
  C    : TMergeChunks;
  J, N   : Integer;
  Part : TDiffLines;
begin
  Result := nil;
  Applied := 0;
  Conflicts := 0;
  LinesRemoved := 0;
  FromTheirs := nil;
  SetLength(FromTheirs, Length(Theirs));
  N := 0;
  C := Merge3(Base, Mine, Theirs);
  for Item in C do
  begin
    if Item.Kind = mkTheirs then
    begin
      Part := Slice(Theirs, Item.TheirStart, Item.TheirLen);
      for J := 0 to Item.TheirLen - 1 do FromTheirs[Item.TheirStart + J] := True;
      Inc(LinesRemoved, Item.MineLen);
      Inc(Applied);
    end
    else
    begin
      Part := Slice(Mine, Item.MineStart, Item.MineLen);
      if Item.Kind = mkConflict then Inc(Conflicts);
    end;
    SetLength(Result, N + Length(Part));
    for J := 0 to High(Part) do Result[N + J] := Part[J];
    Inc(N, Length(Part));
  end;
end;

function AlignRows(const Mine, Theirs: TDiffLines): TAlignedRows;
var
  I, K, N, Pos, TPos, Cnt: Integer;

  procedure AddRow(const L, R: string; LK, RK: TDiffRowKind);
  begin
    if Cnt >= Length(Result.Left) then
    begin
      SetLength(Result.Left, Cnt * 2 + 16);
      SetLength(Result.Right, Cnt * 2 + 16);
      SetLength(Result.LeftKind, Cnt * 2 + 16);
      SetLength(Result.RightKind, Cnt * 2 + 16);
    end;
    Result.Left[Cnt]      := L;
    Result.Right[Cnt]     := R;
    Result.LeftKind[Cnt]  := LK;
    Result.RightKind[Cnt] := RK;
    Inc(Cnt);
  end;

begin
  Result.Left := nil;
  Result.Right := nil;
  Result.LeftKind := nil;
  Result.RightKind := nil;
  Result.HunkRow := nil;
  Cnt := 0;
  Result.Hunks := DiffLines(Mine, Theirs);
  SetLength(Result.HunkRow, Length(Result.Hunks));
  Pos := 0;     { lines of Mine done }
  TPos := 0;    { lines of Theirs done }
  for I := 0 to High(Result.Hunks) do
  begin
    while Pos < Result.Hunks[I].AStart do
    begin
      AddRow(Mine[Pos], Theirs[TPos], rkEqual, rkEqual);
      Inc(Pos);
      Inc(TPos);
    end;
    Result.HunkRow[I] := Cnt;
    N := Result.Hunks[I].ALen;
    if Result.Hunks[I].BLen > N then N := Result.Hunks[I].BLen;
    for K := 0 to N - 1 do
    begin
      if (K < Result.Hunks[I].ALen) and (K < Result.Hunks[I].BLen) then
        AddRow(Mine[Pos + K], Theirs[TPos + K], rkChanged, rkChanged)
      else if K < Result.Hunks[I].ALen then
        AddRow(Mine[Pos + K], '', rkRemoved, rkFiller)
      else
        AddRow('', Theirs[TPos + K], rkFiller, rkAdded);
    end;
    Inc(Pos, Result.Hunks[I].ALen);
    Inc(TPos, Result.Hunks[I].BLen);
  end;
  while Pos < Length(Mine) do
  begin
    AddRow(Mine[Pos], Theirs[TPos], rkEqual, rkEqual);
    Inc(Pos);
    Inc(TPos);
  end;
  SetLength(Result.Left, Cnt);
  SetLength(Result.Right, Cnt);
  SetLength(Result.LeftKind, Cnt);
  SetLength(Result.RightKind, Cnt);
end;

function AlignRows3(const Editor, Middle, Disk: TDiffLines): TAligned3;
var
  AL, AR     : TAlignedRows;
  MapL : array of Integer = nil;      { the row of each row of AL }
  MapR : array of Integer = nil;      { the row of each row of AR }
  I, J, Cnt  : Integer;
  EL, ER     : array of Integer;      { the rows of AL / AR waiting in a gap }
  K, NE, H   : Integer;

  procedure AddRow(const L, M, R: string; LK, MK, RK: TDiffRowKind);
  begin
    if Cnt >= Length(Result.L) then
    begin
      SetLength(Result.L, Cnt * 2 + 16);
      SetLength(Result.M, Cnt * 2 + 16);
      SetLength(Result.R, Cnt * 2 + 16);
      SetLength(Result.LK, Cnt * 2 + 16);
      SetLength(Result.MK, Cnt * 2 + 16);
      SetLength(Result.RK, Cnt * 2 + 16);
    end;
    Result.L[Cnt] := L;
    Result.M[Cnt] := M;
    Result.R[Cnt] := R;
    Result.LK[Cnt] := LK;
    Result.MK[Cnt] := MK;
    Result.RK[Cnt] := RK;
    Inc(Cnt);
  end;

begin
  Result.L := nil;
  Result.M := nil;
  Result.R := nil;
  Result.LK := nil;
  Result.MK := nil;
  Result.RK := nil;
  AL := AlignRows(Middle, Editor);       { Left: the result's side, Right: the editor's }
  AR := AlignRows(Middle, Disk);
  SetLength(MapL, Length(AL.Left));
  SetLength(MapR, Length(AR.Left));
  Cnt := 0;
  I := 0;
  J := 0;
  while (I < Length(AL.Left)) or (J < Length(AR.Left)) do
  begin
    { rows with no result line: only the editor's or only the disk's lines }
    EL := nil;
    ER := nil;
    while (I < Length(AL.Left)) and (AL.LeftKind[I] = rkFiller) do
    begin
      SetLength(EL, Length(EL) + 1);
      EL[High(EL)] := I;
      Inc(I);
    end;
    while (J < Length(AR.Left)) and (AR.LeftKind[J] = rkFiller) do
    begin
      SetLength(ER, Length(ER) + 1);
      ER[High(ER)] := J;
      Inc(J);
    end;
    NE := Length(EL);
    if Length(ER) > NE then NE := Length(ER);
    for K := 0 to NE - 1 do
    begin
      if K < Length(EL) then MapL[EL[K]] := Cnt;
      if K < Length(ER) then MapR[ER[K]] := Cnt;
      if (K < Length(EL)) and (K < Length(ER)) then
        AddRow(AL.Right[EL[K]], '', AR.Right[ER[K]], rkAdded, rkFiller, rkAdded)
      else if K < Length(EL) then
        AddRow(AL.Right[EL[K]], '', '', rkAdded, rkFiller, rkFiller)
      else
        AddRow('', '', AR.Right[ER[K]], rkFiller, rkFiller, rkAdded);
    end;
    { the result's line, with what each side has beside it }
    if (I < Length(AL.Left)) and (J < Length(AR.Left)) then
    begin
      MapL[I] := Cnt;
      MapR[J] := Cnt;
      if (AL.LeftKind[I] = rkEqual) and (AR.LeftKind[J] = rkEqual) then
        AddRow(AL.Right[I], AL.Left[I], AR.Right[J], rkEqual, rkEqual, rkEqual)
      else
        AddRow(AL.Right[I], AL.Left[I], AR.Right[J], AL.RightKind[I], rkChanged,
          AR.RightKind[J]);
      Inc(I);
      Inc(J);
    end;
  end;
  SetLength(Result.L, Cnt);
  SetLength(Result.M, Cnt);
  SetLength(Result.R, Cnt);
  SetLength(Result.LK, Cnt);
  SetLength(Result.MK, Cnt);
  SetLength(Result.RK, Cnt);
  Result.LeftHunks := AL.Hunks;
  Result.RightHunks := AR.Hunks;
  SetLength(Result.LeftHunkRow, Length(AL.Hunks));
  SetLength(Result.RightHunkRow, Length(AR.Hunks));
  for H := 0 to High(AL.Hunks) do Result.LeftHunkRow[H] := MapL[AL.HunkRow[H]];
  for H := 0 to High(AR.Hunks) do Result.RightHunkRow[H] := MapR[AR.HunkRow[H]];
end;

function IsWordChar(C: Char): Boolean;
begin
  Result := C in ['A'..'Z', 'a'..'z', '0'..'9', '_', #128..#255];
end;

procedure DifferingSpan(const A, B: string; out AFrom, ATo, BFrom, BTo: Integer);
var
  P, SA, SB: Integer;     { P: common start length; SA, SB: where the common end begins - 1 }
begin
  P := 0;
  while (P < Length(A)) and (P < Length(B)) and (A[P + 1] = B[P + 1]) do Inc(P);
  { back to the start of the word the difference is in }
  while (P > 0) and (P < Length(A)) and (P < Length(B)) and IsWordChar(A[P]) and
        IsWordChar(A[P + 1]) do Dec(P);
  SA := Length(A);
  SB := Length(B);
  while (SA > P) and (SB > P) and (A[SA] = B[SB]) do
  begin
    Dec(SA);
    Dec(SB);
  end;
  { forward to the end of that word }
  while (SA < Length(A)) and (SB < Length(B)) and (SA > P) and IsWordChar(A[SA]) and
        IsWordChar(A[SA + 1]) do
  begin
    Inc(SA);
    Inc(SB);
  end;
  AFrom := P + 1;
  ATo := SA + 1;
  BFrom := P + 1;
  BTo := SB + 1;
end;

end.
