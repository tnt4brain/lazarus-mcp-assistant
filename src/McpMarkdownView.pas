{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpMarkdownView;

{ The window of ide_show_markdown (ADR-024): one modeless form with a tab per document,
  each a TIpHtmlPanel.  Display only: nothing goes back to the model, nothing is saved.
  Main thread only.

  IPro raises a modal error box for an img that has no handler, or whose handler raises
  (ADR-011 forbids modals), and blanks the page when the handler answers nil.  So the image
  handler answers every request with a picture, a placeholder when it has to. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Graphics;

const
  MCP_MD_MAX_TABS = 8;

{ Show a document: in the tab ATab when there is one, else in a new tab (the oldest tab is
  dropped past MCP_MD_MAX_TABS).  ABaseDir resolves relative image paths.  The window is shown
  without taking the focus. }
function McpMarkdownShow(const AMarkdown, ATitle, ATab, ABaseDir: string;
  out ATabId, AError: string): Boolean;

{ Show a Markdown file (the user's View command): a tab per file, so opening it again
  refreshes that tab.  AText <> '' is used instead of the file's content (an editor buffer
  with unsaved changes). }
function McpMarkdownOpenFile(const AFile, AText: string; out AError: string): Boolean;

{ The user's "View Markdown" commands: the active source editor when it holds a Markdown file,
  else a file dialog.  Errors are shown in the IDE's message line, never as a modal box. }
procedure McpMarkdownViewActive(Sender: TObject);
procedure McpMarkdownPickFile(Sender: TObject);

{ Make the window known to the IDE's window layout, so that with the docking layout the user
  can dock it beside the source editor, and the IDE remembers where it was.  Called from the
  package's Register. }
procedure RegisterMarkdownWindow;

{ The picture of an img of a rendered document: a local file (relative to ABaseDir) or an
  "mcp-img:N" of AImages ('type:base64').  Checks type, size and the pixel count; nil with the
  reason in AWhy when it is not shown.  The caller frees the picture. }
function McpLoadMarkdownPicture(const AUrl, ABaseDir: string; AImages: TStrings;
  out AWhy: string): TPicture;

implementation

uses
  Forms, Controls, ComCtrls, IpHtml, IpHtmlNodes, IpFileBroker,
  LCLIntf, LazFileUtils, base64, IDEWindowIntf, Dialogs, SrcEditorIntf, IDEMsgIntf, IDEExternToolIntf,
  McpMarkdown, McpImageInfo, McpMessages;

const
  MD_FORM_ID = 'McpMarkdownFormID';

type
  { One document: its panel, its images, the handlers of its panel }
  TMdTab = class(TTabSheet)
  private
    FPanel   : TIpHtmlPanel;
    FProv    : TIpHtmlDataProvider;
    FImages  : TStringList;     { 'type:base64', the index is the N of mcp-img:N }
    FBaseDir : string;
    FId      : string;
    FFile    : string;     { the file this tab shows ('' = a document from ide_show_markdown) }
    function  LoadImage(const AUrl: string; out AWhy: string): TPicture;
    procedure GetImage(Sender: TIpHtmlNode; const URL: string; var Picture: TPicture);
    function  CanHandle(Sender: TObject; const URL: string): Boolean;
    procedure HotClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetDocument(const AMarkdown: string);
    property Id: string read FId;
  end;

  TMdForm = class(TForm)
  private
    FPages : TPageControl;
    FLink  : string;       { a relative .md link clicked, opened after the click returns }
    procedure OpenLink(Data: PtrInt);
    procedure CloseTab(Sender: TObject);
    procedure WindowClosed(Sender: TObject; var CloseAction: TCloseAction);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure CloseIfEmpty(Data: PtrInt);
    function FindTab(const AId: string): TMdTab;
    function FindFileTab(const AFile: string): TMdTab;
    function NewTab: TMdTab;
    property Pages: TPageControl read FPages;
  end;

var
  GForm  : TMdForm = nil;
  GCount : Integer = 0;

{ ── The image handler ────────────────────────────────────────────────────── }

function Placeholder(ANode: TIpHtmlNode; const AWhy: string): TPicture;
var
  Alt : string;
  Bmp : TBitmap;
begin
  Alt := '[image]';
  if ANode is TIpHtmlNodeIMG then
    if TIpHtmlNodeIMG(ANode).Alt <> '' then Alt := '[' + TIpHtmlNodeIMG(ANode).Alt + ']';
  Bmp := TBitmap.Create;
  try
    Bmp.Canvas.Font.Size := 9;
    Bmp.SetSize(Bmp.Canvas.TextWidth(Alt) + 8, Bmp.Canvas.TextHeight(Alt) + 6);
    Bmp.Canvas.Brush.Color := $F0F0F0;
    Bmp.Canvas.Pen.Color := clGray;
    Bmp.Canvas.Rectangle(0, 0, Bmp.Width, Bmp.Height);
    Bmp.Canvas.TextOut(4, 3, Alt);
    Result := TPicture.Create;
    Result.Bitmap.Assign(Bmp);
  finally
    Bmp.Free;
  end;
end;

function ReadWholeFile(const AFile: string; out AData: string): Boolean;
var
  S : TFileStream;
begin
  Result := False;
  AData := '';
  S := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
  try
    if S.Size > MCP_IMG_MAX_FILE_BYTES then Exit;
    SetLength(AData, S.Size);
    if S.Size > 0 then S.ReadBuffer(AData[1], S.Size);
    Result := True;
  finally
    S.Free;
  end;
end;

{ The first monospace font among the usual ones that this system has }
function MonospaceFont: string;
const
  Names : array[0..5] of string =
    ('Consolas', 'DejaVu Sans Mono', 'Menlo', 'Liberation Mono', 'Cascadia Mono', 'Courier New');
var
  I : Integer;
begin
  for I := Low(Names) to High(Names) do
    if Screen.Fonts.IndexOf(Names[I]) >= 0 then Exit(Names[I]);
  Result := 'Courier New';
end;

function McpLoadMarkdownPicture(const AUrl, ABaseDir: string; AImages: TStrings;
  out AWhy: string): TPicture;
var
  Data, Declared, Payload, Kind, Path, Ext : string;
  N : Integer;
  Gr : TGraphic;
  Ms : TMemoryStream;
begin
  Result := nil;
  AWhy := '';
  Declared := '';
  Data := '';
  case MdUrlScheme(AUrl) of
    'mcp-img':
      begin
        N := StrToIntDef(Copy(AUrl, 9, 10), -1);
        if (AImages = nil) or (N < 0) or (N >= AImages.Count) then
        begin
          AWhy := 'unknown image';
          Exit;
        end;
        Declared := Copy(AImages[N], 1, Pos(':', AImages[N]) - 1);
        Payload := Copy(AImages[N], Pos(':', AImages[N]) + 1, MaxInt);
        if Length(Payload) > (MCP_IMG_MAX_DATA_BYTES div 3 + 1) * 4 then
        begin
          AWhy := 'picture too large';
          Exit;
        end;
        Data := DecodeStringBase64(Payload, False);
        if Length(Data) > MCP_IMG_MAX_DATA_BYTES then begin AWhy := 'picture too large'; Exit; end;
      end;
    '':
      begin
        Path := AUrl;
        if (Copy(Path, 1, 2) = '\\') or (Copy(Path, 1, 2) = '//') then
        begin
          AWhy := 'network path';
          Exit;
        end;
        Ext := LowerCase(ExtractFileExt(Path));
        if (Ext <> '.png') and (Ext <> '.jpg') and (Ext <> '.jpeg') and (Ext <> '.gif') and
           (Ext <> '.bmp') then
        begin
          AWhy := 'not a picture file';
          Exit;
        end;
        if not FilenameIsAbsolute(Path) then
        begin
          if ABaseDir = '' then begin AWhy := 'no project directory'; Exit; end;
          Path := AppendPathDelim(ABaseDir) + Path;
        end;
        if not FileExists(Path) then begin AWhy := 'file not found'; Exit; end;
        if not ReadWholeFile(Path, Data) then begin AWhy := 'picture too large'; Exit; end;
      end;
  else
    AWhy := 'not a local picture';
    Exit;
  end;
  if not McpImageAcceptable(Data, Declared, Kind, AWhy) then Exit;
  case Kind of
    'png':  Gr := TPortableNetworkGraphic.Create;
    'jpeg': Gr := TJPEGImage.Create;
    'gif':  Gr := TGIFImage.Create;
  else
    Gr := TBitmap.Create;
  end;
  Ms := TMemoryStream.Create;
  try
    Ms.WriteBuffer(Data[1], Length(Data));
    Ms.Position := 0;
    Gr.LoadFromStream(Ms);
    Result := TPicture.Create;
    Result.Assign(Gr);
  finally
    Ms.Free;
    Gr.Free;
  end;
end;

function TMdTab.LoadImage(const AUrl: string; out AWhy: string): TPicture;
begin
  Result := McpLoadMarkdownPicture(AUrl, FBaseDir, FImages, AWhy);
end;

procedure TMdTab.GetImage(Sender: TIpHtmlNode; const URL: string; var Picture: TPicture);
var
  Why : string;
begin
  Picture := nil;
  try
    Picture := LoadImage(URL, Why);
  except
    FreeAndNil(Picture);       { a decoder or file error: a placeholder, no message box }
  end;
  if Picture = nil then
    try
      Picture := Placeholder(Sender, Why);
    except
      Picture := TPicture.Create;
      Picture.Bitmap.SetSize(1, 1);
    end;
end;

function TMdTab.CanHandle(Sender: TObject; const URL: string): Boolean;
begin
  { never fetch anything: the panel scrolls to a "#heading" of this page and that is all;
    http(s) links go to OnHotClick, which opens the system browser }
  Result := (Length(URL) > 1) and (URL[1] = '#');
end;

procedure TMdTab.HotClick(Sender: TObject);
var
  Url, Scheme : string;
  I : Integer;
begin
  if not (Sender is TIpHtmlPanel) then Exit;
  Url := TIpHtmlPanel(Sender).HotURL;
  Scheme := MdUrlScheme(Url);
  if Scheme = '' then
  begin
    { a relative link to another Markdown file opens in this window }
    if (FFile <> '') and (Owner is TMdForm) then
    begin
      I := Pos('#', Url);
      if I > 0 then Url := Copy(Url, 1, I - 1);
      Url := StringReplace(Url, '%20', ' ', [rfReplaceAll]);
      if (Url <> '') and ((LowerCase(ExtractFileExt(Url)) = '.md') or
                          (LowerCase(ExtractFileExt(Url)) = '.markdown')) then
      begin
        TMdForm(Owner).FLink := CleanAndExpandFilename(AppendPathDelim(FBaseDir) + Url);
        Application.QueueAsyncCall(@TMdForm(Owner).OpenLink, 0);
      end;
    end;
    Exit;
  end;
  if (Scheme <> 'http') and (Scheme <> 'https') then Exit;
  for I := 1 to Length(Url) do
    if Url[I] <= ' ' then Exit;
  OpenURL(Url);
end;

constructor TMdTab.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FImages := TStringList.Create;
  FPanel := TIpHtmlPanel.Create(Self);
  FPanel.Parent := Self;
  FPanel.Align := alClient;
  FPanel.ShowHints := True;      { the hint shows the link's target before a click }
  { IPro's own defaults are Times and a letter-spaced Courier: use the UI font, and a real
    monospace font for code }
  FPanel.DefaultTypeFace := Screen.SystemFont.Name;
  FPanel.DefaultFontSize := Screen.SystemFont.Size + 2;
  FPanel.FixedTypeface := MonospaceFont;
  FPanel.FontQuality := fqCleartype;
  { Bootstrap 5: body text #212529, links #0d6efd }
  FPanel.TextColor := RGBToColor(33, 37, 41);
  FPanel.LinkColor := RGBToColor(13, 110, 253);
  FPanel.VLinkColor := RGBToColor(13, 110, 253);
  FPanel.ALinkColor := RGBToColor(10, 88, 202);
  FPanel.MarginWidth := 24;
  FPanel.MarginHeight := 16;
  FPanel.FactBAParag := 1.25;      { Bootstrap's line height of 1.5 }
  FProv := TIpHtmlDataProvider.Create(Self);
  FProv.OnGetImage := @GetImage;
  FProv.OnCanHandle := @CanHandle;
  FPanel.DataProvider := FProv;
  FPanel.OnHotClick := @HotClick;
end;

destructor TMdTab.Destroy;
begin
  FImages.Free;
  inherited Destroy;
end;

procedure TMdTab.SetDocument(const AMarkdown: string);
var
  C : TMarkdownHtml;
  Html : string;
begin
  C := TMarkdownHtml.Create;
  try
    Html := C.ToHtml(AMarkdown, FImages);
  finally
    C.Free;
  end;
  FPanel.SetHtmlFromStr(Html);
end;

{ ── The window ───────────────────────────────────────────────────────────── }

constructor TMdForm.Create(AOwner: TComponent);
var
  R : TRect;
  W, H : Integer;
begin
  inherited CreateNew(AOwner);
  Caption := 'MCP Assistant: document';
  Name := MD_FORM_ID;
  FPages := TPageControl.Create(Self);
  FPages.Parent := Self;
  FPages.Align := alClient;
  FPages.Options := FPages.Options + [nboShowCloseButtons];
  FPages.OnCloseTabClicked := @CloseTab;
  OnClose := @WindowClosed;
  { on the monitor of the IDE's main window, about two thirds of its work area }
  R := Screen.PrimaryMonitor.WorkareaRect;
  if Assigned(Application.MainForm) and Application.MainForm.HandleAllocated then
    R := Screen.MonitorFromWindow(Application.MainForm.Handle).WorkareaRect;
  W := (R.Right - R.Left) * 2 div 3;
  H := (R.Bottom - R.Top) * 3 div 4;
  if W > 1100 then W := 1100;
  if H > 900 then H := 900;
  Position := poDesigned;
  SetBounds(R.Left + (R.Right - R.Left - W) div 2, R.Top + (R.Bottom - R.Top - H) div 2, W, H);
end;

destructor TMdForm.Destroy;
begin
  if GForm = Self then GForm := nil;
  Application.RemoveAsyncCalls(Self);
  inherited Destroy;
end;

{ The IDE re-creates its windows at start when they were open at exit; documents are not
  kept, so a window that comes back empty goes away again. }
procedure TMdForm.CloseIfEmpty(Data: PtrInt);
begin
  if FPages.PageCount = 0 then Close;
end;

function TMdForm.FindTab(const AId: string): TMdTab;
var
  I : Integer;
begin
  Result := nil;
  if AId = '' then Exit;
  for I := 0 to FPages.PageCount - 1 do
    if (FPages.Pages[I] is TMdTab) and (TMdTab(FPages.Pages[I]).Id = AId) then
      Exit(TMdTab(FPages.Pages[I]));
end;

function TMdForm.FindFileTab(const AFile: string): TMdTab;
var
  I : Integer;
begin
  Result := nil;
  for I := 0 to FPages.PageCount - 1 do
    if (FPages.Pages[I] is TMdTab) and (TMdTab(FPages.Pages[I]).FFile <> '') and
       (CompareFilenames(TMdTab(FPages.Pages[I]).FFile, AFile) = 0) then
      Exit(TMdTab(FPages.Pages[I]));
end;

procedure TMdForm.OpenLink(Data: PtrInt);
var
  Err : string;
begin
  if FLink = '' then Exit;
  if not McpMarkdownOpenFile(FLink, '', Err) then
    McpAddMessage(mluImportant, 'Markdown: ' + Err);
  FLink := '';
end;

function TMdForm.NewTab: TMdTab;
begin
  while FPages.PageCount >= MCP_MD_MAX_TABS do
    FPages.Pages[0].Free;                 { the oldest: tabs are added at the end }
  Inc(GCount);
  Result := TMdTab.Create(Self);
  Result.FId := 'md' + IntToStr(GCount);
  Result.PageControl := FPages;
end;

procedure TMdForm.CloseTab(Sender: TObject);
var
  P : TTabSheet;
begin
  P := FPages.ActivePage;
  if P <> nil then P.Free;
  if FPages.PageCount = 0 then Close;
end;

procedure TMdForm.WindowClosed(Sender: TObject; var CloseAction: TCloseAction);
begin
  { Closing discards every document, but the form itself is kept hidden: freeing it makes the
    IDE forget where it was docked, and the next one opens floating. }
  while FPages.PageCount > 0 do FPages.Pages[0].Free;
  CloseAction := caHide;
end;

{ ── Window layout (docking) ──────────────────────────────────────────────── }

procedure CreateMarkdownForm(Sender: TObject; aFormName: string;
  var AForm: TCustomForm; DoDisableAutoSizing: boolean);
begin
  if CompareText(aFormName, MD_FORM_ID) <> 0 then Exit;
  IDEWindowCreators.CreateForm(AForm, TMdForm, DoDisableAutoSizing, Application);
  AForm.Name := aFormName;
  GForm := TMdForm(AForm);
  Application.QueueAsyncCall(@GForm.CloseIfEmpty, 0);
end;

procedure RegisterMarkdownWindow;
begin
  if Assigned(IDEWindowCreators) then
    IDEWindowCreators.Add(MD_FORM_ID, @CreateMarkdownForm, nil, '', '', '', '',
      'SourceNotebook', alRight, False);   { where a new window docks until the user moves it }
end;

{ The IDE's window layout may put a new window on the primary monitor.  A floating window goes
  to the monitor of the IDE's main window; a docked one is part of that window already. }
procedure MoveToIdeMonitor(AForm: TCustomForm);
var
  Host   : TCustomForm;
  Target : TRect;
  W, H   : Integer;
begin
  if not (Assigned(Application.MainForm) and Application.MainForm.HandleAllocated) then Exit;
  Host := GetParentForm(AForm);
  if Host = nil then Host := AForm;
  if Host = Application.MainForm then Exit;
  if Host.Monitor.MonitorNum = Application.MainForm.Monitor.MonitorNum then Exit;
  Target := Application.MainForm.Monitor.WorkareaRect;
  W := Host.Width;
  H := Host.Height;
  if W > Target.Right - Target.Left then W := Target.Right - Target.Left;
  if H > Target.Bottom - Target.Top then H := Target.Bottom - Target.Top;
  Host.SetBounds(Target.Left + (Target.Right - Target.Left - W) div 2,
                 Target.Top + (Target.Bottom - Target.Top - H) div 2, W, H);
end;

function McpMarkdownShow(const AMarkdown, ATitle, ATab, ABaseDir: string;
  out ATabId, AError: string): Boolean;
var
  Tab : TMdTab;
  Title : string;
  Prev : TCustomForm;
  Registered : Boolean;
begin
  Result := False;
  ATabId := '';
  AError := '';
  try
    Registered := Assigned(IDEWindowCreators) and
                  (IDEWindowCreators.FindWithName(MD_FORM_ID) <> nil);
    if GForm = nil then
    begin
      if Registered then IDEWindowCreators.GetForm(MD_FORM_ID, True);   { sets GForm }
      if GForm = nil then GForm := TMdForm.Create(Application);
    end;
    Tab := GForm.FindTab(ATab);
    if Tab = nil then Tab := GForm.NewTab;
    Title := Trim(ATitle);
    if Title = '' then Title := 'Document';
    Tab.Caption := Title;
    Tab.FBaseDir := ABaseDir;
    Tab.SetDocument(AMarkdown);
    GForm.Pages.ActivePage := Tab;
    { shown, not activated: the user keeps typing where they were (ADR-011) }
    if not (GForm.Visible and (GetParentForm(GForm) <> nil) and GetParentForm(GForm).Visible) then
    begin
      { Show activates the form; give the focus back to the IDE form that had it }
      Prev := Screen.ActiveCustomForm;
      if Registered then
        IDEWindowCreators.ShowForm(GForm, False)    { floating or docked, as the layout says }
      else
        GForm.Show;
      MoveToIdeMonitor(GForm);
      if Assigned(Prev) and (Prev <> GForm) and Prev.Visible and Prev.CanFocus then
        Prev.SetFocus;
    end;
    ATabId := Tab.Id;
    Result := True;
  except
    on E: Exception do
      AError := E.ClassName + ': ' + E.Message;
  end;
end;

{ ── The user's commands ──────────────────────────────────────────────────── }

const
  MD_MAX_FILE_BYTES = 8 * 1024 * 1024;

function IsMarkdownName(const AName: string): Boolean;
var
  Ext : string;
begin
  Ext := LowerCase(ExtractFileExt(AName));
  Result := (Ext = '.md') or (Ext = '.markdown') or (Ext = '.mdown');
end;

function McpMarkdownOpenFile(const AFile, AText: string; out AError: string): Boolean;
var
  Text, TabId, Err : string;
  S    : TFileStream;
  Tab  : TMdTab;
  Reuse: string;
begin
  Result := False;
  AError := '';
  Text := AText;
  if Text = '' then
  begin
    if not FileExists(AFile) then begin AError := 'no such file: ' + AFile; Exit; end;
    try
      S := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
      try
        if S.Size > MD_MAX_FILE_BYTES then begin AError := AFile + ' is too large'; Exit; end;
        SetLength(Text, S.Size);
        if S.Size > 0 then S.ReadBuffer(Text[1], S.Size);
      finally
        S.Free;
      end;
    except
      on E: Exception do begin AError := E.Message; Exit; end;
    end;
  end;
  if (Length(Text) >= 3) and (Text[1] = #$EF) and (Text[2] = #$BB) and (Text[3] = #$BF) then
    Delete(Text, 1, 3);
  Reuse := '';
  if Assigned(GForm) then
  begin
    Tab := GForm.FindFileTab(AFile);
    if Assigned(Tab) then Reuse := Tab.Id;
  end;
  if not McpMarkdownShow(Text, ExtractFileName(AFile), Reuse, ExtractFilePath(AFile),
                         TabId, Err) then
  begin
    AError := Err; Exit;
  end;
  if Assigned(GForm) then
  begin
    Tab := GForm.FindTab(TabId);
    if Assigned(Tab) then Tab.FFile := AFile;
  end;
  Result := True;
end;

procedure McpMarkdownViewActive(Sender: TObject);
var
  Ed  : TSourceEditorInterface;
  Err : string;
begin
  Ed := nil;
  if Assigned(SourceEditorManagerIntf) then Ed := SourceEditorManagerIntf.ActiveEditor;
  if Assigned(Ed) and IsMarkdownName(Ed.FileName) then
  begin
    if not McpMarkdownOpenFile(Ed.FileName, Ed.Lines.Text, Err) then
      McpAddMessage(mluImportant, 'Markdown: ' + Err);
  end
  else
    McpMarkdownPickFile(Sender);
end;

procedure McpMarkdownPickFile(Sender: TObject);
var
  Dlg : TOpenDialog;
  Err : string;
begin
  Dlg := TOpenDialog.Create(nil);
  try
    Dlg.Title := 'View Markdown file';
    Dlg.Filter := 'Markdown (*.md;*.markdown)|*.md;*.markdown|All files|*.*';
    Dlg.Options := Dlg.Options + [ofFileMustExist];
    if Dlg.Execute then
      if not McpMarkdownOpenFile(Dlg.FileName, '', Err) then
        McpAddMessage(mluImportant, 'Markdown: ' + Err);
  finally
    Dlg.Free;
  end;
end;

end.
