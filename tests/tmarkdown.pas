{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TMarkdown;

{ TTestMarkdown — McpMarkdown (ADR-024): the HTML it emits for each construct, and what it
  does with hostile input.  Pure string code. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry;

type
  TTestMarkdown = class(TTestCase)
  private
    function H(const AMd: string; AImages: TStrings = nil): string;
    procedure Has(const AHtml, ANeedle: string);
    procedure HasNot(const AHtml, ANeedle: string);
  published
    procedure TestEmpty;
    procedure TestHeadings;
    procedure TestHeadingClosingHashes;
    procedure TestParagraphsAndBreaks;
    procedure TestEmphasis;
    procedure TestUnderscoreInWord;
    procedure TestInlineCode;
    procedure TestFence;
    procedure TestFenceUnterminated;
    procedure TestIndentedCode;
    procedure TestList;
    procedure TestOrderedListStart;
    procedure TestNestedList;
    procedure TestListItemWithFence;
    procedure TestQuote;
    procedure TestTable;
    procedure TestTableAlign;
    procedure TestHr;
    procedure TestLinkHttp;
    procedure TestLinkJavascript;
    procedure TestAutolink;
    procedure TestRawHtmlEscaped;
    procedure TestImageLocal;
    procedure TestImageDriveLetter;
    procedure TestImageHttp;
    procedure TestImageUnc;
    procedure TestImageOtherScheme;
    procedure TestImageDataUri;
    procedure TestImageDataUriBad;
    procedure TestImageDataUriWithoutList;
    procedure TestImageLiteralMcpImg;
    procedure TestImageLimit;
    procedure TestDeepNesting;
    procedure TestHugeLine;
    procedure TestControlCharacters;
    procedure TestScheme;
    procedure TestTextSize;
  end;

  TTestImageInfo = class(TTestCase)
  published
    procedure TestPng;
    procedure TestGif;
    procedure TestBmp;
    procedure TestJpeg;
    procedure TestJpegWithoutFrame;
    procedure TestNotPictures;
    procedure TestDeclaredKind;
    procedure TestTooManyPixels;
    procedure TestImpossibleSizes;
  end;

implementation

uses
  McpMarkdown, McpImageInfo;

function Be32(V: LongWord): string;
begin
  Result := Chr(V shr 24) + Chr((V shr 16) and 255) + Chr((V shr 8) and 255) + Chr(V and 255);
end;

function Le16(V: Integer): string;
begin
  Result := Chr(V and 255) + Chr((V shr 8) and 255);
end;

function Le32(V: LongWord): string;
begin
  Result := Chr(V and 255) + Chr((V shr 8) and 255) + Chr((V shr 16) and 255) + Chr(V shr 24);
end;

function PngOf(W, H: LongWord): string;
begin
  Result := #$89'PNG'#13#10#26#10 + Be32(13) + 'IHDR' + Be32(W) + Be32(H) + #8#6#0#0#0;
end;

function JpegOf(W, H: Integer): string;
begin
  { SOI, an APP0 segment of 16 bytes, then SOF0: length 17, precision, height, width }
  Result := #$FF#$D8 + #$FF#$E0 + #0#16 + StringOfChar('J', 14) +
            #$FF#$C0 + #0#17#8 + Chr(H shr 8) + Chr(H and 255) + Chr(W shr 8) + Chr(W and 255) +
            #3#1#$22#0#2#$11#1#3#$11#1;
end;

function TTestMarkdown.H(const AMd: string; AImages: TStrings): string;
var
  C : TMarkdownHtml;
begin
  C := TMarkdownHtml.Create;
  try
    Result := C.ToHtml(AMd, AImages);
  finally
    C.Free;
  end;
end;

procedure TTestMarkdown.Has(const AHtml, ANeedle: string);
begin
  AssertTrue('expected "' + ANeedle + '" in: ' + AHtml, Pos(ANeedle, AHtml) > 0);
end;

procedure TTestMarkdown.HasNot(const AHtml, ANeedle: string);
begin
  AssertTrue('did not expect "' + ANeedle + '" in: ' + AHtml, Pos(ANeedle, AHtml) = 0);
end;

procedure TTestMarkdown.TestEmpty;
begin
  AssertEquals('<html><body>' + #10 + '</body></html>', H(''));
end;

procedure TTestMarkdown.TestHeadings;
var
  R : string;
begin
  R := H('# One' + #10 + '### Three' + #10 + '####### seven');
  Has(R, '<h1>One</h1>');
  Has(R, '<h3>Three</h3>');
  HasNot(R, '<h7>');
  Has(R, '<p>####### seven</p>');
  Has(H('#nospace'), '<p>#nospace</p>');
end;

procedure TTestMarkdown.TestHeadingClosingHashes;
begin
  Has(H('## Title ##'), '<h2>Title</h2>');
  Has(H('## C#'), '<h2>C#</h2>');
end;

procedure TTestMarkdown.TestParagraphsAndBreaks;
var
  R : string;
begin
  R := H('one' + #10 + 'two' + #10#10 + 'three');
  Has(R, '<p>one two</p>');
  Has(R, '<p>three</p>');
  Has(H('a  ' + #10 + 'b'), '<p>a<br>b</p>');
  Has(H('a\' + #10 + 'b'), '<p>a<br>b</p>');
  Has(H('a' + #13#10 + 'b'), '<p>a b</p>');
end;

procedure TTestMarkdown.TestEmphasis;
var
  R : string;
begin
  R := H('**bold** *em* _em2_ ~~gone~~ ***both***');
  Has(R, '<strong>bold</strong>');
  Has(R, '<em>em</em>');
  Has(R, '<em>em2</em>');
  Has(R, '<del>gone</del>');
  Has(H('a * b * c'), 'a * b * c');
  Has(H('**open'), '**open');
  Has(H('\*not\*'), '*not*');
end;

procedure TTestMarkdown.TestUnderscoreInWord;
begin
  Has(H('snake_case_name'), 'snake_case_name');
  HasNot(H('snake_case_name'), '<em>');
end;

procedure TTestMarkdown.TestInlineCode;
var
  R : string;
begin
  R := H('use `a<b` and ``x ` y``');
  Has(R, '<tt>a&lt;b</tt>');
  Has(R, '<tt>x&nbsp;`&nbsp;y</tt>');
  Has(H('lone ` tick'), 'lone ` tick');
  HasNot(H('`**x**`'), '<strong>');
end;

procedure TTestMarkdown.TestFence;
var
  R : string;
begin
  R := H('```pascal' + #10 + 'if a < b then' + #10 + '  x := 1;' + #10#10 + 'end;' + #10 + '```' + #10 + 'after');
  Has(R, 'bgcolor="#EEEEEE"');
  Has(R, '<tt>if&nbsp;a&nbsp;&lt;&nbsp;b&nbsp;then</tt><br>');
  Has(R, '<tt>&nbsp;&nbsp;x&nbsp;:=&nbsp;1;</tt><br>');
  Has(R, '<tt>&nbsp;</tt><br>');
  Has(R, '<p>after</p>');
  HasNot(R, '<pre>');
  HasNot(R, '```');
end;

procedure TTestMarkdown.TestFenceUnterminated;
var
  R : string;
begin
  R := H('~~~' + #10 + 'a' + #10 + 'b');
  Has(R, '<tt>a</tt><br>');
  Has(R, '<tt>b</tt><br>');
end;

procedure TTestMarkdown.TestIndentedCode;
var
  R : string;
begin
  R := H('text' + #10#10 + '    code <x>' + #10 + '    more');
  Has(R, '<tt>code&nbsp;&lt;x&gt;</tt>');
  Has(R, '<tt>more</tt>');
end;

procedure TTestMarkdown.TestList;
var
  R : string;
begin
  R := H('- a' + #10 + '- b' + #10 + '* c');
  Has(R, '<ul><li>a' + #10 + '</li><li>b' + #10 + '</li>');
  AssertEquals('two lists are one: markers differ only in char', 1, Length(R) - Length(StringReplace(R, '<ul>', '', [rfReplaceAll])) - 3);
end;

procedure TTestMarkdown.TestOrderedListStart;
begin
  Has(H('1. a' + #10 + '2. b'), '<ol><li>a');
  Has(H('3. a' + #10 + '4. b'), '<ol start="3">');
  { a number in the middle of a paragraph does not start a list }
  Has(H('in the year' + #10 + '2020. was it'), '<p>in the year 2020. was it</p>');
end;

procedure TTestMarkdown.TestNestedList;
var
  R : string;
begin
  R := H('- a' + #10 + '  - b' + #10 + '    - c' + #10 + '- d');
  Has(R, '<li>a' + #10 + '<ul><li>b' + #10 + '<ul><li>c');
  Has(R, '<li>d');
  R := H('1. a' + #10 + '   - b' + #10 + '2. c');
  Has(R, '<ol><li>a' + #10 + '<ul><li>b');
  Has(R, '<li>c');
end;

procedure TTestMarkdown.TestListItemWithFence;
var
  R : string;
begin
  R := H('- step' + #10 + '  ```' + #10 + '  run it' + #10 + '  ```' + #10 + '- next');
  Has(R, '<tt>run&nbsp;it</tt>');
  Has(R, '<li>next');
end;

procedure TTestMarkdown.TestQuote;
var
  R : string;
begin
  R := H('> quoted **text**' + #10 + '> - item' + #10 + 'lazy');
  Has(R, '<blockquote>');
  Has(R, '<strong>text</strong>');
  Has(R, '<ul><li>item');
  Has(R, 'lazy');
  Has(R, '</blockquote>');
end;

procedure TTestMarkdown.TestTable;
var
  R : string;
begin
  R := H('| a | b |' + #10 + '|---|---|' + #10 + '| 1 | `x|y` |' + #10 + '| 2 |' + #10 + 'after');
  Has(R, '<table border="1"');
  Has(R, '<th>a</th><th>b</th>');
  Has(R, '<td>1</td>');
  Has(R, '<td>2</td><td>&nbsp;</td>');
  Has(R, '<p>after</p>');
  { an escaped pipe stays inside the cell }
  Has(H('| a |' + #10 + '|---|' + #10 + '| x \| y |'), '<td>x | y</td>');
end;

procedure TTestMarkdown.TestTableAlign;
var
  R : string;
begin
  R := H('a | b | c' + #10 + ':-- | :-: | --:' + #10 + '1 | 2 | 3');
  Has(R, '<th align="left">a</th>');
  Has(R, '<th align="center">b</th>');
  Has(R, '<th align="right">c</th>');
  Has(R, '<td align="right">3</td>');
end;

procedure TTestMarkdown.TestHr;
begin
  Has(H('a' + #10#10 + '---' + #10#10 + 'b'), '<hr>');
  Has(H('* * *'), '<hr>');
  HasNot(H('* * *'), '<ul>');
end;

procedure TTestMarkdown.TestLinkHttp;
var
  R : string;
begin
  R := H('see [the *docs*](https://example.com/a?b=1&c=2) now');
  Has(R, '<a href="https://example.com/a?b=1&amp;c=2">the <em>docs</em></a>');
  Has(H('[x](http://a.b "title")'), '<a href="http://a.b">x</a>');
  Has(H('[x](<https://a.b/c d>)'), 'x');
end;

procedure TTestMarkdown.TestLinkJavascript;
var
  R : string;
begin
  R := H('[click](javascript:alert(1)) [f](file:///C:/x) [m](mailto:a@b.c) [r](rel/path.md)');
  HasNot(R, '<a ');
  HasNot(R, 'href');
  Has(R, 'click');
  Has(H('[x](JaVaScRiPt:alert(1))'), 'x');
  HasNot(H('[x](JaVaScRiPt:alert(1))'), '<a ');
  { a control character ends the URL and never reaches the output }
  R := H('[x](http://a.b/' + #7 + 'c)');
  HasNot(R, #7);
  Has(R, 'href="http://a.b/"');
end;

procedure TTestMarkdown.TestAutolink;
begin
  Has(H('<https://example.com/x>'), '<a href="https://example.com/x">https://example.com/x</a>');
  HasNot(H('<javascript:alert(1)>'), '<a ');
  Has(H('<javascript:alert(1)>'), '&lt;javascript');
end;

procedure TTestMarkdown.TestRawHtmlEscaped;
var
  R : string;
begin
  R := H('<script>alert(1)</script> <img src=x onerror=y> & "q"');
  HasNot(R, '<script');
  HasNot(R, '<img');
  Has(R, '&lt;script&gt;');
  Has(R, '&amp; &quot;q&quot;');
  R := H('```' + #10 + '</td></tr></table><script>' + #10 + '```');
  HasNot(R, '<script');
  Has(R, '&lt;/td&gt;');
end;

procedure TTestMarkdown.TestImageLocal;
begin
  Has(H('![a pic](shots/a.png)'), '<img src="shots/a.png" alt="a pic">');
  Has(H('![](a.png)'), 'alt="image"');
  Has(H('![x"y](a".png)'), 'alt="x&quot;y"');
end;

procedure TTestMarkdown.TestImageDriveLetter;
begin
  Has(H('![d](C:\temp\a.png)'), '<img src="C:\temp\a.png" alt="d">');
  Has(H('![d](d:/a b.png)'), '<img');
end;

procedure TTestMarkdown.TestImageHttp;
var
  R : string;
begin
  R := H('![logo](https://example.com/l.png)');
  HasNot(R, '<img');
  Has(R, '<a href="https://example.com/l.png">[logo]</a>');
end;

procedure TTestMarkdown.TestImageUnc;
begin
  HasNot(H('![x](\\host\share\a.png)'), '<img');
  HasNot(H('![x](//host/share/a.png)'), '<img');
  Has(H('![x](\\host\share\a.png)'), '[x]');
end;

procedure TTestMarkdown.TestImageOtherScheme;
var
  R : string;
begin
  R := H('![a](ftp://h/a.png) ![b](file:///C:/a.png) ![c](javascript:x)');
  HasNot(R, '<img');
  HasNot(R, '<a ');
  Has(R, '[a] [b] [c]');
end;

procedure TTestMarkdown.TestImageDataUri;
var
  L : TStringList;
  R : string;
begin
  L := TStringList.Create;
  try
    R := H('x ![p](data:image/png;base64,iVBORw0KGgo=) y ![q](DATA:image/JPEG;base64,/9j/4AAQ)', L);
    AssertEquals(2, L.Count);
    AssertEquals('png:iVBORw0KGgo=', L[0]);
    AssertEquals('jpeg:/9j/4AAQ', L[1]);
    Has(R, '<img src="mcp-img:0" alt="p">');
    Has(R, '<img src="mcp-img:1" alt="q">');
    HasNot(R, 'iVBOR');
    { a second conversion starts the list again }
    H('![p](data:image/gif;base64,R0lGODlh)', L);
    AssertEquals(1, L.Count);
    AssertEquals('gif:R0lGODlh', L[0]);
  finally
    L.Free;
  end;
end;

procedure TTestMarkdown.TestImageDataUriBad;
var
  L : TStringList;
  R : string;
begin
  L := TStringList.Create;
  try
    R := H('![a](data:image/svg+xml;base64,PHN2Zz4=) ![b](data:text/html;base64,PGI+) ' +
           '![c](data:image/png;base64,) ![d](data:image/png;base64,ab"onerror=x) ' +
           '![e](data:image/png,raw) ![f](data:image/webp;base64,AAAA)', L);
    AssertEquals(0, L.Count);
    HasNot(R, '<img');
    Has(R, '[a] [b] [c] [d] [e] [f]');
  finally
    L.Free;
  end;
end;

procedure TTestMarkdown.TestImageDataUriWithoutList;
var
  R : string;
begin
  R := H('![p](data:image/png;base64,iVBORw0KGgo=)');
  HasNot(R, '<img');
  Has(R, '[p]');
end;

procedure TTestMarkdown.TestImageLiteralMcpImg;
var
  L : TStringList;
  R : string;
begin
  L := TStringList.Create;
  try
    R := H('![sneaky](mcp-img:0)', L);
    HasNot(R, '<img');
    Has(R, '[sneaky]');
  finally
    L.Free;
  end;
end;

procedure TTestMarkdown.TestImageLimit;
var
  L : TStringList;
  Md, R : string;
  I : Integer;
begin
  L := TStringList.Create;
  try
    Md := '';
    for I := 1 to MD_MAX_IMAGES + 5 do
      Md := Md + '![i](data:image/png;base64,AAAA) ';
    R := H(Md, L);
    AssertEquals(MD_MAX_IMAGES, L.Count);
    Has(R, 'mcp-img:' + IntToStr(MD_MAX_IMAGES - 1));
    HasNot(R, 'mcp-img:' + IntToStr(MD_MAX_IMAGES) + '"');
  finally
    L.Free;
  end;
end;

procedure TTestMarkdown.TestDeepNesting;
var
  Md, R : string;
  I : Integer;
begin
  Md := '';
  for I := 1 to 500 do Md := Md + '>';
  R := H(Md + ' deep');
  Has(R, 'deep');
  Md := '';
  for I := 1 to 300 do Md := Md + StringOfChar(' ', I * 2) + '- x' + #10;
  R := H(Md);
  Has(R, 'x');
  Md := '';
  for I := 1 to 300 do Md := Md + '*a ';
  Md := Md + 'z';
  R := H(Md);
  Has(R, 'z');
  Md := '';
  for I := 1 to 300 do Md := Md + '[';
  R := H(Md + 'x' + StringOfChar(']', 300) + '(http://a.b)');
  Has(R, 'x');
end;

procedure TTestMarkdown.TestHugeLine;
var
  Md, R : string;
begin
  Md := StringOfChar('a', 256 * 1024);
  R := H(Md);
  AssertTrue(Length(R) > 256 * 1024);
  { many short lines and many emphasis marks stay linear enough to finish }
  Md := StringOfChar('*', 20000) + 'x';
  R := H(Md);
  Has(R, 'x');
end;

procedure TTestMarkdown.TestControlCharacters;
var
  R : string;
begin
  R := H('a' + #0 + 'b' + #1 + 'c' + #9 + 'd');
  HasNot(R, #0);
  HasNot(R, #1);
  Has(R, 'a b');                       { NUL becomes a space }
  Has(R, 'bc');                        { the private break marker is dropped }
  Has(H('x' + #1 + 'y'), 'xy');
  AssertEquals(0, Pos(#1, H('line' + #1 + '  ' + #10 + 'next')));
end;

procedure TTestMarkdown.TestScheme;
begin
  AssertEquals('', MdUrlScheme('a.png'));
  AssertEquals('', MdUrlScheme('C:\x\a.png'));
  AssertEquals('', MdUrlScheme('c:/a.png'));
  AssertEquals('', MdUrlScheme('./a:b.png'));
  AssertEquals('http', MdUrlScheme('HTTP://x'));
  AssertEquals('mcp-img', MdUrlScheme('mcp-img:0'));
  AssertEquals('data', MdUrlScheme('data:image/png;base64,AA'));
  AssertEquals('javascript', MdUrlScheme('javascript:alert(1)'));
end;

procedure TTestMarkdown.TestTextSize;
var
  Pic : string;
begin
  AssertEquals(0, MdTextSize(''));
  AssertEquals(5, MdTextSize('hello'));
  Pic := StringOfChar('A', 5000);
  { the payload does not count, the rest of the line does }
  AssertEquals(Length('![p](data:image/png;base64,') + Length(') text'),
    MdTextSize('![p](data:image/png;base64,' + Pic + ') text'));
  { not an image URI: counted in full }
  AssertEquals(Length('data:text/plain;base64,' + Pic), MdTextSize('data:text/plain;base64,' + Pic));
  { no payload }
  AssertEquals(Length('x data:image/png;base64,'), MdTextSize('x data:image/png;base64,'));
  { two pictures }
  AssertEquals(2 * Length('![p](data:image/gif;base64,)'),
    MdTextSize('![p](data:image/gif;base64,' + Pic + ')![p](data:image/gif;base64,' + Pic + ')'));
end;

procedure TTestImageInfo.TestPng;
var
  K : string;
  W, H : Integer;
begin
  AssertTrue(McpImageHeader(PngOf(160, 80), K, W, H));
  AssertEquals('png', K);
  AssertEquals(160, W);
  AssertEquals(80, H);
end;

procedure TTestImageInfo.TestGif;
var
  K : string;
  W, H : Integer;
begin
  AssertTrue(McpImageHeader('GIF89a' + Le16(300) + Le16(200) + #0#0#0, K, W, H));
  AssertEquals('gif', K);
  AssertEquals(300, W);
  AssertEquals(200, H);
end;

procedure TTestImageInfo.TestBmp;
var
  K : string;
  W, H : Integer;
  Hdr : string;
begin
  Hdr := 'BM' + Le32(100) + Le32(0) + Le32(54) + Le32(40) + Le32(64) + Le32(48) + #1#0#24#0;
  AssertTrue(McpImageHeader(Hdr, K, W, H));
  AssertEquals('bmp', K);
  AssertEquals(64, W);
  AssertEquals(48, H);
  { top-down: the height is negative }
  Hdr := 'BM' + Le32(100) + Le32(0) + Le32(54) + Le32(40) + Le32(64) + Le32(LongWord(-48)) + #1#0#24#0;
  AssertTrue(McpImageHeader(Hdr, K, W, H));
  AssertEquals(48, H);
end;

procedure TTestImageInfo.TestJpeg;
var
  K : string;
  W, H : Integer;
begin
  AssertTrue(McpImageHeader(JpegOf(640, 480), K, W, H));
  AssertEquals('jpeg', K);
  AssertEquals(640, W);
  AssertEquals(480, H);
end;

procedure TTestImageInfo.TestJpegWithoutFrame;
var
  K : string;
  W, H : Integer;
begin
  { cut off before the frame header, and a segment length that points nowhere }
  AssertFalse(McpImageHeader(#$FF#$D8#$FF#$E0#0#16 + StringOfChar('J', 14), K, W, H));
  AssertFalse(McpImageHeader(#$FF#$D8#$FF#$E0#0#1 + StringOfChar('J', 14), K, W, H));
  AssertFalse(McpImageHeader(#$FF#$D8 + StringOfChar('x', 20), K, W, H));
end;

procedure TTestImageInfo.TestNotPictures;
var
  K : string;
  W, H : Integer;
begin
  AssertFalse(McpImageHeader('', K, W, H));
  AssertFalse(McpImageHeader('<svg xmlns="http://www.w3.org/2000/svg"/>', K, W, H));
  AssertFalse(McpImageHeader('MZ' + StringOfChar(#0, 40), K, W, H));
  AssertFalse(McpImageHeader(#$89'PNG'#13#10#26#10, K, W, H));
  { a PNG signature without an IHDR chunk }
  AssertFalse(McpImageHeader(#$89'PNG'#13#10#26#10 + Be32(13) + 'IDAT' + Be32(1) + Be32(1), K, W, H));
end;

procedure TTestImageInfo.TestDeclaredKind;
var
  K, Why : string;
begin
  AssertTrue(McpImageAcceptable(PngOf(10, 10), 'png', K, Why));
  AssertTrue(McpImageAcceptable(PngOf(10, 10), '', K, Why));
  AssertFalse(McpImageAcceptable(PngOf(10, 10), 'gif', K, Why));
  AssertTrue(Why <> '');
  AssertFalse(McpImageAcceptable('plain text, long enough', 'png', K, Why));
end;

procedure TTestImageInfo.TestTooManyPixels;
var
  K, Why : string;
begin
  AssertTrue(McpImageAcceptable(PngOf(4000, 4000), 'png', K, Why));      { 16 MP exactly }
  AssertFalse(McpImageAcceptable(PngOf(4001, 4000), 'png', K, Why));
  AssertFalse(McpImageAcceptable(PngOf(60000, 60000), 'png', K, Why));
end;

procedure TTestImageInfo.TestImpossibleSizes;
var
  K : string;
  W, H : Integer;
begin
  AssertFalse(McpImageHeader(PngOf(0, 10), K, W, H));
  AssertFalse(McpImageHeader(PngOf(10, 0), K, W, H));
  AssertFalse(McpImageHeader(PngOf($FFFFFFFF, 10), K, W, H));
  AssertFalse(McpImageHeader(PngOf(200000, 10), K, W, H));
end;

initialization
  RegisterTest(TTestMarkdown);
  RegisterTest(TTestImageInfo);

end.
