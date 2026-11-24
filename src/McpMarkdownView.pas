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
  Classes, SysUtils, Graphics, Forms, LCLVersion;

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
function McpMarkdownOpenFile(const AFile, AText: string; out AError: string): Boolean; overload;
function McpMarkdownOpenFile(const AFile, AText: string; out ATabId, AError: string): Boolean; overload;

{ The user's "View Markdown" commands: the active source editor when it holds a Markdown file,
  else a file dialog.  Errors are shown in the IDE's message line, never as a modal box. }
procedure McpMarkdownViewActive(Sender: TObject);
procedure McpMarkdownPickFile(Sender: TObject);

{ Make the window known to the IDE's window layout, so that with the docking layout the user
  can dock it beside the source editor, and the IDE remembers where it was.  Called from the
  package's Register. }
procedure RegisterMarkdownWindow;

{ A floating window of the plugin goes to the monitor of the IDE's main window (the
  window layout may put a new one on the primary monitor). }
procedure MoveToIdeMonitor(AForm: TCustomForm);

{ The picture of an img of a rendered document: a local file (relative to ABaseDir) or an
  "mcp-img:N" of AImages ('type:base64').  Checks type, size and the pixel count; nil with the
  reason in AWhy when it is not shown.  The caller frees the picture. }
function McpLoadMarkdownPicture(const AUrl, ABaseDir: string; AImages: TStrings;
  out AWhy: string): TPicture;

implementation

uses
  Controls, ComCtrls, ExtCtrls, IpHtml, IpHtmlNodes, IpFileBroker,
  LCLIntf, LazFileUtils, base64, IDEWindowIntf, Dialogs, SrcEditorIntf, IDEExternToolIntf,
  SynEdit, SynHighlighterPas, IDEOptEditorIntf, McpMarkdownHighlight,
  McpMarkdown, McpImageInfo, McpMessages, McpIdeState
  {$IF lcl_fullversion >= 4090000}, EditorOptionsIntf{$ENDIF};

const
  MD_FORM_ID = 'McpMarkdownFormID';
  MD_MAX_FILE_BYTES = 8 * 1024 * 1024;
  MIN_PAGE_SIZE = 40;      { pixels: a smaller tab is a collapsed dock, nothing is laid out in it }

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
    FSource  : string;     { the text last rendered for FFile (LF line ends, no BOM) }
    FStamp   : string;     { age and size of FFile when it was last read from disk }
    FText    : string;     { the Markdown last given to SetDocument, rendered again on a zoom }
    FDeferred   : Boolean;  { SetDocument found no room: FText is rendered once the tab has a size }
    FZoomSteps  : Integer;  { wheel notches (Ctrl) not yet applied }
    FZoomQueued : Boolean;
    procedure ApplyZoom(Data: PtrInt);
    procedure HookWheel(AControl: TWinControl);
    procedure WheelZoom(Sender: TObject; Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint; var Handled: Boolean);
    procedure RestoreScroll(Data: PtrInt);
    procedure ApplyColors;
    function  LoadImage(const AUrl: string; out AWhy: string): TPicture;
    procedure GetImage(Sender: TIpHtmlNode; const URL: string; var Picture: TPicture);
    function  CanHandle(Sender: TObject; const URL: string): Boolean;
    procedure HotClick(Sender: TObject);
  protected
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetDocument(const AMarkdown: string);
    procedure Follow(const AText: string);
    procedure CheckSource;
    function  FileEditor: TSourceEditorInterface;
    property Id: string read FId;
    property FileName: string read FFile;
  end;

  TMdForm = class(TForm)
  private
    FPages : TPageControl;
    FLink  : string;       { a relative .md link clicked, opened after the click returns }
    FTimer    : TTimer;     { slow stat of the files that no editor holds }
    FDebounce : TTimer;     { armed by an editor event, one shot }
    procedure Tick(Sender: TObject);
    procedure Debounced(Sender: TObject);
    procedure EditorStatus(Sender: TObject);
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
  { the editor scheme's colours, as last read (IdeColors); used by what is drawn here }
  GBack   : TColor = clWindow;
  GFore   : TColor = clWindowText;
  GLink   : TColor = clHotLight;
  GShade  : TColor = $F0F0F0;
  GBorder : TColor = clGray;

{ ── The IDE's colours ────────────────────────────────────────────────────── }

function HtmlColor(AColor: TColor): string;
begin
  AColor := ColorToRGB(AColor);
  Result := '#' + HexStr(Red(AColor), 2) + HexStr(Green(AColor), 2) + HexStr(Blue(AColor), 2);
end;

{ A mix of two colours: APercent of B in A. }
function Blend(A, B: TColor; APercent: Integer): TColor;
begin
  A := ColorToRGB(A);
  B := ColorToRGB(B);
  Result := RGBToColor(
    (Red(A) * (100 - APercent) + Red(B) * APercent) div 100,
    (Green(A) * (100 - APercent) + Green(B) * APercent) div 100,
    (Blue(A) * (100 - APercent) + Blue(B) * APercent) div 100);
end;

{ A scheme attribute's colour; ADefault where the scheme leaves it unset. }
function Pick(AColor, ADefault: TColor): TColor;
begin
  if (AColor = clNone) or (AColor = clDefault) then Result := ADefault
  else Result := AColor;
end;

{ Hue of a colour in degrees (0..359); -1 for a grey, which has none. }
function HueOf(AColor: TColor): Integer;
var
  R, G, B, Mx, Mn, D : Integer;
  H : Integer;
begin
  AColor := ColorToRGB(AColor);
  R := Red(AColor);
  G := Green(AColor);
  B := Blue(AColor);
  Mx := R;
  if G > Mx then Mx := G;
  if B > Mx then Mx := B;
  Mn := R;
  if G < Mn then Mn := G;
  if B < Mn then Mn := B;
  D := Mx - Mn;
  if D < 40 then Exit(-1);
  if Mx = R then H := (60 * (G - B)) div D
  else if Mx = G then H := 120 + (60 * (B - R)) div D
  else H := 240 + (60 * (R - G)) div D;
  Result := (H + 360) mod 360;
end;

{ A colour of hue AHue (degrees) that reads well on a background of the scheme's brightness:
  light and strong on a dark one, dark and strong on a light one. }
function Synth(AHue: Integer; ADarkBack: Boolean): TColor;
var
  V, S, Sector, F, P, Q, T : Integer;
begin
  S := 190;                                  { saturation, 0..255 }
  if ADarkBack then V := 240 else V := 185;  { brightness, 0..255 }
  Sector := (AHue mod 360) div 60;
  F := ((AHue mod 360) mod 60) * 255 div 60;
  P := V * (255 - S) div 255;
  Q := V * (255 - S * F div 255) div 255;
  T := V * (255 - S * (255 - F) div 255) div 255;
  case Sector of
    0: Result := RGBToColor(V, T, P);
    1: Result := RGBToColor(Q, V, P);
    2: Result := RGBToColor(P, V, T);
    3: Result := RGBToColor(P, Q, V);
    4: Result := RGBToColor(T, P, V);
  else Result := RGBToColor(V, P, Q);
  end;
end;

{ Of the highlighter's colours, the one whose hue is nearest to AHue (a circular distance),
  when it is near enough (within 35 degrees) to be taken for that hue; otherwise a colour of
  that hue made for the scheme's background (Synth), so a scheme without amber still gets an
  amber warning.  AFallback only when nothing can be made. }
function Nearest(AHl: TSynPasSyn; AHue: Integer; AFallback: TColor;
  const AUsed: array of TColor): TColor;
var
  Cands : array[0..7] of TColor;
  I, Hu, Dist, Best : Integer;
  C : TColor;
  Taken : Boolean;
begin
  Cands[0] := AHl.NumberAttri.Foreground;
  Cands[1] := AHl.StringAttri.Foreground;
  Cands[2] := AHl.KeyAttri.Foreground;
  Cands[3] := AHl.SymbolAttri.Foreground;
  Cands[4] := AHl.DirectiveAttri.Foreground;
  Cands[5] := AHl.CommentAttri.Foreground;
  Cands[6] := AHl.AsmAttri.Foreground;
  Cands[7] := AHl.IdentifierAttri.Foreground;
  Result := AFallback;
  Best := 1000;
  for I := Low(Cands) to High(Cands) do
  begin
    if (Cands[I] = clNone) or (Cands[I] = clDefault) then Continue;
    Hu := HueOf(Cands[I]);
    if Hu < 0 then Continue;
    Taken := False;
    for C in AUsed do
      if ColorToRGB(C) = ColorToRGB(Cands[I]) then Taken := True;
    if Taken then Continue;
    Dist := Abs(Hu - AHue);
    if Dist > 180 then Dist := 360 - Dist;
    if Dist < Best then
    begin
      Best := Dist;
      Result := Cands[I];
    end;
  end;
  if Best > 35 then
    Result := Synth(AHue, (Red(ColorToRGB(GBack)) * 299 + Green(ColorToRGB(GBack)) * 587 +
      Blue(ColorToRGB(GBack)) * 114) div 1000 < 128);
end;

{ The Markdown palette from the editor's colour scheme (Tools > Options > Editor > Colors):
  the text and its background, the mouse-link colour for links, the highlighter's colours
  for code and the alert stripes.  Without the IDE's options (or when they fail) the
  Bootstrap defaults stay.  Read at every render, so a scheme change shows in the next
  document. }
procedure IdeColors(out APalette: TMdPalette);
var
  Ed : TSynEdit;
  Hl : TSynPasSyn;
  CCaution, CWarning, CImportant, CTip : TColor;
begin
  MdDefaultPalette(APalette);
  if not Assigned(IDEEditorOptions) then Exit;
  Ed := TSynEdit.Create(nil);
  Hl := TSynPasSyn.Create(nil);
  try
    try
      IDEEditorOptions.GetSynEditorSettings(Ed);
      IDEEditorOptions.GetHighlighterObjSettings(Hl);
    except
      Exit;
    end;
    GBack := ColorToRGB(Ed.Color);
    GFore := ColorToRGB(Ed.Font.Color);
    GLink := Pick(Ed.MouseLinkColor.Foreground, Pick(Hl.KeyAttri.Foreground, GFore));
    GShade := Blend(GBack, GFore, 6);
    GBorder := Blend(GBack, GFore, 25);
    APalette.Back      := HtmlColor(GBack);
    APalette.Text      := HtmlColor(GFore);
    APalette.Link      := HtmlColor(GLink);
    APalette.Border    := HtmlColor(GBorder);
    APalette.Shade     := HtmlColor(GShade);
    APalette.Cell      := HtmlColor(GBack);
    APalette.Code      := HtmlColor(Pick(Hl.StringAttri.Foreground, GFore));
    APalette.Note      := HtmlColor(GLink);
    { the alerts rise in alertness: note (the link colour) < tip < important < warning < caution;
      from the scheme's colours, red for caution, then amber, yellow and green, each a colour
      the others do not use where the scheme has enough of them }
    CCaution := Nearest(Hl, 0, GFore, [GLink]);
    CWarning := Nearest(Hl, 30, GFore, [GLink, CCaution]);
    CImportant := Nearest(Hl, 60, GFore, [GLink, CCaution, CWarning]);
    CTip := Nearest(Hl, 120, GFore, [GLink, CCaution, CWarning, CImportant]);
    APalette.Tip       := HtmlColor(CTip);
    APalette.Important := HtmlColor(CImportant);
    APalette.Warning   := HtmlColor(CWarning);
    APalette.Caution   := HtmlColor(CCaution);
    APalette.Added     := APalette.Tip;
    APalette.Removed   := APalette.Caution;
  finally
    Hl.Free;
    Ed.Free;
  end;
end;
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
    Bmp.Canvas.Brush.Color := GShade;
    Bmp.Canvas.Pen.Color := GBorder;
    Bmp.Canvas.Font.Color := GFore;
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

{ The text size in points before any zoom: the IDE's font plus 2 (IPro's default is too small). }
function MdBaseSize: Integer;
begin
  Result := Screen.SystemFont.Size + 2;
end;

{ What a new tab starts with: the base size and the zoom the view last had (kept in the settings,
  so it survives an IDE restart; stored as an offset, so a change of the IDE's font keeps it sane). }
function MdFontSize: Integer;
begin
  Result := MdBaseSize;
  if Assigned(McpSettings) then Inc(Result, McpSettings.MarkdownZoom);
  if Result < 6 then Result := 6;
  if Result > 48 then Result := 48;
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
  FPanel.DefaultFontSize := MdFontSize;
  FPanel.FixedTypeface := MonospaceFont;
  FPanel.FontQuality := fqCleartype;
  ApplyColors;
  FPanel.MarginWidth := 24;
  FPanel.MarginHeight := 16;
  FPanel.FactBAParag := 1.25;      { Bootstrap's line height of 1.5 }
  FProv := TIpHtmlDataProvider.Create(Self);
  FProv.OnGetImage := @GetImage;
  FProv.OnCanHandle := @CanHandle;
  FPanel.DataProvider := FProv;
  FPanel.OnHotClick := @HotClick;
end;

{ Ctrl + wheel zooms this tab.  IPro makes a new inner panel (the control that takes the
  wheel) for every page it renders, so the handler is put on the controls below FPanel after
  each SetHtmlFromStr; the old ones are gone.  Remove first: hooking twice would zoom twice. }
procedure TMdTab.HookWheel(AControl: TWinControl);
var
  I : Integer;
  C : TControl;
begin
  for I := 0 to AControl.ControlCount - 1 do
  begin
    C := AControl.Controls[I];
    if not (C is TWinControl) then Continue;
    TWinControl(C).RemoveHandlerOnMouseWheel(@WheelZoom);
    TWinControl(C).AddHandlerOnMouseWheel(@WheelZoom, True);
    HookWheel(TWinControl(C));
  end;
end;

{ Runs inside the inner panel's own wheel handling, which the re-render frees: only note
  the step here and do the work once the event is over. }
procedure TMdTab.WheelZoom(Sender: TObject; Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint; var Handled: Boolean);
begin
  if not (ssCtrl in Shift) or (WheelDelta = 0) then Exit;
  if WheelDelta > 0 then Inc(FZoomSteps) else Dec(FZoomSteps);
  if not FZoomQueued then
  begin
    FZoomQueued := True;
    Application.QueueAsyncCall(@ApplyZoom, 0);
  end;
  Handled := True;
end;

{ One point per notch, 6 to 48; the page is rendered again at the same relative place. }
procedure TMdTab.ApplyZoom(Data: PtrInt);
var
  Old, New, Y : Integer;
begin
  FZoomQueued := False;
  Old := FPanel.DefaultFontSize;
  New := Old + FZoomSteps;
  FZoomSteps := 0;
  if New < 6 then New := 6;
  if New > 48 then New := 48;
  if (New = Old) or (Old <= 0) or (FText = '') then Exit;
  Y := FPanel.VScrollPos * New div Old;
  FPanel.DefaultFontSize := New;
  if Assigned(McpSettings) then
  begin
    McpSettings.MarkdownZoom := New - MdBaseSize;  { the next tab, and the next IDE start }
    McpSettings.SaveSettings;
  end;
  SetDocument(FText);
  FPanel.VScrollPos := Y;
  Application.QueueAsyncCall(@RestoreScroll, Y);
end;

procedure TMdTab.Resize;
begin
  inherited Resize;
  if FDeferred and (Width >= MIN_PAGE_SIZE) and (Height >= MIN_PAGE_SIZE) then
    SetDocument(FText);          { clears FDeferred }
end;

destructor TMdTab.Destroy;
begin
  Application.RemoveAsyncCalls(Self);    { a queued zoom or scroll restore }
  FImages.Free;
  inherited Destroy;
end;

{ The panel's own colours: the editor scheme's, or Bootstrap's where the IDE gives none. }
procedure TMdTab.ApplyColors;
begin
  IdeColors(MdPalette);
  if MdPalette.Back <> '' then
  begin
    FPanel.Color := GBack;
    FPanel.TextColor := GFore;
    FPanel.LinkColor := GLink;
    FPanel.VLinkColor := GLink;
    FPanel.ALinkColor := Blend(GLink, GFore, 30);
  end
  else
  begin
    { Bootstrap 5: body text #212529, links #0d6efd }
    FPanel.TextColor := RGBToColor(33, 37, 41);
    FPanel.LinkColor := RGBToColor(13, 110, 253);
    FPanel.VLinkColor := RGBToColor(13, 110, 253);
    FPanel.ALinkColor := RGBToColor(10, 88, 202);
  end;
end;

procedure TMdTab.SetDocument(const AMarkdown: string);
var
  C : TMarkdownHtml;
  Html : string;
begin
  FText := AMarkdown;
  { a window docked as a bare title bar (or not sized yet) has no room: IPro divides by the
    width and height while it lays out, so the page waits until the tab has a size (Resize) }
  FDeferred := (Width < MIN_PAGE_SIZE) or (Height < MIN_PAGE_SIZE);
  if FDeferred then Exit;
  ApplyColors;
  C := TMarkdownHtml.Create;
  try
    Html := C.ToHtml(AMarkdown, FImages);
  finally
    C.Free;
  end;
  FPanel.SetHtmlFromStr(Html);
  HookWheel(FPanel);       { the page has a new inner panel }
end;

{ Text as the tab compares it: LF line ends, no byte order mark. }
function NormalizedText(const AText: string): string;
begin
  Result := StringReplace(AText, #13#10, #10, [rfReplaceAll]);
  if (Length(Result) >= 3) and (Result[1] = #$EF) and (Result[2] = #$BB) and (Result[3] = #$BF) then
    Delete(Result, 1, 3);
end;

function FileStamp(const AFile: string): string;
var
  F : TSearchRec;
begin
  Result := '';
  if FindFirst(AFile, faAnyFile, F) = 0 then
  begin
    Result := IntToStr(F.Time) + ':' + IntToStr(F.Size);
    FindClose(F);
  end;
end;

procedure TMdTab.RestoreScroll(Data: PtrInt);
begin
  FPanel.VScrollPos := Data;
end;

{ The file changed: show the new text where the reader was (the layout of a new page
  is built after SetHtmlFromStr returns, so the position is set again once it is). }
procedure TMdTab.Follow(const AText: string);
var
  Y : Integer;
begin
  FSource := NormalizedText(AText);
  Y := FPanel.VScrollPos;
  SetDocument(FSource);
  FPanel.VScrollPos := Y;
  Application.QueueAsyncCall(@RestoreScroll, Y);
end;

function TMdTab.FileEditor: TSourceEditorInterface;
begin
  Result := nil;
  if (FFile <> '') and Assigned(SourceEditorManagerIntf) then
    Result := SourceEditorManagerIntf.SourceEditorIntfWithFilename(FFile);
end;

{ An editor holding the file is the truth (also while the user types), else the file on
  disk when its age or size changed.  Called after an editor event (debounced) and by the
  slow timer for files no editor holds. }
procedure TMdTab.CheckSource;
var
  Ed    : TSourceEditorInterface;
  Raw   : string;
  Stamp : string;
  S     : TFileStream;
begin
  if FFile = '' then Exit;
  try
    Ed := FileEditor;
    if Assigned(Ed) then
      Raw := Ed.Lines.Text
    else
    begin
      Stamp := FileStamp(FFile);
      if (Stamp = '') or (Stamp = FStamp) then Exit;
      FStamp := Stamp;
      S := TFileStream.Create(FFile, fmOpenRead or fmShareDenyNone);
      try
        if S.Size > MD_MAX_FILE_BYTES then Exit;
        SetLength(Raw, S.Size);
        if S.Size > 0 then S.ReadBuffer(Raw[1], S.Size);
      finally
        S.Free;
      end;
    end;
    if NormalizedText(Raw) <> FSource then Follow(Raw);
  except
    { a file being written or an editor going away: the next tick tries again }
  end;
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
  { Typing is an event: any status change of an editor (a keystroke moves the caret).  The
    handler only arms a one-shot debounce, so rendering waits for a pause in the typing. }
  FDebounce := TTimer.Create(Self);
  FDebounce.Enabled := False;
  FDebounce.Interval := 250;
  FDebounce.OnTimer := @Debounced;
  if Assigned(SourceEditorManagerIntf) then
    SourceEditorManagerIntf.RegisterChangeEvent(semEditorStatus, @EditorStatus);
  { A file on disk that no editor holds changes without any event the IDE could give (the
    LCL has no file watcher), so one stat per such tab, rarely. }
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 2000;
  FTimer.OnTimer := @Tick;
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
  if Assigned(SourceEditorManagerIntf) then
    SourceEditorManagerIntf.UnRegisterChangeEvent(semEditorStatus, @EditorStatus);
  Application.RemoveAsyncCalls(Self);
  inherited Destroy;
end;

{ An editor changed: if it holds a file shown in a tab, look at that tab after a pause. }
procedure TMdForm.EditorStatus(Sender: TObject);
var
  I : Integer;
begin
  if not (Sender is TSourceEditorInterface) then Exit;
  for I := 0 to FPages.PageCount - 1 do
    if (FPages.Pages[I] is TMdTab) and (TMdTab(FPages.Pages[I]).FileName <> '') and
       (CompareFilenames(TMdTab(FPages.Pages[I]).FileName,
                         TSourceEditorInterface(Sender).FileName) = 0) then
    begin
      FDebounce.Enabled := False;
      FDebounce.Enabled := True;
      Exit;
    end;
end;

procedure TMdForm.Debounced(Sender: TObject);
var
  I : Integer;
begin
  FDebounce.Enabled := False;
  if not Visible then Exit;
  for I := 0 to FPages.PageCount - 1 do
    if (FPages.Pages[I] is TMdTab) and Assigned(TMdTab(FPages.Pages[I]).FileEditor) then
      TMdTab(FPages.Pages[I]).CheckSource;
end;

{ Files no editor holds: a stat each, only while the window is shown. }
procedure TMdForm.Tick(Sender: TObject);
var
  I : Integer;
begin
  if not Visible then Exit;
  for I := 0 to FPages.PageCount - 1 do
    if (FPages.Pages[I] is TMdTab) and (TMdTab(FPages.Pages[I]).FileName <> '') and
       (TMdTab(FPages.Pages[I]).FileEditor = nil) then
      TMdTab(FPages.Pages[I]).CheckSource;
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
  { Sender is the tab whose button was clicked (other widgetsets), not always the active one. }
  if Sender is TTabSheet then P := TTabSheet(Sender) else P := FPages.ActivePage;
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

function IsMarkdownName(const AName: string): Boolean;
var
  Ext : string;
begin
  Ext := LowerCase(ExtractFileExt(AName));
  Result := (Ext = '.md') or (Ext = '.markdown') or (Ext = '.mdown');
end;

function McpMarkdownOpenFile(const AFile, AText: string; out AError: string): Boolean;
var
  TabId : string;
begin
  Result := McpMarkdownOpenFile(AFile, AText, TabId, AError);
end;

function McpMarkdownOpenFile(const AFile, AText: string; out ATabId, AError: string): Boolean;
var
  Text, TabId, Err : string;
  S    : TFileStream;
  Tab  : TMdTab;
  Reuse: string;
begin
  Result := False;
  AError := '';
  ATabId := '';
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
    if Assigned(Tab) then
    begin
      Tab.FFile   := AFile;
      Tab.FSource := NormalizedText(Text);
      Tab.FStamp  := FileStamp(AFile);
    end;
  end;
  ATabId := TabId;
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
