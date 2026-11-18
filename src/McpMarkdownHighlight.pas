{ McpMarkdownHighlight - colours fenced code in the Markdown viewer with the editor's own
  highlighters, in the colours of the user's scheme (ADR-030).

  McpMarkdown knows nothing of SynEdit: this unit sets its MdHighlighter hook.  For a language it
  creates the matching highlighter, has the IDE fill it from the scheme, walks the tokens of the
  code and reports the stretches that have a colour, bold or italic.  Created and freed per block,
  on the thread that renders the page (the main thread). }
unit McpMarkdownHighlight;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Graphics, SynEditHighlighter, SynHighlighterPas, SynHighlighterLFM,
  SynHighlighterSQL, SynHighlighterXML, SynHighlighterHTML, SynHighlighterCss,
  SynHighlighterPython, SynHighlighterJScript, SynHighlighterCPP, SynHighlighterJava,
  SynHighlighterPHP, SynHighlighterPerl, SynHighlighterUNIXShellScript, SynHighlighterIni,
  SynHighlighterDiff, SynHighlighterBat, IDEOptEditorIntf, McpMarkdown;

{ The runs of ACode in language ALang (lower case); False for a language without a highlighter. }
function McpHighlightCode(const ALang: string; ACode: TStrings; out ARuns: TMdRuns): Boolean;

implementation

function NewHighlighter(const ALang: string): TSynCustomHighlighter;
begin
  case ALang of
    'pascal', 'pas', 'delphi', 'objectpascal', 'fpc', 'lazarus', 'lpr', 'pp', 'inc':
      Result := TSynPasSyn.Create(nil);
    'lfm', 'dfm':                        Result := TSynLFMSyn.Create(nil);
    'sql':                               Result := TSynSQLSyn.Create(nil);
    'xml', 'lpi', 'lpk', 'xsd', 'svg':   Result := TSynXMLSyn.Create(nil);
    'html', 'htm':                       Result := TSynHTMLSyn.Create(nil);
    'css':                               Result := TSynCssSyn.Create(nil);
    'python', 'py':                      Result := TSynPythonSyn.Create(nil);
    'js', 'javascript', 'json', 'ts', 'typescript':
      Result := TSynJScriptSyn.Create(nil);
    'c', 'h', 'cpp', 'c++', 'cc', 'hpp', 'cxx':
      Result := TSynCppSyn.Create(nil);
    'java':                              Result := TSynJavaSyn.Create(nil);
    'php':                               Result := TSynPHPSyn.Create(nil);
    'perl', 'pl':                        Result := TSynPerlSyn.Create(nil);
    'sh', 'bash', 'shell', 'zsh', 'console':
      Result := TSynUNIXShellScriptSyn.Create(nil);
    'ini', 'toml', 'conf', 'cfg':        Result := TSynIniSyn.Create(nil);
    'diff', 'patch':                     Result := TSynDiffSyn.Create(nil);
    'bat', 'batch', 'cmd':               Result := TSynBatSyn.Create(nil);
  else
    Result := nil;
  end;
end;

function HtmlColor(AColor: TColor): string;
var
  C : LongInt;
begin
  C := ColorToRGB(AColor);
  Result := '#' + IntToHex(C and $FF, 2) + IntToHex((C shr 8) and $FF, 2) +
            IntToHex((C shr 16) and $FF, 2);
end;

{ A diff is coloured by what each line starts with (the SynEdit diff highlighter marks files with
  background colours, which a run cannot carry): added and removed lines in the viewer's colours
  for them, which come from the scheme, hunk headers in the link colour, file headers bold. }
function DiffRuns(ACode: TStrings): TMdRuns;
var
  N, Cnt : Integer;
  L, Color : string;
  Bold : Boolean;
begin
  Result := nil;
  SetLength(Result, ACode.Count);
  Cnt := 0;
  for N := 0 to ACode.Count - 1 do
  begin
    L := ACode[N];
    Color := '';
    Bold := False;
    if (Copy(L, 1, 4) = '+++ ') or (Copy(L, 1, 4) = '--- ') or (Copy(L, 1, 5) = 'diff ') or
       (Copy(L, 1, 6) = 'index ') then
      Bold := True
    else if Copy(L, 1, 2) = '@@' then
    begin
      Color := MdPalette.Link;
      Bold := True;
    end
    else if Copy(L, 1, 1) = '+' then Color := MdPalette.Added
    else if Copy(L, 1, 1) = '-' then Color := MdPalette.Removed;
    if (L <> '') and ((Color <> '') or Bold) then
    begin
      Result[Cnt].Line := N;
      Result[Cnt].Start := 1;
      Result[Cnt].Len := Length(L);
      Result[Cnt].Color := Color;
      Result[Cnt].Bold := Bold;
      Result[Cnt].Italic := False;
      Inc(Cnt);
    end;
  end;
  SetLength(Result, Cnt);
