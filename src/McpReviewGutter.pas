{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpReviewGutter;

{ ADR-025: markers in the gutter of the REAL editor of a file that waits for review.

  A narrow part of the editor's gutter, drawn like the change bars of a version control
  gutter: a line only the editor has is green, a line that differs from the file on disk is
  blue, and a red tick marks the place where the disk has lines the editor lacks.  A click
  on the bar opens the review.  The comparison is made again when the text changes. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Graphics, Controls, SynEdit, McpDiff;

type
  TReviewGutterClick = procedure(const AFile: string) of object;

{ Adds the part to AEdit's gutter, or updates it when it is there already for AFile.
  ADisk is the text of the file on disk. }
procedure McpGutterAttach(AEdit: TSynEdit; const AFile: string; const ADisk: TDiffLines;
  AOnClick: TReviewGutterClick);

{ Takes the part away again (nothing happens when there is none). }
procedure McpGutterDetach(AEdit: TSynEdit; const AFile: string);

implementation

uses
  SynGutterBase, LazSynEditText, SynEditMiscProcs;

const
  KindNone = 0;
  KindAdded = 1;
  KindModified = 2;
  ClAdded    = $5AB43C;       { BGR: green  (60, 180, 90) }
  ClModified = $DC8246;       { BGR: blue   (70, 130, 220) }
  ClDeleted  = $5050D7;       { BGR: red    (215, 80, 80) }

type
  TReviewGutterPart = class(TSynGutterPartBase)
  private
    FFile    : string;
    FDisk    : TDiffLines;
    FOnClick : TReviewGutterClick;
    FStamp   : Int64;
    FKind    : array of Byte;      { per text line; index line - 1 }
    FTick    : array of Boolean;   { a red tick above the line }
    procedure CompareWithDisk;
  protected
    function PreferedWidthAtCurrentPPI: Integer; override;
  public
    procedure Paint(Canvas: TCanvas; AClip: TRect; FirstLine, LastLine: integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure SetDisk(const ADisk: TDiffLines);
    property FileName: string read FFile write FFile;
    property OnClick: TReviewGutterClick read FOnClick write FOnClick;
  end;

function TReviewGutterPart.PreferedWidthAtCurrentPPI: Integer;
begin
  Result := Scale96ToFont(7);
end;

procedure TReviewGutterPart.SetDisk(const ADisk: TDiffLines);
begin
  FDisk := Copy(ADisk, 0, Length(ADisk));
  FStamp := -1;                        { compare again at the next paint }
  DoChange(Self);
end;

{ The editor's lines against the disk's.  A final empty line is the line break after the
  last line, not a line of the file. }
procedure TReviewGutterPart.CompareWithDisk;
var
  Hunk : TDiffHunk;
  Mine  : TDiffLines;
  Hunks : TDiffHunks;
  I, J, N : Integer;
begin
  N := SynEdit.Lines.Count;
  if (N > 0) and (SynEdit.Lines[N - 1] = '') then Dec(N);
  Mine := nil;
  SetLength(Mine, N);
  for I := 0 to N - 1 do Mine[I] := SynEdit.Lines[I];
  SetLength(FKind, 0);
  SetLength(FKind, N);
  SetLength(FTick, 0);
  SetLength(FTick, N + 1);
  Hunks := DiffLines(Mine, FDisk);
  for Hunk in Hunks do
  begin
    for J := Hunk.AStart to Hunk.AStart + Hunk.ALen - 1 do
      if Hunk.BLen = 0 then FKind[J] := KindAdded else FKind[J] := KindModified;
    if (Hunk.ALen = 0) and (Hunk.AStart <= N) then FTick[Hunk.AStart] := True;
  end;
  FStamp := TSynEdit(SynEdit).ChangeStamp;
end;

procedure TReviewGutterPart.Paint(Canvas: TCanvas; AClip: TRect; FirstLine, LastLine: integer);
var
  I, ILine, LineHeight, TopRow: Integer;
  R: TRect;
  Range: TLineRange;
begin
  if not Visible then Exit;
  if FStamp <> TSynEdit(SynEdit).ChangeStamp then CompareWithDisk;
  Canvas.Brush.Color := Gutter.Color;
  Canvas.FillRect(AClip);
  LineHeight := SynEdit.LineHeight;
  TopRow := ToIdx(GutterArea.TextArea.TopLine);
  R := AClip;
  R.Bottom := AClip.Top;
  for I := TopRow + FirstLine to TopRow + LastLine do
  begin
    ILine := ToPos(ViewedTextBuffer.DisplayView.ViewToTextIndexEx(I, Range));
    if (ILine < 1) or (ILine > SynEdit.Lines.Count) then Break;
    R.Top := R.Bottom;
    Inc(R.Bottom, LineHeight);
    if I <> Range.Top then Continue;          { a folded or wrapped line: its first row }
    if (ILine <= Length(FKind)) and (FKind[ILine - 1] <> KindNone) then
    begin
      if FKind[ILine - 1] = KindAdded then Canvas.Brush.Color := ClAdded
      else Canvas.Brush.Color := ClModified;
      Canvas.FillRect(R.Left + 1, R.Top, R.Right - 1, R.Bottom);
    end;
    if (ILine <= Length(FTick)) and FTick[ILine - 1] then
    begin
      Canvas.Brush.Color := ClDeleted;
      Canvas.FillRect(R.Left, R.Top, R.Right, R.Top + 3);
    end;
  end;
end;

procedure TReviewGutterPart.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button = mbLeft) and Assigned(FOnClick) then FOnClick(FFile);
end;

function FindPart(AEdit: TSynEdit; const AFile: string): TReviewGutterPart;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to AEdit.Gutter.Parts.Count - 1 do
    if (AEdit.Gutter.Parts[I] is TReviewGutterPart) and
       (TReviewGutterPart(AEdit.Gutter.Parts[I]).FileName = AFile) then
      Exit(TReviewGutterPart(AEdit.Gutter.Parts[I]));
end;

procedure McpGutterAttach(AEdit: TSynEdit; const AFile: string; const ADisk: TDiffLines;
  AOnClick: TReviewGutterClick);
var
  Part: TReviewGutterPart;
begin
  if AEdit = nil then Exit;
  Part := FindPart(AEdit, AFile);
  if Part = nil then
  begin
    Part := TReviewGutterPart.Create(AEdit.Gutter.Parts);
    Part.FileName := AFile;
    Part.OnClick := AOnClick;
  end;
  Part.SetDisk(ADisk);
  AEdit.Invalidate;
end;

procedure McpGutterDetach(AEdit: TSynEdit; const AFile: string);
var
  Part: TReviewGutterPart;
begin
  if AEdit = nil then Exit;
  Part := FindPart(AEdit, AFile);
  if Part <> nil then
  begin
    Part.Free;
    AEdit.Invalidate;
  end;
end;

end.
