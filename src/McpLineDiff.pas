{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpLineDiff;

{ Line hunks between two versions of a source: reported by code_complete and
  code_format, and applied to a source editor by code_format.

  Lines common to both versions are matched by a longest common subsequence
  between the common head and tail, so edits far apart (a class declaration
  and a method body) are separate hunks.  Where the part between them is too
  large for that table (a formatted unit of thousands of lines), lines that
  occur once in each version anchor it (patience diff) and each part between
  anchors is matched the same way.  A hunk that only adds or only removes
  lines is moved down as far as the unchanged lines after it allow, as git
  does: an inserted method then starts at its comment and ends with its own
  "end;", not with the one before it. }

{$mode objfpc}{$H+}

interface

uses
  Classes, fpjson, SrcEditorIntf;

type
  TLineHunk = record
    AStart, ACount, BStart, BCount: Integer;  { 0-based line indexes }
  end;
  TLineHunks = array of TLineHunk;

{ The hunks that turn the lines of A into the lines of B. }
function ComputeLineHunks(A, B: TStrings): TLineHunks;

{ The hunks as JSON: line (1-based, in the new text), the numbers of lines
  removed and added, and their text, while the text so far is under
  MaxHunkText; the hunks after that are one last entry, omitted_hunks (their
  number) and from_line. }
function LineHunksJSON(A, B: TStrings; const Hunks: TLineHunks): TJSONArray;

{ ComputeLineHunks and LineHunksJSON for two source texts. }
function LineHunks(const OldSrc, NewSrc: string): TJSONArray;

{ Applies the hunks to an editor holding the lines of A, last first so the
  line numbers of the ones before stay valid, in one undo block: one Ctrl+Z
  takes them all back.  The caret stays on its line of code.  Main thread. }
procedure ApplyLineHunks(Ed: TSourceEditorInterface; A, B: TStrings;
  const Hunks: TLineHunks);

const
  MaxHunkText = 64 * 1024;

implementation

uses
  Types;

const
  MaxCells = 4000000;  { the largest table for one exact match }

{ The lines SL[Lo..Hi-1], sorted, each with its index; compared byte by
  byte, as the matching does. }
function LineIndex(SL: TStrings; Lo, Hi: Integer): TStringList;
var
  I : Integer;
begin
  Result := TStringList.Create;
  Result.CaseSensitive := True;
  Result.UseLocale := False;
  Result.Capacity := Hi - Lo;
  for I := Lo to Hi - 1 do
    Result.AddObject(SL[I], TObject(PtrInt(I)));
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

function ComputeLineHunks(A, B: TStrings): TLineHunks;
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
    L          : array of Integer;

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
    Tails, Prev   : array of Integer;
    Chain         : array of Integer;
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
    if (AEnd > PA) or (BEnd > PB) then
    begin
      SetLength(Result, Length(Result) + 1);
      with Result[High(Result)] do
      begin
        AStart := PA; ACount := AEnd - PA;
        BStart := PB; BCount := BEnd - PB;
      end;
    end;
  end;

begin
  Result := nil;
  MC := 0;
  MA := nil;
  MB := nil;
  Match(0, A.Count, 0, B.Count);
  { the hunks are the gaps between matched lines }
  PA := 0;
  PB := 0;
  for K := 0 to MC - 1 do
  begin
    AddHunk(MA[K], MB[K]);
    PA := MA[K] + 1;
    PB := MB[K] + 1;
  end;
  AddHunk(A.Count, B.Count);
  for K := 0 to High(Result) do
    with Result[K] do
      if ACount = 0 then
      begin
        if K < High(Result) then Limit := Result[K + 1].BStart else Limit := B.Count;
        while (BStart + BCount < Limit) and (B[BStart] = B[BStart + BCount]) do
        begin
          Inc(AStart); Inc(BStart);
        end;
      end
      else if BCount = 0 then
      begin
        if K < High(Result) then Limit := Result[K + 1].AStart else Limit := A.Count;
        while (AStart + ACount < Limit) and (A[AStart] = A[AStart + ACount]) do
        begin
          Inc(AStart); Inc(BStart);
        end;
      end;
end;

{ Count lines from From, each followed by Sep. }
function Joined(SL: TStrings; From, Count: Integer; const Sep: string): string;
var
  X : Integer;
begin
  Result := '';
  for X := From to From + Count - 1 do
    Result := Result + SL[X] + Sep;
end;

function LineHunksJSON(A, B: TStrings; const Hunks: TLineHunks): TJSONArray;
var
  K, Size  : Integer;
  H        : TJSONObject;
  Rem, Ins : string;
begin
  Result := TJSONArray.Create;
  Size := 0;
  for K := 0 to High(Hunks) do
    with Hunks[K] do
    begin
      H := TJSONObject.Create;
      H.Add('line', BStart + 1);
      H.Add('removed_lines', ACount);
      H.Add('added_lines', BCount);
      Rem := Joined(A, AStart, ACount, #10);
      Ins := Joined(B, BStart, BCount, #10);
      Inc(Size, Length(Rem) + Length(Ins));
      if Size > MaxHunkText then
      begin
        { the rest as one summary: read the file for them }
        H.Free;
        H := TJSONObject.Create;
        H.Add('omitted_hunks', Length(Hunks) - K);
        H.Add('from_line', BStart + 1);
        Result.Add(H);
        Break;
      end;
      if ACount > 0 then H.Add('removed', Rem);
      if BCount > 0 then H.Add('added', Ins);
      Result.Add(H);
    end;
end;

function LineHunks(const OldSrc, NewSrc: string): TJSONArray;
var
  A, B : TStringList;
begin
  A := TStringList.Create;
  B := TStringList.Create;
  try
    A.Text := OldSrc;
    B.Text := NewSrc;
    Result := LineHunksJSON(A, B, ComputeLineHunks(A, B));
  finally
    A.Free;
    B.Free;
  end;
end;

procedure ApplyLineHunks(Ed: TSourceEditorInterface; A, B: TStrings;
  const Hunks: TLineHunks);
var
  K     : Integer;
  Last  : Integer;  { 1-based number of A's last line }
  Txt   : string;
  Caret : TPoint;
  Y     : Integer;  { the caret's 0-based line in B }
begin
  Last := A.Count;
  { where the caret's line ends up: moved by the hunks above it, or to the
    start of the hunk that replaced it }
  Caret := Ed.CursorTextXY;
  Y := Caret.Y - 1;
  for K := High(Hunks) downto 0 do
    with Hunks[K] do
      if Caret.Y - 1 >= AStart + ACount then
      begin
        Y := Caret.Y - 1 + (BStart + BCount) - (AStart + ACount);
        Break;
      end
      else if Caret.Y - 1 >= AStart then
      begin
        Y := BStart;
        Caret.X := 1;
        Break;
      end;
  Ed.BeginUndoBlock;
  try
    for K := High(Hunks) downto 0 do
      with Hunks[K] do
        if (ACount > 0) and (BCount > 0) then
        begin
          { whole lines replaced: the line end after them stays }
          Txt := Joined(B, BStart, BCount, LineEnding);
          SetLength(Txt, Length(Txt) - Length(LineEnding));
          Ed.ReplaceLines(AStart + 1, AStart + ACount, Txt, True);
        end
        else if ACount > 0 then
        begin
          if AStart + ACount < Last then
            Ed.ReplaceText(Point(1, AStart + 1), Point(1, AStart + ACount + 1), '')
          else if AStart > 0 then
            { the last lines: from the end of the line before them }
            Ed.ReplaceText(Point(Length(A[AStart - 1]) + 1, AStart),
                           Point(Length(A[Last - 1]) + 1, Last), '')
          else
            Ed.ReplaceText(Point(1, 1), Point(Length(A[Last - 1]) + 1, Last), '');
        end
        else if AStart < Last then
          Ed.ReplaceText(Point(1, AStart + 1), Point(1, AStart + 1),
                         Joined(B, BStart, BCount, LineEnding))
        else if Last > 0 then
        begin
          { after the last line }
          Txt := Joined(B, BStart, BCount, LineEnding);
          SetLength(Txt, Length(Txt) - Length(LineEnding));
          Ed.ReplaceText(Point(Length(A[Last - 1]) + 1, Last),
                         Point(Length(A[Last - 1]) + 1, Last), LineEnding + Txt);
        end
        else
          Ed.ReplaceText(Point(1, 1), Point(1, 1), Joined(B, BStart, BCount, LineEnding));
  finally
    Ed.EndUndoBlock;
  end;
  if B.Count > 0 then
  begin
    if Y > B.Count - 1 then Y := B.Count - 1;
    if Y < 0 then Y := 0;
    if Caret.X > Length(B[Y]) + 1 then Caret.X := Length(B[Y]) + 1;
    Ed.CursorTextXY := Point(Caret.X, Y + 1);
  end;
end;

end.
