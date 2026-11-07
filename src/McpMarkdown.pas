{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpMarkdown;

{ Markdown to the HTML subset that TIpHtmlPanel renders (ADR-024).  Plain RTL, no IDE units.

  The input is untrusted: raw HTML is escaped, only http(s) links are emitted, and an image
  becomes an img only for a local path or a Base64 data: URI (lifted out as mcp-img:N).
  An unknown construct is escaped text, never an error. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

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
    procedure CollectRefs(ALines: TStrings);
    function RefLinkAt(const S: string; P: Integer; out AText, AUrl: string;
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

{ [label]: url "title" }
function ParseRefDef(const S: string; out ALabel, AUrl: string): Boolean;
var
  T, Rest : string;
  P, Q : Integer;
begin
  Result := False;
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
  Result := AUrl <> '';
end;

{ ── The converter ────────────────────────────────────────────────────────── }

const
  MD_MAX_REFS = 256;
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
  L, U : string;
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
    else if ParseRefDef(ALines[I], L, U) then
    begin
      if (FRefs.Count < MD_MAX_REFS) and (FRefs.IndexOfName(L) < 0) then
        FRefs.Add(L + '=' + U);
      ALines.Delete(I);
    end
    else
      Inc(I);
  end;
end;

{ [text][label], [text][] and [label] at S[P] = '[', when the label is defined }
function TMarkdownHtml.RefLinkAt(const S: string; P: Integer; out AText, AUrl: string;
  out NextP: Integer): Boolean;
var
  N, Q, R, Depth : Integer;
  Lbl : string;
begin
  Result := False;
  if (FRefs = nil) or (FRefs.Count = 0) then Exit;
  N := Length(S);
  Depth := 0;
  Q := P;
  while Q <= N do
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
  if Q > N then Exit;
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
  AUrl := FRefs.ValueFromIndex[Q];
  Result := True;
end;

{ [text](url) at S[P] = '['; NextP is the position after the closing parenthesis }
function ParseLinkAt(const S: string; P: Integer; out AText, AUrl: string;
  out NextP: Integer): Boolean;
var
  N, Q, R, Depth : Integer;
  Raw : string;
begin
  Result := False;
  N := Length(S);
  Depth := 0;
  Q := P;
  while Q <= N do
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
  if (Q > N) or (Q + 1 > N) or (S[Q + 1] <> '(') then Exit;
  AText := Copy(S, P + 1, Q - P - 1);
  Depth := 1;
  R := Q + 2;
  while R <= N do
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
  if R > N then Exit;
  Raw := Trim(Copy(S, Q + 2, R - Q - 2));
  if (Raw <> '') and (Raw[1] = '<') and (Pos('>', Raw) > 0) then
    AUrl := Copy(Raw, 2, Pos('>', Raw) - 2)
  else
  begin
    Q := 1;
    while (Q <= Length(Raw)) and (Raw[Q] > ' ') do Inc(Q);
    AUrl := Copy(Raw, 1, Q - 1);
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
  I, N, J, P, Run, Len, NextP : Integer;
  C : Char;
  Inner, Url, Text, Delim, Tag : string;
  Found : Boolean;

  function IsAlnum(Ch: Char): Boolean;
  begin
    Result := Ch in ['A'..'Z', 'a'..'z', '0'..'9'];
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
      if not (C in ['\', '`', '!', '[', '<', '*', '_', '~', HardBreak]) then
      begin
        J := I;
        while (J <= N) and not (S[J] in ['\', '`', '!', '[', '<', '*', '_', '~', HardBreak]) do
          Inc(J);
        B.Append(MdEscape(Copy(S, I, J - I)));
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
          if (I < N) and (S[I + 1] = '[') and ParseLinkAt(S, I + 1, Text, Url, NextP) then
          begin
            B.Append(ImageHtml(Text, Url));
            I := NextP;
          end
          else
          begin
            B.Append('!');
            Inc(I);
          end;
        '[':
          if ParseLinkAt(S, I, Text, Url, NextP) or RefLinkAt(S, I, Text, Url, NextP) then
          begin
            if IsSafeHttp(Url) then
              B.Append('<a href="' + MdEscape(Url) + '">' + Inline(Text) + '</a>')
            else
              B.Append(Inline(Text));
            I := NextP;
          end
          else
          begin
            B.Append('[');
            Inc(I);
          end;
        '<':
          begin
            P := Pos('>', Copy(S, I, 2100));
            if SameText(Copy(S, I, 4), '<br>') then
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
  L, T, Para : string;
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
      else if IsHeading(L, Lv, T) then
      begin
        B.Append('<h' + IntToStr(Lv) + '>').Append(Inline(T)).Append('</h' + IntToStr(Lv) + '>').Append(#10);
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
          B.Append('<h' + IntToStr(SetextLv) + '>').Append(Inline(Para))
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
  S : string;
begin
  FImages := AImages;
  FDepth := 0;
  if Assigned(FImages) then FImages.Clear;
  S := StringReplace(AMarkdown, HardBreak, '', [rfReplaceAll]);
  S := StringReplace(S, #0, ' ', [rfReplaceAll]);
  S := StringReplace(S, #9, '    ', [rfReplaceAll]);
  S := StringReplace(S, #13#10, #10, [rfReplaceAll]);
  S := StringReplace(S, #13, #10, [rfReplaceAll]);
  Lines := TStringList.Create;
  FRefs := TStringList.Create;
  try
    Lines.StrictDelimiter := True;
    Lines.LineBreak := #10;
    Lines.Text := S;
    CollectRefs(Lines);
    Result := '<html><head><style type="text/css">' + MD_STYLE + '</style></head><body>' + #10 +
              Blocks(Lines, False) + '</body></html>';
  finally
    FreeAndNil(FRefs);
    Lines.Free;
  end;
end;

end.
