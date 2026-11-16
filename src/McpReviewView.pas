{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpReviewView;

{ The review window of ADR-025: three versions of a text side by side in editors,
  aligned with filler lines, scrolling together, the changed lines tinted.

  Left: the editor's own text, as it is now.  Right: the file on disk.  Both are
  read-only.  Middle: the RESULT, the text "Apply to editor" hands to ADone; it can be
  edited ("Edit"), and the arrows between the panes pull a side's version of a change
  into it ("<<" the disk's, ">>" the editor's).  Nothing reaches the real editor until
  "Apply to editor".

  When the text the editor and the disk both started from (the base) is known, the
  result starts as the three-way merge: every change only the disk made is already in
  it (green), the user's own changes stay, and what is left to decide is shown as the
  differences (conflicts, and the user's changes the disk lacks). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Types, Graphics, Controls, Forms, ExtCtrls, StdCtrls, Dialogs,
  SynEdit, SynEditTypes, SynEditMiscClasses, McpDiff;

type
  { AApplied: "Apply to editor" was pressed and ANewText is the working copy;
    otherwise the window was closed and the editor stays as it is. }
  TReviewDone = procedure(const AFile: string; AApplied: Boolean;
    const ANewText: string) of object;

var
  { The folder the tree shows file names relative to (the project directory). }
  McpReviewRoot: string = '';

{ Adds a file to the review window (one window for all files; opened when hidden, left
  where it is otherwise).  Mine: the editor's text.  Theirs: the file on disk.  Base:
  the text both started from, when AHasBase.  A file that is in the window already is
  replaced by the new state. }
procedure McpReviewShow(const AFile, ALeftTitle, ARightTitle: string;
  const Mine, Theirs, Base: TDiffLines; AHasBase: Boolean; ADone: TReviewDone);

{ The file's editor was closed: its page is removed from the window, unanswered. }
procedure McpReviewDrop(const AFile: string);

{ Shows the window with that file selected. }
procedure McpReviewFocus(const AFile: string);

{ Makes the window known to the IDE's window layout: it can be docked beside the source
  editor, minimised or floated like any IDE window, and the IDE remembers where it was.
  Called from the package's Register. }
procedure RegisterReviewWindow;

{ AColor mixed into ABack, APercent of it. }
function BlendColor(ABack, AColor: TColor; APercent: Integer): TColor;

implementation

uses
  Clipbrd, ComCtrls, LazFileUtils, SynEditMarkup, IDEOptEditorIntf, IDEWindowIntf,
  McpMarkdownView, McpReviewPaths;

const
  REVIEW_FORM_ID = 'McpReviewFormID';
  ArrowWidth = 28;                    { the column of arrows between two panes }

type
  { The part of a changed line that differs from the other side, drawn stronger than
    the tint of the whole line.  One range per text line (1-based columns, End excluded). }
  TWordMarkup = class(TSynEditMarkup)
  private
    FFrom, FTo: array of Integer;     { index: line - 1; 0 = none }
  public
    procedure SetRange(ALine, AFrom, ATo: Integer);
    procedure Clear;
    function GetMarkupAttributeAtRowCol(const aRow: Integer;
      const aStartCol: TLazSynDisplayTokenBound;
      const AnRtlInfo: TLazSynDisplayRtlInfo): TSynSelectedColor; override;
    procedure GetNextMarkupColAfterRowCol(const aRow: Integer;
      const aStartCol: TLazSynDisplayTokenBound; const AnRtlInfo: TLazSynDisplayRtlInfo;
      out ANextPhys, ANextLog: Integer); override;
  end;

  { One file of the review: the three panes (the editor's text, the result, the disk's
    text) and their buttons.  The window shows one page at a time and keeps the others
    (with the user's results) alive. }
  TReviewPage = class(TPanel)
  private
    FConflicts    : Integer;       { after the automatic merge; -1: no base, unknown }
    FFinished     : Boolean;
    FState        : string;        { what was done: 'applied' or 'kept' }
    FOnChange     : TNotifyEvent;  { the number of differences or the state changed }
    FBottom, FPanL, FPanM, FPanR, FStripPanL, FStripPanR : TPanel;
    FApplyBtn, FKeepBtn : TButton;
    FWordL, FWordM, FWordR : TWordMarkup;
    FMergedTheirs : TLineFlags;    { the disk's lines the automatic merge took, by their place there }
    FMergedRow    : array of Boolean;    { the same, by row of the aligned view }
    FNav          : TDiffRowArray;     { the rows of all changes, in order }
    FFile         : string;
    FEdL, FEdM, FEdR : TSynEdit;   { editor's text, result (the one that can be edited), disk }
    FStripL, FStripR : TPaintBox;  { the arrows: editor-result and result-disk }
    FEditBtn      : TButton;
    FEditor, FTheirs, FResult, FInitial : TDiffLines;
    FRows         : TAligned3;
    FEditing      : Boolean;
    FSyncing      : Boolean;
    FDone         : TReviewDone;
    FIgnored      : TStringList;   { changes marked "keep": by their text }
    function HunkKey(ASide: Integer; const AHunk: TDiffHunk): string;
    procedure IgnoreHunk(ASide, AHunk: Integer);
    procedure ExplainClick(Sender: TObject);
    procedure MarkWords;
    procedure MakeEditor(var AEdit: TSynEdit; AParent: TWinControl);
    procedure MakePane(var APanel: TPanel; var AEdit: TSynEdit; const ATitle: string;
      ALocked: Boolean);
    procedure LockPaint(Sender: TObject);
    function MakeStrip(var APanel: TPanel; ASide: Integer): TPaintBox;
    procedure EditorStatus(Sender: TObject; Changes: TSynStatusChanges);
    procedure LineMarkup(Sender: TObject; Line: Integer; var Special: Boolean;
      Markup: TSynSelectedColor);
    function Tint(AEdit: TSynEdit; ARow: Integer; out ATint: TColor): Boolean;
    procedure StripPaint(Sender: TObject);
    procedure StripMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer);
    function ArrowRect(ARow: Integer): TRect;
    function StripRows(ASide: Integer): TDiffRowArray;
    procedure Rebuild;
    procedure TakeHunk(ASide, AHunk: Integer);
    procedure ToggleEdit(Sender: TObject);
    procedure GoToChange(ADirection: Integer);
    procedure PrevChange(Sender: TObject);
    procedure NextChange(Sender: TObject);
    procedure ApplyClick(Sender: TObject);
    procedure DiscardClick(Sender: TObject);
    procedure ReadWorkingCopy;
    function Changed: Boolean;
    function WorkingText: string;
    procedure Buttons(AParent: TWinControl);
    procedure PositionButtons(Sender: TObject);
    procedure PageResize(Sender: TObject);
    procedure Finish(AApplied: Boolean);
    function GetDifferences: Integer;
  public
    constructor CreateReview(AOwner: TComponent; const AFile, ALeftTitle, ARightTitle: string;
      const Mine, Theirs, Base: TDiffLines; AHasBase: Boolean; ADone: TReviewDone);
    destructor Destroy; override;
    procedure Apply;                       { "Apply to editor" }
    procedure Keep(AAsk: Boolean);         { "Keep mine"; AAsk: confirm when edited }
    property FileName: string read FFile;
    property Finished: Boolean read FFinished;
    property State: string read FState;
    property Conflicts: Integer read FConflicts;
    property Differences: Integer read GetDifferences;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;


  { The review window: the files to review as a tree on the left, the page of the
    selected one on the right.  Closing it hides it; files not yet answered stay. }
  TReviewWindow = class(TForm)
  private
    FTree    : TTreeView;
    FHost    : TPanel;
    FPages   : TList;           { of TReviewPage }
    FRoot    : string;
    FCurrent : TReviewPage;
    procedure TreeChange(Sender: TObject; Node: TTreeNode);
    procedure TreeDraw(Sender: TCustomTreeView; Node: TTreeNode; State: TCustomDrawState;
      var DefaultDraw: Boolean);
    procedure PageChanged(Sender: TObject);
    procedure ApplyCleanClick(Sender: TObject);
    procedure KeepAllClick(Sender: TObject);
    procedure WindowClosed(Sender: TObject; var CloseAction: TCloseAction);
    procedure ShowPage(APage: TReviewPage);
    procedure RefreshTree;
    function Pending: Integer;
    function NextPending: TReviewPage;
    function PageLabel(APage: TReviewPage): string;
    function FindPage(const AFile: string): TReviewPage;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function Add(const AFile, ALeftTitle, ARightTitle: string;
      const Mine, Theirs, Base: TDiffLines; AHasBase: Boolean;
      ADone: TReviewDone): TReviewPage;
    procedure Focus(const AFile: string);
    procedure Drop(const AFile: string);
  end;

function BlendColor(ABack, AColor: TColor; APercent: Integer): TColor;
var
  B, C: Longint;
  function Mix(X, Y: Integer): Integer;
  begin
    Result := (X * (100 - APercent) + Y * APercent) div 100;
  end;
begin
  B := ColorToRGB(ABack);
  C := ColorToRGB(AColor);
  Result := RGBToColor(Mix(Red(B), Red(C)), Mix(Green(B), Green(C)), Mix(Blue(B), Blue(C)));
end;

{ ── Word-level markup ───────────────────────────────────────────────────── }

procedure TWordMarkup.SetRange(ALine, AFrom, ATo: Integer);
begin
  if Length(FFrom) < ALine then
  begin
    SetLength(FFrom, ALine);
    SetLength(FTo, ALine);
  end;
  FFrom[ALine - 1] := AFrom;
  FTo[ALine - 1] := ATo;
end;

procedure TWordMarkup.Clear;
begin
  FFrom := nil;
  FTo := nil;
end;

function TWordMarkup.GetMarkupAttributeAtRowCol(const aRow: Integer;
  const aStartCol: TLazSynDisplayTokenBound;
  const AnRtlInfo: TLazSynDisplayRtlInfo): TSynSelectedColor;
begin
  Result := nil;
  if (aRow < 1) or (aRow > Length(FFrom)) or (FFrom[aRow - 1] = 0) then Exit;
  if (aStartCol.Logical >= FFrom[aRow - 1]) and (aStartCol.Logical < FTo[aRow - 1]) then
  begin
    Result := MarkupInfo;
    MarkupInfo.SetFrameBoundsLog(FFrom[aRow - 1], FTo[aRow - 1]);
  end;
end;

procedure TWordMarkup.GetNextMarkupColAfterRowCol(const aRow: Integer;
  const aStartCol: TLazSynDisplayTokenBound; const AnRtlInfo: TLazSynDisplayRtlInfo;
  out ANextPhys, ANextLog: Integer);
begin
  ANextPhys := -1;
  ANextLog := -1;
  if (aRow < 1) or (aRow > Length(FFrom)) or (FFrom[aRow - 1] = 0) then Exit;
  if FFrom[aRow - 1] > aStartCol.Logical then ANextLog := FFrom[aRow - 1]
  else if FTo[aRow - 1] > aStartCol.Logical then ANextLog := FTo[aRow - 1];
end;

{ ── The window ───────────────────────────────────────────────────────────── }

procedure TReviewPage.MakeEditor(var AEdit: TSynEdit; AParent: TWinControl);
begin
  AEdit := TSynEdit.Create(Self);
  AEdit.Parent := AParent;
  AEdit.Align := alClient;
  if Assigned(IDEEditorOptions) then
    try
      IDEEditorOptions.GetSynEditorSettings(AEdit);   { the user's font and colours }
    except
    end;
  AEdit.ReadOnly := True;
  AEdit.OnStatusChange := @EditorStatus;
  AEdit.OnSpecialLineMarkup := @LineMarkup;
end;

{ A titled pane with an editor.  Its place is set by PageResize. }
procedure TReviewPage.MakePane(var APanel: TPanel; var AEdit: TSynEdit;
  const ATitle: string; ALocked: Boolean);
var
  Bar: TPanel;
  Title: TLabel;
  Lock: TPaintBox;
begin
  APanel := TPanel.Create(Self);
  APanel.Parent := Self;
  APanel.BevelOuter := bvNone;
  APanel.Align := alNone;
  Bar := TPanel.Create(Self);
  Bar.Parent := APanel;
  Bar.Align := alTop;
  Bar.Height := 22;
  Bar.BevelOuter := bvNone;
  Title := TLabel.Create(Self);
  Title.Parent := Bar;
  Title.Left := 6;
  Title.Top := 3;
  Title.Caption := ATitle;
  if ALocked then
  begin
    { a padlock: this text is not edited here; take its changes with the arrows }
    Lock := TPaintBox.Create(Self);
    Lock.Parent := Bar;
    Lock.Align := alRight;
    Lock.Width := 22;
    Lock.OnPaint := @LockPaint;
    Lock.Hint := 'Read-only while resolving: take its changes with the arrows, or edit ' +
      'the result in the middle';
    Lock.ShowHint := True;
  end;
  MakeEditor(AEdit, APanel);
end;

procedure TReviewPage.LockPaint(Sender: TObject);
var
  C: TCanvas;
  X, Y: Integer;
begin
  C := TPaintBox(Sender).Canvas;
  C.Brush.Color := TPaintBox(Sender).Parent.Color;
  C.FillRect(0, 0, TPaintBox(Sender).Width, TPaintBox(Sender).Height);
  X := (TPaintBox(Sender).Width - 12) div 2;
  Y := (TPaintBox(Sender).Height - 16) div 2;
  C.Pen.Color := clGrayText;
  C.Pen.Width := 2;
  C.Brush.Style := bsClear;
  C.Polyline([Point(X + 2, Y + 7), Point(X + 2, Y + 4), Point(X + 4, Y + 1),
    Point(X + 8, Y + 1), Point(X + 10, Y + 4), Point(X + 10, Y + 7)]);   { the shackle }
  C.Pen.Width := 1;
  C.Brush.Style := bsSolid;
  C.Brush.Color := clGrayText;
  C.RoundRect(X, Y + 7, X + 13, Y + 16, 3, 3);                           { the body }
  C.Brush.Color := TPaintBox(Sender).Parent.Color;
  C.Pen.Color := TPaintBox(Sender).Parent.Color;
  C.Ellipse(X + 5, Y + 10, X + 8, Y + 13);                               { the keyhole }
end;

{ The column of arrows between two panes (ASide 0: editor and result, 1: result and disk). }
function TReviewPage.MakeStrip(var APanel: TPanel; ASide: Integer): TPaintBox;
var
  Pan, Bar: TPanel;
begin
  Pan := TPanel.Create(Self);
  APanel := Pan;
  Pan.Parent := Self;
  Pan.BevelOuter := bvNone;
  Pan.Align := alNone;
  Bar := TPanel.Create(Self);          { the same height as the titles above the panes }
  Bar.Parent := Pan;
  Bar.Align := alTop;
  Bar.Height := 22;
  Bar.BevelOuter := bvNone;
  Result := TPaintBox.Create(Self);
  Result.Parent := Pan;
  Result.Align := alClient;
  Result.Tag := ASide;
  Result.OnPaint := @StripPaint;
  Result.OnMouseDown := @StripMouseDown;
end;

procedure TReviewPage.Buttons(AParent: TWinControl);
  function Btn(const ACaption: string; ALeft, AWidth: Integer; AClick: TNotifyEvent;
    AAlignRight: Boolean): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := AParent;
    Result.Caption := ACaption;
    Result.Width := AWidth;
    Result.Top := 5;
    Result.Left := ALeft;
    if AAlignRight then Result.Anchors := [akTop, akRight] else Result.Anchors := [akTop, akLeft];
    Result.OnClick := AClick;
  end;
begin
  with Btn(#$E2#$96#$B2, 6, 30, @PrevChange, False) do      { the up arrow }
  begin
    Hint := 'Previous change';
    ShowHint := True;
  end;
  with Btn(#$E2#$96#$BC, 40, 30, @NextChange, False) do      { the down arrow }
  begin
    Hint := 'Next change';
    ShowHint := True;
  end;
  FEditBtn := Btn('Edit', 82, 84, @ToggleEdit, False);
  FEditBtn.Hint := 'Edit the result in the middle';
  FEditBtn.ShowHint := True;
  with Btn('Explain', 172, 84, @ExplainClick, False) do
  begin
    Hint := 'Copy a prompt with the differences, to ask an assistant about them';
    ShowHint := True;
    Visible := False;    { hidden for now: the prompt is not finished }
  end;
  FKeepBtn := Btn('Keep mine', 0, 110, @DiscardClick, True);
  FKeepBtn.Hint := 'Leave the editor as it is';
  FKeepBtn.ShowHint := True;
  FApplyBtn := Btn('Apply to editor', 0, 130, @ApplyClick, True);
  FApplyBtn.Font.Style := [fsBold];                           { the main action }
  FApplyBtn.Hint := 'Put the result into the editor (Ctrl+Z undoes it)';
  FApplyBtn.ShowHint := True;
  AParent.OnResize := @PositionButtons;
  PositionButtons(AParent);
end;

procedure TReviewPage.PositionButtons(Sender: TObject);
begin
  if FBottom = nil then Exit;
  FApplyBtn.Left := FBottom.Width - 136;
  FKeepBtn.Left := FApplyBtn.Left - 118;
end;

{ The five columns, in this order: editor, arrows, result, arrows, disk.  The three texts
  get a third of the width each.  Placed by hand, so the order cannot be changed by the
  alignment of the parent. }
procedure TReviewPage.PageResize(Sender: TObject);
var
  W, H, X: Integer;
begin
  if (FPanL = nil) or (FPanM = nil) or (FPanR = nil) or (FBottom = nil) or
     (FStripPanL = nil) or (FStripPanR = nil) then Exit;
  W := (ClientWidth - 2 * ArrowWidth) div 3;
  if W < 60 then W := 60;
  H := ClientHeight - FBottom.Height;
  if H < 0 then H := 0;
  X := 0;
  FPanL.SetBounds(X, 0, W, H);
  Inc(X, W);
  FStripPanL.SetBounds(X, 0, ArrowWidth, H);
  Inc(X, ArrowWidth);
  FPanM.SetBounds(X, 0, W, H);
  Inc(X, W);
  FStripPanR.SetBounds(X, 0, ArrowWidth, H);
  Inc(X, ArrowWidth);
  FPanR.SetBounds(X, 0, ClientWidth - X, H);
end;

constructor TReviewPage.CreateReview(AOwner: TComponent; const AFile, ALeftTitle,
  ARightTitle: string; const Mine, Theirs, Base: TDiffLines; AHasBase: Boolean;
  ADone: TReviewDone);
var
  BottomBar : TPanel;
  Applied, NConflicts, NRemoved : Integer;
  Info   : string;
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  Caption := '';
  FFile := AFile;
  FDone := ADone;
  FIgnored := TStringList.Create;
  FTheirs := Copy(Theirs, 0, Length(Theirs));
  FEditor := Copy(Mine, 0, Length(Mine));
  Info := '';
  FConflicts := -1;
  if AHasBase then
  begin
    FResult := MergeAutoEx(Base, Mine, Theirs, Applied, NConflicts, FMergedTheirs, NRemoved);
    FConflicts := NConflicts;
    Info := Format('%d change(s) from disk merged automatically (green)', [Applied]);
  end
  else
  begin
    FResult := Copy(Mine, 0, Length(Mine));
    Info := 'no common base known: every difference is shown';
  end;
  FInitial := Copy(FResult, 0, Length(FResult));
  OnResize := @PageResize;

  BottomBar := TPanel.Create(Self);
  FBottom := BottomBar;
  BottomBar.Parent := Self;
  BottomBar.Align := alBottom;
  BottomBar.Height := 36;
  BottomBar.BevelOuter := bvNone;
  Buttons(BottomBar);

  { editor | arrows | result | arrows | disk }
  MakePane(FPanL, FEdL, ALeftTitle, True);
  FStripL := MakeStrip(FStripPanL, 0);
  MakePane(FPanM, FEdM, 'Result - ' + Info, False);
  FStripR := MakeStrip(FStripPanR, 1);
  MakePane(FPanR, FEdR, ARightTitle, True);
  PageResize(Self);

  FWordL := TWordMarkup.Create(FEdL);      { the editors own and free them }
  FEdL.MarkupManager.AddMarkUp(FWordL);
  FWordM := TWordMarkup.Create(FEdM);
  FEdM.MarkupManager.AddMarkUp(FWordM);
  FWordR := TWordMarkup.Create(FEdR);
  FEdR.MarkupManager.AddMarkUp(FWordR);
  Rebuild;
end;

{ ── What is shown ────────────────────────────────────────────────────────── }

procedure TReviewPage.Rebuild;
var
  I, J, N, KeepTop, KeepNav : Integer;

  { the changes marked "keep" get no arrow and are skipped by Next/Previous }
  procedure DropIgnored(ASide: Integer; var AHunks: TDiffHunks; var ARows: TDiffRowArray);
  var
    K, Cnt: Integer;
  begin
    Cnt := 0;
    for K := 0 to High(AHunks) do
      if FIgnored.IndexOf(HunkKey(ASide, AHunks[K])) < 0 then
      begin
        AHunks[Cnt] := AHunks[K];
        ARows[Cnt] := ARows[K];
        Inc(Cnt);
      end;
    SetLength(AHunks, Cnt);
    SetLength(ARows, Cnt);
  end;

begin
  KeepTop := FEdM.TopLine;
  FEdL.Lines.BeginUpdate;
  FEdM.Lines.BeginUpdate;
  FEdR.Lines.BeginUpdate;
  try
    FEdL.Lines.Clear;
    FEdM.Lines.Clear;
    FEdR.Lines.Clear;
    FNav := nil;
    if FEditing then
    begin
      { no alignment while the result is being edited: the plain texts }
      FRows := Default(TAligned3);
      FMergedRow := nil;
      for I := 0 to High(FEditor) do FEdL.Lines.Add(FEditor[I]);
      for I := 0 to High(FResult) do FEdM.Lines.Add(FResult[I]);
      for I := 0 to High(FTheirs) do FEdR.Lines.Add(FTheirs[I]);
    end
    else
    begin
      FRows := AlignRows3(FEditor, FResult, FTheirs);
      DropIgnored(0, FRows.LeftHunks, FRows.LeftHunkRow);
      DropIgnored(1, FRows.RightHunks, FRows.RightHunkRow);
      { the rows of all changes, in order, once each, for Next and Previous
        (both lists are sorted: merge them) }
      SetLength(FNav, Length(FRows.LeftHunkRow) + Length(FRows.RightHunkRow));
      N := 0;
      I := 0;
      J := 0;
      while (I <= High(FRows.LeftHunkRow)) or (J <= High(FRows.RightHunkRow)) do
      begin
        if (J > High(FRows.RightHunkRow)) or
           ((I <= High(FRows.LeftHunkRow)) and (FRows.LeftHunkRow[I] <= FRows.RightHunkRow[J])) then
        begin
          KeepNav := FRows.LeftHunkRow[I];
          Inc(I);
        end
        else
        begin
          KeepNav := FRows.RightHunkRow[J];
          Inc(J);
        end;
        if (N = 0) or (FNav[N - 1] <> KeepNav) then
        begin
          FNav[N] := KeepNav;
          Inc(N);
        end;
      end;
      SetLength(FNav, N);
      { which result lines the automatic merge took from the disk }
      SetLength(FMergedRow, Length(FRows.M));
      N := 0;
      for I := 0 to High(FRows.M) do
      begin
        FMergedRow[I] := False;
        if FRows.RK[I] = rkFiller then Continue;
        if (FRows.MK[I] <> rkFiller) and (FRows.RK[I] = rkEqual) and
           (N < Length(FMergedTheirs)) and FMergedTheirs[N] then
          FMergedRow[I] := True;
        Inc(N);
      end;
      for I := 0 to High(FRows.M) do
      begin
        FEdL.Lines.Add(FRows.L[I]);
        FEdM.Lines.Add(FRows.M[I]);
        FEdR.Lines.Add(FRows.R[I]);
      end;
    end;
  finally
    FEdL.Lines.EndUpdate;
    FEdM.Lines.EndUpdate;
    FEdR.Lines.EndUpdate;
  end;
  MarkWords;
  FEdM.ReadOnly := not FEditing;
  FEdM.TopLine := KeepTop;
  FEdL.TopLine := FEdM.TopLine;
  FEdR.TopLine := FEdM.TopLine;
  FEdL.Invalidate;
  FEdM.Invalidate;
  FEdR.Invalidate;
  FStripL.Invalidate;
  FStripR.Invalidate;
  if FEditing then FEditBtn.Caption := 'Done editing' else FEditBtn.Caption := 'Edit';
  if Assigned(FOnChange) then FOnChange(Self);      { the tree shows the count }
end;

{ In every changed row, the part that differs gets a stronger blue than the row's tint. }
procedure TReviewPage.MarkWords;
var
  I, MF, MT, OF_, OT: Integer;
  Blue: TColor;
begin
  FWordL.Clear;
  FWordM.Clear;
  FWordR.Clear;
  Blue := RGBToColor(70, 130, 220);
  FWordL.MarkupInfo.Background := BlendColor(FEdL.Color, Blue, 55);
  FWordL.MarkupInfo.Foreground := clNone;
  FWordM.MarkupInfo.Background := BlendColor(FEdM.Color, Blue, 55);
  FWordM.MarkupInfo.Foreground := clNone;
  FWordR.MarkupInfo.Background := BlendColor(FEdR.Color, Blue, 55);
  FWordR.MarkupInfo.Foreground := clNone;
  if FEditing then Exit;
  for I := 0 to High(FRows.M) do
  begin
    if FRows.MK[I] <> rkChanged then Continue;
    if FRows.LK[I] = rkChanged then
    begin
      DifferingSpan(FRows.M[I], FRows.L[I], MF, MT, OF_, OT);
      if OT > OF_ then FWordL.SetRange(I + 1, OF_, OT);
      if MT > MF then FWordM.SetRange(I + 1, MF, MT);
    end;
    if FRows.RK[I] = rkChanged then
    begin
      DifferingSpan(FRows.M[I], FRows.R[I], MF, MT, OF_, OT);
      if OT > OF_ then FWordR.SetRange(I + 1, OF_, OT);
      if MT > MF then FWordM.SetRange(I + 1, MF, MT);   { the disk's difference wins }
    end;
  end;
end;

{ JetBrains-like tints, mixed into the editor's own background (a dark scheme gets dark
  tints).  Editor and disk panes: a line the result lacks is red (editor) or green (disk),
  a different line blue, no line grey.  Result pane: blue where it differs from a side,
  green where the merge took a line from the disk, red where a side has a line the result
  lacks. }
function TReviewPage.Tint(AEdit: TSynEdit; ARow: Integer; out ATint: TColor): Boolean;
var
  Kind: TDiffRowKind;
  Back: TColor;
begin
  Result := True;
  ATint := clNone;
  Back := AEdit.Color;
  if AEdit = FEdL then Kind := FRows.LK[ARow]
  else if AEdit = FEdM then Kind := FRows.MK[ARow]
  else Kind := FRows.RK[ARow];
  if (AEdit = FEdM) and (ARow < Length(FMergedRow)) and FMergedRow[ARow] then
    ATint := BlendColor(Back, RGBToColor(60, 180, 90), 16)
  else
    case Kind of
      rkAdded:
        if AEdit = FEdL then ATint := BlendColor(Back, RGBToColor(215, 80, 80), 24)
        else ATint := BlendColor(Back, RGBToColor(60, 180, 90), 24);
      rkChanged: ATint := BlendColor(Back, RGBToColor(70, 130, 220), 24);
      rkFiller:
        if AEdit = FEdM then ATint := BlendColor(Back, RGBToColor(215, 80, 80), 40)
        else ATint := BlendColor(Back, RGBToColor(128, 128, 128), 14);
    else
      Result := False;
    end;
end;

procedure TReviewPage.LineMarkup(Sender: TObject; Line: Integer; var Special: Boolean;
  Markup: TSynSelectedColor);
var
  C: TColor;
begin
  if (Line < 1) or (Line > Length(FRows.M)) then Exit;
  if Tint(TSynEdit(Sender), Line - 1, C) then
  begin
    Special := True;
    Markup.Background := C;
    Markup.Foreground := clNone;
  end;
end;

procedure TReviewPage.EditorStatus(Sender: TObject; Changes: TSynStatusChanges);
var
  NewTop: Integer;

  procedure Follow(AEdit: TSynEdit);
  begin
    if (AEdit <> nil) and (AEdit <> Sender) then AEdit.TopLine := NewTop;
  end;

begin
  if not (scTopLine in Changes) then Exit;
  if FStripL <> nil then FStripL.Invalidate;
  if FStripR <> nil then FStripR.Invalidate;
  if FSyncing or FEditing then Exit;     { no common rows while editing }
  NewTop := TSynEdit(Sender).TopLine;
  FSyncing := True;
  try
    Follow(FEdL);
    Follow(FEdM);
    Follow(FEdR);
  finally
    FSyncing := False;
  end;
end;

{ ── The arrows between the panes ─────────────────────────────────────────── }

function TReviewPage.ArrowRect(ARow: Integer): TRect;
var
  Y, H: Integer;
begin
  H := FEdM.LineHeight;
  Y := (ARow + 1 - FEdM.TopLine) * H;
  Result := Rect(3, Y + 1, FStripL.Width - 3, Y + H - 1);
end;

function TReviewPage.StripRows(ASide: Integer): TDiffRowArray;
begin
  if ASide = 0 then Result := FRows.LeftHunkRow else Result := FRows.RightHunkRow;
end;

procedure TReviewPage.StripPaint(Sender: TObject);
var
  I, Side: Integer;
  R: TRect;
  C: TCanvas;
  TW, TH: Integer;
  Rows: TDiffRowArray;
  Sign: string;
begin
  Side := TPaintBox(Sender).Tag;
  C := TPaintBox(Sender).Canvas;
  C.Brush.Color := FEdM.Color;
  C.FillRect(0, 0, TPaintBox(Sender).Width, TPaintBox(Sender).Height);
  if FEditing then Exit;
  C.Font.Assign(FEdM.Font);
  Rows := StripRows(Side);
  if Side = 0 then Sign := '>>' else Sign := '<<';   { pulls the side's text into the result }
  for I := 0 to High(Rows) do
  begin
    R := ArrowRect(Rows[I]);
    if (R.Bottom < 0) or (R.Top > TPaintBox(Sender).Height) then Continue;
    C.Brush.Color := BlendColor(FEdM.Color, RGBToColor(70, 130, 220), 35);
    C.Pen.Color := BlendColor(FEdM.Color, RGBToColor(70, 130, 220), 70);
    C.RoundRect(R.Left, R.Top, R.Right, R.Bottom, 4, 4);
    C.Font.Color := FEdM.Font.Color;
    TW := C.TextWidth(Sign);
    TH := C.TextHeight(Sign);
    C.TextOut(R.Left + (R.Right - R.Left - TW) div 2, R.Top + (R.Bottom - R.Top - TH) div 2, Sign);
  end;
end;

procedure TReviewPage.StripMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  I, Side: Integer;
  Rows: TDiffRowArray;
begin
  if (not (Button in [mbLeft, mbRight])) or FEditing then Exit;
  Side := TPaintBox(Sender).Tag;
  Rows := StripRows(Side);
  for I := 0 to High(Rows) do
    if PtInRect(ArrowRect(Rows[I]), Point(X, Y)) then
    begin
      if Button = mbLeft then TakeHunk(Side, I) else IgnoreHunk(Side, I);   { right: keep the result }
      Exit;
    end;
end;

{ A change is known by the text on both sides, so it stays "kept" after the rows move. }
function TReviewPage.HunkKey(ASide: Integer; const AHunk: TDiffHunk): string;
begin
  with AHunk do
    if ASide = 0 then
      Result := 'L' + JoinLines(Slice(FResult, AStart, ALen), #10, False) + #1 +
        JoinLines(Slice(FEditor, BStart, BLen), #10, False)
    else
      Result := 'R' + JoinLines(Slice(FResult, AStart, ALen), #10, False) + #1 +
        JoinLines(Slice(FTheirs, BStart, BLen), #10, False);
end;

procedure TReviewPage.IgnoreHunk(ASide, AHunk: Integer);
begin
  if ASide = 0 then FIgnored.Add(HunkKey(0, FRows.LeftHunks[AHunk]))
  else FIgnored.Add(HunkKey(1, FRows.RightHunks[AHunk]));
  Rebuild;
end;

{ Explain: a prompt with the differences between the result and the disk, on the
  clipboard, for the user to paste into the assistant. }
procedure TReviewPage.ExplainClick(Sender: TObject);
var
  S: string;
  I, J: Integer;
  H: TDiffHunks;
begin
  if FEditing then ReadWorkingCopy;
  H := DiffLines(FResult, FTheirs);
  S := 'The file ' + FFile + ' was changed on disk while the IDE held unsaved edits in it.' +
    LineEnding + 'Below, "-" lines are in the current result (the editor text with the merge so far) ' +
    'and "+" lines are on disk. ' +
    'Please explain what each change does, whether they conflict, and which to keep.' +
    LineEnding + LineEnding + '```diff' + LineEnding;
  for I := 0 to High(H) do
  begin
    S := S + Format('@@ result line %d, disk line %d @@', [H[I].AStart + 1, H[I].BStart + 1]) +
      LineEnding;
    for J := 0 to H[I].ALen - 1 do S := S + '-' + FResult[H[I].AStart + J] + LineEnding;
    for J := 0 to H[I].BLen - 1 do S := S + '+' + FTheirs[H[I].BStart + J] + LineEnding;
  end;
  S := S + '```' + LineEnding;
  Clipboard.AsText := S;
  ShowMessage('The prompt is on the clipboard: paste it into your assistant.');
end;

{ ── Changing the result ──────────────────────────────────────────────────── }

{ The side's version of one change goes into the result. }
procedure TReviewPage.TakeHunk(ASide, AHunk: Integer);
var
  Take: array of Boolean;
  I   : Integer;
begin
  if ASide = 0 then SetLength(Take, Length(FRows.LeftHunks))
  else SetLength(Take, Length(FRows.RightHunks));
  for I := 0 to High(Take) do Take[I] := I = AHunk;
  if ASide = 0 then FResult := ApplyHunks(FResult, FEditor, FRows.LeftHunks, Take)
  else FResult := ApplyHunks(FResult, FTheirs, FRows.RightHunks, Take);
  Rebuild;
end;

procedure TReviewPage.ReadWorkingCopy;
var
  Dummy: Boolean;
begin
  FResult := SplitLines(FEdM.Lines.Text, Dummy);
end;

procedure TReviewPage.ToggleEdit(Sender: TObject);
begin
  if FEditing then ReadWorkingCopy;     { back to the aligned view of what was typed }
  FEditing := not FEditing;
  Rebuild;
end;

procedure TReviewPage.GoToChange(ADirection: Integer);
var
  I, Row, Cur: Integer;
begin
  if Length(FNav) = 0 then Exit;
  Cur := FEdM.TopLine - 1;
  Row := -1;
  if ADirection > 0 then
  begin
    for I := 0 to High(FNav) do
      if FNav[I] > Cur + 1 then
      begin
        Row := FNav[I];
        Break;
      end;
    if Row < 0 then Row := FNav[0];
  end
  else
  begin
    for I := High(FNav) downto 0 do
      if FNav[I] < Cur + 1 then
      begin
        Row := FNav[I];
        Break;
      end;
    if Row < 0 then Row := FNav[High(FNav)];
  end;
  Row := Row - 2;                         { a little context above }
  if Row < 0 then Row := 0;
  FEdM.TopLine := Row + 1;
end;

procedure TReviewPage.PrevChange(Sender: TObject);
begin
  GoToChange(-1);
end;

procedure TReviewPage.NextChange(Sender: TObject);
begin
  GoToChange(1);
end;

function TReviewPage.WorkingText: string;
begin
  if FEditing then ReadWorkingCopy;
  Result := JoinLines(FResult, LineEnding, True);
end;

function TReviewPage.Changed: Boolean;
var
  I: Integer;
begin
  if FEditing then ReadWorkingCopy;
  Result := Length(FResult) <> Length(FInitial);
  if not Result then
    for I := 0 to High(FResult) do
      if FResult[I] <> FInitial[I] then Exit(True);
end;

procedure TReviewPage.ApplyClick(Sender: TObject);
begin
  Apply;
end;

procedure TReviewPage.DiscardClick(Sender: TObject);
begin
  Keep(True);
end;

{ The answer is final: the buttons go, and the owner of the review hears of it.  The
  window is not closed; the file stays in its tree, marked as done. }
procedure TReviewPage.Finish(AApplied: Boolean);
var
  NewText: string;
begin
  if FFinished then Exit;
  if AApplied then NewText := WorkingText else NewText := '';
  FFinished := True;
  if AApplied then FState := 'applied' else FState := 'kept';
  FApplyBtn.Enabled := False;
  FKeepBtn.Enabled := False;
  FEditBtn.Enabled := False;
  FEdM.ReadOnly := True;
  if Assigned(FDone) then FDone(FFile, AApplied, NewText);
  if Assigned(FOnChange) then FOnChange(Self);
end;

procedure TReviewPage.Apply;
begin
  Finish(True);
end;

procedure TReviewPage.Keep(AAsk: Boolean);
begin
  if FFinished then Exit;
  if AAsk and Changed and (MessageDlg('Keep the editor as it is? The changes made in this ' +
                                      'window are lost, and the editor keeps its own text.',
                                      mtConfirmation, [mbYes, mbNo], 0) <> mrYes) then Exit;
  Finish(False);
end;

function TReviewPage.GetDifferences: Integer;
begin
  Result := Length(FRows.RightHunks);
end;

destructor TReviewPage.Destroy;
begin
  FIgnored.Free;
  inherited Destroy;
end;

{ ── The window with the tree of files ────────────────────────────────────── }

var
  GWindow: TReviewWindow = nil;

constructor TReviewWindow.Create(AOwner: TComponent);
var
  LeftPane, Bottom: TPanel;
  Split: TSplitter;
  Btn: TButton;
begin
  inherited CreateNew(AOwner);
  FPages := TList.Create;
  Caption := 'Review';
  Name := REVIEW_FORM_ID;         { the name the IDE's window layout knows it by }
  Width := 1280;
  Height := 640;
  Position := poDesigned;
  SetBounds((Screen.Width - Width) div 2, (Screen.Height - Height) div 2, Width, Height);
  OnClose := @WindowClosed;

  LeftPane := TPanel.Create(Self);
  LeftPane.Parent := Self;
  LeftPane.Align := alLeft;
  LeftPane.Width := 270;
  LeftPane.BevelOuter := bvNone;
  Split := TSplitter.Create(Self);
  Split.Parent := Self;
  Split.Align := alLeft;
  Split.Left := 271;
  FHost := TPanel.Create(Self);
  FHost.Parent := Self;
  FHost.Align := alClient;
  FHost.BevelOuter := bvNone;
  FHost.Caption := '';

  Bottom := TPanel.Create(Self);
  { the actions on all files wait above the tree: the bar at the bottom is the file's }
  Bottom.Parent := LeftPane;
  Bottom.Align := alTop;
  Bottom.Height := 36;
  Bottom.BevelOuter := bvNone;
  Btn := TButton.Create(Self);
  Btn.Parent := Bottom;
  Btn.SetBounds(4, 5, 140, 26);
  Btn.Caption := 'Apply all clean';
  Btn.Hint := 'Apply every file whose merge has no conflicts';
  Btn.ShowHint := True;
  Btn.OnClick := @ApplyCleanClick;
  Btn := TButton.Create(Self);
  Btn.Parent := Bottom;
  Btn.SetBounds(148, 5, 110, 26);
  Btn.Caption := 'Keep all mine';
  Btn.Hint := 'Leave every editor as it is';
  Btn.ShowHint := True;
  Btn.OnClick := @KeepAllClick;

  FTree := TTreeView.Create(Self);
  FTree.Parent := LeftPane;
  FTree.Align := alClient;
  FTree.ReadOnly := True;
  FTree.OnChange := @TreeChange;
  FTree.OnCustomDrawItem := @TreeDraw;
end;

destructor TReviewWindow.Destroy;
begin
  GWindow := nil;
  FPages.Free;
  inherited Destroy;
end;

function TReviewWindow.FindPage(const AFile: string): TReviewPage;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to FPages.Count - 1 do
    if CompareFilenames(TReviewPage(FPages[I]).FileName, AFile) = 0 then
      Exit(TReviewPage(FPages[I]));
end;

function TReviewWindow.Pending: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FPages.Count - 1 do
    if not TReviewPage(FPages[I]).Finished then Inc(Result);
end;

function TReviewWindow.NextPending: TReviewPage;
var
  I, Start: Integer;
begin
  Result := nil;
  Start := FPages.IndexOf(FCurrent);
  for I := 1 to FPages.Count do
    if not TReviewPage(FPages[(Start + I + FPages.Count) mod FPages.Count]).Finished then
      Exit(TReviewPage(FPages[(Start + I + FPages.Count) mod FPages.Count]));
end;

function TReviewWindow.PageLabel(APage: TReviewPage): string;
begin
  if APage.Finished then
    Result := '  [' + APage.State + ']'
  else if APage.Differences = 0 then
    Result := '  [identical]'
  else
    Result := '  [' + IntToStr(APage.Differences) + ' to review]';
end;

procedure TReviewWindow.RefreshTree;
var
  I, J: Integer;
  Page: TReviewPage;
  Parts: TPathParts;
  Outside: Boolean;
  OutNode, Dir, Node, Child, Sel: TTreeNode;
begin
  FTree.OnChange := nil;                    { the selection is set here, not by the user }
  FTree.Items.BeginUpdate;
  try
    FTree.Items.Clear;
    OutNode := nil;
    Sel := nil;
    for I := 0 to FPages.Count - 1 do
    begin
      Page := TReviewPage(FPages[I]);
      Parts := ReviewPathParts(Page.FileName, FRoot, Outside);
      if Outside then
      begin
        if OutNode = nil then OutNode := FTree.Items.Add(nil, 'Outside the project');
        Node := FTree.Items.AddChildObject(OutNode, Parts[0] + PageLabel(Page), Page);
      end
      else
      begin
        Dir := nil;
        for J := 0 to High(Parts) - 1 do
        begin
          { the folder's node, made on first use }
          if Dir = nil then Child := FTree.Items.GetFirstNode
          else Child := Dir.GetFirstChild;
          while (Child <> nil) and not ((Child.Data = nil) and (Child.Text = Parts[J])) do
            Child := Child.GetNextSibling;
          if Child = nil then
          begin
            if Dir = nil then Child := FTree.Items.Add(nil, Parts[J])
            else Child := FTree.Items.AddChild(Dir, Parts[J]);
          end;
          Dir := Child;
        end;
        if Dir = nil then
          Node := FTree.Items.AddObject(nil, Parts[High(Parts)] + PageLabel(Page), Page)
        else
          Node := FTree.Items.AddChildObject(Dir, Parts[High(Parts)] + PageLabel(Page), Page);
      end;
      if Page = FCurrent then Sel := Node;
    end;
    FTree.FullExpand;
  finally
    FTree.Items.EndUpdate;
  end;
  if Sel <> nil then FTree.Selected := Sel;
  FTree.OnChange := @TreeChange;
  if Pending = 0 then
    Caption := 'Review: nothing waiting'
  else
    Caption := Format('Review: %d file(s) waiting', [Pending]);
end;

procedure TReviewWindow.ShowPage(APage: TReviewPage);
begin
  if APage = FCurrent then Exit;
  if FCurrent <> nil then FCurrent.Visible := False;
  FCurrent := APage;
  if APage <> nil then APage.Visible := True;
  RefreshTree;
end;

procedure TReviewWindow.TreeChange(Sender: TObject; Node: TTreeNode);
begin
  if (Node <> nil) and (Node.Data <> nil) then ShowPage(TReviewPage(Node.Data));
end;

procedure TReviewWindow.TreeDraw(Sender: TCustomTreeView; Node: TTreeNode;
  State: TCustomDrawState; var DefaultDraw: Boolean);
begin
  { what is answered already is dimmed }
  if (Node.Data <> nil) and TReviewPage(Node.Data).Finished then
    Sender.Canvas.Font.Color := clGrayText;
end;

procedure TReviewWindow.PageChanged(Sender: TObject);
begin
  if (Sender = FCurrent) and TReviewPage(Sender).Finished and (NextPending <> nil) then
    ShowPage(NextPending)               { on to the next file waiting }
  else
    RefreshTree;
end;

procedure TReviewWindow.ApplyCleanClick(Sender: TObject);
var
  I: Integer;
  P: TReviewPage;
begin
  for I := 0 to FPages.Count - 1 do
  begin
    P := TReviewPage(FPages[I]);
    if (not P.Finished) and (P.Conflicts = 0) then P.Apply;
  end;
end;

procedure TReviewWindow.KeepAllClick(Sender: TObject);
var
  I: Integer;
begin
  if (Pending > 0) and (MessageDlg('Keep the editor text of all ' + IntToStr(Pending) +
                                   ' file(s) waiting? Nothing from the disk is taken.',
                                   mtConfirmation, [mbYes, mbNo], 0) <> mrYes) then Exit;
  for I := 0 to FPages.Count - 1 do TReviewPage(FPages[I]).Keep(False);
end;

{ The window only hides; the files not answered yet stay waiting in it. }
procedure TReviewWindow.WindowClosed(Sender: TObject; var CloseAction: TCloseAction);
var
  I: Integer;
  P: TReviewPage;
begin
  CloseAction := caHide;
  for I := FPages.Count - 1 downto 0 do
  begin
    P := TReviewPage(FPages[I]);
    if not P.Finished then Continue;
    if P = FCurrent then FCurrent := nil;
    FPages.Delete(I);
    P.Free;
  end;
  if (FCurrent = nil) and (FPages.Count > 0) then ShowPage(NextPending) else RefreshTree;
end;

function TReviewWindow.Add(const AFile, ALeftTitle, ARightTitle: string;
  const Mine, Theirs, Base: TDiffLines; AHasBase: Boolean;
  ADone: TReviewDone): TReviewPage;
var
  Old: TReviewPage;
  WasCurrent: Boolean;
begin
  FRoot := McpReviewRoot;
  Old := FindPage(AFile);
  WasCurrent := (Old <> nil) and (Old = FCurrent);
  if Old <> nil then
  begin
    if Old = FCurrent then FCurrent := nil;
    FPages.Remove(Old);
    Old.Free;
  end;
  Result := TReviewPage.CreateReview(Self, AFile, ALeftTitle, ARightTitle, Mine, Theirs,
    Base, AHasBase, ADone);
  Result.Parent := FHost;
  Result.Align := alClient;
  Result.Visible := False;
  Result.OnChange := @PageChanged;
  FPages.Add(Result);
  { the one looked at stays; a new file is shown only when nothing is }
  if WasCurrent or (FCurrent = nil) or FCurrent.Finished then ShowPage(Result)
  else RefreshTree;
end;

{ The file's editor is gone: its page leaves the window without an answer. }
procedure TReviewWindow.Drop(const AFile: string);
var
  P: TReviewPage;
begin
  P := FindPage(AFile);
  if P = nil then Exit;
  FPages.Remove(P);
  if P = FCurrent then FCurrent := nil;
  P.Free;
  if (FCurrent = nil) and (NextPending <> nil) then ShowPage(NextPending) else RefreshTree;
end;

procedure TReviewWindow.Focus(const AFile: string);
var
  P: TReviewPage;
begin
  P := FindPage(AFile);
  if P <> nil then ShowPage(P);
  { the user asked for it: shown and brought forward, docked or floating }
  if Assigned(IDEWindowCreators) and (IDEWindowCreators.FindWithName(REVIEW_FORM_ID) <> nil) then
    IDEWindowCreators.ShowForm(Self, True)
  else
    Show;
  MoveToIdeMonitor(Self);
end;

{ ── Window layout (docking) ──────────────────────────────────────────────── }

procedure CreateReviewForm(Sender: TObject; aFormName: string;
  var AForm: TCustomForm; DoDisableAutoSizing: boolean);
begin
  if CompareText(aFormName, REVIEW_FORM_ID) <> 0 then Exit;
  IDEWindowCreators.CreateForm(AForm, TReviewWindow, DoDisableAutoSizing, Application);
  AForm.Name := aFormName;
  GWindow := TReviewWindow(AForm);
end;

procedure RegisterReviewWindow;
begin
  if Assigned(IDEWindowCreators) then
    IDEWindowCreators.Add(REVIEW_FORM_ID, @CreateReviewForm, nil, '', '', '', '',
      'SourceNotebook', alRight, False);   { where a new window docks until the user moves it }
end;

{ The window, made on first use through the IDE's window layout when it knows it. }
function ReviewWindow(out ARegistered: Boolean): TReviewWindow;
begin
  ARegistered := Assigned(IDEWindowCreators) and
                 (IDEWindowCreators.FindWithName(REVIEW_FORM_ID) <> nil);
  if GWindow = nil then
  begin
    if ARegistered then IDEWindowCreators.GetForm(REVIEW_FORM_ID, True);   { sets GWindow }
    if GWindow = nil then GWindow := TReviewWindow.Create(Application);
  end;
  Result := GWindow;
end;

{ Shown, not activated: the user keeps typing where they were (ADR-011). }
procedure ShowWindowQuietly(AWindow: TReviewWindow; ARegistered: Boolean);
var
  Prev: TCustomForm;
begin
  if AWindow.Visible and (GetParentForm(AWindow) <> nil) and GetParentForm(AWindow).Visible then
    Exit;
  Prev := Screen.ActiveCustomForm;
  if ARegistered then
    IDEWindowCreators.ShowForm(AWindow, False)      { floating or docked, as the layout says }
  else
    AWindow.Show;
  MoveToIdeMonitor(AWindow);
  if Assigned(Prev) and (Prev <> AWindow) and Prev.Visible and Prev.CanFocus then
    Prev.SetFocus;
end;

procedure McpReviewShow(const AFile, ALeftTitle, ARightTitle: string;
  const Mine, Theirs, Base: TDiffLines; AHasBase: Boolean; ADone: TReviewDone);
var
  W: TReviewWindow;
  Registered: Boolean;
begin
  W := ReviewWindow(Registered);
  W.Add(AFile, ALeftTitle, ARightTitle, Mine, Theirs, Base, AHasBase, ADone);
  ShowWindowQuietly(W, Registered);
end;

procedure McpReviewFocus(const AFile: string);
var
  W: TReviewWindow;
  Registered: Boolean;
begin
  W := ReviewWindow(Registered);
  W.Focus(AFile);
end;

procedure McpReviewDrop(const AFile: string);
begin
  if GWindow <> nil then GWindow.Drop(AFile);       { no window: nothing waits }
end;

end.
