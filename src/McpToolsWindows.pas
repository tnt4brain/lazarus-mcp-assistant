{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsWindows;

{ project_get_windows: the windows of the running project (the active
  project's target file), as a text tree of controls and optionally as PNG
  images.  Runs off the main thread, and sends the program no message that
  could wait: a program paused in the debugger does not answer messages, and
  the call would wait as long.  Windows: the controls too.  X11: the top-level
  windows only.  Not on macOS yet. }

{$mode objfpc}{$H+}

{$IF DEFINED(UNIX) AND NOT DEFINED(DARWIN)}
  {$DEFINE MCP_X11}
{$ENDIF}

interface

implementation

uses
  {$IFDEF WINDOWS} Windows, {$ENDIF}
  {$IFDEF MCP_X11} BaseUnix, ctypes, x, xlib, xutil, xatom, {$ENDIF}
  Classes, SysUtils, SyncObjs, StrUtils, Math, base64, FPImage, FPWritePNG,
  MacroIntf, LazFileUtils,
  fpjson,
  McpToolContext;

const
  SCHEMA_GET_WINDOWS =
    '{"type":"object","properties":{' +
    '"window":{"type":"string","description":"Only top-level windows whose caption contains this text (case-insensitive)"},' +
    '"image":{"type":"boolean","description":"Also return a PNG of each top-level window (default false)"},' +
    '"max_size":{"type":"integer","description":"Longest edge of an image in pixels; larger windows are scaled down (default 1024, 64..4096)"}}}';

type
  TTargetReader = class
    Target : string;
    procedure Read;   { main thread }
  end;

procedure TTargetReader.Read;
begin
  Target := '$(TargetFile)';
  if not Assigned(IDEMacros) or not IDEMacros.SubstituteMacros(Target) then
    Target := '';
end;

{$IFDEF WINDOWS}

const
  PW_RENDERFULLCONTENT              = 2;
  DWMWA_EXTENDED_FRAME_BOUNDS       = 9;
  PROCESS_QUERY_LIMITED_INFORMATION = $1000;
  ANSWER_TIMEOUT                    = 200;   { ms }
  PRINT_TIMEOUT                     = 1000;  { ms }

function PrintWindow(hwnd: HWND; hdcBlt: HDC; nFlags: UINT): BOOL; stdcall;
  external 'user32.dll';
{ reads the caption the system keeps, without a message to the window }
function InternalGetWindowText(hWnd: HWND; pString: LPWSTR; cchMaxCount: Integer): Integer;
  stdcall; external 'user32.dll';
function DwmGetWindowAttribute(hwnd: HWND; dwAttribute: DWORD; pvAttribute: Pointer;
  cbAttribute: DWORD): HRESULT; stdcall; external 'dwmapi.dll';

type
  TWindowLister = class
    Target   : string;
    Filter   : string;
    Windows  : array of HWND;
    Pids     : array of DWORD;
    Checked  : array of DWORD;   { pids already compared with Target }
    Matching : array of Boolean;
    function IsTargetPid(Pid: DWORD): Boolean;
  end;

function WideBuf(P: PWideChar; Len: Integer): string;
var
  W : WideString;
begin
  SetString(W, P, Max(0, Len));
  Result := UTF8Encode(W);
end;

function ProcessFile(Pid: DWORD): string;
var
  H   : THandle;
  Buf : array[0..MAX_PATH * 2] of WideChar;
  Len : DWORD;
begin
  Result := '';
  H := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, Pid);
  if H = 0 then Exit;
  try
    Len := Length(Buf);
    if QueryFullProcessImageNameW(H, 0, @Buf[0], @Len) then
      Result := WideBuf(@Buf[0], Len);
  finally
    CloseHandle(H);
  end;
end;

function TWindowLister.IsTargetPid(Pid: DWORD): Boolean;
var
  I : Integer;
begin
  for I := 0 to High(Checked) do
    if Checked[I] = Pid then Exit(Matching[I]);
  Result := SameFileName(ProcessFile(Pid), Target);
  SetLength(Checked, Length(Checked) + 1);
  SetLength(Matching, Length(Matching) + 1);
  Checked[High(Checked)]   := Pid;
  Matching[High(Matching)] := Result;
end;

function SystemCaption(H: HWND): string;
var
  Buf : array[0..511] of WideChar;
  Len : Integer;
begin
  Len := InternalGetWindowText(H, @Buf[0], Length(Buf));
  Result := WideBuf(@Buf[0], Len);
end;

function ListTopWindow(H: HWND; Data: LPARAM): BOOL; stdcall;
var
  L   : TWindowLister;
  Pid : DWORD;
begin
  Result := True;
  L := TWindowLister(Data);
  if not IsWindowVisible(H) then Exit;
  Pid := 0;
  GetWindowThreadProcessId(H, @Pid);
  if not L.IsTargetPid(Pid) then Exit;
  if (L.Filter <> '') and (Pos(LowerCase(L.Filter), LowerCase(SystemCaption(H))) = 0) then Exit;
  SetLength(L.Windows, Length(L.Windows) + 1);
  SetLength(L.Pids, Length(L.Pids) + 1);
  L.Windows[High(L.Windows)] := H;
  L.Pids[High(L.Pids)]       := Pid;
end;

{ Does the window's thread answer?  Not when paused in the debugger. }
function Answers(H: HWND): Boolean;
var
  R : DWORD_PTR;
begin
  Result := SendMessageTimeoutW(H, WM_NULL, 0, 0, SMTO_ABORTIFHUNG or SMTO_BLOCK,
                                ANSWER_TIMEOUT, @R) <> 0;
end;

type
  TTreeWriter = class
    Lines   : TStringList;
    CanAsk  : Boolean;   { the program answers messages }
    function Text(H: HWND): string;
    procedure Add(H, Parent: HWND; const Indent: string);
  end;

function TTreeWriter.Text(H: HWND): string;
var
  Len : DWORD_PTR;
  W   : WideString;
begin
  Result := '';
  { an edit's text is not its caption: it answers WM_GETTEXT }
  if CanAsk and (SendMessageTimeoutW(H, WM_GETTEXTLENGTH, 0, 0, SMTO_ABORTIFHUNG or SMTO_BLOCK,
                 ANSWER_TIMEOUT, @Len) <> 0) then
  begin
    Len := Min(Len, 200);
    SetLength(W, Len + 1);
    if SendMessageTimeoutW(H, WM_GETTEXT, Len + 1, LPARAM(PWideChar(W)),
         SMTO_ABORTIFHUNG or SMTO_BLOCK, ANSWER_TIMEOUT, @Len) <> 0 then
      Result := UTF8Encode(Copy(W, 1, Len))
    else
      CanAsk := False;
  end
  else
    Result := SystemCaption(H);
  if Length(Result) > 60 then Result := Copy(Result, 1, 57) + '...';
  Result := StringReplace(StringReplace(Result, #13, '', [rfReplaceAll]),
                          #10, '\n', [rfReplaceAll]);
end;

{ One line per visible window, its children indented below it:
  Class "text" x,y wxh — relative to the parent's client area, on screen for
  a top-level window. }
procedure TTreeWriter.Add(H, Parent: HWND; const Indent: string);
var
  R     : TRect;
  Cls   : array[0..255] of WideChar;
  S, T  : string;
  Child : HWND;
begin
  GetWindowRect(H, R);
  if Parent <> 0 then
    MapWindowPoints(0, Parent, R, 2);
  S := WideBuf(@Cls[0], GetClassNameW(H, @Cls[0], Length(Cls)));
  T := Text(H);
  if T <> '' then S := S + ' "' + T + '"';
  S := Indent + S + Format(' %d,%d %dx%d', [R.Left, R.Top, R.Right - R.Left, R.Bottom - R.Top]);
  if not IsWindowEnabled(H) then S := S + ' disabled';
  Lines.Add(S);
  Child := GetWindow(H, GW_CHILD);
  while Child <> 0 do
  begin
    if IsWindowVisible(Child) then
      Add(Child, H, Indent + '  ');
    Child := GetWindow(Child, GW_HWNDNEXT);
  end;
end;

type
  { PrintWindow in a thread of its own: it may wait for the window's thread
    (paused in the debugger, say), and the caller does not wait as long.
    Frees itself once Release is set and PrintWindow has returned. }
  TPrintThread = class(TThread)
  private
    FWnd  : HWND;
    FW, FH: Integer;
    FBmp  : HBITMAP;
    FOld  : HGDIOBJ;
  protected
    procedure Execute; override;
  public
    DC      : HDC;
    Ok      : Boolean;
    Done    : TEvent;
    Release : TEvent;
    constructor Create(AWnd: HWND; AW, AH: Integer);
    destructor Destroy; override;
  end;

constructor TPrintThread.Create(AWnd: HWND; AW, AH: Integer);
begin
  FWnd := AWnd; FW := AW; FH := AH;
  Done    := TEvent.Create(nil, True, False, '');
  Release := TEvent.Create(nil, True, False, '');
  FreeOnTerminate := True;
  inherited Create(False);
end;

destructor TPrintThread.Destroy;
begin
  Done.Free;
  Release.Free;
  inherited Destroy;
end;

procedure TPrintThread.Execute;
var
  ScreenDC : HDC;
begin
  ScreenDC := GetDC(0);
  DC   := CreateCompatibleDC(ScreenDC);
  FBmp := CreateCompatibleBitmap(ScreenDC, FW, FH);
  ReleaseDC(0, ScreenDC);
  FOld := SelectObject(DC, FBmp);
  Ok := PrintWindow(FWnd, DC, PW_RENDERFULLCONTENT);
  GdiFlush;
  Done.SetEvent;
  Release.WaitFor(INFINITE);
  SelectObject(DC, FOld);
  DeleteObject(FBmp);
  DeleteDC(DC);
end;

{ A PNG of the window, base64; '' if it could not be taken.  A window that
  answers draws itself (PrintWindow), also when covered.  One that does not,
  or takes too long, is copied from the screen, with whatever covers it:
  PrintWindow waits for a program paused in the debugger. }
function Capture(H: HWND; CanAsk: Boolean; MaxSize: Integer; out FromScreen: Boolean): string;
var
  WR, FR     : TRect;
  W, Hh      : Integer;
  CX, CY     : Integer;
  CW, CH     : Integer;
  DW, DH     : Integer;
  Scale      : Double;
  ScreenDC   : HDC;
  SrcDC      : HDC;
  OutDC      : HDC;
  SrcBmp     : HBITMAP;
  OutBmp     : HBITMAP;
  OldSrc     : HGDIOBJ;
  OldOut     : HGDIOBJ;
  BI         : TBitmapInfo;
  Bits       : PByte;
  Img        : TFPMemoryImage;
  Writer     : TFPWriterPNG;
  Stream     : TStringStream;
  X, Y       : Integer;
  P          : PByte;
  C          : TFPColor;
  Printer    : TPrintThread;
begin
  Result := '';
  FromScreen := True;
  if not GetWindowRect(H, WR) then Exit;
  { without the invisible resize border and shadow }
  if DwmGetWindowAttribute(H, DWMWA_EXTENDED_FRAME_BOUNDS, @FR, SizeOf(FR)) <> S_OK then
    FR := WR;
  W  := WR.Right - WR.Left;
  Hh := WR.Bottom - WR.Top;
  CX := Max(0, FR.Left - WR.Left);
  CY := Max(0, FR.Top - WR.Top);
  CW := Min(FR.Right - FR.Left, W - CX);
  CH := Min(FR.Bottom - FR.Top, Hh - CY);
  if (CW <= 0) or (CH <= 0) then Exit;
  Scale := Min(1.0, MaxSize / Max(CW, CH));
  DW := Max(1, Round(CW * Scale));
  DH := Max(1, Round(CH * Scale));

  ScreenDC := GetDC(0);
  SrcDC  := CreateCompatibleDC(ScreenDC);
  OutDC  := CreateCompatibleDC(ScreenDC);
  SrcBmp := CreateCompatibleBitmap(ScreenDC, W, Hh);
  FillChar(BI, SizeOf(BI), 0);
  BI.bmiHeader.biSize     := SizeOf(BI.bmiHeader);
  BI.bmiHeader.biWidth    := DW;
  BI.bmiHeader.biHeight   := -DH;   { top-down }
  BI.bmiHeader.biPlanes   := 1;
  BI.bmiHeader.biBitCount := 32;
  BI.bmiHeader.biCompression := BI_RGB;
  Bits   := nil;
  OutBmp := CreateDIBSection(ScreenDC, BI, DIB_RGB_COLORS, Pointer(Bits), 0, 0);
  OldSrc := SelectObject(SrcDC, SrcBmp);
  OldOut := SelectObject(OutDC, OutBmp);
  Img := nil;
  try
    if CanAsk then
    begin
      Printer := TPrintThread.Create(H, W, Hh);
      FromScreen := not ((Printer.Done.WaitFor(PRINT_TIMEOUT) = wrSignaled) and Printer.Ok);
      if not FromScreen then
        BitBlt(SrcDC, 0, 0, W, Hh, Printer.DC, 0, 0, SRCCOPY);
      Printer.Release.SetEvent;   { Printer is not touched after this }
    end;
    if FromScreen then
      BitBlt(SrcDC, 0, 0, W, Hh, ScreenDC, WR.Left, WR.Top, SRCCOPY);
    SetStretchBltMode(OutDC, HALFTONE);
    SetBrushOrgEx(OutDC, 0, 0, nil);
    StretchBlt(OutDC, 0, 0, DW, DH, SrcDC, CX, CY, CW, CH, SRCCOPY);
    GdiFlush;
    if Bits = nil then Exit;

    Img := TFPMemoryImage.Create(DW, DH);
    for Y := 0 to DH - 1 do
    begin
      P := Bits + Y * DW * 4;
      for X := 0 to DW - 1 do
      begin
        C.Blue  := P[0] * $101;
        C.Green := P[1] * $101;
        C.Red   := P[2] * $101;
        C.Alpha := alphaOpaque;
        Img.Colors[X, Y] := C;
        Inc(P, 4);
      end;
    end;
    Writer := TFPWriterPNG.Create;
    Stream := TStringStream.Create('');
    try
      Writer.UseAlpha  := False;
      Writer.Indexed   := False;
      Writer.GrayScale := False;
      Writer.WordSized := False;
      Img.SaveToStream(Stream, Writer);
      Result := EncodeStringBase64(Stream.DataString);
    finally
      Stream.Free;
      Writer.Free;
    end;
  finally
    Img.Free;
    SelectObject(SrcDC, OldSrc);
    SelectObject(OutDC, OldOut);
    DeleteObject(SrcBmp);
    DeleteObject(OutBmp);
    DeleteDC(SrcDC);
    DeleteDC(OutDC);
    ReleaseDC(0, ScreenDC);
  end;
end;

procedure GetWindows(var Ctx: TMcpToolCall; const ATarget: string);
var
  L        : TWindowLister;
  Tree     : TTreeWriter;
  I        : Integer;
  WantImg  : Boolean;
  MaxSize  : Integer;
  Png      : string;
  Answer   : Boolean;
  FromScreen : Boolean;
begin
  WantImg := False;
  MaxSize := 1024;
  L := TWindowLister.Create;
  Tree := TTreeWriter.Create;
  Tree.Lines := TStringList.Create;
  Tree.Lines.LineBreak := #10;
  try
    L.Target := ATarget;
    if Assigned(Ctx.Params) then
    begin
      L.Filter := Ctx.Params.Get('window', '');
      WantImg  := Ctx.Params.Get('image', False);
      MaxSize  := EnsureRange(Ctx.Params.Get('max_size', 1024), 64, 4096);
    end;
    EnumWindows(@ListTopWindow, LPARAM(L));
    if Length(L.Windows) = 0 then
    begin
      Ctx.Result := 'No visible window of ' + ATarget +
                    IfThen(L.Filter <> '', ' with "' + L.Filter + '" in its caption') +
                    '. Start it with project_run or debug_run.';
      Exit;
    end;
    Tree.Lines.Add(ATarget + ', pid ' + IntToStr(L.Pids[0]));
    for I := 0 to High(L.Windows) do
    begin
      Answer := Answers(L.Windows[I]);
      Tree.CanAsk := Answer;
      if not Answer then
        Tree.Lines.Add('(not answering: paused in the debugger, or busy)');
      Tree.Add(L.Windows[I], 0, '');
      if WantImg then
      begin
        Png := Capture(L.Windows[I], Answer, MaxSize, FromScreen);
        if Png <> '' then
        begin
          SetLength(Ctx.Images, Length(Ctx.Images) + 1);
          Ctx.Images[High(Ctx.Images)] := Png;
          if FromScreen then
            Tree.Lines.Add('(image copied from the screen: what covers the window shows)');
        end
        else
          Tree.Lines.Add('(no image of this window)');
      end;
    end;
    Ctx.Result := TrimRight(Tree.Lines.Text);
  finally
    Tree.Lines.Free;
    Tree.Free;
    L.Free;
  end;
end;

{$ENDIF}

{$IFDEF MCP_X11}

{ X11: the top-level windows of the program, found by _NET_WM_PID, with their
  captions and a PNG of each.  No controls: X knows only the windows the toolkit
  creates, and the LCL draws its graphic controls itself.  Runs on the main
  thread, where the IDE's own GTK uses Xlib; asking the X server never waits for
  the program, so a program paused in the debugger is no problem (the image is
  what is on the screen then). }

type
  PMcpToolCall = ^TMcpToolCall;

  TX11Lister = class
    Dpy      : PDisplay;
    Target   : string;
    Filter   : string;
    AtomPid  : TAtom;
    AtomName : TAtom;
    AtomUtf8 : TAtom;
    Wins     : array of TWindow;
    Pids     : array of culong;
    Checked  : array of culong;
    Matching : array of Boolean;
    function  IsTargetPid(Pid: culong): Boolean;
    procedure Consider(W: TWindow; Pid: culong);
    procedure Collect(W: TWindow; ADepth: Integer);
  end;

  TX11Windows = class
    Ctx    : PMcpToolCall;
    Target : string;
    procedure Run;   { main thread }
  end;

var
  GXError : Boolean;

{ An X error (a window closed between two calls) must not reach GDK's handler,
  which ends the IDE. }
function QuietXErrors(Dpy: PDisplay; Ev: PXErrorEvent): cint; cdecl;
begin
  GXError := True;
  Result := 0;
end;

{ The property's data (free it with XFree), nil if the window has none. }
function WinProperty(Dpy: PDisplay; W: TWindow; Prop, PropType: TAtom;
  ALongs: clong; out Fmt: cint; out N: culong): pcuchar;
var
  ActType : TAtom;
  After   : culong;
begin
  Result := nil;
  Fmt := 0;
  N   := 0;
  if XGetWindowProperty(Dpy, W, Prop, 0, ALongs, False, PropType, @ActType, @Fmt,
       @N, @After, @Result) <> Success then
    Result := nil;
end;

function WindowPid(Dpy: PDisplay; W: TWindow; AtomPid: TAtom): culong;
var
  D   : pcuchar;
  Fmt : cint;
  N   : culong;
begin
  Result := 0;
  D := WinProperty(Dpy, W, AtomPid, XA_CARDINAL, 1, Fmt, N);
  if D = nil then Exit;
  if (Fmt = 32) and (N >= 1) then Result := pculong(D)^;
  XFree(D);
end;

function WindowCaption(Dpy: PDisplay; W: TWindow; AtomName, AtomUtf8: TAtom): string;
var
  D   : pcuchar;
  Fmt : cint;
  N   : culong;
  P   : PChar;
begin
  Result := '';
  D := WinProperty(Dpy, W, AtomName, AtomUtf8, 256, Fmt, N);
  if D <> nil then
  begin
    if Fmt = 8 then SetString(Result, PChar(D), N);
    XFree(D);
  end;
  if Result = '' then
  begin
    P := nil;
    if (XFetchName(Dpy, W, @P) <> 0) and (P <> nil) then
    begin
      Result := P;
      XFree(P);
    end;
  end;
  if Length(Result) > 60 then Result := Copy(Result, 1, 57) + '...';
  Result := StringReplace(StringReplace(Result, #13, '', [rfReplaceAll]),
                          #10, '\n', [rfReplaceAll]);
end;

function WindowClass(Dpy: PDisplay; W: TWindow): string;
var
  H : TXClassHint;
begin
  Result := '';
  FillChar(H, SizeOf(H), 0);
  if XGetClassHint(Dpy, W, @H) = 0 then Exit;
  if H.res_class <> nil then Result := H.res_class;
  if H.res_name  <> nil then XFree(H.res_name);
  if H.res_class <> nil then XFree(H.res_class);
end;

function TX11Lister.IsTargetPid(Pid: culong): Boolean;
var
  I : Integer;
begin
  for I := 0 to High(Checked) do
    if Checked[I] = Pid then Exit(Matching[I]);
  Result := SameFileName(fpReadLink('/proc/' + IntToStr(Pid) + '/exe'), Target);
  SetLength(Checked, Length(Checked) + 1);
  SetLength(Matching, Length(Matching) + 1);
  Checked[High(Checked)]   := Pid;
  Matching[High(Matching)] := Result;
end;

procedure TX11Lister.Consider(W: TWindow; Pid: culong);
var
  Attr : TXWindowAttributes;
begin
  if XGetWindowAttributes(Dpy, W, @Attr) = 0 then Exit;
  if Attr.map_state <> IsViewable then Exit;
  if not IsTargetPid(Pid) then Exit;
  if (Filter <> '') and
     (Pos(LowerCase(Filter), LowerCase(WindowCaption(Dpy, W, AtomName, AtomUtf8))) = 0) then Exit;
  SetLength(Wins, Length(Wins) + 1);
  SetLength(Pids, Length(Pids) + 1);
  Wins[High(Wins)] := W;
  Pids[High(Pids)] := Pid;
end;

{ The window manager's frames sit between the root and the program's window:
  look a few levels down, and stop at a window that names its process. }
procedure TX11Lister.Collect(W: TWindow; ADepth: Integer);
var
  Root, Parent : TWindow;
  Kids         : PWindow;
  N            : cuint;
  I            : Integer;
  Kid          : TWindow;
  Pid          : culong;
begin
  Kids := nil;
  N := 0;
  if XQueryTree(Dpy, W, @Root, @Parent, @Kids, @N) = 0 then Exit;
  try
    for I := 0 to Integer(N) - 1 do
    begin
      Kid := PWindow(PByte(Kids) + I * SizeOf(TWindow))^;
      Pid := WindowPid(Dpy, Kid, AtomPid);
      if Pid <> 0 then
        Consider(Kid, Pid)
      else if ADepth < 3 then
        Collect(Kid, ADepth + 1);
    end;
  finally
    if Kids <> nil then XFree(Kids);
  end;
end;

procedure MaskInfo(Mask: culong; out Shift: Integer; out MaxV: culong);
begin
  Shift := 0;
  MaxV  := 1;
  if Mask = 0 then Exit;
  while ((Mask shr Shift) and 1) = 0 do Inc(Shift);
  MaxV := Mask shr Shift;
end;

{ The window's pixels as they are on the screen (what covers the window shows),
  scaled down to MaxSize, as a base64 PNG; '' if the server refuses. }
function CaptureWindow(Dpy: PDisplay; W: TWindow; AWidth, AHeight, MaxSize: Integer): string;
var
  Src          : PXImage;
  Img          : TFPMemoryImage;
  Writer       : TFPWriterPNG;
  Stream       : TStringStream;
  Scale        : Double;
  DW, DH       : Integer;
  Ox, Oy       : Integer;
  Sx, Sy       : Integer;
  X0, X1       : Integer;
  Y0, Y1       : Integer;
  Cnt          : Integer;
  Pix          : culong;
  SumR, SumG, SumB : Int64;
  RS, GS, BS   : Integer;
  RM, GM, BM   : culong;
  C            : TFPColor;
begin
  Result := '';
  if (AWidth <= 0) or (AHeight <= 0) then Exit;
  GXError := False;
  Src := XGetImage(Dpy, W, 0, 0, AWidth, AHeight, culong(-1), ZPixmap);
  XSync(Dpy, False);
  if (Src = nil) or GXError then
  begin
    if Src <> nil then XDestroyImage(Src);
    Exit;
  end;
  Img := nil;
  try
    MaskInfo(Src^.red_mask,   RS, RM);
    MaskInfo(Src^.green_mask, GS, GM);
    MaskInfo(Src^.blue_mask,  BS, BM);
    Scale := Min(1.0, MaxSize / Max(AWidth, AHeight));
    DW := Max(1, Round(AWidth * Scale));
    DH := Max(1, Round(AHeight * Scale));
    Img := TFPMemoryImage.Create(DW, DH);
    for Oy := 0 to DH - 1 do
    begin
      Y0 := Oy * AHeight div DH;
      Y1 := Max(Y0 + 1, (Oy + 1) * AHeight div DH);
      for Ox := 0 to DW - 1 do
      begin
        X0 := Ox * AWidth div DW;
        X1 := Max(X0 + 1, (Ox + 1) * AWidth div DW);
        SumR := 0; SumG := 0; SumB := 0; Cnt := 0;
        for Sy := Y0 to Y1 - 1 do
          for Sx := X0 to X1 - 1 do
          begin
            Pix := XGetPixel(Src, Sx, Sy);
            Inc(SumR, ((Pix and Src^.red_mask)   shr RS) * 255 div RM);
            Inc(SumG, ((Pix and Src^.green_mask) shr GS) * 255 div GM);
            Inc(SumB, ((Pix and Src^.blue_mask)  shr BS) * 255 div BM);
            Inc(Cnt);
          end;
        C.Red   := (SumR div Cnt) * $101;
        C.Green := (SumG div Cnt) * $101;
        C.Blue  := (SumB div Cnt) * $101;
        C.Alpha := alphaOpaque;
        Img.Colors[Ox, Oy] := C;
      end;
    end;
    Writer := TFPWriterPNG.Create;
    Stream := TStringStream.Create('');
    try
      Writer.UseAlpha  := False;
      Writer.Indexed   := False;
      Writer.GrayScale := False;
      Writer.WordSized := False;
      Img.SaveToStream(Stream, Writer);
      Result := EncodeStringBase64(Stream.DataString);
    finally
      Stream.Free;
      Writer.Free;
    end;
  finally
    Img.Free;
    XDestroyImage(Src);
  end;
end;

procedure TX11Windows.Run;
var
  L       : TX11Lister;
  Lines   : TStringList;
  Old     : TXErrorHandler;
  Root    : TWindow;
  Attr    : TXWindowAttributes;
  Child   : TWindow;
  I       : Integer;
  Px, Py  : cint;
  Cls, Cap, Png, S : string;
  WantImg : Boolean;
  MaxSize : Integer;
begin
  WantImg := False;
  MaxSize := 1024;
  L := TX11Lister.Create;
  Lines := TStringList.Create;
  Lines.LineBreak := #10;
  try
    L.Target := Target;
    if Assigned(Ctx^.Params) then
    begin
      L.Filter := Ctx^.Params.Get('window', '');
      WantImg  := Ctx^.Params.Get('image', False);
      MaxSize  := EnsureRange(Ctx^.Params.Get('max_size', 1024), 64, 4096);
    end;
    L.Dpy := XOpenDisplay(nil);
    if L.Dpy = nil then
    begin
      Ctx^.Error  := True;
      Ctx^.Result := 'The IDE has no X display to look at (no DISPLAY; Wayland without XWayland?)';
      Exit;
    end;
    GXError := False;
    Old := XSetErrorHandler(@QuietXErrors);
    try
      L.AtomPid  := XInternAtom(L.Dpy, '_NET_WM_PID', False);
      L.AtomName := XInternAtom(L.Dpy, '_NET_WM_NAME', False);
      L.AtomUtf8 := XInternAtom(L.Dpy, 'UTF8_STRING', False);
      Root := XDefaultRootWindow(L.Dpy);
      L.Collect(Root, 0);
      if Length(L.Wins) = 0 then
      begin
        Ctx^.Result := 'No visible window of ' + Target +
                       IfThen(L.Filter <> '', ' with "' + L.Filter + '" in its caption') +
                       '. Start it with project_run or debug_run.';
        Exit;
      end;
      Lines.Add(Target + ', pid ' + IntToStr(L.Pids[0]));
      for I := 0 to High(L.Wins) do
      begin
        if XGetWindowAttributes(L.Dpy, L.Wins[I], @Attr) = 0 then Continue;
        { on screen: the origin of the window's own area }
        Px := 0; Py := 0;
        XTranslateCoordinates(L.Dpy, L.Wins[I], Root, 0, 0, @Px, @Py, @Child);
        Cls := WindowClass(L.Dpy, L.Wins[I]);
        if Cls = '' then Cls := 'Window';
        Cap := WindowCaption(L.Dpy, L.Wins[I], L.AtomName, L.AtomUtf8);
        S := Cls;
        if Cap <> '' then S := S + ' "' + Cap + '"';
        Lines.Add(Format('%s %d,%d %dx%d', [S, Px, Py, Attr.width, Attr.height]));
        if WantImg then
        begin
          Png := CaptureWindow(L.Dpy, L.Wins[I], Attr.width, Attr.height, MaxSize);
          if Png <> '' then
          begin
            SetLength(Ctx^.Images, Length(Ctx^.Images) + 1);
            Ctx^.Images[High(Ctx^.Images)] := Png;
            Lines.Add('(image copied from the screen: what covers the window shows)');
          end
          else
            Lines.Add('(no image of this window)');
        end;
      end;
      Lines.Add('(top-level windows only: the controls inside are not listed on X11)');
      Ctx^.Result := TrimRight(Lines.Text);
    finally
      XSync(L.Dpy, False);
      XSetErrorHandler(Old);
      XCloseDisplay(L.Dpy);
    end;
  finally
    Lines.Free;
    L.Free;
  end;
end;

{$ENDIF}

function DispatchWindowsTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  Reader : TTargetReader;
  {$IFDEF MCP_X11}
  Runner : TX11Windows;
  {$ENDIF}
begin
  Result := Name = 'project_get_windows';
  if not Result then Exit;
  {$IF DEFINED(WINDOWS) OR DEFINED(MCP_X11)}
  Reader := TTargetReader.Create;
  try
    TThread.Synchronize(nil, @Reader.Read);
    if Reader.Target = '' then
    begin
      Ctx.Error := True; Ctx.Result := 'No active project'; Exit;
    end;
    {$IFDEF WINDOWS}
    GetWindows(Ctx, Reader.Target);
    {$ELSE}
    Runner := TX11Windows.Create;
    try
      Runner.Ctx    := @Ctx;
      Runner.Target := Reader.Target;
      TThread.Synchronize(nil, @Runner.Run);
    finally
      Runner.Free;
    end;
    {$ENDIF}
  finally
    Reader.Free;
  end;
  {$ELSE}
  Reader := nil;
  Ctx.Error  := True;
  Ctx.Result := 'project_get_windows works on Windows and X11 only for now';
  {$ENDIF}
end;

procedure RegisterWindowsSchemas(Tools: TJSONArray);
begin
  Tools.Add(MakeTool('project_get_windows',
    'See the running project (started with project_run or debug_run): its ' +
    'visible top-level windows as a tree, one line per windowed control: ' +
    'Class "text" x,y wxh, relative to the parent (on screen for a window). ' +
    'Controls without a window handle (TLabel, TSpeedButton, TShape, TImage, ' +
    'TBevel, other TGraphicControls) are not in the tree; image=true adds a ' +
    'PNG of each window, which shows them. On Linux (X11) only the top-level ' +
    'windows are listed (class, caption, position on screen, size), without the ' +
    'controls inside, and the image is copied from the screen. Not on macOS.',
    SCHEMA_GET_WINDOWS, MCP_ANN_RO));
end;

initialization
  RegisterMcpBlockingGroup(@DispatchWindowsTool);
  RegisterMcpSchemas(@RegisterWindowsSchemas);

end.
