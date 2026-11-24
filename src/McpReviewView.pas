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
  SynEdit, SynEditTypes, SynEditMiscClasses, McpDiff, LCLVersion;

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
  const Mine, Theirs, Base: TDiffLines; AHasBase: Boolean; ADone: TReviewDone;
  AConflict: Boolean = False);

{ AConflict (a git merge conflict, ADR-028): the page says "Resolve (write and stage)" and
  "Leave unresolved"; Apply stays disabled until every conflicting change is decided (an
  arrow, "keep" with the right click, or an edit of the result) and while the result still
  holds a conflict block; "Leave unresolved" asks nothing. }

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
  Clipbrd, ComCtrls, LazFileUtils, LazUTF8, SynEditMarkup, IDEOptEditorIntf, IDEWindowIntf,
  McpMarkdownView, McpReviewPaths, McpConflictFiles
  {$IF lcl_fullversion >= 4090000}, EditorOptionsIntf, LazEditHighlighter{$ENDIF};

type
  { what a markup returns for a position: Lazarus 5.0 made it a base class of TSynSelectedColor }
  {$IF lcl_fullversion >= 4090000}
  TMdMarkupColor = TLazEditHighlighterAttributesModifier;
  {$ELSE}
  TMdMarkupColor = TSynSelectedColor;
  {$ENDIF}

