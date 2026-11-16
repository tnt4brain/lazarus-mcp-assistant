{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpReviewFlow;

{ ADR-025: what happens when the file of an editor WITH unsaved changes changed on disk.

  The base: for an editor that is not modified, its text is the file's text.  The
  reload pass (McpReloadChangedFiles) tells us that text here, as the "base" the
  editor and the disk started from.  When the editor is modified and the file has
  changed since, the review window opens (McpReviewOffer) with mine = the editor,
  theirs = the disk, and that base for the three-way merge.

  "Apply" puts the working copy into the editor as one undo step (never on the disk).
  Any answer marks the disk's version as seen, so the IDE's own dialog stays away,
  and makes it the new base. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SrcEditorIntf;

var
  { One line for the model, set when a review was opened; the tool call that
    finds it appends it to its result. }
  GMcpReviewNotice: string = '';

{ The text of an editor that is not modified: remembered as its base. }
procedure McpReviewNoteBase(const AFile, AText: string);

type
  { What became of a modified editor whose file changed on disk: nothing, the review window
    was opened (ask), the editor kept its text and the disk text went to name.ext.agent, or
    the editor took the disk text (the Review/Policy setting). }
  TReviewOutcome = (roNone, roAsk, roEditorWon, roDiskWon);

{ A modified editor whose file changed on disk.  By the policy setting: opens the review
  window (unless one is open for that file already), or settles it without one.
  AForceAsk (the Tools menu) always opens the window. }
function McpReviewOffer(AEditor: TSourceEditorInterface; const ADiskText: string;
  AForceAsk: Boolean = False): TReviewOutcome;

{ One sentence for the model about the files of one reload pass, appended to
  GMcpReviewNotice (the next tool result carries it). }
procedure McpReviewNotice(AAsk, AKept, ATaken: TStrings);

{ Tools menu: review the active editor against its file on disk, no agent needed. }
procedure McpReviewActiveEditor(Sender: TObject);

{ The base text remembered for a file. }
function McpReviewBase(const AFile: string; out ABase: string): Boolean;

implementation

uses
  Types, LazFileUtils, FileUtil, Forms, Dialogs, ComCtrls, Controls, SynEdit, McpReviewGutter,
  CodeCache, CodeToolManager, McpDiff, McpReviewView, McpReviewPaths, McpMessages, McpIdeState,
  IDEExternToolIntf;

const
  MaxBaseBytes = 1024 * 1024;   { a bigger text has no base: the window shows two ways }

type
  TTextHolder = class
    Text: string;
  end;

  TSession = class
    FileName : string;
    Editor   : TSourceEditorInterface;   { only compared, never used: it may be gone }
    Stamp    : string;              { McpFileStamp of the disk version under review }
    Disk     : string;
  end;

  TFlow = class
    procedure Done(const AFile: string; AApplied: Boolean; const ANewText: string);
    procedure GutterClick(const AFile: string);
    procedure TabCaptionUpdated(Sender: TObject);
    procedure EditorDestroyed(Sender: TObject);
  end;

const
  TabMark = ' (!)';                { on the tab of an editor that waits for its review }

var
  GBases    : TStringList = nil;   { file name -> TTextHolder }
  GSessions : TList = nil;         { of TSession }
  GFlow     : TFlow = nil;
  GDestroyHooked : Boolean = False;
  GHookedWindows : TList = nil;    { the source windows that report tab caption updates to us }

function BaseList: TStringList;
begin
  if GBases = nil then
  begin
    GBases := TStringList.Create;
    GBases.Sorted := True;
    GBases.OwnsObjects := True;
    GBases.CaseSensitive := {$IFDEF WINDOWS}False{$ELSE}True{$ENDIF};
  end;
  Result := GBases;
end;

procedure McpReviewNoteBase(const AFile, AText: string);
var
  I: Integer;
  H: TTextHolder;
begin
  if Length(AText) > MaxBaseBytes then
  begin
    I := BaseList.IndexOf(AFile);
    if I >= 0 then BaseList.Delete(I);
    Exit;
  end;
  I := BaseList.IndexOf(AFile);
  if I >= 0 then
    TTextHolder(BaseList.Objects[I]).Text := AText
  else
  begin
    H := TTextHolder.Create;
    H.Text := AText;
    BaseList.AddObject(AFile, H);
  end;
end;

function McpReviewBase(const AFile: string; out ABase: string): Boolean;
var
  I: Integer;
begin
  ABase := '';
  I := BaseList.IndexOf(AFile);
  Result := I >= 0;
  if Result then ABase := TTextHolder(BaseList.Objects[I]).Text;
end;

function FindSession(const AFile: string): TSession;
var
  Ptr : Pointer;
begin
  Result := nil;
  if GSessions = nil then Exit;
  for Ptr in GSessions do
    if CompareFilenames(TSession(Ptr).FileName, AFile) = 0 then
      Exit(TSession(Ptr));
end;

function LinesOf(const AText: string): TDiffLines;
var
  Dummy: Boolean;
begin
  Result := SplitLines(AText, Dummy);
end;

procedure TFlow.GutterClick(const AFile: string);
begin
  McpReviewFocus(AFile);
end;

{ The tab of an editor: its page, found from the editor control upwards. }
function PageOf(AEditor: TSourceEditorInterface): TCustomPage;
var
  C: TControl;
begin
  Result := nil;
  if AEditor = nil then Exit;
  C := AEditor.EditorControl;
  while (C <> nil) and not (C is TCustomPage) do C := C.Parent;
  if C <> nil then Result := TCustomPage(C);
end;

{ A mark on the tab caption.  The IDE rewrites the caption when it differs from its own
  (a save, a rename); the handler below puts the mark back while the file waits. }
procedure SetTabMark(AEditor: TSourceEditorInterface; AOn: Boolean);
var
  Page : TCustomPage;
  Cap  : string;
  L    : Integer;
begin
  try
    Page := PageOf(AEditor);
    if Page = nil then Exit;
    Cap := Page.Caption;
    L := Length(TabMark);
    if (Length(Cap) >= L) and (Copy(Cap, Length(Cap) - L + 1, L) = TabMark) then
      Cap := Copy(Cap, 1, Length(Cap) - L);
    if AOn then Cap := Cap + TabMark;
    if Page.Caption <> Cap then Page.Caption := Cap;
  except
  end;
end;

procedure TFlow.TabCaptionUpdated(Sender: TObject);
begin
  if (Sender is TSourceEditorInterface) and
     (FindSession(TSourceEditorInterface(Sender).FileName) <> nil) then
    SetTabMark(TSourceEditorInterface(Sender), True);
end;

{ An editor was closed: a review waiting for it has no one to answer to.  Its page leaves
  the window and the remembered base goes (a file reopened later starts afresh). }
procedure TFlow.EditorDestroyed(Sender: TObject);
var
  Ptr : Pointer;
  S    : TSession;
  Name : string;
  I    : Integer;
begin
  { the editor is told apart by identity: when it is released its code buffer is gone
    already, and so is its file name }
  S := nil;
  if GSessions <> nil then
    for Ptr in GSessions do
      if TObject(TSession(Ptr).Editor) = Sender then
        S := TSession(Ptr);
  if S = nil then Exit;
  Name := S.FileName;
  GSessions.Remove(S);
  S.Free;
  McpReviewDrop(Name);
  I := BaseList.IndexOf(Name);
  if I >= 0 then BaseList.Delete(I);
end;

{ The source window of an editor tells us when it rewrites a tab caption. }
procedure HookWindow(AEditor: TSourceEditorInterface);
var
  Win: TSourceEditorWindowInterface;
begin
  if (SourceEditorManagerIntf = nil) or (GFlow = nil) then Exit;
  Win := SourceEditorManagerIntf.SourceWindowWithEditor(AEditor);
  if Win = nil then Exit;
  if GHookedWindows = nil then GHookedWindows := TList.Create;
  if GHookedWindows.IndexOf(Win) >= 0 then Exit;
  GHookedWindows.Add(Win);
  Win.AddUpdateEditorPageCaptionHandler(@GFlow.TabCaptionUpdated);
end;

{ The whole text of an editor replaced, as one undoable step. }
procedure ReplaceWholeText(AEditor: TSourceEditorInterface; const ANewText: string);
var
  N: Integer;
begin
  N := AEditor.LineCount;
  if N = 0 then
    AEditor.ReplaceText(Point(1, 1), Point(1, 1), ANewText)
  else
    AEditor.ReplaceText(Point(1, 1), Point(Length(AEditor.Lines[N - 1]) + 1, N), ANewText);
end;

{ The change bars in the real editor's gutter, while the file waits for its review. }
procedure AttachGutter(AEditor: TSourceEditorInterface; const ADiskText: string);
begin
  if AEditor.EditorControl is TSynEdit then
    McpGutterAttach(TSynEdit(AEditor.EditorControl), AEditor.FileName, LinesOf(ADiskText),
      @GFlow.GutterClick);
end;

procedure DetachGutter(const AFile: string);
var
  Ed: TSourceEditorInterface;
begin
  Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(AFile);
  if (Ed <> nil) and (Ed.EditorControl is TSynEdit) then
    McpGutterDetach(TSynEdit(Ed.EditorControl), AFile);
end;

procedure MarkSeen(const AFile, ADiskText: string); forward;

{ The policy settings other than "ask".  False: nothing was settled, the window must open. }
function SettleByPolicy(AEditor: TSourceEditorInterface; const ADiskText: string;
  out AOutcome: TReviewOutcome): Boolean;
var
  Policy : string;
  Name   : string;
begin
  Result := False;
  AOutcome := roNone;
  Policy := 'ask';
  if McpSettings <> nil then Policy := McpSettings.ReviewPolicy;
  Name := ExtractFileName(AEditor.FileName);
  case Policy of
    'editor':
    begin
      { the editor keeps its text; the disk version is saved beside the file, never over it }
      if not CopyFile(AEditor.FileName, AEditor.FileName + '.agent', [cffOverwriteFile]) then
      begin
        McpAddMessage(mluImportant, 'Review: ' + Name + ' could not be copied to ' + Name +
          '.agent; the review window is opened instead');
        Exit;
      end;
      MarkSeen(AEditor.FileName, ADiskText);
      McpAddMessage(mluProgress, 'Review: ' + Name + ' changed on disk; the editor keeps its text, ' +
        'the disk version is in ' + Name + '.agent');
      AOutcome := roEditorWon;
      Result := True;
    end;
    'disk':
    begin
      ReplaceWholeText(AEditor, ADiskText);
      MarkSeen(AEditor.FileName, ADiskText);
      McpAddMessage(mluProgress, 'Review: ' + Name + ' changed on disk; the editor took the disk ' +
        'text (Ctrl+Z undoes it)');
      AOutcome := roDiskWon;
      Result := True;
    end;
  end;
end;

function McpReviewOffer(AEditor: TSourceEditorInterface; const ADiskText: string;
  AForceAsk: Boolean): TReviewOutcome;
var
  S        : TSession;
  Base     : string;
  HasBase  : Boolean;
  Empty    : TDiffLines;
begin
  Result := roNone;
  if AEditor = nil then Exit;
  if (not AForceAsk) and (FindSession(AEditor.FileName) = nil) and
     SettleByPolicy(AEditor, ADiskText, Result) then Exit;
  if GSessions = nil then GSessions := TList.Create;
  if GFlow = nil then GFlow := TFlow.Create;
  HookWindow(AEditor);
  if (not GDestroyHooked) and (SourceEditorManagerIntf <> nil) then
  begin
    SourceEditorManagerIntf.RegisterChangeEvent(semEditorDestroy, @GFlow.EditorDestroyed);
    GDestroyHooked := True;
  end;
  { the file changed again while it waits in the window: its entry is made anew }
  S := FindSession(AEditor.FileName);
  if S = nil then
  begin
    S := TSession.Create;
    S.FileName := AEditor.FileName;
    GSessions.Add(S);
  end;
  S.Editor := AEditor;
  S.Stamp := McpFileStamp(AEditor.FileName);
  S.Disk := ADiskText;
  HasBase := McpReviewBase(AEditor.FileName, Base);
  Empty := nil;
  if McpProject <> nil then McpReviewRoot := McpProject.GetProjectDirectory;
  if HasBase then
    McpReviewShow(AEditor.FileName, 'Working copy: your unsaved text',
      'On disk now (changed outside the editor)', LinesOf(AEditor.Lines.Text),
      LinesOf(ADiskText), LinesOf(Base), True, @GFlow.Done)
  else
    McpReviewShow(AEditor.FileName, 'Working copy: your unsaved text',
      'On disk now (changed outside the editor)', LinesOf(AEditor.Lines.Text),
      LinesOf(ADiskText), Empty, False, @GFlow.Done);
  AttachGutter(AEditor, ADiskText);
  SetTabMark(AEditor, True);
  McpAddMessage(mluImportant, 'Review: ' + ExtractFileName(AEditor.FileName) +
    ' changed on disk while the editor holds unsaved changes');
  Result := roAsk;
end;

procedure McpReviewNotice(AAsk, AKept, ATaken: TStrings);
var
  S: string;
begin
  S := ReviewNoticeText(AAsk, AKept, ATaken);
  if S = '' then Exit;
  if GMcpReviewNotice <> '' then GMcpReviewNotice := GMcpReviewNotice + ' ';
  GMcpReviewNotice := GMcpReviewNotice + S;
end;

procedure McpReviewActiveEditor(Sender: TObject);
var
  Ed   : TSourceEditorInterface;
  List : TStringList;
begin
  Ed := SourceEditorManagerIntf.ActiveEditor;
  if (Ed = nil) or (Ed.FileName = '') or not FileExists(Ed.FileName) then
  begin
    MessageDlg('Review', 'The active editor has no file on disk to compare with.',
      mtInformation, [mbOK], 0);
    Exit;
  end;
  if FindSession(Ed.FileName) <> nil then
  begin
    McpReviewFocus(Ed.FileName);
    Exit;
  end;
  List := TStringList.Create;
  try
    List.LoadFromFile(Ed.FileName);
    McpReviewOffer(Ed, List.Text, True);
  finally
    List.Free;
  end;
end;

{ The disk's version of the file is the one seen now. }
procedure MarkSeen(const AFile, ADiskText: string);
var
  Buf: TCodeBuffer;
begin
  try
    Buf := CodeToolBoss.FindFile(AFile);
    if Assigned(Buf) then Buf.MakeFileDateValid;
  except
  end;
  McpReviewNoteBase(AFile, ADiskText);
end;

procedure TFlow.Done(const AFile: string; AApplied: Boolean; const ANewText: string);
var
  S  : TSession;
  Ed : TSourceEditorInterface;
begin
  S := FindSession(AFile);
  if S = nil then Exit;
  DetachGutter(AFile);                  { answered: the bars go }
  Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(AFile);
  try
    if AApplied then
    begin
      if Ed = nil then
        McpAddMessage(mluImportant, 'Review: ' + ExtractFileName(AFile) +
          ' is not open in an editor any more; nothing was applied')
      else if McpFileStamp(AFile) <> S.Stamp then
        McpAddMessage(mluImportant, 'Review: ' + ExtractFileName(AFile) +
          ' changed on disk again while it was reviewed; nothing was applied. ' +
          'The next tool call opens the review again')
      else
      begin
        ReplaceWholeText(Ed, ANewText);     { the whole text, as one undoable replacement }
        MarkSeen(AFile, S.Disk);
        McpAddMessage(mluProgress, 'Review: ' + ExtractFileName(AFile) +
          ' updated in the editor (Ctrl+Z undoes it)');
      end;
    end
    else
    begin
      MarkSeen(AFile, S.Disk);
      McpAddMessage(mluProgress, 'Review: ' + ExtractFileName(AFile) +
        ' kept as it is in the editor');
    end;
  finally
    GSessions.Remove(S);
    S.Free;
    { after the session is gone: an edit above made the IDE rewrite the caption, and the
      handler put the mark back while the session still existed }
    if Ed <> nil then SetTabMark(Ed, False);
  end;
end;

finalization
  GBases.Free;
  GSessions.Free;
  { GFlow stays alive and its hooks stay in the source windows: a window may still call it
    while the IDE shuts down }
end.