end;

{ The attribute of the Pascal scheme that plays the same part as Attr (a keyword, a string, a
  number, a comment, a symbol), or nil.  Highlighters of other languages often come without
  colours of their own, SQL for one: their parts take the colours the user chose for Pascal. }
function SchemeRole(AHl: TSynCustomHighlighter; AAttr: TSynHighlighterAttributes;
  ARef: TSynPasSyn): TSynHighlighterAttributes;
var
  Name : string;
begin
  Result := nil;
  if ARef = nil then Exit;
  if AAttr = AHl.CommentAttribute then Result := ARef.CommentAttri
  else if AAttr = AHl.KeywordAttribute then Result := ARef.KeyAttri
  else if AAttr = AHl.StringAttribute then Result := ARef.StringAttri
  else if AAttr = AHl.SymbolAttribute then Result := ARef.SymbolAttri
  else
  begin
    Name := LowerCase(AAttr.StoredName);
    if Pos('number', Name) > 0 then Result := ARef.NumberAttri
    else if (Pos('type', Name) > 0) or (Pos('function', Name) > 0) or
            (Pos('exception', Name) > 0) or (Pos('directive', Name) > 0) or
            (Pos('plsql', Name) > 0) or (Pos('sqlplus', Name) > 0) then
      Result := ARef.KeyAttri;
  end;
end;

function McpHighlightCode(const ALang: string; ACode: TStrings; out ARuns: TMdRuns): Boolean;
var
  Hl : TSynCustomHighlighter;
  Ref : TSynPasSyn;
  Attr, Role : TSynHighlighterAttributes;
  N, P, Cnt, Len : Integer;
  Color : string;
  Bold, Italic : Boolean;
begin
  ARuns := nil;
  Result := False;
  if (ALang = 'diff') or (ALang = 'patch') then
  begin
    ARuns := DiffRuns(ACode);
    Exit(True);
  end;
  Hl := NewHighlighter(ALang);
  if Hl = nil then Exit;
  Ref := nil;
  try
    if Assigned(IDEEditorOptions) then
      try
        IDEEditorOptions.GetHighlighterObjSettings(Hl);
        if not (Hl is TSynPasSyn) then
        begin
          Ref := TSynPasSyn.Create(nil);
          IDEEditorOptions.GetHighlighterObjSettings(Ref);
        end;
      except
        { the highlighter's own colours then }
      end;
    Cnt := 0;
    SetLength(ARuns, 64);
    Hl.ResetRange;
    for N := 0 to ACode.Count - 1 do
    begin
      Hl.SetLine(ACode[N], N);
      while not Hl.GetEol do
      begin
        Attr := Hl.GetTokenAttribute;
        if Attr <> nil then
        begin
          P := Hl.GetTokenPos + 1;
          Len := Length(Hl.GetToken);
          Color := '';
          if (Attr.Foreground <> clNone) and (Attr.Foreground <> clDefault) then
            Color := HtmlColor(Attr.Foreground);
          Bold := fsBold in Attr.Style;
          Italic := fsItalic in Attr.Style;
          if Color = '' then
          begin
            Role := SchemeRole(Hl, Attr, Ref);
            if (Role <> nil) and (Role.Foreground <> clNone) and (Role.Foreground <> clDefault) then
            begin
              Color := HtmlColor(Role.Foreground);
              Bold := Bold or (fsBold in Role.Style);
              Italic := Italic or (fsItalic in Role.Style);
            end;
          end;
          if (Len > 0) and ((Color <> '') or Bold or Italic) then
          begin
            { the same look as the run before, right behind it: one run }
            if (Cnt > 0) and (ARuns[Cnt - 1].Line = N) and
               (ARuns[Cnt - 1].Start + ARuns[Cnt - 1].Len = P) and
               (ARuns[Cnt - 1].Color = Color) and (ARuns[Cnt - 1].Bold = Bold) and
               (ARuns[Cnt - 1].Italic = Italic) then
              Inc(ARuns[Cnt - 1].Len, Len)
            else
            begin
              if Cnt > High(ARuns) then SetLength(ARuns, Cnt * 2);
              ARuns[Cnt].Line := N;
              ARuns[Cnt].Start := P;
              ARuns[Cnt].Len := Len;
              ARuns[Cnt].Color := Color;
              ARuns[Cnt].Bold := Bold;
              ARuns[Cnt].Italic := Italic;
              Inc(Cnt);
            end;
          end;
        end;
        Hl.Next;
      end;
    end;
    SetLength(ARuns, Cnt);
    Result := True;
  finally
    Ref.Free;
    Hl.Free;
  end;
end;

initialization
  MdHighlighter := @McpHighlightCode;
finalization
  MdHighlighter := nil;
end.
