{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpMarkdown;

{ Markdown to the HTML subset that TIpHtmlPanel renders (ADR-024).  Plain RTL, no IDE units.

  The input is untrusted: raw HTML is escaped, only http(s) links are emitted, and an image
  becomes an img only for a local path or a Base64 data: URI (lifted out as mcp-img:N).
  An unknown construct is escaped text, never an error. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils;

const
  MD_MAX_DEPTH  = 16;   { nesting of quotes, lists and emphasis }
  MD_MAX_IMAGES = 32;   { data: images lifted out of one document }

  { the look of Bootstrap 5: borders, shaded areas and inline code }
  MD_BORDER     = '#DEE2E6';
  MD_SHADE      = '#F8F9FA';
  MD_CODE_COLOR = '#D63384';

  { IPro reads tag selectors and whole-pixel margins: Bootstrap's 1rem under a block, half
    that under a heading }
  MD_STYLE =
    'h1,h2,h3,h4,h5,h6{margin-top:0px;margin-bottom:8px}' +
    'p{margin-top:0px;margin-bottom:16px}' +
    'ul{margin-top:0px;margin-bottom:16px}' +
    'ol{margin-top:0px;margin-bottom:16px}' +
    'table{margin-bottom:16px}' +
    'table.md{border:1px solid ' + MD_BORDER + '}';

type
  TMarkdownHtml = class
  private
    FImages : TStrings;
    FDepth  : Integer;
    FRefs   : TStringList;     { reference link definitions: 'label=url', label in lower case }
    FNotes  : TStringList;     { footnote definitions: 'id=text', id in lower case }
    FNoteOrder : TStringList;  { footnote ids in the order they are first used }
    FNoAuto : Integer;         { above 0: no bare URLs (inside a link's text) }
    FHeads  : TStringList;     { top-level headings: 'level' #2 'id' #2 'html', for [[_TOC_]] }
    FSlugs  : TStringList;     { the ids given to headings }
    FWantIds : Boolean;        { the text has a table of contents or a "#anchor" link }
    function NoteHeading(ALevel: Integer; const AHtml: string): string;
    function TocHtml: string;
    procedure CollectRefs(ALines: TStrings);
    function NotesHtml: string;
    function DefListHtml(ALines: TStrings; var I: Integer): string;
    function RefLinkAt(const S: string; P: Integer; out AText, AUrl, ATitle: string;
      out NextP: Integer): Boolean;
    function QuoteOut(AInner: TStringList): string;
    function Inline(const S: string): string;
    function ImageHtml(const AAlt, AUrl: string): string;
    function Blocks(ALines: TStrings; ATight: Boolean): string;
    function CodeBlockHtml(ALines: TStrings): string;
    function TableHtml(ALines: TStrings; var I: Integer): string;
    function ListHtml(ALines: TStrings; var I: Integer): string;
    function QuoteHtml(ALines: TStrings; var I: Integer): string;
  public
    { Items of AImages (when given) are 'type:base64', type is png, jpeg, gif or bmp; the
      index of an item is the N of the matching mcp-img:N in the HTML. }
    function ToHtml(const AMarkdown: string; AImages: TStrings = nil): string;
  end;

function MdEscape(const S: string): string;
function MdUrlScheme(const AUrl: string): string;

{ The length of a document less the Base64 payload of its data:image URIs, which have their
  own limit where a picture is decoded: the size a limit on "text" applies to. }
function MdTextSize(const AMarkdown: string): Integer;

implementation

const
  HardBreak = #1;

function ParseTitle(const ARest: string): string; forward;

function MdEscape(const S: string): string;
var
  I : Integer;
  B : TStringBuilder;
begin
  if (Pos('&', S) = 0) and (Pos('<', S) = 0) and (Pos('>', S) = 0) and (Pos('"', S) = 0) then
    Exit(S);
  B := TStringBuilder.Create;
  try
    for I := 1 to Length(S) do
      case S[I] of
        '&': B.Append('&amp;');
        '<': B.Append('&lt;');
        '>': B.Append('&gt;');
        '"': B.Append('&quot;');
      else
        B.Append(S[I]);
      end;
    Result := B.ToString;
  finally
    B.Free;
  end;
end;

{ '' for a relative path or a drive letter path ("C:\x"), else the lowercase scheme }
function MdUrlScheme(const AUrl: string): string;
var
  I : Integer;
begin
  Result := '';
  if (AUrl = '') or not (AUrl[1] in ['A'..'Z', 'a'..'z']) then Exit;
  I := 2;
  while (I <= Length(AUrl)) and (AUrl[I] in ['A'..'Z', 'a'..'z', '0'..'9', '+', '.', '-']) do
    Inc(I);
  if (I <= Length(AUrl)) and (AUrl[I] = ':') and (I > 2) then
    Result := LowerCase(Copy(AUrl, 1, I - 1));
end;

function MdTextSize(const AMarkdown: string): Integer;
var
  P, Q, E, N : Integer;
begin
  N := Length(AMarkdown);
  Result := N;
  P := 1;
  while P <= N - 11 do
  begin
    if (AMarkdown[P] in ['d', 'D']) and (CompareText(Copy(AMarkdown, P, 11), 'data:image/') = 0) then
    begin
      Q := P + 11;
      E := Q;
      while (E <= N) and (E < Q + 30) and (AMarkdown[E] <> ',') and (AMarkdown[E] > ' ') do
        Inc(E);
      if (E <= N) and (AMarkdown[E] = ',') and
         (Pos(';base64', LowerCase(Copy(AMarkdown, Q, E - Q))) > 0) then
      begin
        Inc(E);
        Q := E;
        while (E <= N) and (AMarkdown[E] in ['A'..'Z', 'a'..'z', '0'..'9', '+', '/', '=']) do
          Inc(E);
        Dec(Result, E - Q);
        P := E;
        Continue;
      end;
    end;
    Inc(P);
  end;
end;

function IsSafeHttp(const AUrl: string): Boolean;
var
  S : string;
  I : Integer;
begin
  S := LowerCase(Copy(AUrl, 1, 8));
  Result := (Copy(S, 1, 7) = 'http://') or (S = 'https://');
  if not Result then Exit;
  if Length(AUrl) > 2048 then Exit(False);
  for I := 1 to Length(AUrl) do
    if AUrl[I] <= ' ' then Exit(False);
end;

function LeadingSpaces(const S: string): Integer;
begin
  Result := 0;
  while (Result < Length(S)) and (S[Result + 1] = ' ') do
    Inc(Result);
end;

function IsBlank(const S: string): Boolean;
begin
  Result := Trim(S) = '';
end;

function IsHr(const S: string): Boolean;
var
  T : string;
  I, N : Integer;
  C : Char;
begin
  Result := False;
  T := Trim(S);
  if (Length(T) < 3) or (LeadingSpaces(S) > 3) or not (T[1] in ['-', '*', '_']) then Exit;
  C := T[1];
  N := 0;
  for I := 1 to Length(T) do
    if T[I] = C then Inc(N)
    else if T[I] <> ' ' then Exit;
  Result := N >= 3;
end;

function IsFenceStart(const S: string; out AChar: Char; out ALen: Integer): Boolean;
var
  T : string;
begin
  Result := False;
  if LeadingSpaces(S) > 3 then Exit;
  T := TrimLeft(S);
  if (Length(T) < 3) or not (T[1] in ['`', '~']) then Exit;
  AChar := T[1];
  ALen := 0;
  while (ALen < Length(T)) and (T[ALen + 1] = AChar) do Inc(ALen);
  Result := ALen >= 3;
  { an info string of a backtick fence holds no backtick; else it was inline code }
  if Result and (AChar = '`') and (Pos('`', Copy(T, ALen + 1, MaxInt)) > 0) then
    Result := False;
end;

function IsFenceEnd(const S: string; AChar: Char; ALen: Integer): Boolean;
var
  T : string;
  I : Integer;
begin
  T := Trim(S);
  Result := Length(T) >= ALen;
  if not Result then Exit;
  for I := 1 to Length(T) do
    if T[I] <> AChar then Exit(False);
end;

function IsHeading(const S: string; out ALevel: Integer; out AText: string): Boolean;
var
  T, Closed : string;
begin
  Result := False;
  if LeadingSpaces(S) > 3 then Exit;
  T := Trim(S);
  ALevel := 0;
  while (ALevel < Length(T)) and (T[ALevel + 1] = '#') do Inc(ALevel);
  if (ALevel < 1) or (ALevel > 6) then Exit;
  if (Length(T) > ALevel) and (T[ALevel + 1] <> ' ') then Exit;
  AText := Trim(Copy(T, ALevel + 1, MaxInt));
  { a closing run of #s counts only when a space (or nothing) precedes it: "foo#" keeps it }
  Closed := AText;
  while (Closed <> '') and (Closed[Length(Closed)] = '#') do Delete(Closed, Length(Closed), 1);
  if (Closed = '') or (Closed[Length(Closed)] = ' ') then AText := Trim(Closed);
  Result := True;
end;

function IsQuote(const S: string): Boolean;
begin
  Result := (LeadingSpaces(S) <= 3) and (Copy(TrimLeft(S), 1, 1) = '>');
end;

{ A list marker: "-", "*", "+" or "12." / "12)" followed by a space.  AContentCol is the
  column (0-based) where the item's text starts. }
function ListMarker(const S: string; out AIndent, AContentCol: Integer;
  out AOrdered: Boolean; out ANum: Integer): Boolean;
var
  P, D : Integer;
  Spaces : Integer;
begin
  Result := False;
  AIndent := LeadingSpaces(S);
  P := AIndent + 1;
  if P > Length(S) then Exit;
  AOrdered := False;
  ANum := 0;
  if S[P] in ['-', '*', '+'] then
    Inc(P)
  else if S[P] in ['0'..'9'] then
  begin
    D := 0;
    while (P <= Length(S)) and (S[P] in ['0'..'9']) and (D < 9) do
    begin
      ANum := ANum * 10 + Ord(S[P]) - 48;
      Inc(P);
      Inc(D);
    end;
    if (P > Length(S)) or not (S[P] in ['.', ')']) then Exit;
    AOrdered := True;
    Inc(P);
  end
  else
    Exit;
  if P > Length(S) then
  begin
    AContentCol := P - 1 + 1;
    Exit(True);                      { an empty item }
  end;
  if S[P] <> ' ' then Exit;
  Spaces := 0;
  while (P + Spaces <= Length(S)) and (S[P + Spaces] = ' ') do Inc(Spaces);
  if Spaces > 4 then Spaces := 1;    { indented code after the marker }
  AContentCol := P - 1 + Spaces;
  Result := True;
end;

function ListMarkerSimple(const S: string): Boolean;
var
  A, B : Integer;
  O : Boolean;
  N : Integer;
begin
  Result := ListMarker(S, A, B, O, N) and not IsHr(S);
end;

{ ── Table helpers ────────────────────────────────────────────────────────── }

procedure SplitRow(const ALine: string; ACells: TStrings);
var
  T, Cur : string;
  I : Integer;
begin
  ACells.Clear;
  T := Trim(ALine);
  if (T <> '') and (T[1] = '|') then Delete(T, 1, 1);
  if (T <> '') and (T[Length(T)] = '|') and
     ((Length(T) < 2) or (T[Length(T) - 1] <> '\')) then
    Delete(T, Length(T), 1);
  Cur := '';
  I := 1;
  while I <= Length(T) do
  begin
    if (T[I] = '\') and (I < Length(T)) and (T[I + 1] = '|') then
    begin
      Cur := Cur + '|';
      Inc(I, 2);
    end
    else if T[I] = '|' then
    begin
      ACells.Add(Trim(Cur));
      Cur := '';
      Inc(I);
    end
    else
    begin
      Cur := Cur + T[I];
      Inc(I);
    end;
  end;
  ACells.Add(Trim(Cur));
end;

function IsSeparatorRow(const ALine: string): Boolean;
var
  Cells : TStringList;
  I, J : Integer;
  C : string;
begin
  Result := False;
  if Pos('|', ALine) = 0 then Exit;
  Cells := TStringList.Create;
  try
    SplitRow(ALine, Cells);
    for I := 0 to Cells.Count - 1 do
    begin
      C := Cells[I];
      if C = '' then Exit;
      if C[1] = ':' then Delete(C, 1, 1);
      if (C <> '') and (C[Length(C)] = ':') then Delete(C, Length(C), 1);
      if C = '' then Exit;
      for J := 1 to Length(C) do
        if C[J] <> '-' then Exit;
    end;
    Result := True;
  finally
    Cells.Free;
  end;
end;

function IsTableStart(ALines: TStrings; I: Integer): Boolean;
begin
  Result := (I + 1 < ALines.Count) and (Pos('|', ALines[I]) > 0) and
            IsSeparatorRow(ALines[I + 1]);
end;

{ Anything that ends a paragraph }
function StartsBlock(ALines: TStrings; I: Integer): Boolean;
var
  Ch : Char;
  Len, Lv, A, B, N : Integer;
  T : string;
  O : Boolean;
begin
  Result := IsFenceStart(ALines[I], Ch, Len) or IsHeading(ALines[I], Lv, T) or
            IsHr(ALines[I]) or IsQuote(ALines[I]) or IsTableStart(ALines, I);
  if Result then Exit;
  if ListMarker(ALines[I], A, B, O, N) and (not O or (N = 1)) and
     (Trim(ALines[I]) <> '') then
    Result := True;
end;

{ A line of "=" (heading 1) or "-" (heading 2) under a paragraph.  ALevel is set only when True. }
function IsSetextLine(const S: string; out ALevel: Integer): Boolean;
var
  T : string;
  I : Integer;
begin
  Result := False;
  if LeadingSpaces(S) > 3 then Exit;
  T := Trim(S);
  if (T = '') or not (T[1] in ['=', '-']) then Exit;
  for I := 1 to Length(T) do
    if T[I] <> T[1] then Exit;
  if T[1] = '=' then ALevel := 1 else ALevel := 2;
  Result := True;
end;

{ GitLab's multiline quote: a line with ">>>" alone opens it, the next one closes it }
function IsMultiQuoteFence(const S: string): Boolean;
begin
  Result := (LeadingSpaces(S) <= 3) and (Trim(S) = '>>>');
end;

{ YAML front matter ("---" ... "---" at the very top, with a "key:" line in it) is shown as a
  code block, as GitLab shows it in a box, not read as a rule and a heading. }
procedure FrontMatterToCode(ALines: TStrings);
var
  I, E : Integer;
  HasKey : Boolean;
begin
  if (ALines.Count < 3) or (Trim(ALines[0]) <> '---') then Exit;
  E := 0;
  HasKey := False;
  for I := 1 to ALines.Count - 1 do
  begin
    if I > 60 then Exit;
    if Trim(ALines[I]) = '---' then begin E := I; Break; end;
    if (not HasKey) and (Trim(ALines[I]) <> '') then
      HasKey := (Pos(':', ALines[I]) > 1) and (LeadingSpaces(ALines[I]) = 0);
  end;
  if (E = 0) or not HasKey then Exit;
  ALines[0] := '~~~~~~~~';
  ALines[E] := '~~~~~~~~';
end;

{ HTML comments are not shown, as in GitLab.  A comment may run over several lines; one that is
  not closed runs to the end.  Fenced code keeps its lines, and "<!--" after an odd number of
  backticks on its line is inside inline code. }
procedure StripComments(ALines: TStrings);
var
  I, K, P, E, J, Ticks, FLen : Integer;
  FCh : Char;
  InFence, InComment : Boolean;
  L : string;
  B : TStringBuilder;
begin
  InFence := False;
  InComment := False;
  FCh := '`';
  FLen := 3;
  for I := 0 to ALines.Count - 1 do
  begin
    L := ALines[I];
    if InComment then
    begin
      E := Pos('-->', L);
      if E = 0 then
      begin
        ALines[I] := '';
        Continue;
      end;
      L := Copy(L, E + 3, MaxInt);
      InComment := False;
    end
    else
    begin
      if InFence then
      begin
        if IsFenceEnd(L, FCh, FLen) then InFence := False;
        Continue;
      end;
      if IsFenceStart(L, FCh, FLen) then
      begin
        InFence := True;
        Continue;
      end;
    end;
    if Pos('<!--', L) = 0 then
    begin
      ALines[I] := L;
      Continue;
    end;
    B := TStringBuilder.Create;
    try
      K := 1;
      Ticks := 0;
      while K <= Length(L) do
      begin
        P := PosEx('<!--', L, K);
        if P = 0 then
        begin
          B.Append(Copy(L, K, MaxInt));
          Break;
        end;
        for J := K to P - 1 do
          if L[J] = '`' then Inc(Ticks);
        B.Append(Copy(L, K, P - K));
        if Odd(Ticks) then
        begin
          B.Append('<!--');
          K := P + 4;
          Continue;
        end;
        E := PosEx('-->', L, P + 4);
        if E = 0 then
        begin
          InComment := True;
          Break;
        end;
        K := E + 3;
      end;
      ALines[I] := B.ToString;
    finally
      B.Free;
    end;
  end;
end;

{ "{width=50% height=20}" right after an image: ' width="50%" height="20"'.  Classes (".float-left")
  are taken and ignored.  Anything else leaves NextP = P: the braces stay text. }
function ParseImageSize(const S: string; P: Integer; out NextP: Integer): string;
var
  E, I, V, Digits : Integer;
  T, Tok, Key, Val : string;
  Pct : Boolean;
begin
  Result := '';
  NextP := P;
  if (P > Length(S)) or (S[P] <> '{') then Exit;
  E := PosEx('}', S, P + 1);
  if (E = 0) or (E - P > 60) then Exit;
  T := Trim(Copy(S, P + 1, E - P - 1));
  if T = '' then Exit;
  while T <> '' do
  begin
    I := Pos(' ', T);
    if I = 0 then I := Length(T) + 1;
    Tok := Copy(T, 1, I - 1);
    T := TrimLeft(Copy(T, I + 1, MaxInt));
    if Tok[1] = '.' then Continue;
    I := Pos('=', Tok);
    if I < 2 then Exit('');
    Key := LowerCase(Copy(Tok, 1, I - 1));
    Val := LowerCase(Copy(Tok, I + 1, MaxInt));
    if (Key <> 'width') and (Key <> 'height') then Exit('');
    Pct := (Val <> '') and (Val[Length(Val)] = '%');
    if Pct then Delete(Val, Length(Val), 1)
    else if (Length(Val) > 2) and (Copy(Val, Length(Val) - 1, 2) = 'px') then
      Delete(Val, Length(Val) - 1, 2);
    Digits := Length(Val);
    if (Digits < 1) or (Digits > 4) then Exit('');
    V := 0;
    for I := 1 to Digits do
    begin
      if not (Val[I] in ['0'..'9']) then Exit('');
      V := V * 10 + Ord(Val[I]) - 48;
    end;
    if V < 1 then Exit('');
    if Pct and (V > 100) then Exit('');
    Result := Result + ' ' + Key + '="' + IntToStr(V);
    if Pct then Result := Result + '%';
    Result := Result + '"';
  end;
  NextP := E + 1;
end;

{ The emoji of a shortcode (:name:) as UTF-8: a curated set of the common ones.  GitLab knows
  far more; an unknown name stays as typed. }
function EmojiText(const AName: string): string;
const
  Table : array[0..127] of string = (
    'smile=1F604', 'smiley=1F603', 'grinning=1F600', 'laughing=1F606', 'joy=1F602',
    'wink=1F609', 'blush=1F60A', 'heart_eyes=1F60D', 'sunglasses=1F60E', 'thinking=1F914',
    'thinking_face=1F914', 'neutral_face=1F610', 'confused=1F615', 'cry=1F622', 'sob=1F62D',
    'angry=1F620', 'scream=1F631', 'sweat_smile=1F605', 'slightly_smiling_face=1F642',
    'upside_down_face=1F643', 'hugs=1F917', 'shrug=1F937', 'facepalm=1F926',
    '+1=1F44D', 'thumbsup=1F44D', '-1=1F44E', 'thumbsdown=1F44E', 'clap=1F44F', 'pray=1F64F',
    'muscle=1F4AA', 'ok_hand=1F44C', 'wave=1F44B', 'point_right=1F449', 'point_left=1F448',
    'point_up=261D,FE0F', 'point_down=1F447', 'raised_hands=1F64C', 'eyes=1F440',
    'heart=2764,FE0F', 'broken_heart=1F494', 'green_heart=1F49A', 'blue_heart=1F499',
    'yellow_heart=1F49B', 'star=2B50', 'star2=1F31F', 'sparkles=2728', 'fire=1F525',
    'boom=1F4A5', 'zap=26A1', 'tada=1F389', 'rocket=1F680', '100=1F4AF', 'trophy=1F3C6',
    'gift=1F381', 'bulb=1F4A1', 'warning=26A0,FE0F', 'x=274C', 'white_check_mark=2705',
    'heavy_check_mark=2714,FE0F', 'heavy_multiplication_x=2716,FE0F', 'question=2753',
    'exclamation=2757', 'grey_question=2754', 'information_source=2139,FE0F',
    'no_entry=26D4', 'no_entry_sign=1F6AB', 'construction=1F6A7', 'memo=1F4DD', 'book=1F4D6',
    'books=1F4DA', 'bug=1F41B', 'wrench=1F527', 'hammer=1F528', 'gear=2699,FE0F',
    'lock=1F512', 'unlock=1F513', 'key=1F511', 'link=1F517', 'mag=1F50D', 'package=1F4E6',
    'bell=1F514', 'hourglass=231B', 'calendar=1F4C6', 'chart_with_upwards_trend=1F4C8',
    'chart_with_downwards_trend=1F4C9', 'clipboard=1F4CB', 'pushpin=1F4CC', 'paperclip=1F4CE',
    'email=1F4E7', 'envelope=2709,FE0F', 'arrow_right=27A1,FE0F', 'arrow_left=2B05,FE0F',
    'arrow_up=2B06,FE0F', 'arrow_down=2B07,FE0F', 'heavy_plus_sign=2795',
    'heavy_minus_sign=2796', 'red_circle=1F534', 'large_blue_circle=1F535',
    'white_circle=26AA', 'black_circle=26AB', 'coffee=2615', 'beer=1F37A', 'pizza=1F355',
    'cake=1F370', 'monkey=1F412', 'see_no_evil=1F648', 'skull=1F480', 'ghost=1F47B',
    'robot=1F916', 'cat=1F431', 'dog=1F436', 'snake=1F40D', 'turtle=1F422', 'whale=1F433',
    'bee=1F41D', 'sunny=2600,FE0F', 'cloud=2601,FE0F', 'snowflake=2744,FE0F',
    'rainbow=1F308', 'truck=1F69A', 'car=1F697', 'airplane=2708,FE0F', 'ship=1F6A2',
    'hammer_and_wrench=1F6E0,FE0F', 'rotating_light=1F6A8', 'checkered_flag=1F3C1',
    'closed_lock_with_key=1F510', 'wastebasket=1F5D1,FE0F');
var
  I, P, J : Integer;
  Hex, Part : string;

  function Utf8(ACode: LongWord): string;
  begin
    if ACode < $800 then Result := Chr($C0 or (ACode shr 6)) + Chr($80 or (ACode and $3F))
    else if ACode < $10000 then
      Result := Chr($E0 or (ACode shr 12)) + Chr($80 or ((ACode shr 6) and $3F)) + Chr($80 or (ACode and $3F))
    else
      Result := Chr($F0 or (ACode shr 18)) + Chr($80 or ((ACode shr 12) and $3F)) +
                Chr($80 or ((ACode shr 6) and $3F)) + Chr($80 or (ACode and $3F));
  end;

begin
  Result := '';
  for I := 0 to High(Table) do
  begin
    P := Pos('=', Table[I]);
    if Copy(Table[I], 1, P - 1) <> AName then Continue;
    Hex := Copy(Table[I], P + 1, MaxInt);
    while Hex <> '' do
    begin
      J := Pos(',', Hex);
      if J = 0 then J := Length(Hex) + 1;
      Part := Copy(Hex, 1, J - 1);
      Hex := Copy(Hex, J + 1, MaxInt);
      Result := Result + Utf8(LongWord(StrToInt('$' + Part)));
    end;
    Exit;
  end;
end;

{ A link to a heading of the same document: "#some-heading" }
function IsAnchorRef(const AUrl: string): Boolean;
var
  I : Integer;
begin
  Result := (Length(AUrl) >= 2) and (Length(AUrl) <= 120) and (AUrl[1] = '#');
  if not Result then Exit;
  for I := 2 to Length(AUrl) do
    if (AUrl[I] <= ' ') or (AUrl[I] in ['"', '<', '>', '#']) then Exit(False);
end;

{ GitLab's table of contents: "[[_TOC_]]" or "[TOC]" alone on a line }
function IsTocLine(const S: string): Boolean;
var
  T : string;
begin
  Result := False;
  if LeadingSpaces(S) > 3 then Exit;
  T := UpperCase(Trim(S));
  Result := (T = '[[_TOC_]]') or (T = '[TOC]');
end;

{ ": definition" of a description list }
function IsDefLine(const S: string): Boolean;
begin
  Result := (LeadingSpaces(S) <= 3) and (Copy(TrimLeft(S), 1, 2) = ': ');
end;

{ [label]: url "title" }
function ParseRefDef(const S: string; out ALabel, AUrl, ATitle: string): Boolean;
var
  T, Rest : string;
  P, Q : Integer;
begin
  Result := False;
  ATitle := '';
  if LeadingSpaces(S) > 3 then Exit;
  T := Trim(S);
  if (Length(T) < 5) or (T[1] <> '[') then Exit;
  P := Pos(']:', T);
  if P < 3 then Exit;
  ALabel := LowerCase(Trim(Copy(T, 2, P - 2)));
  { "[^1]:" is a footnote; "=" would break the name=value list }
  if (ALabel = '') or (ALabel[1] = '^') or (Pos('[', ALabel) > 0) or (Pos('=', ALabel) > 0) then
    Exit;
  T := Trim(Copy(T, P + 2, MaxInt));
  if T = '' then Exit;
  if T[1] = '<' then
  begin
    Q := Pos('>', T);
    if Q = 0 then Exit;
    AUrl := Copy(T, 2, Q - 2);
  end
  else
  begin
    Q := 1;
    while (Q <= Length(T)) and (T[Q] > ' ') do Inc(Q);
    Dec(Q);
    AUrl := Copy(T, 1, Q);
  end;
  Rest := Trim(Copy(T, Q + 1, MaxInt));
  { only a quoted title may follow: else it is ordinary text that starts with "[x]:" }
  if (Rest <> '') and not (Rest[1] in ['"', '''', '(']) then Exit;
  ATitle := ParseTitle(Rest);
  Result := AUrl <> '';
end;

{ [^id]: text, one line.  The id has no spaces or brackets. }
function ParseNoteDef(const S: string; out AId, AText: string): Boolean;
var
  T : string;
  P, I : Integer;
begin
  Result := False;
  if LeadingSpaces(S) > 3 then Exit;
  T := Trim(S);
  if (Length(T) < 6) or (Copy(T, 1, 2) <> '[^') then Exit;
  P := Pos(']:', T);
  if (P < 4) or (P > 42) then Exit;
  AId := LowerCase(Copy(T, 3, P - 3));
  for I := 1 to Length(AId) do
    if (AId[I] <= ' ') or (AId[I] in ['[', ']', '=']) then Exit;
  AText := Trim(Copy(T, P + 2, MaxInt));
  Result := AText <> '';
end;

{ The text of an entity (&amp; &#35; &#x23;) as UTF-8, or '' when it is none we know. }
function EntityText(const AName: string): string;
const
  Names : array[0..29] of string = ('amp', 'lt', 'gt', 'quot', 'apos', 'nbsp', 'copy', 'reg',
    'trade', 'hellip', 'mdash', 'ndash', 'laquo', 'raquo', 'euro', 'larr', 'rarr', 'uarr',
    'darr', 'bull', 'middot', 'times', 'divide', 'deg', 'plusmn', 'para', 'sect', 'pound',
    'yen', 'cent');
  Codes : array[0..29] of LongWord = (38, 60, 62, 34, 39, 160, 169, 174, 8482, 8230, 8212, 8211,
    171, 187, 8364, 8592, 8594, 8593, 8595, 8226, 183, 215, 247, 176, 177, 182, 167, 163, 165,
    162);
var
  Code : LongWord;
  I, First, Base : Integer;
  Hex : Boolean;
begin
  Result := '';
  Code := 0;
  if (AName <> '') and (AName[1] = '#') then
  begin
    Hex := (Length(AName) > 2) and (AName[2] in ['x', 'X']);
    if Hex then begin First := 3; Base := 16; end else begin First := 2; Base := 10; end;
    if (First > Length(AName)) or (Length(AName) - First + 1 > 7) then Exit;
    for I := First to Length(AName) do
    begin
      if AName[I] in ['0'..'9'] then Code := Code * LongWord(Base) + LongWord(Ord(AName[I]) - 48)
      else if Hex and (AName[I] in ['a'..'f']) then Code := Code * 16 + LongWord(Ord(AName[I]) - 87)
      else if Hex and (AName[I] in ['A'..'F']) then Code := Code * 16 + LongWord(Ord(AName[I]) - 55)
      else Exit;
    end;
  end
  else
  begin
    for I := 0 to High(Names) do
      if AName = Names[I] then Code := Codes[I];
    if Code = 0 then Exit;
  end;
  { no controls, no surrogates, nothing past Unicode }
  if (Code < 32) or ((Code >= $7F) and (Code < $A0)) or (Code > $10FFFF) or
     ((Code >= $D800) and (Code <= $DFFF)) then Exit;
  if Code < $80 then Result := Chr(Code)
  else if Code < $800 then Result := Chr($C0 or (Code shr 6)) + Chr($80 or (Code and $3F))
  else if Code < $10000 then
    Result := Chr($E0 or (Code shr 12)) + Chr($80 or ((Code shr 6) and $3F)) + Chr($80 or (Code and $3F))
  else
    Result := Chr($F0 or (Code shr 18)) + Chr($80 or ((Code shr 12) and $3F)) +
              Chr($80 or ((Code shr 6) and $3F)) + Chr($80 or (Code and $3F));
end;

{ Entities in a run of plain text become their characters (escaped again by the caller). }
function DecodeEntities(const S: string): string;
var
  B : TStringBuilder;
  I, J : Integer;
  T : string;
begin
  if Pos('&', S) = 0 then Exit(S);
  B := TStringBuilder.Create;
  try
    I := 1;
    while I <= Length(S) do
    begin
      if S[I] = '&' then
      begin
        J := I + 1;
        while (J <= Length(S)) and (J - I <= 9) and (S[J] <> ';') and (S[J] > ' ') and (S[J] <> '&') do
          Inc(J);
        if (J <= Length(S)) and (S[J] = ';') then
        begin
          T := EntityText(Copy(S, I + 1, J - I - 1));
          if T <> '' then
          begin
            B.Append(T);
            I := J + 1;
            Continue;
          end;
        end;
      end;
      B.Append(S[I]);
      Inc(I);
    end;
    Result := B.ToString;
  finally
    B.Free;
  end;
end;

{ A bare http(s):// address in running text; ALen is its length.  Trailing punctuation and an
  unmatched ")" are not part of it. }
function BareUrlAt(const S: string; P: Integer; out ALen: Integer): Boolean;
var
  N, E, L, Open, Close, I : Integer;
begin
  Result := False;
  ALen := 0;
  N := Length(S);
  if (P > 1) and (S[P - 1] in ['A'..'Z', 'a'..'z', '0'..'9']) then Exit;
  if SameText(Copy(S, P, 7), 'http://') then L := 7
  else if SameText(Copy(S, P, 8), 'https://') then L := 8
  else Exit;
  E := P + L;
  while (E <= N) and (S[E] > ' ') and not (S[E] in ['<', '>']) do Inc(E);
  while (E > P + L) and (S[E - 1] in ['.', ',', ':', ';', '!', '?', '"', '''', '*', '_', '~']) do
    Dec(E);
  Open := 0;
  Close := 0;
  for I := P to E - 1 do
    if S[I] = '(' then Inc(Open) else if S[I] = ')' then Inc(Close);
  if (Close > Open) and (S[E - 1] = ')') then Dec(E);
  ALen := E - P;
  Result := (ALen > L) and IsSafeHttp(Copy(S, P, ALen));
end;

{ ── The converter ────────────────────────────────────────────────────────── }

const
  MD_MAX_REFS = 256;
  TocMark = #3;         { stands for the table of contents until the headings are known }
  { task list boxes: U+2610 and U+2611 }
  MD_BOX_OPEN   = #$E2#$98#$90;
  MD_BOX_CHECKED = #$E2#$98#$91;

{ Reference definitions are taken out of the text before the blocks are read; a fenced block
  keeps its lines. }
procedure TMarkdownHtml.CollectRefs(ALines: TStrings);
var
  I, FLen : Integer;
  FCh : Char;
  InFence : Boolean;
  L, U, T : string;
begin
  I := 0;
  InFence := False;
  FCh := '`';
  FLen := 3;
  while I < ALines.Count do
  begin
    if InFence then
    begin
      if IsFenceEnd(ALines[I], FCh, FLen) then InFence := False;
      Inc(I);
    end
    else if IsFenceStart(ALines[I], FCh, FLen) then
    begin
      InFence := True;
      Inc(I);
    end
    else if ParseRefDef(ALines[I], L, U, T) then
    begin
      if (FRefs.Count < MD_MAX_REFS) and (FRefs.IndexOfName(L) < 0) then
        FRefs.Add(L + '=' + U + #2 + T);        { the title follows the address }
      ALines.Delete(I);
    end
    else if ParseNoteDef(ALines[I], L, U) then
    begin
      if (FNotes.Count < MD_MAX_REFS) and (FNotes.IndexOfName(L) < 0) then
        FNotes.Add(L + '=' + U);
      ALines.Delete(I);
    end
    else
      Inc(I);
  end;
end;

{ [text][label], [text][] and [label] at S[P] = '[', when the label is defined }
function TMarkdownHtml.RefLinkAt(const S: string; P: Integer; out AText, AUrl, ATitle: string;
  out NextP: Integer): Boolean;
var
  N, Q, R, Depth : Integer;
  Lbl, V : string;
begin
  Result := False;
  ATitle := '';
  if (FRefs = nil) or (FRefs.Count = 0) then Exit;
  N := Length(S);
  Depth := 0;
  Q := P;
  while (Q <= N) and (Q - P <= 2000) do       { a link's text is not longer than this }
  begin
    if S[Q] = '\' then begin Inc(Q, 2); Continue; end;
    if S[Q] = '[' then Inc(Depth)
    else if S[Q] = ']' then
    begin
      Dec(Depth);
      if Depth = 0 then Break;
    end;
    Inc(Q);
  end;
  if (Q > N) or (Q - P > 2000) then Exit;
  AText := Copy(S, P + 1, Q - P - 1);
  Lbl := AText;
  NextP := Q + 1;
  if (Q < N) and (S[Q + 1] = '[') then
  begin
    R := Q + 2;
    while (R <= N) and (S[R] <> ']') do Inc(R);
    if R > N then Exit;
    if R > Q + 2 then Lbl := Copy(S, Q + 2, R - Q - 2);
    NextP := R + 1;
  end;
  Q := FRefs.IndexOfName(LowerCase(Trim(Lbl)));
  if Q < 0 then Exit;
  V := FRefs.ValueFromIndex[Q];
  R := Pos(#2, V);
  AUrl := Copy(V, 1, R - 1);
  ATitle := Copy(V, R + 1, MaxInt);
  Result := True;
end;

{ GitLab's heading anchor: the text in lower case, spaces as "-", no punctuation }
function MdSlug(const AHtml: string): string;
var
  I, J : Integer;
  InTag : Boolean;
  C : Char;
begin
  Result := '';
  InTag := False;
  I := 1;
  while (I <= Length(AHtml)) and (Length(Result) < 100) do
  begin
    C := AHtml[I];
    if InTag then
    begin
      if C = '>' then InTag := False;
    end
    else if C = '<' then
      InTag := True
    else if C = '&' then
    begin
      J := PosEx(';', AHtml, I);              { an entity: skipped }
      if (J > 0) and (J - I <= 8) then I := J;
    end
    else if C in ['A'..'Z'] then
      Result := Result + Chr(Ord(C) + 32)
    else if (C in ['a'..'z', '0'..'9', '-', '_']) or (C >= #128) then
      Result := Result + C
    else if C = ' ' then
      Result := Result + '-';
    Inc(I);
  end;
end;

{ The same HTML without its links: a link may not sit inside the link of a table of contents }
function StripLinks(const S: string): string;
var
  B : TStringBuilder;
  I, J : Integer;
begin
  if Pos('<a ', S) = 0 then Exit(S);
  B := TStringBuilder.Create;
  try
    I := 1;
    while I <= Length(S) do
    begin
      if Copy(S, I, 3) = '<a ' then
      begin
        J := PosEx('>', S, I);
        if J = 0 then J := Length(S);
        I := J + 1;
      end
      else if Copy(S, I, 4) = '</a>' then
        Inc(I, 4)
      else
      begin
        B.Append(S[I]);
        Inc(I);
      end;
    end;
    Result := B.ToString;
  finally
    B.Free;
  end;
end;

{ Records a top-level heading for the table of contents and returns its id ('' when the text
  has no use for ids, or the heading is not top-level) }
function TMarkdownHtml.NoteHeading(ALevel: Integer; const AHtml: string): string;
var
  Base : string;
  N : Integer;
begin
  Result := '';
  if (FDepth <> 0) or (FHeads.Count >= 500) or not FWantIds then Exit;
  Base := MdSlug(AHtml);
  if Base = '' then Base := 'section';
  Result := Base;
  N := 0;
  while FSlugs.IndexOf(Result) >= 0 do
  begin
    Inc(N);
    Result := Base + '-' + IntToStr(N);
  end;
  FSlugs.Add(Result);
  FHeads.Add(IntToStr(ALevel) + #2 + Result + #2 + AHtml);
end;

{ The headings of the document as nested bulleted lists: [[_TOC_]] and [TOC] (GitLab).  A jump
  of more than one level counts as one, so every list sits inside an item. }
function TMarkdownHtml.TocHtml: string;
var
  B : TStringBuilder;
  I, Lv, Base, D, T, P, Q : Integer;
  Item, Id : string;
begin
  Result := '';
  if FHeads.Count = 0 then Exit;
  Base := 6;
  for I := 0 to FHeads.Count - 1 do
  begin
    Lv := StrToIntDef(Copy(FHeads[I], 1, Pos(#2, FHeads[I]) - 1), 1);
    if Lv < Base then Base := Lv;
  end;
  B := TStringBuilder.Create;
  try
    D := 0;
    for I := 0 to FHeads.Count - 1 do
    begin
      P := Pos(#2, FHeads[I]);
      Lv := StrToIntDef(Copy(FHeads[I], 1, P - 1), 1);
      Q := PosEx(#2, FHeads[I], P + 1);
      Id := Copy(FHeads[I], P + 1, Q - P - 1);
      Item := '<a href="#' + MdEscape(Id) + '">' + StripLinks(Copy(FHeads[I], Q + 1, MaxInt)) + '</a>';
      T := Lv - Base + 1;
      if T > D + 1 then T := D + 1;
      if D = T then
        B.Append('</li>')
      else if D < T then
      begin
        B.Append('<ul>');
        Inc(D);
      end
      else
      begin
        while D > T do
        begin
          B.Append('</li></ul>');
          Dec(D);
        end;
        B.Append('</li>');
      end;
      B.Append('<li>').Append(Item);
    end;
    while D > 0 do
    begin
      B.Append('</li></ul>');
      Dec(D);
    end;
    Result := B.ToString;
  finally
    B.Free;
  end;
end;

{ The footnotes used, as a numbered list under a rule, in the order they were first cited. }
function TMarkdownHtml.NotesHtml: string;
var
  B : TStringBuilder;
  I : Integer;
begin
  Result := '';
  if FNoteOrder.Count = 0 then Exit;
  B := TStringBuilder.Create;
  try
    B.Append('<hr><ol>');
    I := 0;
    while I < FNoteOrder.Count do         { the text of a note may cite another }
    begin
      B.Append('<li>').Append(Inline(FNotes.Values[FNoteOrder[I]])).Append('</li>');
      Inc(I);
    end;
    B.Append('</ol>');
    Result := B.ToString;
  finally
    B.Free;
  end;
end;

{ term, then one or more ": definition" lines; more such groups may follow }
function TMarkdownHtml.DefListHtml(ALines: TStrings; var I: Integer): string;
var
  B : TStringBuilder;
  K : Integer;
begin
  B := TStringBuilder.Create;
  try
    B.Append('<dl>');
    repeat
      B.Append('<dt><strong>').Append(Inline(Trim(ALines[I]))).Append('</strong></dt>');
      Inc(I);
      while (I < ALines.Count) and IsDefLine(ALines[I]) do
      begin
        B.Append('<dd>').Append(Inline(Trim(Copy(TrimLeft(ALines[I]), 2, MaxInt)))).Append('</dd>');
        Inc(I);
      end;
      K := I;
      while (K < ALines.Count) and IsBlank(ALines[K]) do Inc(K);
      if (K + 1 < ALines.Count) and not IsDefLine(ALines[K]) and (Trim(ALines[K]) <> '') and
         IsDefLine(ALines[K + 1]) then
        I := K
      else
        Break;
    until False;
    B.Append('</dl>');
    Result := B.ToString;
  finally
    B.Free;
  end;
end;

{ [text](url) at S[P] = '['; NextP is the position after the closing parenthesis }
{ A title: "text", 'text' or (text); '' when Rest is anything else }
function ParseTitle(const ARest: string): string;
var
  T : string;
begin
  Result := '';
  T := Trim(ARest);
  if Length(T) < 2 then Exit;
  if ((T[1] = '"') and (T[Length(T)] = '"')) or ((T[1] = '''') and (T[Length(T)] = '''')) or
     ((T[1] = '(') and (T[Length(T)] = ')')) then
    Result := Copy(T, 2, Length(T) - 2);
end;

function ParseLinkAt(const S: string; P: Integer; out AText, AUrl, ATitle: string;
  out NextP: Integer): Boolean;
var
  N, Q, R, Depth : Integer;
  Raw : string;
begin
  Result := False;
  ATitle := '';
  N := Length(S);
  Depth := 0;
  Q := P;
  while (Q <= N) and (Q - P <= 2000) do       { a link's text is not longer than this }
  begin
    if S[Q] = '\' then begin Inc(Q, 2); Continue; end;
    if S[Q] = '[' then Inc(Depth)
    else if S[Q] = ']' then
    begin
      Dec(Depth);
      if Depth = 0 then Break;
    end;
    Inc(Q);
  end;
  if (Q > N) or (Q - P > 2000) or (Q + 1 > N) or (S[Q + 1] <> '(') then Exit;
  AText := Copy(S, P + 1, Q - P - 1);
  Depth := 1;
  R := Q + 2;
  while (R <= N) and (R - Q <= 2200) do        { the address and title: 2048 and some room }
  begin
    if S[R] = '\' then begin Inc(R, 2); Continue; end;
    if S[R] = '(' then Inc(Depth)
    else if S[R] = ')' then
    begin
      Dec(Depth);
      if Depth = 0 then Break;
    end;
    Inc(R);
  end;
  if (R > N) or (R - Q > 2200) then Exit;
  Raw := Trim(Copy(S, Q + 2, R - Q - 2));
  if (Raw <> '') and (Raw[1] = '<') and (Pos('>', Raw) > 0) then
  begin
    AUrl := Copy(Raw, 2, Pos('>', Raw) - 2);
    ATitle := ParseTitle(Copy(Raw, Pos('>', Raw) + 1, MaxInt));
  end
  else
  begin
    Q := 1;
    while (Q <= Length(Raw)) and (Raw[Q] > ' ') do Inc(Q);
    AUrl := Copy(Raw, 1, Q - 1);
    ATitle := ParseTitle(Copy(Raw, Q, MaxInt));
  end;
  NextP := R + 1;
  Result := True;
end;

function TMarkdownHtml.ImageHtml(const AAlt, AUrl: string): string;
var
  Alt, Scheme, L, Kind, Payload : string;
  P, I : Integer;
  Ok : Boolean;
begin
  Alt := Trim(AAlt);
  if Alt = '' then Alt := 'image';
  Scheme := MdUrlScheme(AUrl);
  if Scheme = 'data' then
  begin
    L := LowerCase(Copy(AUrl, 1, 40));
    Kind := '';
    if Copy(L, 1, 11) = 'data:image/' then
    begin
      P := Pos(';base64,', L);
      if P > 12 then
      begin
        Kind := Copy(L, 12, P - 12);
        if not ((Kind = 'png') or (Kind = 'jpeg') or (Kind = 'gif') or (Kind = 'bmp')) then
          Kind := '';
        if Kind <> '' then
        begin
          Payload := Copy(AUrl, P + 8, MaxInt);
          Ok := Payload <> '';
          for I := 1 to Length(Payload) do
            if not (Payload[I] in ['A'..'Z', 'a'..'z', '0'..'9', '+', '/', '=']) then
            begin
              Ok := False;
              Break;
            end;
          if Ok and Assigned(FImages) and (FImages.Count < MD_MAX_IMAGES) then
            Exit('<img src="mcp-img:' + IntToStr(FImages.Add(Kind + ':' + Payload)) +
                 '" alt="' + MdEscape(Alt) + '">');
        end;
      end;
    end;
    Exit(MdEscape('[' + Alt + ']'));
  end;
  if Scheme = '' then
  begin
    { a UNC path would make Windows try to log on to a model-named host }
    if (Copy(AUrl, 1, 2) = '\\') or (Copy(AUrl, 1, 2) = '//') or (AUrl = '') then
      Exit(MdEscape('[' + Alt + ']'));
    Exit('<img src="' + MdEscape(AUrl) + '" alt="' + MdEscape(Alt) + '">');
  end;
  if IsSafeHttp(AUrl) then
    Exit('<a href="' + MdEscape(AUrl) + '">' + MdEscape('[' + Alt + ']') + '</a>');
  Result := MdEscape('[' + Alt + ']');
end;

function TMarkdownHtml.Inline(const S: string): string;
var
  B : TStringBuilder;
  I, N, J, P, Run, Len, NextP, K : Integer;
  C : Char;
  Inner, Url, Text, Delim, Tag, Title, Lo, Failed : string;
  Found : Boolean;

  function IsAlnum(Ch: Char): Boolean;
  begin
    Result := Ch in ['A'..'Z', 'a'..'z', '0'..'9'];
  end;

  function AsciiLower(const T: string): string;
  var
    X : Integer;
  begin
    Result := T;
    for X := 1 to Length(Result) do
      if Result[X] in ['A'..'Z'] then Result[X] := Chr(Ord(Result[X]) + 32);
  end;

  { GitLab's inline diff: {+ added +}, [+ added +], {- removed -}, [- removed -] }
  function TryDiff: Boolean;
  var
    Sign, Close : Char;
    E : Integer;
  begin
    Result := False;
    if (I + 3 > N) or not (S[I + 1] in ['+', '-']) or (S[I + 2] <> ' ') then Exit;
    Sign := S[I + 1];
    if S[I] = '{' then Close := '}' else Close := ']';
    { a closer missing here is missing further on too: look once }
    if Pos('|' + Sign + Close + '|', Failed) > 0 then Exit;
    E := PosEx(' ' + Sign + Close, S, I + 3);
    if E = 0 then
    begin
      Failed := Failed + '|' + Sign + Close + '|';
      Exit;
    end;
    if Sign = '+' then
      B.Append('<font color="#198754"><u>').Append(Inline(Copy(S, I + 3, E - I - 3))).Append('</u></font>')
    else
      B.Append('<font color="#DC3545"><del>').Append(Inline(Copy(S, I + 3, E - I - 3))).Append('</del></font>');
    I := E + 3;
    Result := True;
  end;

begin
  if FDepth >= MD_MAX_DEPTH then
    Exit(StringReplace(MdEscape(S), HardBreak, '<br>', [rfReplaceAll]));
  Inc(FDepth);
  B := TStringBuilder.Create;
  try
    N := Length(S);
    I := 1;
    while I <= N do
    begin
      C := S[I];
      { a run of ordinary characters goes out in one piece }
      if (FNoAuto = 0) and (C in ['h', 'H']) and BareUrlAt(S, I, Len) then
      begin
        Url := Copy(S, I, Len);
        B.Append('<a href="' + MdEscape(Url) + '">' + MdEscape(Url) + '</a>');
        Inc(I, Len);
        Continue;
      end;
      if not (C in ['\', '`', '!', '[', '<', '*', '_', '~', '{', ':', HardBreak]) then
      begin
        J := I;
        while (J <= N) and not (S[J] in ['\', '`', '!', '[', '<', '*', '_', '~', '{', ':', HardBreak]) and
              not ((FNoAuto = 0) and (S[J] in ['h', 'H']) and (J > I) and BareUrlAt(S, J, Len)) do
          Inc(J);
        B.Append(MdEscape(DecodeEntities(Copy(S, I, J - I))));
        I := J;
        Continue;
      end;
      case C of
        HardBreak:
          begin
            B.Append('<br>');
            Inc(I);
          end;
        '\':
          if (I < N) and (S[I + 1] in ['!'..'/', ':'..'@', '['..'`', '{'..'~']) then
          begin
            B.Append(MdEscape(S[I + 1]));
            Inc(I, 2);
          end
          else
          begin
            B.Append('\');
            Inc(I);
          end;
        '`':
          begin
            Run := 0;
            while (I + Run <= N) and (S[I + Run] = '`') do Inc(Run);
            P := I + Run;
            Found := False;
            while P <= N do
            begin
              if S[P] = '`' then
              begin
                Len := 0;
                while (P + Len <= N) and (S[P + Len] = '`') do Inc(Len);
                if Len = Run then begin Found := True; Break; end;
                Inc(P, Len);
              end
              else
                Inc(P);
            end;
            if Found then
            begin
              Inner := Copy(S, I + Run, P - I - Run);
              if (Length(Inner) > 1) and (Inner[1] = ' ') and (Inner[Length(Inner)] = ' ') then
                Inner := Copy(Inner, 2, Length(Inner) - 2);
              Inner := StringReplace(MdEscape(Inner), ' ', '&nbsp;', [rfReplaceAll]);
              B.Append('<font color="' + MD_CODE_COLOR + '"><tt>' + Inner + '</tt></font>');
              I := P + Run;
            end
            else
            begin
              B.Append(StringOfChar('`', Run));
              Inc(I, Run);
            end;
          end;
        '!':
          if (I < N) and (S[I + 1] = '[') and
             (ParseLinkAt(S, I + 1, Text, Url, Title, NextP) or
              RefLinkAt(S, I + 1, Text, Url, Title, NextP)) then
          begin
            Tag := ImageHtml(Text, Url);
            { {width=50%}: only on a real img, not on a placeholder }
            Inner := ParseImageSize(S, NextP, K);
            if (Inner <> '') and (Copy(Tag, 1, 5) = '<img ') then
              Tag := Copy(Tag, 1, Length(Tag) - 1) + Inner + '>';
            B.Append(Tag);
            I := K;
          end
          else
          begin
            B.Append('!');
            Inc(I);
          end;
        ':':
          begin
            { :name: is an emoji when we know the name }
            Found := False;
            P := I + 1;
            while (P <= N) and (P - I <= 33) and (S[P] in ['a'..'z', '0'..'9', '_', '+', '-']) do
              Inc(P);
            if (P <= N) and (S[P] = ':') and (P > I + 1) then
            begin
              Inner := EmojiText(Copy(S, I + 1, P - I - 1));
              if Inner <> '' then
              begin
                B.Append(Inner);
                I := P + 1;
                Found := True;
              end;
            end;
            if not Found then
            begin
              B.Append(':');
              Inc(I);
            end;
          end;
        '{':
          if not TryDiff then
          begin
            B.Append('{');
            Inc(I);
          end;
        '[':
          begin
            Found := False;
            { a footnote reference [^id]: a small superscript number }
            if (I + 2 <= N) and (S[I + 1] = '^') and (FNotes.Count > 0) then
            begin
              P := PosEx(']', S, I + 2);
              if P > 0 then
              begin
                Tag := AsciiLower(Copy(S, I + 2, P - I - 2));
                if FNotes.IndexOfName(Tag) >= 0 then
                begin
                  K := FNoteOrder.IndexOf(Tag);
                  if K < 0 then K := FNoteOrder.Add(Tag);
                  B.Append('<sup>' + IntToStr(K + 1) + '</sup>');
                  I := P + 1;
                  Found := True;
                end;
              end;
            end;
            if not Found then Found := TryDiff;
            if not Found then
            begin
              if ParseLinkAt(S, I, Text, Url, Title, NextP) or
                 RefLinkAt(S, I, Text, Url, Title, NextP) then
              begin
                if IsSafeHttp(Url) or IsAnchorRef(Url) then
                begin
                  B.Append('<a href="' + MdEscape(Url) + '"');
                  if Title <> '' then B.Append(' title="' + MdEscape(Title) + '"');
                  B.Append('>');
                  Inc(FNoAuto);          { no link inside a link }
                  try
                    B.Append(Inline(Text));
                  finally
                    Dec(FNoAuto);
                  end;
                  B.Append('</a>');
                end
                else
                  B.Append(Inline(Text));
                I := NextP;
              end
              else
              begin
                B.Append('[');
                Inc(I);
              end;
            end;
          end;
        '<':
          begin
            P := Pos('>', Copy(S, I, 2100));
            { <kbd>, <sub>, <sup>: the only paired tags let through, and only when the closing
              one is there, so that a stray one cannot change the rest of the page }
            Tag := '';
            K := 0;
            if SameText(Copy(S, I, 5), '<kbd>') then Tag := 'kbd'
            else if SameText(Copy(S, I, 5), '<sub>') then Tag := 'sub'
            else if SameText(Copy(S, I, 5), '<sup>') then Tag := 'sup';
            if (Tag <> '') and (Pos('|' + Tag + '|', Failed) = 0) then
            begin
              if Lo = '' then Lo := AsciiLower(S);
              K := PosEx('</' + Tag + '>', Lo, I + 5);
              if K = 0 then Failed := Failed + '|' + Tag + '|';
            end;
            if K > 0 then
            begin
              B.Append('<' + Tag + '>').Append(Inline(Copy(S, I + 5, K - I - 5)))
               .Append('</' + Tag + '>');
              I := K + 6;
            end
            else if SameText(Copy(S, I, 4), '<br>') then
            begin
              B.Append('<br>');
              Inc(I, 4);
            end
            else if SameText(Copy(S, I, 5), '<br/>') then
            begin
              B.Append('<br>');
              Inc(I, 5);
            end
            else if SameText(Copy(S, I, 6), '<br />') then
            begin
              B.Append('<br>');
              Inc(I, 6);
            end
            else if (P > 0) and IsSafeHttp(Copy(S, I + 1, P - 2)) then
            begin
              Url := Copy(S, I + 1, P - 2);
              B.Append('<a href="' + MdEscape(Url) + '">' + MdEscape(Url) + '</a>');
              Inc(I, P);
            end
            else
            begin
              B.Append('&lt;');
              Inc(I);
            end;
          end;
        '*', '_', '~':
          begin
            Len := 1;
            if (I < N) and (S[I + 1] = C) then Len := 2;
            if (C = '~') and (Len = 1) then
            begin
              B.Append('~');
              Inc(I);
              Continue;
            end;
            Delim := StringOfChar(C, Len);
            Found := False;
            { opening: followed by non-space; for "_" not inside a word }
            if (I + Len <= N) and (S[I + Len] > ' ') and
               not ((C = '_') and (I > 1) and IsAlnum(S[I - 1])) then
            begin
              P := I + Len;
              while P <= N - Len + 1 do
              begin
                if S[P] = '\' then begin Inc(P, 2); Continue; end;
                if (S[P] = C) and (Copy(S, P, Len) = Delim) and (S[P - 1] > ' ') then
                begin
                  if (Len = 1) and (P < N) and (S[P + 1] = C) then
                  begin
                    Inc(P, 2);       { part of a longer run }
                    Continue;
                  end;
                  if (C = '_') and (P + Len <= N) and IsAlnum(S[P + Len]) then
                  begin
                    Inc(P);
                    Continue;
                  end;
                  Found := True;
                  Break;
                end;
                Inc(P);
              end;
            end;
            if Found then
            begin
              Inner := Copy(S, I + Len, P - I - Len);
              if C = '~' then Tag := 'del'
              else if Len = 2 then Tag := 'strong'
              else Tag := 'em';
              B.Append('<' + Tag + '>' + Inline(Inner) + '</' + Tag + '>');
              I := P + Len;
            end
            else
            begin
              B.Append(Delim);
              Inc(I, Len);
            end;
          end;
      end;
    end;
    Result := B.ToString;
  finally
    B.Free;
    Dec(FDepth);
  end;
end;

function TMarkdownHtml.CodeBlockHtml(ALines: TStrings): string;
var
  B : TStringBuilder;
  I : Integer;
  L : string;
begin
  B := TStringBuilder.Create;
  try
    { the frame's colour comes from the table.md rule of the style block }
    B.Append('<table class="md" width="100%" border="1" cellpadding="12" cellspacing="0">' +
             '<tr><td bgcolor="' + MD_SHADE + '">');
    for I := 0 to ALines.Count - 1 do
    begin
      L := StringReplace(MdEscape(ALines[I]), ' ', '&nbsp;', [rfReplaceAll]);
      if L = '' then L := '&nbsp;';
      B.Append('<tt>').Append(L).Append('</tt><br>');
    end;
    B.Append('</td></tr></table>');
    Result := B.ToString;
  finally
    B.Free;
  end;
end;

function TMarkdownHtml.TableHtml(ALines: TStrings; var I: Integer): string;
var
  B : TStringBuilder;
  Head, Sep, Row : TStringList;
  Align : array of string;
  Cols, K : Integer;
  S, A : string;

  procedure EmitRow(ACells: TStrings; const ATag: string);
  var
    C : Integer;
    Cell : string;
  begin
    B.Append('<tr>');
    for C := 0 to Cols - 1 do
    begin
      if C < ACells.Count then Cell := Inline(ACells[C]) else Cell := '';
      if Cell = '' then Cell := '&nbsp;';
      B.Append('<' + ATag);
      if Align[C] <> '' then B.Append(' align="' + Align[C] + '"');
      if ATag = 'th' then B.Append(' bgcolor="' + MD_SHADE + '"')
      else B.Append(' bgcolor="#FFFFFF"');
      B.Append('>' + Cell + '</' + ATag + '>');
    end;
    B.Append('</tr>');
  end;

begin
  B := TStringBuilder.Create;
  Head := TStringList.Create;
  Sep := TStringList.Create;
  Row := TStringList.Create;
  try
    SplitRow(ALines[I], Head);
    SplitRow(ALines[I + 1], Sep);
    Cols := Head.Count;
    SetLength(Align, Cols);
    for K := 0 to Cols - 1 do
    begin
      Align[K] := '';
      if K < Sep.Count then
      begin
        S := Sep[K];
        if (S <> '') and (S[1] = ':') and (S[Length(S)] = ':') then A := 'center'
        else if (S <> '') and (S[Length(S)] = ':') then A := 'right'
        else if (S <> '') and (S[1] = ':') then A := 'left'
        else A := '';
        Align[K] := A;
      end;
    end;
    B.Append('<table class="md" border="1" cellpadding="8" cellspacing="0">');
    EmitRow(Head, 'th');
    Inc(I, 2);
    while (I < ALines.Count) and not IsBlank(ALines[I]) and (Pos('|', ALines[I]) > 0) do
    begin
      SplitRow(ALines[I], Row);
      EmitRow(Row, 'td');
      Inc(I);
    end;
    B.Append('</table>');
    Result := B.ToString;
  finally
    Row.Free;
    Sep.Free;
    Head.Free;
    B.Free;
  end;
end;

{ The quote itself.  A first line "[!note]" (also tip, important, warning, caution), with an
  optional title after it, makes a GitLab alert: a coloured stripe and a bold title. }
function TMarkdownHtml.QuoteOut(AInner: TStringList): string;
var
  Color, Title, Kind, First : string;
  P : Integer;
begin
  Color := MD_BORDER;
  Title := '';
  if AInner.Count > 0 then
  begin
    First := Trim(AInner[0]);
    P := Pos(']', First);
    if (Copy(First, 1, 2) = '[!') and (P > 3) then
    begin
      Kind := LowerCase(Copy(First, 3, P - 3));
      if Kind = 'note' then Color := '#0D6EFD'
      else if Kind = 'tip' then Color := '#198754'
      else if Kind = 'important' then Color := '#6F42C1'
      else if Kind = 'warning' then Color := '#FD7E14'
      else if Kind = 'caution' then Color := '#DC3545'
      else Kind := '';
      if Kind <> '' then
      begin
        Title := Trim(Copy(First, P + 1, MaxInt));
        if Title = '' then Title := UpCase(Kind[1]) + Copy(Kind, 2, MaxInt);
        AInner.Delete(0);
        Title := '<strong><font color="' + Color + '">' + MdEscape(Title) + '</font></strong><br>';
      end;
    end;
  end;
  Inc(FDepth);
  try
    { a stripe on the left, then the text: a quote has no border of its own in IPro }
    Result := '<table border="0" cellpadding="0" cellspacing="0"><tr>' +
              '<td width="5" bgcolor="' + Color + '">&nbsp;</td>' +
              '<td width="12">&nbsp;</td><td>' + Title + Blocks(AInner, False) +
              '</td></tr></table>';
  finally
    Dec(FDepth);
  end;
end;

function TMarkdownHtml.QuoteHtml(ALines: TStrings; var I: Integer): string;
var
  Inner : TStringList;
  L : string;
  PrevBlank : Boolean;
begin
  Inner := TStringList.Create;
  try
    PrevBlank := False;
    while I < ALines.Count do
    begin
      L := ALines[I];
      if IsQuote(L) then
      begin
        L := TrimLeft(L);
        Delete(L, 1, 1);
        if (L <> '') and (L[1] = ' ') then Delete(L, 1, 1);
        Inner.Add(L);
        PrevBlank := IsBlank(L);
      end
      else if not IsBlank(L) and not PrevBlank and not StartsBlock(ALines, I) then
        Inner.Add(Trim(L))          { lazy continuation }
      else
        Break;
      Inc(I);
    end;
    Result := QuoteOut(Inner);
  finally
    Inner.Free;
  end;
end;

function TMarkdownHtml.ListHtml(ALines: TStrings; var I: Integer): string;
var
  B : TStringBuilder;
  Item : TStringList;
  BaseIndent, ItemIndent, ContentCol, Ind, A, Col, Num, J, K, Strip : Integer;
  Ordered, ItemOrdered, PrevBlank : Boolean;
  First : string;
  Ch : Char;
  Len, Lv : Integer;
  T : string;
begin
  B := TStringBuilder.Create;
  Item := TStringList.Create;
  try
    ListMarker(ALines[I], BaseIndent, ContentCol, Ordered, Num);
    if Ordered then
    begin
      if Num <> 1 then B.Append('<ol start="' + IntToStr(Num) + '">') else B.Append('<ol>');
    end
    else
      B.Append('<ul>');
    while I < ALines.Count do
    begin
      ListMarker(ALines[I], ItemIndent, ContentCol, ItemOrdered, Num);
      First := Copy(ALines[I], ContentCol + 1, MaxInt);
      { a task list item: "[ ] " or "[x] " becomes a box }
      if (Length(First) >= 4) and (First[1] = '[') and (First[3] = ']') and (First[4] = ' ') then
      begin
        if First[2] = ' ' then First := MD_BOX_OPEN + Copy(First, 4, MaxInt)
        else if First[2] in ['x', 'X'] then First := MD_BOX_CHECKED + Copy(First, 4, MaxInt);
      end;
      Item.Clear;
      Item.Add(First);
      PrevBlank := False;
      J := I + 1;
      while J < ALines.Count do
      begin
        if IsBlank(ALines[J]) then
        begin
          { the blank belongs to the item only when indented text follows }
          K := J;
          while (K < ALines.Count) and IsBlank(ALines[K]) do Inc(K);
          if (K < ALines.Count) and (LeadingSpaces(ALines[K]) > ItemIndent + 1) then
          begin
            while J < K do begin Item.Add(''); Inc(J); end;
            PrevBlank := True;
            Continue;
          end;
          Break;
        end;
        Ind := LeadingSpaces(ALines[J]);
        if Ind > ItemIndent + 1 then
        begin
          Strip := Ind;
          if Strip > ContentCol then Strip := ContentCol;
          Item.Add(Copy(ALines[J], Strip + 1, MaxInt));
        end
        else if ListMarkerSimple(ALines[J]) then
          Break
        else if IsFenceStart(ALines[J], Ch, Len) or IsHeading(ALines[J], Lv, T) or
                IsHr(ALines[J]) or IsQuote(ALines[J]) then
          Break
        else if PrevBlank then
          Break
        else
          Item.Add(Trim(ALines[J]));       { lazy continuation }
        PrevBlank := False;
        Inc(J);
      end;
      I := J;
      Inc(FDepth);
      try
        B.Append('<li>').Append(Blocks(Item, True)).Append('</li>');
      finally
        Dec(FDepth);
      end;
      { the next item: after blank lines, a marker of the same kind at the list's level }
      K := I;
      while (K < ALines.Count) and IsBlank(ALines[K]) do Inc(K);
      if (K < ALines.Count) and ListMarker(ALines[K], Ind, Col, ItemOrdered, A) and
         not IsHr(ALines[K]) and (Ind <= BaseIndent + 1) and (ItemOrdered = Ordered) then
        I := K
      else
        Break;
    end;
    if Ordered then B.Append('</ol>') else B.Append('</ul>');
    Result := B.ToString;
  finally
    Item.Free;
    B.Free;
  end;
end;

function TMarkdownHtml.Blocks(ALines: TStrings; ATight: Boolean): string;
var
  B : TStringBuilder;
  I, J, Lv, Len, SetextLv : Integer;
  L, T, Para, HText, HId : string;
  Ch : Char;
  Code : TStringList;
  PrevPara : Boolean;
begin
  B := TStringBuilder.Create;
  try
    if FDepth >= MD_MAX_DEPTH then
    begin
      for I := 0 to ALines.Count - 1 do
        if not IsBlank(ALines[I]) then B.Append(MdEscape(Trim(ALines[I]))).Append('<br>');
      Exit(B.ToString);
    end;
    PrevPara := False;
    I := 0;
    while I < ALines.Count do
    begin
      L := ALines[I];
      if IsBlank(L) then begin Inc(I); Continue; end;
      if IsFenceStart(L, Ch, Len) then
      begin
        Code := TStringList.Create;
        try
          Inc(I);
          while (I < ALines.Count) and not IsFenceEnd(ALines[I], Ch, Len) do
          begin
            Code.Add(ALines[I]);
            Inc(I);
          end;
          Inc(I);                      { the closing fence, or past the end }
          B.Append(CodeBlockHtml(Code)).Append(#10);
        finally
          Code.Free;
        end;
        PrevPara := False;
      end
      else if IsTocLine(L) then
      begin
        B.Append(TocMark).Append(#10);       { filled in when all headings are known }
        Inc(I);
        PrevPara := False;
      end
      else if IsHeading(L, Lv, T) then
      begin
        HText := Inline(T);
        HId := NoteHeading(Lv, HText);
        if HId <> '' then HId := ' id="' + MdEscape(HId) + '"';
        B.Append('<h' + IntToStr(Lv) + HId + '>').Append(HText).Append('</h' + IntToStr(Lv) + '>').Append(#10);
        Inc(I);
        PrevPara := False;
      end
      else if IsHr(L) then
      begin
        B.Append('<hr>').Append(#10);
        Inc(I);
        PrevPara := False;
      end
      else if IsTableStart(ALines, I) then
      begin
        B.Append(TableHtml(ALines, I)).Append(#10);
        PrevPara := False;
      end
      else if IsMultiQuoteFence(L) then
      begin
        Code := TStringList.Create;
        try
          Inc(I);
          while (I < ALines.Count) and not IsMultiQuoteFence(ALines[I]) do
          begin
            Code.Add(ALines[I]);
            Inc(I);
          end;
          Inc(I);                      { the closing ">>>", or past the end }
          B.Append(QuoteOut(Code)).Append(#10);
        finally
          Code.Free;
        end;
        PrevPara := False;
      end
      else if IsQuote(L) then
      begin
        B.Append(QuoteHtml(ALines, I)).Append(#10);
        PrevPara := False;
      end
      else if ListMarkerSimple(L) then
      begin
        B.Append(ListHtml(ALines, I)).Append(#10);
        PrevPara := False;
      end
      else if LeadingSpaces(L) >= 4 then
      begin
        Code := TStringList.Create;
        try
          while (I < ALines.Count) and (IsBlank(ALines[I]) or (LeadingSpaces(ALines[I]) >= 4)) do
          begin
            Code.Add(Copy(ALines[I], 5, MaxInt));
            Inc(I);
          end;
          while (Code.Count > 0) and IsBlank(Code[Code.Count - 1]) do
            Code.Delete(Code.Count - 1);
          B.Append(CodeBlockHtml(Code)).Append(#10);
        finally
          Code.Free;
        end;
        PrevPara := False;
      end
      else if (I + 1 < ALines.Count) and IsDefLine(ALines[I + 1]) and not IsDefLine(L) then
      begin
        B.Append(DefListHtml(ALines, I)).Append(#10);
        PrevPara := False;
      end
      else
      begin
        { a paragraph: lines up to a blank line or the start of another block }
        Para := '';
        SetextLv := 0;
        J := I;
        while J < ALines.Count do
        begin
          if IsBlank(ALines[J]) then Break;
          if (J > I) and IsSetextLine(ALines[J], SetextLv) then
          begin
            Inc(J);                    { the underline belongs to the heading }
            Break;
          end;
          if (J > I) and StartsBlock(ALines, J) then Break;
          T := ALines[J];
          if (Length(T) >= 2) and (Copy(T, Length(T) - 1, 2) = '  ') and (J + 1 < ALines.Count) then
            Para := Para + Trim(T) + HardBreak
          else if (T <> '') and (T[Length(T)] = '\') and (J + 1 < ALines.Count) then
            Para := Para + Trim(Copy(T, 1, Length(T) - 1)) + HardBreak
          else
            Para := Para + Trim(T) + ' ';
          Inc(J);
        end;
        I := J;
        Para := Trim(Para);
        if SetextLv > 0 then
        begin
          Para := Trim(StringReplace(Para, HardBreak, ' ', [rfReplaceAll]));
          HText := Inline(Para);
          HId := NoteHeading(SetextLv, HText);
          if HId <> '' then HId := ' id="' + MdEscape(HId) + '"';
          B.Append('<h' + IntToStr(SetextLv) + HId + '>').Append(HText)
           .Append('</h' + IntToStr(SetextLv) + '>').Append(#10);
          PrevPara := False;
        end
        else if ATight then
        begin
          if PrevPara then B.Append('<br>');
          B.Append(Inline(Para)).Append(#10);
        end
        else
          B.Append('<p>').Append(Inline(Para)).Append('</p>').Append(#10);
        PrevPara := True;
      end;
    end;
    Result := B.ToString;
  finally
    B.Free;
  end;
end;

function TMarkdownHtml.ToHtml(const AMarkdown: string; AImages: TStrings): string;
var
  Lines : TStringList;
  S, Body : string;
begin
  FImages := AImages;
  FDepth := 0;
  if Assigned(FImages) then FImages.Clear;
  S := StringReplace(AMarkdown, HardBreak, '', [rfReplaceAll]);
  S := StringReplace(S, TocMark, '', [rfReplaceAll]);
  S := StringReplace(S, #0, ' ', [rfReplaceAll]);
  S := StringReplace(S, #9, '    ', [rfReplaceAll]);
  S := StringReplace(S, #13#10, #10, [rfReplaceAll]);
  S := StringReplace(S, #13, #10, [rfReplaceAll]);
  Lines := TStringList.Create;
  FRefs := TStringList.Create;
  FNotes := TStringList.Create;
  FNoteOrder := TStringList.Create;
  FHeads := TStringList.Create;
  FSlugs := TStringList.Create;
  FNoAuto := 0;
  { heading ids are only worth their bytes when something can point at them }
  FWantIds := (Pos('](#', S) > 0) or (Pos(']: #', S) > 0) or
              (Pos('[TOC]', UpperCase(S)) > 0) or (Pos('[[_TOC_]]', UpperCase(S)) > 0);
  try
    Lines.StrictDelimiter := True;
    Lines.LineBreak := #10;
    Lines.Text := S;
    FrontMatterToCode(Lines);
    StripComments(Lines);
    CollectRefs(Lines);
    Body := Blocks(Lines, False);
    if Pos(TocMark, Body) > 0 then
      Body := StringReplace(Body, TocMark, TocHtml, [rfReplaceAll]);
    Result := '<html><head><style type="text/css">' + MD_STYLE + '</style></head><body>' + #10 +
              Body + NotesHtml + '</body></html>';
  finally
    FreeAndNil(FSlugs);
    FreeAndNil(FHeads);
    FreeAndNil(FNoteOrder);
    FreeAndNil(FNotes);
    FreeAndNil(FRefs);
    Lines.Free;
  end;
end;

end.
