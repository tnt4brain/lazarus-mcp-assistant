{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpLineDiff;

{ Line hunks between two versions of a source: reported by code_complete and
  code_format, and applied to a source editor by code_format.

  The hunks themselves are McpDiff.DiffLines (the review window uses the same). }

{$mode objfpc}{$H+}

interface

uses
  Classes, fpjson, SrcEditorIntf, McpDiff;

type
  { 0-based line indexes; the matching itself is McpDiff.DiffLines }
  TLineHunks = TDiffHunks;

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

function ToLines(SL: TStrings): TDiffLines;
var
  I : Integer;
begin
  Result := nil;
  SetLength(Result, SL.Count);
  for I := 0 to SL.Count - 1 do
    Result[I] := SL[I];
end;

function ComputeLineHunks(A, B: TStrings): TLineHunks;
begin
  Result := DiffLines(ToLines(A), ToLines(B));
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
      H.Add('removed_lines', ALen);
      H.Add('added_lines', BLen);
      Rem := Joined(A, AStart, ALen, #10);
      Ins := Joined(B, BStart, BLen, #10);
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
      if ALen > 0 then H.Add('removed', Rem);
      if BLen > 0 then H.Add('added', Ins);
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
      if Caret.Y - 1 >= AStart + ALen then
      begin
        Y := Caret.Y - 1 + (BStart + BLen) - (AStart + ALen);
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
        if (ALen > 0) and (BLen > 0) then
        begin
          { whole lines replaced: the line end after them stays }
          Txt := Joined(B, BStart, BLen, LineEnding);
          SetLength(Txt, Length(Txt) - Length(LineEnding));
          Ed.ReplaceLines(AStart + 1, AStart + ALen, Txt, True);
        end
        else if ALen > 0 then
        begin
          if AStart + ALen < Last then
            Ed.ReplaceText(Point(1, AStart + 1), Point(1, AStart + ALen + 1), '')
          else if AStart > 0 then
            { the last lines: from the end of the line before them }
            Ed.ReplaceText(Point(Length(A[AStart - 1]) + 1, AStart),
                           Point(Length(A[Last - 1]) + 1, Last), '')
          else
            Ed.ReplaceText(Point(1, 1), Point(Length(A[Last - 1]) + 1, Last), '');
        end
        else if AStart < Last then
          Ed.ReplaceText(Point(1, AStart + 1), Point(1, AStart + 1),
                         Joined(B, BStart, BLen, LineEnding))
        else if Last > 0 then
        begin
          { after the last line }
          Txt := Joined(B, BStart, BLen, LineEnding);
          SetLength(Txt, Length(Txt) - Length(LineEnding));
          Ed.ReplaceText(Point(Length(A[Last - 1]) + 1, Last),
                         Point(Length(A[Last - 1]) + 1, Last), LineEnding + Txt);
        end
        else
          Ed.ReplaceText(Point(1, 1), Point(1, 1), Joined(B, BStart, BLen, LineEnding));
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