const
  REVIEW_FORM_ID = 'McpReviewFormID';
  ArrowWidth = 28;                    { the column of arrows between two panes }
  GutterWidth = 58;                   { the same for a git conflict: up to two buttons }
  GutterBtnWidth = 24;                { one of them }

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
      const AnRtlInfo: TLazSynDisplayRtlInfo): TMdMarkupColor; override;
    procedure GetNextMarkupColAfterRowCol(const aRow: Integer;
      const aStartCol: TLazSynDisplayTokenBound; const AnRtlInfo: TLazSynDisplayRtlInfo;
      out ANextPhys, ANextLog: Integer); override;
  end;

  { What a button in the gutter of a conflict's change does: drop the change (keep the
    result as it is), take it (the side's lines replace the result's), or put the side's
    lines below the result's (both stay). }
  TGutterAct = (gaDrop, gaTake, gaBeside, gaReset);   { gaReset: Hunk is a conflict, not a change }
  TGutterCtl = record
    Act  : TGutterAct;
    Hunk : Integer;        { the index among the side's changes }
    Rect : TRect;
  end;
  TGutterCtls = array of TGutterCtl;

  { One file of the review: the three panes (the editor's text, the result, the disk's
    text) and their buttons.  The window shows one page at a time and keeps the others
    (with the user's results) alive. }
  TReviewPage = class(TPanel)
  private
    FConflicts    : Integer;       { after the automatic merge; -1: no base, unknown }
    FConflictMode : Boolean;       { a git conflict: Apply writes and stages (ADR-028) }
    { the conflicts of a git merge, in order (FConflictMode): their lines in the result
      follow it through every arrow, "keep" and edit, and one is settled when one of those
      touched its lines (McpConflictFiles) }
    FSpans        : TConflictSpans;
    FStripW       : Integer;       { the width of a column of arrows or gutter buttons }
    FBeforeEdit   : TDiffLines;    { the result when editing began, to see what was changed }
    FStatus       : TLabel;
    FFinished     : Boolean;
    FState        : string;        { what was done: 'applied' or 'kept' }
    FOnChange     : TNotifyEvent;  { the number of differences or the state changed }
    FBottom, FPanL, FPanM, FPanR, FStripPanL, FStripPanR : TPanel;
    FApplyBtn, FKeepBtn : TButton;
    FWordL, FWordM, FWordR : TWordMarkup;
    FMergedTheirs : TLineFlags;    { the disk's lines the automatic merge took, by their place there }
    FMergedRow    : array of Boolean;    { the same, by row of the aligned view }
    FNav          : TDiffRowArray;     { the rows of all changes, in order }
    { a git conflict: the rows of the result that a change still to be dealt with covers,
      by side; what has been taken or dropped is no longer coloured }
    FLive         : array[0..1] of array of Boolean;
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
    function ApplyBlocker: string;
    procedure UpdateApplyState;
    procedure InitSpans(const Base, Mine, Theirs: TDiffLines; AHasBase: Boolean);
    procedure MoveSpans(AStart, ALen, ABLen: Integer; ASettle, AEdges: Boolean);
    function Unsettled: Integer;
    function HunkSpan(ASide, AHunk: Integer): Integer;
    function HunkOffered(ASide, AHunk: Integer): Boolean;
    procedure MarkDone(ASpan, ASide: Integer; ATook: Boolean);
    procedure FindLiveRows;
    function GutterControls(ASide: Integer): TGutterCtls;
    procedure GutterPaint(ASide: Integer; C: TCanvas; AWidth, AHeight: Integer);
    procedure GutterMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure TakeBeside(ASide, AHunk: Integer);
    function TintConflict(AEdit: TSynEdit; ARow: Integer; out ATint: TColor): Boolean;
    function RowLive(ASide, ARow: Integer): Boolean;
    function SpanRow(ASpan: Integer): Integer;
    procedure DecideAgain(ASpan: Integer);
    function PlaceRow(AEdit: TSynEdit; ARow: Integer; out AColor: TColor): Boolean;
    function LineBelow(AEdit: TSynEdit; ARow: Integer; out AColor: TColor): Boolean;
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
      const Mine, Theirs, Base: TDiffLines; AHasBase: Boolean; ADone: TReviewDone;
      AConflict: Boolean = False);
    destructor Destroy; override;
    procedure Apply;                       { "Apply to editor" }
    procedure Keep(AAsk: Boolean);         { "Keep mine"; AAsk: confirm when edited }
    property FileName: string read FFile;
    property Finished: Boolean read FFinished;
    property State: string read FState;
    property Conflicts: Integer read FConflicts;
    property ConflictMode: Boolean read FConflictMode;
    property Differences: Integer read GetDifferences;
    function TreeNote: string;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;


  { The review window: the files to review as a tree on the left, the page of the
    selected one on the right.  Closing it hides it; files not yet answered stay. }
  TReviewWindow = class(TForm)
  private
    FTree    : TTreeView;
    FHost    : TPanel;
    FAllApplyBtn, FAllKeepBtn : TButton;   { the actions on all files; worded for the page shown }
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
    procedure WordAllButtons(AConflict: Boolean);
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
      ADone: TReviewDone; AConflict: Boolean = False): TReviewPage;
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

{ SynEdit's markup overrides: the signatures are fixed, AnRtlInfo is not needed }
{$PUSH}{$WARN 5024 OFF}
function TWordMarkup.GetMarkupAttributeAtRowCol(const aRow: Integer;
  const aStartCol: TLazSynDisplayTokenBound;
  const AnRtlInfo: TLazSynDisplayRtlInfo): TMdMarkupColor;
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
{$POP}

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
  Result.OnMouseMove := @GutterMouseMove;
  Result.ShowHint := True;
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
  if FConflictMode then
  begin
    FEditBtn.Hint := 'Write your own version of a conflict: edit the result, then press Done editing. ' +
      'The buttons beside each change take it (>> or <<), drop it (X) or put it below what is there';
    FStatus := TLabel.Create(Self);
    FStatus.Parent := AParent;
    FStatus.Left := 180;
    FStatus.Top := 11;
  end;
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
  if FConflictMode then
  begin
    FKeepBtn.Caption := 'Leave unresolved';
    FKeepBtn.Hint := 'The conflict markers stay in the file and nothing is staged';
    FApplyBtn.Caption := 'Resolve (write and stage)';
    FApplyBtn.Width := 180;
    FKeepBtn.Width := 120;
    FApplyBtn.Hint := 'Write the result to the file and stage it. Not an editor undo step: ' +
      'git_merge_abort or git_rebase_abort is the way back';
  end;
  AParent.OnResize := @PositionButtons;
  PositionButtons(AParent);
end;

{ event handlers: the LCL fixes the signatures, Sender is not needed }
{$PUSH}{$WARN 5024 OFF}
procedure TReviewPage.PositionButtons(Sender: TObject);
begin
  if FBottom = nil then Exit;
  FApplyBtn.Left := FBottom.Width - FApplyBtn.Width - 6;
  FKeepBtn.Left := FApplyBtn.Left - FKeepBtn.Width - 8;
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
  W := (ClientWidth - 2 * FStripW) div 3;
  if W < 60 then W := 60;
  H := ClientHeight - FBottom.Height;
  if H < 0 then H := 0;
  X := 0;
  FPanL.SetBounds(X, 0, W, H);
  Inc(X, W);
  FStripPanL.SetBounds(X, 0, FStripW, H);
  Inc(X, FStripW);
  FPanM.SetBounds(X, 0, W, H);
  Inc(X, W);
  FStripPanR.SetBounds(X, 0, FStripW, H);
  Inc(X, FStripW);
  FPanR.SetBounds(X, 0, ClientWidth - X, H);
end;
{$POP}

constructor TReviewPage.CreateReview(AOwner: TComponent; const AFile, ALeftTitle,
  ARightTitle: string; const Mine, Theirs, Base: TDiffLines; AHasBase: Boolean;
  ADone: TReviewDone; AConflict: Boolean);
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
  FConflictMode := AConflict;
  if FConflictMode then FStripW := GutterWidth else FStripW := ArrowWidth;
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
  if FConflictMode then
  begin
    { each conflict starts as the common lines: both sides stand against them (ADR-028) }
    FResult := ConflictStart(Base, Mine, Theirs, AHasBase);
    InitSpans(Base, Mine, Theirs, AHasBase);
    Info := 'each conflict shows the common lines: take, drop or write your own';
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
  NavL, NavR : TDiffRowArray;       { the rows Next and Previous stop at, by side }

  { a git conflict stops only at what has buttons: the changes nobody has dealt with }
  procedure OfferedRows(ASide: Integer; var ARows: TDiffRowArray);
  var
    K, Cnt : Integer;
    Src : TDiffRowArray;
  begin
    if ASide = 0 then Src := FRows.LeftHunkRow else Src := FRows.RightHunkRow;
    ARows := nil;
    SetLength(ARows, Length(Src));
    Cnt := 0;
    for K := 0 to High(Src) do
      if HunkOffered(ASide, K) then
      begin
        ARows[Cnt] := Src[K];
        Inc(Cnt);
      end;
    SetLength(ARows, Cnt);
  end;

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
      NavL := FRows.LeftHunkRow;
      NavR := FRows.RightHunkRow;
      if FConflictMode then
      begin
        FindLiveRows;
        OfferedRows(0, NavL);
        OfferedRows(1, NavR);
      end;
      SetLength(FNav, Length(NavL) + Length(NavR));
      N := 0;
      I := 0;
      J := 0;
      while (I <= High(NavL)) or (J <= High(NavR)) do
      begin
        if (J > High(NavR)) or ((I <= High(NavL)) and (NavL[I] <= NavR[J])) then
        begin
          KeepNav := NavL[I];
          Inc(I);
        end
        else
        begin
          KeepNav := NavR[J];
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
  UpdateApplyState;
  if Assigned(FOnChange) then FOnChange(Self);      { the tree shows the count }
end;

{ Why Apply is not possible yet; '' when it is.  Only a git conflict has reasons. }
function TReviewPage.ApplyBlocker: string;
var
  N : Integer;
begin
  Result := '';
  if not FConflictMode then Exit;
  if FEditing then
    Exit('Press "Done editing" first: what is typed settles a conflict only then.');
  if HasConflictBlock(FResult) then
    Exit('The result still has a conflict block (<<<<<<< ... >>>>>>>): edit it away.');
  { the automatic merge put each conflict as the left version, but a conflict is settled
    only when the user has done something to its lines: an arrow, a "keep", one of the
    Take buttons, or typing over them (a third version) }
  N := Unsettled;
  if N > 0 then
    Result := IntToStr(N) + ' conflict(s) still to decide: use the buttons beside a change ' +
      '(take, drop, or put it below), or edit the result.';
end;

procedure TReviewPage.UpdateApplyState;
begin
  if FStatus <> nil then
    if Length(FSpans) = 0 then
      FStatus.Caption := 'No conflicting changes'
    else if Unsettled = 0 then
      FStatus.Caption := Format('All %d conflict(s) decided', [Length(FSpans)])
    else
      FStatus.Caption := Format('%d of %d conflict(s) to decide', [Unsettled, Length(FSpans)]);
  if FFinished or (FApplyBtn = nil) then Exit;
  FApplyBtn.Enabled := ApplyBlocker = '';
  if FConflictMode and not FApplyBtn.Enabled then
    FApplyBtn.Hint := ApplyBlocker;
end;

{ ── The conflicts of a git merge ─────────────────────────────────────────── }

{ Where each conflict's lines are in the result the automatic merge made: it takes the
  left (Mine) version of a conflict, the right one of a change only the right made. }
procedure TReviewPage.InitSpans(const Base, Mine, Theirs: TDiffLines; AHasBase: Boolean);
begin
  FSpans := InitConflictSpans(Base, Mine, Theirs, AHasBase);
end;

procedure TReviewPage.MoveSpans(AStart, ALen, ABLen: Integer; ASettle, AEdges: Boolean);
begin
  MoveConflictSpans(FSpans, AStart, ALen, ABLen, ASettle, AEdges);
end;

function TReviewPage.Unsettled: Integer;
begin
  Result := UnsettledSpans(FSpans);
end;

{ The conflict a change of one side belongs to, or -1 (no conflict touches it). }
function TReviewPage.HunkSpan(ASide, AHunk: Integer): Integer;
begin
  if ASide = 0 then
    Result := SpanOfHunk(FSpans, FRows.LeftHunks[AHunk].AStart, FRows.LeftHunks[AHunk].ALen)
  else
    Result := SpanOfHunk(FSpans, FRows.RightHunks[AHunk].AStart, FRows.RightHunks[AHunk].ALen);
end;

{ A change that has buttons: it belongs to a conflict and this side has not dealt with it.
  Only those are coloured and stopped at: a change the automatic merge took has no buttons,
  and what the other side's lines look like to a side that has taken its own is no news. }
function TReviewPage.HunkOffered(ASide, AHunk: Integer): Boolean;
var
  Span : Integer;
begin
  Span := HunkSpan(ASide, AHunk);
  Result := (Span >= 0) and not FSpans[Span].Done[ASide];
end;

procedure TReviewPage.MarkDone(ASpan, ASide: Integer; ATook: Boolean);
begin
  if (ASpan < 0) or (ASpan > High(FSpans)) then Exit;
  FSpans[ASpan].Done[ASide] := True;
  if ATook then FSpans[ASpan].Took[ASide] := True;
end;

{ The rows each side's live changes cover, for the colours. }
procedure TReviewPage.FindLiveRows;
var
  Side, I, K, N : Integer;
  Hunks : TDiffHunks;
  Rows  : TDiffRowArray;
begin
  for Side := 0 to 1 do
  begin
    FLive[Side] := nil;
    SetLength(FLive[Side], Length(FRows.M));
    if Side = 0 then
    begin
      Hunks := FRows.LeftHunks;
      Rows  := FRows.LeftHunkRow;
    end
    else
    begin
      Hunks := FRows.RightHunks;
      Rows  := FRows.RightHunkRow;
    end;
    for I := 0 to High(Hunks) do
    begin
      if not HunkOffered(Side, I) then Continue;
      N := Hunks[I].ALen;
      if Hunks[I].BLen > N then N := Hunks[I].BLen;
      for K := Rows[I] to Rows[I] + N - 1 do
        if K < Length(FLive[Side]) then FLive[Side][K] := True;
    end;
  end;
end;

{ The buttons beside the changes of one side that touch a conflict, in the order of the
  gutter: drop, take, put below.  The left gutter reads [drop] [take] [below], the right one
  the other way round, so that "take" points at the result in both.  "Put below" is offered
  only once the conflict has been settled (something else sits there now) and the side has
  lines to put there.  A change that belongs to no conflict (the automatic merge took the
  other side's or the same change) gets nothing. }
function TReviewPage.GutterControls(ASide: Integer): TGutterCtls;
var
  Hunks : TDiffHunks;
  Rows  : TDiffRowArray;
  I, N, H, Span, K : Integer;

  procedure Add(AAct: TGutterAct; ASlot: Integer);
  var
    X, Y : Integer;
  begin
    if ASide = 0 then
      X := 3 + ASlot * (GutterBtnWidth + 2)
    else
      X := 3 + (1 - ASlot) * (GutterBtnWidth + 2);
    Y := (Rows[I] + 1 - FEdM.TopLine) * H;
    SetLength(Result, N + 1);
    Result[N].Act  := AAct;
    Result[N].Hunk := I;
    Result[N].Rect := Rect(X, Y + 1, X + GutterBtnWidth, Y + H - 1);
    Inc(N);
  end;

begin
  Result := nil;
  if FEditing or not FConflictMode then Exit;
  if ASide = 0 then
  begin
    Hunks := FRows.LeftHunks;
    Rows  := FRows.LeftHunkRow;
  end
  else
  begin
    Hunks := FRows.RightHunks;
    Rows  := FRows.RightHunkRow;
  end;
  H := FEdM.LineHeight;
  N := 0;
  for I := 0 to High(Hunks) do
  begin
    Span := SpanOfHunk(FSpans, Hunks[I].AStart, Hunks[I].ALen);
    if (Span < 0) or FSpans[Span].Done[ASide] then Continue;
    Add(gaDrop, 0);
    { "below" needs lines of the other side to go below and lines of this side to put there;
      in any other case (nothing taken yet, or the other side's change left no lines, as a
      deletion does) the change simply goes in }
    if FSpans[Span].Took[1 - ASide] and (Hunks[I].ALen > 0) and (Hunks[I].BLen > 0) then
      Add(gaBeside, 1)
    else
      Add(gaTake, 1);
  end;
  { a conflict something was done to can be decided again: a button on the row of its
    first line in the gutter of each side that was dealt with; both do the same }
  for I := 0 to High(FSpans) do
  begin
    { each side that was dealt with has its own button; typed text, which no side did, has
      one on the left }
    if not (FSpans[I].Done[ASide] or
            ((ASide = 0) and FSpans[I].Settled and not FSpans[I].Done[1])) then Continue;
    N := Length(Result);
    SetLength(Result, N + 1);
    Result[N].Act  := gaReset;
    Result[N].Hunk := I;
    Span := SpanRow(I);
    if Span < 0 then Span := 0;
    { the slot next to the pane's edge, as "drop" has it }
    K := 3 + ASide * (GutterBtnWidth + 2);
    Result[N].Rect := Rect(K, (Span + 1 - FEdM.TopLine) * H + 1,
      K + GutterBtnWidth, (Span + 1 - FEdM.TopLine) * H + H - 1);
  end;
end;

{ The row of a conflict's first line in the result (a conflict with no lines: the row after
  the line above it), or -1. }
function TReviewPage.SpanRow(ASpan: Integer): Integer;
var
  I, N, Line : Integer;
  After : Boolean;
begin
  Result := -1;
  Line := FSpans[ASpan].Start;
  After := FSpans[ASpan].Len = 0;
  if After then Dec(Line);
  if Line < 0 then Exit(0);
  N := -1;
  for I := 0 to High(FRows.MK) do
    if FRows.MK[I] <> rkFiller then
    begin
      Inc(N);
      if N = Line then
      begin
        if After then Exit(I + 1);
        Exit(I);
      end;
    end;
end;

{ The conflict goes back to the common lines and its changes are offered again.  Text
  typed over it is lost, so that is asked first. }
procedure TReviewPage.DecideAgain(ASpan: Integer);
var
  Side, K : Integer;
  Hunks : TDiffHunks;
  Idx : Integer;
begin
  if FEditing or (ASpan < 0) or (ASpan > High(FSpans)) then Exit;
  if FSpans[ASpan].Settled and not (FSpans[ASpan].Done[0] or FSpans[ASpan].Done[1]) and
     (MessageDlg('Decide this conflict again? The lines you typed there are replaced by ' +
                 'the common lines.', mtConfirmation, [mbYes, mbNo], 0) <> mrYes) then Exit;
  ResetConflict(FSpans, ASpan, FResult);
  { the changes of this conflict were marked "keep" by their text: forget those marks }
  for Side := 0 to 1 do
  begin
    if Side = 0 then Hunks := DiffLines(FResult, FEditor)
    else Hunks := DiffLines(FResult, FTheirs);
    for K := 0 to High(Hunks) do
      if SpanOfHunk(FSpans, Hunks[K].AStart, Hunks[K].ALen) = ASpan then
      begin
        Idx := FIgnored.IndexOf(HunkKey(Side, Hunks[K]));
        while Idx >= 0 do
        begin
          FIgnored.Delete(Idx);
          Idx := FIgnored.IndexOf(HunkKey(Side, Hunks[K]));
        end;
      end;
  end;
  Rebuild;
end;

{ The font the symbols of the gutter come from, and whether this machine has it. }
function SymbolFont: string;
begin
  {$IFDEF MSWINDOWS}
  Result := 'Segoe UI Symbol';
  {$ELSE}
  Result := 'DejaVu Sans';
  {$ENDIF}
end;

function HasSymbols: Boolean;
begin
  Result := Screen.Fonts.IndexOf(SymbolFont) >= 0;
end;

var
  GInkCache : TStringList = nil;

{ Where the ink of a glyph is, relative to the point it is drawn at: the middle of what
  shows, not of the text cell around it (a symbol sits high or low and to one side in its
  cell, which is why centring the cell looks off).  Measured once per glyph and size by
  drawing it in a small bitmap and looking for the pixels. }
procedure GlyphInkCentre(AFont: TFont; const AGlyph: string; out ADX, ADY: Integer);
const
  Pad = 12;
var
  Key, Hit : string;
  Bmp : TBitmap;
  X, Y, MinX, MaxX, MinY, MaxY : Integer;
begin
  if GInkCache = nil then GInkCache := TStringList.Create;
  Key := AFont.Name + '|' + IntToStr(AFont.Size) + '|' + AGlyph;
  Hit := GInkCache.Values[Key];
  if Hit <> '' then
  begin
    ADX := StrToIntDef(Copy(Hit, 1, Pos(',', Hit) - 1), 0);
    ADY := StrToIntDef(Copy(Hit, Pos(',', Hit) + 1, MaxInt), 0);
    Exit;
  end;
  ADX := 0;
  ADY := 0;
  Bmp := TBitmap.Create;
  try
    Bmp.SetSize(96, 96);
    Bmp.Canvas.Brush.Color := clWhite;
    Bmp.Canvas.FillRect(0, 0, 96, 96);
    Bmp.Canvas.Font.Assign(AFont);
    Bmp.Canvas.Font.Color := clBlack;
    Bmp.Canvas.Brush.Style := bsClear;
    Bmp.Canvas.TextOut(Pad, Pad, AGlyph);
    MinX := 96; MaxX := -1; MinY := 96; MaxY := -1;
    for Y := 0 to 95 do
      for X := 0 to 95 do
        if Bmp.Canvas.Pixels[X, Y] <> clWhite then
        begin
          if X < MinX then MinX := X;
          if X > MaxX then MaxX := X;
          if Y < MinY then MinY := Y;
          if Y > MaxY then MaxY := Y;
        end;
    if MaxX >= MinX then
    begin
      ADX := (MinX + MaxX + 1) div 2 - Pad;
      ADY := (MinY + MaxY + 1) div 2 - Pad;
    end;
  finally
    Bmp.Free;
  end;
  GInkCache.Values[Key] := IntToStr(ADX) + ',' + IntToStr(ADY);
end;

procedure TReviewPage.GutterPaint(ASide: Integer; C: TCanvas; AWidth, AHeight: Integer);
var
  Ctl  : TGutterCtl;
  Hunk : TDiffHunk;
  Back, Tone : TColor;
  Glyph : string;
  CX, CY, TW, TH : Integer;
begin
  Back := FEdM.Color;
  C.Brush.Color := Back;
  C.FillRect(0, 0, AWidth, AHeight);
  C.Font.Assign(FEdM.Font);
  for Ctl in GutterControls(ASide) do
  begin
    if (Ctl.Rect.Bottom < 0) or (Ctl.Rect.Top > AHeight) then Continue;
    if Ctl.Act = gaReset then
      Tone := RGBToColor(128, 128, 128)                             { not about one change }
    else
    begin
      if ASide = 0 then Hunk := FRows.LeftHunks[Ctl.Hunk] else Hunk := FRows.RightHunks[Ctl.Hunk];
      if Hunk.ALen = 0 then Tone := RGBToColor(60, 180, 90)          { lines added }
      else if Hunk.BLen = 0 then Tone := RGBToColor(215, 80, 80)      { lines deleted }
      else Tone := RGBToColor(70, 130, 220);                          { lines changed }
    end;
    C.Brush.Color := BlendColor(Back, Tone, 35);
    C.Pen.Color := BlendColor(Back, Tone, 70);
    C.RoundRect(Ctl.Rect.Left, Ctl.Rect.Top, Ctl.Rect.Right, Ctl.Rect.Bottom, 4, 4);
    C.Font.Color := FEdM.Font.Color;
    CX := (Ctl.Rect.Left + Ctl.Rect.Right) div 2;
    CY := (Ctl.Rect.Top + Ctl.Rect.Bottom) div 2;
    { "put below" and "again" are symbols: a font that has them draws them, and a machine
      without one gets a letter }
    C.Font.Name := FEdM.Font.Name;
    C.Font.Style := [];
    case Ctl.Act of
      gaDrop:
        if HasSymbols then
        begin
          C.Font.Name := SymbolFont;
          Glyph := UnicodeToUTF8($2716);                       { a heavy cross; DejaVu Sans
                                                                  draws no U+274C }
        end
        else
          Glyph := 'X';
      gaTake:
        if HasSymbols then
        begin
          C.Font.Name := SymbolFont;
          if ASide = 0 then Glyph := UnicodeToUTF8($27A1)      { arrow towards the result }
          else Glyph := UnicodeToUTF8($2B05);
        end
        else if ASide = 0 then Glyph := '>>'
        else Glyph := '<<';
      gaBeside:
      begin
        if HasSymbols then
        begin
          C.Font.Name := SymbolFont;
          if ASide = 0 then Glyph := UnicodeToUTF8($2B0A)      { arrow down and right }
          else Glyph := UnicodeToUTF8($2B0B);                  { down and left }
        end
        else
          Glyph := 'v';
      end;
    else
      if HasSymbols then
      begin
        C.Font.Name := SymbolFont;
        Glyph := UnicodeToUTF8($21BA);                         { anticlockwise open circle arrow }
      end
      else
        Glyph := 'r';
    end;
    { symbols are small for their size: a few points more than the text }
    if C.Font.Name = SymbolFont then
    begin
      TW := FEdM.Font.Size;
      if TW <= 0 then TW := 10;
      { the cross is a big glyph, the arrows are small ones }
      case Ctl.Act of
        gaDrop:  C.Font.Size := TW;
        gaReset:
        begin
          C.Font.Size := TW + 2;             { tall glyph: more would leave the button }
          C.Font.Style := [fsBold];
        end;
      else
        C.Font.Size := TW + 4;               { the arrows are flat }
      end;
    end;
    GlyphInkCentre(C.Font, Glyph, TW, TH);
    C.Brush.Style := bsClear;               { the glyph's cell is taller than the button }
    C.TextOut(CX - TW, CY - TH, Glyph);     { the middle of the ink on the button's middle }
    C.Brush.Style := bsSolid;
  end;
end;

{ a mouse event: the LCL fixes the signature, Sender and Shift are not needed }
{$PUSH}{$WARN 5024 OFF}
procedure TReviewPage.GutterMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  Ctl  : TGutterCtl;
  Side : Integer;
  Tip  : string;
begin
  if not FConflictMode then Exit;
  Side := TPaintBox(Sender).Tag;
  Tip := '';
  for Ctl in GutterControls(Side) do
    if PtInRect(Ctl.Rect, Point(X, Y)) then
    begin
      case Ctl.Act of
        gaDrop:   Tip := 'Drop this change: the result keeps what it has';
        gaTake:   Tip := 'Take this change: these lines go into the result';
        gaBeside: Tip := 'Put these lines below the ones in the result: both stay';
        gaReset:  Tip := 'Decide again: back to the common lines, both changes offered';
      end;
      Break;
    end;
  if Tip <> TPaintBox(Sender).Hint then
  begin
    TPaintBox(Sender).Hint := Tip;
    Application.CancelHint;
  end;
end;
{$POP}

{ The side's lines of one change go below the result's lines there, which stay.  What the
  change is part of counts as decided. }
procedure TReviewPage.TakeBeside(ASide, AHunk: Integer);
var
  Hunk : TDiffHunk;
  Side, Fresh : TDiffLines;
  Joined : TDiffLines = nil;
  At, I, N, Span : Integer;
begin
  if FEditing then Exit;
  if ASide = 0 then
  begin
    Hunk := FRows.LeftHunks[AHunk];
    Side := FEditor;
  end
  else
  begin
    Hunk := FRows.RightHunks[AHunk];
    Side := FTheirs;
  end;
  Fresh := Slice(Side, Hunk.BStart, Hunk.BLen);
  At := Hunk.AStart + Hunk.ALen;
  SetLength(Joined, Length(FResult) + Length(Fresh));
  N := 0;
  for I := 0 to At - 1 do
  begin
    Joined[N] := FResult[I];
    Inc(N);
  end;
  for I := 0 to High(Fresh) do
  begin
    Joined[N] := Fresh[I];
    Inc(N);
  end;
  for I := At to High(FResult) do
  begin
    Joined[N] := FResult[I];
    Inc(N);
  end;
  Span := HunkSpan(ASide, AHunk);
  MoveSpans(At, 0, Length(Fresh), True, True);
  MarkDone(Span, ASide, True);
  FResult := Joined;
  Rebuild;
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
    { a git conflict: what a side has dealt with is no longer marked }
    if FConflictMode and not (RowLive(0, I) or RowLive(1, I)) then Continue;
    if (FRows.LK[I] = rkChanged) and (not FConflictMode or RowLive(0, I)) then
    begin
      DifferingSpan(FRows.M[I], FRows.L[I], MF, MT, OF_, OT);
      if OT > OF_ then FWordL.SetRange(I + 1, OF_, OT);
      if MT > MF then FWordM.SetRange(I + 1, MF, MT);
    end;
    if (FRows.RK[I] = rkChanged) and (not FConflictMode or RowLive(1, I)) then
    begin
      DifferingSpan(FRows.M[I], FRows.R[I], MF, MT, OF_, OT);
      if OT > OF_ then FWordR.SetRange(I + 1, OF_, OT);
      if MT > MF then FWordM.SetRange(I + 1, MF, MT);   { the disk's difference wins }
    end;
  end;
end;

{ The tints of a git conflict, by what a change would do to the result.  A side's lines the
  result lacks are an addition: pale green, and the result's empty slot where they would go
  is pale green too (LineMarkup draws its line).  Lines the result has and a side lacks are a
  deletion: pale red, in both panes.  Different lines on both are pale blue. }
function TReviewPage.TintConflict(AEdit: TSynEdit; ARow: Integer; out ATint: TColor): Boolean;
var
  Back, Green, Red, Blue : TColor;
  Kind : TDiffRowKind;
  Side : Integer;
begin
  Result := True;
  ATint := clNone;
  Back  := AEdit.Color;
  Green := RGBToColor(60, 180, 90);
  Red   := RGBToColor(215, 80, 80);
  Blue  := RGBToColor(70, 130, 220);
  if AEdit = FEdM then
  begin
    if FRows.MK[ARow] = rkFiller then
    begin
      if RowLive(0, ARow) or RowLive(1, ARow) then
        ATint := BlendColor(Back, Green, 30)
      else
        Result := False;
    end
    else if (RowLive(0, ARow) and (FRows.LK[ARow] = rkChanged)) or
            (RowLive(1, ARow) and (FRows.RK[ARow] = rkChanged)) then
      ATint := BlendColor(Back, Blue, 24)
    else if (RowLive(0, ARow) and (FRows.LK[ARow] = rkFiller)) or
            (RowLive(1, ARow) and (FRows.RK[ARow] = rkFiller)) then
      ATint := BlendColor(Back, Red, 26)
    else
      Result := False;         { what the automatic merge took is no conflict: no colour }
    Exit;
  end;
  if AEdit = FEdL then
  begin
    Side := 0;
    Kind := FRows.LK[ARow];
  end
  else
  begin
    Side := 1;
    Kind := FRows.RK[ARow];
  end;
  { a side's change that has been dealt with is no longer coloured; the grey of a row only
    the other side has lines for stays }
  if (Kind <> rkFiller) and not RowLive(Side, ARow) then Exit(False);
  case Kind of
    rkAdded:   ATint := BlendColor(Back, Green, 30);
    rkChanged: ATint := BlendColor(Back, Blue, 24);
    rkFiller:
      if FRows.MK[ARow] = rkFiller then
        ATint := BlendColor(Back, RGBToColor(128, 128, 128), 14)
      else
        Result := False;     { the result has lines, this side none: a red line marks the spot }
  else
    Result := False;
  end;
end;

{ Is row ARow covered by a change of side ASide that has not been dealt with? }
function TReviewPage.RowLive(ASide, ARow: Integer): Boolean;
begin
  Result := (ARow >= 0) and (ARow < Length(FLive[ASide])) and FLive[ASide][ARow];
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
  if FConflictMode then Exit(TintConflict(AEdit, ARow, ATint));
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

{ A row where a change of a git conflict would put lines, or take them away: in the result
  an empty slot a side's lines would fill (green), in a side pane the empty rows facing lines
  the result has and the side lacks (red). }
function TReviewPage.PlaceRow(AEdit: TSynEdit; ARow: Integer; out AColor: TColor): Boolean;
var
  Side : Integer;
begin
  Result := False;
  if (ARow < 0) or (ARow >= Length(FRows.M)) then Exit;
  if AEdit = FEdM then
  begin
    AColor := RGBToColor(60, 180, 90);
    Result := (FRows.MK[ARow] = rkFiller) and (RowLive(0, ARow) or RowLive(1, ARow));
  end
  else
  begin
    AColor := RGBToColor(215, 80, 80);
    if AEdit = FEdL then Side := 0 else Side := 1;
    if Side = 0 then Result := FRows.LK[ARow] = rkFiller
    else Result := FRows.RK[ARow] = rkFiller;
    Result := Result and (FRows.MK[ARow] <> rkFiller) and RowLive(Side, ARow);
  end;
end;

{ The line that shows the place to be: where the hunk would sit, which is the top of its
  first row, so under the row above it (SynEdit draws no top edge).  A hunk on the first row
  has no row above: the line goes under it. }
function TReviewPage.LineBelow(AEdit: TSynEdit; ARow: Integer; out AColor: TColor): Boolean;
var
  Dummy : TColor;
begin
  Result := False;
  if not FConflictMode then Exit;
  if PlaceRow(AEdit, ARow + 1, AColor) and not PlaceRow(AEdit, ARow, Dummy) then
    Exit(True);
  Result := (ARow = 0) and PlaceRow(AEdit, 0, AColor);
end;

procedure TReviewPage.LineMarkup(Sender: TObject; Line: Integer; var Special: Boolean;
  Markup: TSynSelectedColor);
var
  C, LineColor: TColor;
  Tinted, Lined: Boolean;
begin
  if (Line < 1) or (Line > Length(FRows.M)) then Exit;
  Tinted := Tint(TSynEdit(Sender), Line - 1, C);
  Lined  := LineBelow(TSynEdit(Sender), Line - 1, LineColor);
  if Tinted or Lined then
  begin
    Special := True;
    if Tinted then Markup.Background := C else Markup.Background := clNone;
    Markup.Foreground := clNone;
    { the markup object is shared by all lines, so every line says what its frame is }
    if Lined then
    begin
      Markup.FrameColor := LineColor;
      Markup.FrameStyle := slsSolid;
      Markup.FrameEdges := sfeBottom;
    end
    else
      Markup.FrameEdges := sfeNone;
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
  Row : Integer;
  Side   : Integer;
  R: TRect;
  C: TCanvas;
  TW, TH: Integer;
  Rows: TDiffRowArray;
  Sign: string;
begin
  Side := TPaintBox(Sender).Tag;
  C := TPaintBox(Sender).Canvas;
  if FConflictMode then
  begin
    GutterPaint(Side, C, TPaintBox(Sender).Width, TPaintBox(Sender).Height);
    Exit;
  end;
  C.Brush.Color := FEdM.Color;
  C.FillRect(0, 0, TPaintBox(Sender).Width, TPaintBox(Sender).Height);
  if FEditing then Exit;
  C.Font.Assign(FEdM.Font);
  Rows := StripRows(Side);
  if Side = 0 then Sign := '>>' else Sign := '<<';   { pulls the side's text into the result }
  for Row in Rows do
  begin
    R := ArrowRect(Row);
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

{ a mouse event: the LCL fixes the signature, Sender and Shift are not needed }
{$PUSH}{$WARN 5024 OFF}
procedure TReviewPage.StripMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  I, Side: Integer;
  Rows: TDiffRowArray;
  Ctl : TGutterCtl;
begin
  if (not (Button in [mbLeft, mbRight])) or FEditing then Exit;
  Side := TPaintBox(Sender).Tag;
  if FConflictMode then
  begin
    if Button <> mbLeft then Exit;
    for Ctl in GutterControls(Side) do
      if PtInRect(Ctl.Rect, Point(X, Y)) then
      begin
        case Ctl.Act of
          gaDrop:   IgnoreHunk(Side, Ctl.Hunk);
          gaTake:   TakeHunk(Side, Ctl.Hunk);
          gaBeside: TakeBeside(Side, Ctl.Hunk);
          gaReset:  DecideAgain(Ctl.Hunk);
        end;
        Exit;
      end;
    Exit;
  end;
  Rows := StripRows(Side);
  for I := 0 to High(Rows) do
    if PtInRect(ArrowRect(Rows[I]), Point(X, Y)) then
    begin
      if Button = mbLeft then TakeHunk(Side, I) else IgnoreHunk(Side, I);   { right: keep the result }
      Exit;
    end;
end;
{$POP}

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
var
  Hunk : TDiffHunk;
  Span : Integer;
begin
  if ASide = 0 then Hunk := FRows.LeftHunks[AHunk] else Hunk := FRows.RightHunks[AHunk];
  FIgnored.Add(HunkKey(ASide, Hunk));
  { keeping the result's lines is a decision about the conflict they are in }
  if FConflictMode then
  begin
    Span := HunkSpan(ASide, AHunk);
    MoveSpans(Hunk.AStart, Hunk.ALen, Hunk.ALen, True, True);
    MarkDone(Span, ASide, False);
  end;
  Rebuild;
end;

{ Explain: a prompt with the differences between the result and the disk, on the
  clipboard, for the user to paste into the assistant. }
{ a button click: the LCL fixes the signature, Sender is not needed }
{$PUSH}{$WARN 5024 OFF}
procedure TReviewPage.ExplainClick(Sender: TObject);
var
  Hunk : TDiffHunk;
  S: string;
  J   : Integer;
  H: TDiffHunks;
begin
  if FEditing then ReadWorkingCopy;
  H := DiffLines(FResult, FTheirs);
  S := 'The file ' + FFile + ' was changed on disk while the IDE held unsaved edits in it.' +
    LineEnding + 'Below, "-" lines are in the current result (the editor text with the merge so far) ' +
    'and "+" lines are on disk. ' +
    'Please explain what each change does, whether they conflict, and which to keep.' +
    LineEnding + LineEnding + '```diff' + LineEnding;
  for Hunk in H do
  begin
    S := S + Format('@@ result line %d, disk line %d @@', [Hunk.AStart + 1, Hunk.BStart + 1]) +
      LineEnding;
    for J := 0 to Hunk.ALen - 1 do S := S + '-' + FResult[Hunk.AStart + J] + LineEnding;
    for J := 0 to Hunk.BLen - 1 do S := S + '+' + FTheirs[Hunk.BStart + J] + LineEnding;
  end;
  S := S + '```' + LineEnding;
  Clipboard.AsText := S;
  ShowMessage('The prompt is on the clipboard: paste it into your assistant.');
end;
{$POP}

{ ── Changing the result ──────────────────────────────────────────────────── }

{ The side's version of one change goes into the result. }
procedure TReviewPage.TakeHunk(ASide, AHunk: Integer);
var
  Take: array of Boolean = nil;
  I, Span : Integer;
begin
  if ASide = 0 then SetLength(Take, Length(FRows.LeftHunks))
  else SetLength(Take, Length(FRows.RightHunks));
  for I := 0 to High(Take) do Take[I] := I = AHunk;
  if FConflictMode then
  begin
    Span := HunkSpan(ASide, AHunk);
    if ASide = 0 then
      with FRows.LeftHunks[AHunk] do MoveSpans(AStart, ALen, BLen, True, True)
    else
      with FRows.RightHunks[AHunk] do MoveSpans(AStart, ALen, BLen, True, True);
    MarkDone(Span, ASide, True);
  end;
  if ASide = 0 then FResult := ApplyHunks(FResult, FEditor, FRows.LeftHunks, Take)
  else FResult := ApplyHunks(FResult, FTheirs, FRows.RightHunks, Take);
  Rebuild;
end;

procedure TReviewPage.ReadWorkingCopy;
begin
  FResult := LinesOf(FEdM.Lines.Text);
end;

{ a button click: the LCL fixes the signature, Sender is not needed }
{$PUSH}{$WARN 5024 OFF}
procedure TReviewPage.ToggleEdit(Sender: TObject);
var
  Hunks : TDiffHunks;
  I     : Integer;
begin
  if FEditing then
  begin
    ReadWorkingCopy;                    { back to the aligned view of what was typed }
    if FConflictMode then
    begin
      { what was typed over a conflict's lines settles it, whatever it says: a third version
        is as good a decision as either side.  Last change first: the places of the ones
        before it do not move. }
      Hunks := DiffLines(FBeforeEdit, FResult);
      for I := High(Hunks) downto 0 do
        MoveSpans(Hunks[I].AStart, Hunks[I].ALen, Hunks[I].BLen, True, False);
    end;
  end
  else
    FBeforeEdit := Copy(FResult, 0, Length(FResult));
  FEditing := not FEditing;
  Rebuild;
end;
{$POP}

procedure TReviewPage.GoToChange(ADirection: Integer);
var
  NavRow : Integer;
  I, Row, Cur: Integer;
begin
  if Length(FNav) = 0 then Exit;
  Cur := FEdM.TopLine - 1;
  Row := -1;
  if ADirection > 0 then
  begin
    for NavRow in FNav do
      if NavRow > Cur + 1 then
      begin
        Row := NavRow;
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
  Dec(Row, 2);                           { a little context above }
  if Row < 0 then Row := 0;
  FEdM.TopLine := Row + 1;
end;

{ button clicks: the LCL fixes the signature, Sender is not needed }
{$PUSH}{$WARN 5024 OFF}
procedure TReviewPage.PrevChange(Sender: TObject);
begin
  GoToChange(-1);
end;

procedure TReviewPage.NextChange(Sender: TObject);
begin
  GoToChange(1);
end;
{$POP}

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

{ button clicks: the LCL fixes the signature, Sender is not needed }
{$PUSH}{$WARN 5024 OFF}
procedure TReviewPage.ApplyClick(Sender: TObject);
begin
  Apply;
end;

procedure TReviewPage.DiscardClick(Sender: TObject);
begin
  Keep(True);
end;
{$POP}

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
  if FFinished or (ApplyBlocker <> '') then Exit;
  Finish(True);
end;

procedure TReviewPage.Keep(AAsk: Boolean);
begin
  if FFinished then Exit;
  if AAsk and (not FConflictMode) and Changed and (MessageDlg('Keep the editor as it is? The changes made in this ' +
                                      'window are lost, and the editor keeps its own text.',
                                      mtConfirmation, [mbYes, mbNo], 0) <> mrYes) then Exit;
  Finish(False);
end;

function TReviewPage.GetDifferences: Integer;
begin
  Result := Length(FRows.RightHunks);
end;

{ What the tree says after the file's name. }
function TReviewPage.TreeNote: string;
begin
  if FConflictMode then
    if Unsettled = 0 then
      Result := 'ready to resolve'
    else
      Result := IntToStr(Unsettled) + ' to decide'
  else if Differences = 0 then
    Result := 'identical'
  else
    Result := IntToStr(Differences) + ' to review';
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
  FAllApplyBtn := Btn;
  Btn := TButton.Create(Self);
  Btn.Parent := Bottom;
  Btn.SetBounds(148, 5, 110, 26);
  Btn.Caption := 'Keep all mine';
  Btn.Hint := 'Leave every editor as it is';
  Btn.ShowHint := True;
  Btn.OnClick := @KeepAllClick;
  FAllKeepBtn := Btn;

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
  Ptr : Pointer;
begin
  Result := nil;
  for Ptr in FPages do
    if CompareFilenames(TReviewPage(Ptr).FileName, AFile) = 0 then
      Exit(TReviewPage(Ptr));
end;

function TReviewWindow.Pending: Integer;
var
  Ptr : Pointer;
begin
  Result := 0;
  for Ptr in FPages do
    if not TReviewPage(Ptr).Finished then Inc(Result);
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
  else
    Result := '  [' + APage.TreeNote + ']';
end;

procedure TReviewWindow.RefreshTree;
var
  Ptr : Pointer;
  J   : Integer;
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
    for Ptr in FPages do
    begin
      Page := TReviewPage(Ptr);
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
  if APage <> nil then
  begin
    APage.Visible := True;
    WordAllButtons(APage.ConflictMode);
  end;
  RefreshTree;
end;

{ A merge conflict has nothing "clean" to apply and no editor text to keep: the two buttons
  then resolve every file that is decided, or leave every file as git left it. }
procedure TReviewWindow.WordAllButtons(AConflict: Boolean);
begin
  if AConflict then
  begin
    FAllApplyBtn.Caption := 'Resolve all decided';
    FAllApplyBtn.Hint := 'Write and stage every file whose conflicts are all decided';
    FAllKeepBtn.Caption := 'Leave all unresolved';
    FAllKeepBtn.Hint := 'Leave every file as git left it, conflicts and all';
  end
  else
  begin
    FAllApplyBtn.Caption := 'Apply all clean';
    FAllApplyBtn.Hint := 'Apply every file whose merge has no conflicts';
    FAllKeepBtn.Caption := 'Keep all mine';
    FAllKeepBtn.Hint := 'Leave every editor as it is';
  end;
end;

{ tree events: the LCL fixes the signatures, Sender, State and DefaultDraw are not needed }
{$PUSH}{$WARN 5024 OFF}
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
{$POP}

procedure TReviewWindow.PageChanged(Sender: TObject);
begin
  if (Sender = FCurrent) and TReviewPage(Sender).Finished and (NextPending <> nil) then
    ShowPage(NextPending)               { on to the next file waiting }
  else
    RefreshTree;
end;

{ event handlers: the LCL fixes the signatures, Sender is not needed }
{$PUSH}{$WARN 5024 OFF}
procedure TReviewWindow.ApplyCleanClick(Sender: TObject);
var
  Ptr : Pointer;
  P: TReviewPage;
begin
  for Ptr in FPages do
  begin
    P := TReviewPage(Ptr);
    if P.Finished then Continue;
    { a conflict page answers for itself: Apply does nothing while a conflict is undecided }
    if P.ConflictMode or (P.Conflicts = 0) then P.Apply;
  end;
end;

procedure TReviewWindow.KeepAllClick(Sender: TObject);
var
  Ptr : Pointer;
begin
  if (FCurrent <> nil) and FCurrent.ConflictMode then
  begin
    if (Pending > 0) and (MessageDlg('Leave all ' + IntToStr(Pending) + ' file(s) waiting ' +
                                     'unresolved? Git keeps them as conflicts; nothing is written.',
                                     mtConfirmation, [mbYes, mbNo], 0) <> mrYes) then Exit;
  end
  else if (Pending > 0) and (MessageDlg('Keep the editor text of all ' + IntToStr(Pending) +
                                   ' file(s) waiting? Nothing from the disk is taken.',
                                   mtConfirmation, [mbYes, mbNo], 0) <> mrYes) then Exit;
  for Ptr in FPages do TReviewPage(Ptr).Keep(False);
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
{$POP}

function TReviewWindow.Add(const AFile, ALeftTitle, ARightTitle: string;
  const Mine, Theirs, Base: TDiffLines; AHasBase: Boolean;
  ADone: TReviewDone; AConflict: Boolean): TReviewPage;
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
    Base, AHasBase, ADone, AConflict);
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

{ the IDE's form creator: the signature is fixed, Sender is not needed }
{$PUSH}{$WARN 5024 OFF}
procedure CreateReviewForm(Sender: TObject; aFormName: string;
  var AForm: TCustomForm; DoDisableAutoSizing: boolean);
begin
  if CompareText(aFormName, REVIEW_FORM_ID) <> 0 then Exit;
  IDEWindowCreators.CreateForm(AForm, TReviewWindow, DoDisableAutoSizing, Application);
  AForm.Name := aFormName;
  GWindow := TReviewWindow(AForm);
end;
{$POP}

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
  const Mine, Theirs, Base: TDiffLines; AHasBase: Boolean; ADone: TReviewDone;
  AConflict: Boolean);
var
  W: TReviewWindow;
  Registered: Boolean;
begin
  W := ReviewWindow(Registered);
  W.Add(AFile, ALeftTitle, ARightTitle, Mine, Theirs, Base, AHasBase, ADone, AConflict);
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

finalization
  GInkCache.Free;

end.
