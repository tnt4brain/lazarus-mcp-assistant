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
    procedure TestTaskList;
    procedure TestSetextHeading;
    procedure TestReferenceLinks;
    procedure TestLineBreakTag;
    procedure TestAlert;
    procedure TestMultilineQuote;
    procedure TestEntities;
    procedure TestLinkTitle;
    procedure TestReferenceImage;
    procedure TestBareUrl;
    procedure TestPairedTags;
    procedure TestFootnotes;
    procedure TestDescriptionList;
    procedure TestInlineDiff;
    procedure TestFrontMatter;
    procedure TestToc;
    procedure TestNewSyntaxIsLinear;
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
var
  R : string;
begin
  R := H('');
  Has(R, '<body>' + #10 + '</body></html>');
  Has(R, '<style');                    { the margins }
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
  Has(R, 'bgcolor="#F8F9FA"');
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
  Has(R, '<td width="5" bgcolor="#DEE2E6">');     { the stripe }
  Has(R, '<strong>text</strong>');
  Has(R, '<ul><li>item');
  Has(R, 'lazy');
  HasNot(R, '<blockquote');
end;

procedure TTestMarkdown.TestTable;
var
  R : string;
begin
  R := H('| a | b |' + #10 + '|---|---|' + #10 + '| 1 | `x|y` |' + #10 + '| 2 |' + #10 + 'after');
  Has(R, '<table class="md" border="1"');
  Has(R, '<th bgcolor="#F8F9FA">a</th><th bgcolor="#F8F9FA">b</th>');
  Has(R, '<td bgcolor="#FFFFFF">1</td>');
  Has(R, '<td bgcolor="#FFFFFF">2</td><td bgcolor="#FFFFFF">&nbsp;</td>');
  Has(R, '<p>after</p>');
  { an escaped pipe stays inside the cell }
  Has(H('| a |' + #10 + '|---|' + #10 + '| x \| y |'), '>x | y</td>');
end;

procedure TTestMarkdown.TestTableAlign;
var
  R : string;
begin
  R := H('a | b | c' + #10 + ':-- | :-: | --:' + #10 + '1 | 2 | 3');
  Has(R, '<th align="left" bgcolor="#F8F9FA">a</th>');
  Has(R, '<th align="center" bgcolor="#F8F9FA">b</th>');
  Has(R, '<th align="right" bgcolor="#F8F9FA">c</th>');
  Has(R, '<td align="right" bgcolor="#FFFFFF">3</td>');
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
  Has(H('[x](http://a.b "title")'), '<a href="http://a.b" title="title">x</a>');
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

procedure TTestMarkdown.TestTaskList;
var
  R : string;
begin
  R := H('- [ ] open' + #10 + '- [x] done' + #10 + '- [X] big' + #10 + '- [y] other');
  Has(R, '<li>' + #$E2#$98#$90 + ' open');
  Has(R, '<li>' + #$E2#$98#$91 + ' done');
  Has(R, '<li>' + #$E2#$98#$91 + ' big');
  Has(R, '<li>[y] other');
end;

procedure TTestMarkdown.TestSetextHeading;
var
  R : string;
begin
  R := H('Title' + #10 + '=====' + #10#10 + 'Sub' + #10 + '---' + #10#10 + 'text');
  Has(R, '<h1>Title</h1>');
  Has(R, '<h2>Sub</h2>');
  Has(R, '<p>text</p>');
  HasNot(R, '<hr>');
  { more than one line }
  Has(H('a **b**' + #10 + 'c' + #10 + '==='), '<h1>a <strong>b</strong> c</h1>');
  { a rule after a blank line is still a rule }
  Has(H('a' + #10#10 + '---'), '<hr>');
end;

procedure TTestMarkdown.TestReferenceLinks;
var
  R : string;
begin
  R := H('see [docs][d], [d] and [x][] now' + #10#10 + '[d]: https://example.com "t"' + #10 +
         '[X]: <http://a.b>');
  Has(R, '<a href="https://example.com" title="t">docs</a>');
  Has(R, '<a href="https://example.com" title="t">d</a>');
  Has(R, '<a href="http://a.b">x</a>');
  HasNot(R, ']:');
  { an undefined label stays text }
  Has(H('[nope] and [a][b]'), '[nope] and [a][b]');
  { definitions inside a fence are code }
  Has(H('```' + #10 + '[a]: http://x' + #10 + '```'), '[a]:');
  { only http(s) is a live link, as for inline links }
  R := H('[t][j]' + #10#10 + '[j]: javascript:alert(1)');
  HasNot(R, '<a href');
  Has(R, 't');
  { a sentence that starts with a bracket is not a definition }
  Has(H('[1]: see below'), '[1]: see below');
end;

procedure TTestMarkdown.TestLineBreakTag;
begin
  Has(H('a<br>b'), 'a<br>b');
  Has(H('a<BR/>b'), 'a<br>b');
  Has(H('a<br />b'), 'a<br>b');
  Has(H('| a |' + #10 + '|---|' + #10 + '| x<br>y |'), '>x<br>y</td>');
  HasNot(H('a<br>b'), '&lt;br');
  { other tags stay escaped }
  Has(H('<b>x</b>'), '&lt;b&gt;');
end;

procedure TTestMarkdown.TestAlert;
var
  R : string;
begin
  R := H('> [!note]' + #10 + '> hello');
  Has(R, '<td width="5" bgcolor="#0D6EFD">');
  Has(R, '<strong><font color="#0D6EFD">Note</font></strong>');
  Has(R, 'hello');
  HasNot(R, '[!note]');
  R := H('> [!warning] Careful now' + #10 + '> x');
  Has(R, '#FD7E14');
  Has(R, 'Careful now');
  { an unknown kind is an ordinary quote }
  R := H('> [!bogus]' + #10 + '> x');
  Has(R, '<td width="5" bgcolor="#DEE2E6">');
  Has(R, '[!bogus]');
end;

procedure TTestMarkdown.TestMultilineQuote;
var
  R : string;
begin
  R := H('>>>' + #10 + 'line one' + #10#10 + 'line two' + #10 + '>>>' + #10 + 'after');
  Has(R, '<td width="5" bgcolor="#DEE2E6">');
  Has(R, 'line one');
  Has(R, 'line two');
  Has(R, '<p>after</p>');
  { not closed: up to the end }
  Has(H('>>>' + #10 + 'open'), 'open');
  HasNot(H('>>>' + #10 + 'open'), '&gt;');
end;

procedure TTestMarkdown.TestEntities;
begin
  Has(H('a &amp; b'), 'a &amp; b');
  Has(H('&copy; &#35; &#x41; &mdash;'), #$C2#$A9' # A '#$E2#$80#$94);
  { a decoded "<" is text, never a tag; and no markup from "&#42;" }
  Has(H('&lt;script&gt;'), '&lt;script&gt;');
  HasNot(H('&#42;a&#42;'), '<em>');
  { unknown, controls and a missing semicolon stay as typed }
  Has(H('&bogus; &#0; &#1; &copy'), '&amp;bogus; &amp;#0; &amp;#1; &amp;copy');
  { inside code nothing is decoded }
  Has(H('`&amp;`'), '&amp;amp;');
end;

procedure TTestMarkdown.TestLinkTitle;
begin
  Has(H('[x](http://a.b "the title")'), '<a href="http://a.b" title="the title">x</a>');
  Has(H('[x](http://a.b ''t'')'), 'title="t"');
  Has(H('[r]' + #10#10 + '[r]: http://a.b (hint)'), 'title="hint"');
  HasNot(H('[x](http://a.b)'), 'title=');
end;

procedure TTestMarkdown.TestReferenceImage;
begin
  Has(H('![pic][p]' + #10#10 + '[p]: images/a.png'), '<img src="images/a.png" alt="pic">');
end;

procedure TTestMarkdown.TestBareUrl;
begin
  Has(H('go to https://example.com/a_b?x=1&y=2.'), '<a href="https://example.com/a_b?x=1&amp;y=2">');
  { trailing dot and a closing parenthesis are not part of it }
  Has(H('(see http://a.b/c).'), '<a href="http://a.b/c">http://a.b/c</a>).');
  Has(H('http://a.b/x_(y)'), '<a href="http://a.b/x_(y)">');
  Has(H('**https://a.b**'), '<strong><a href="https://a.b">');
  { not in a word, not inside a link, not other schemes }
  HasNot(H('xhttp://a.b'), '<a ');
  Has(H('[see http://a.b](http://c.d)'), '<a href="http://c.d">see http://a.b</a>');
  HasNot(H('ftp://a.b/c'), '<a ');
  HasNot(H('http://'), '<a ');
end;

procedure TTestMarkdown.TestPairedTags;
begin
  Has(H('press <kbd>Ctrl</kbd>+<KBD>C</KBD>'), 'press <kbd>Ctrl</kbd>+<kbd>C</kbd>');
  Has(H('H<sub>2</sub>O and x<sup>2</sup>'), 'H<sub>2</sub>O and x<sup>2</sup>');
  { a tag without its closing one stays text }
  Has(H('a <sub>b'), 'a &lt;sub&gt;b');
  HasNot(H('a <sub>b'), '<sub>');
  { markup inside works; other tags stay escaped }
  Has(H('<kbd>**x**</kbd>'), '<kbd><strong>x</strong></kbd>');
  Has(H('<kbd><b>x</b></kbd>'), '<kbd>&lt;b&gt;x&lt;/b&gt;</kbd>');
end;

procedure TTestMarkdown.TestFootnotes;
var
  R : string;
begin
  R := H('One[^a] and two[^b] and one again[^a].' + #10#10 + '[^a]: First *note*.' + #10 +
         '[^b]: Second.');
  Has(R, 'One<sup>1</sup> and two<sup>2</sup> and one again<sup>1</sup>.');
  Has(R, '<hr><ol><li>First <em>note</em>.</li><li>Second.</li></ol>');
  HasNot(R, '[^a]:');
  { an undefined one stays text; an unused definition shows nothing }
  Has(H('x[^zz]'), 'x[^zz]');
  HasNot(H('[^a]: unused'), '<ol>');
  { a note that cites itself ends }
  Has(H('x[^a]' + #10#10 + '[^a]: me[^a]'), '<li>me<sup>1</sup></li>');
end;

procedure TTestMarkdown.TestDescriptionList;
var
  R : string;
begin
  R := H('Term' + #10 + ': first' + #10 + ': second' + #10#10 + 'Other' + #10 + ': third' +
         #10#10 + 'after');
  Has(R, '<dl><dt><strong>Term</strong></dt><dd>first</dd><dd>second</dd>');
  Has(R, '<dt><strong>Other</strong></dt><dd>third</dd></dl>');
  Has(R, '<p>after</p>');
  { a lone ": x" line is a paragraph }
  HasNot(H(': x'), '<dl>');
end;

procedure TTestMarkdown.TestInlineDiff;
begin
  Has(H('a {+ added +} b'), 'a <font color="#198754"><u>added</u></font> b');
  Has(H('a [- gone -] b'), 'a <font color="#DC3545"><del>gone</del></font> b');
  { not closed: text }
  Has(H('a {+ x'), 'a {+ x');
  { a task box is not a diff }
  Has(H('[+]'), '[+]');
end;

procedure TTestMarkdown.TestToc;
var
  R : string;
begin
  R := H('[[_TOC_]]' + #10#10 + '# One' + #10#10 + '## Two *a*' + #10#10 + '## Three' + #10#10 +
         '#### Deep' + #10#10 + '# Four' + #10#10 + 'Five' + #10 + '---');
  Has(R, '<ul><li>One<ul><li>Two <em>a</em></li><li>Three<ul><li>Deep</li></ul></li></ul></li>' +
         '<li>Four<ul><li>Five</li></ul></li></ul>');
  { [TOC] works too, in any case; with no headings there is nothing }
  Has(H('[toc]' + #10#10 + '# A'), '<ul><li>A</li></ul>');
  HasNot(H('[TOC]'), '<ul>');
  { the marker never reaches the page, also when typed into the text }
  HasNot(R, #3);
  HasNot(H('a' + #3 + 'b' + #10#10 + '# A'), #3);
  { two of them list the same headings; a heading in a quote is not listed }
  R := H('[TOC]' + #10#10 + '[[_TOC_]]' + #10#10 + '# A' + #10#10 + '> # Q');
  AssertEquals(2, (Length(R) - Length(StringReplace(R, '<ul><li>A</li></ul>', '', [rfReplaceAll]))) div
    Length('<ul><li>A</li></ul>'));
  { in a code block it is code }
  Has(H('```' + #10 + '[TOC]' + #10 + '```' + #10#10 + '# A'), '<tt>[TOC]</tt>');
end;

procedure TTestMarkdown.TestNewSyntaxIsLinear;
var
  I : Integer;
  S : string;
  T : QWord;
begin
  { many unclosed tags, brackets, entities and addresses on one line must not be quadratic }
  S := '';
  for I := 1 to 20000 do
    S := S + '<sub>[^a]{+ &amp; [x][y] [[[ [x](u http://a.b ![i](';
  T := GetTickCount64;
  H(S);
  AssertTrue('took ' + IntToStr(GetTickCount64 - T) + ' ms', GetTickCount64 - T < 3000);
end;

procedure TTestMarkdown.TestFrontMatter;
var
  R : string;
begin
  R := H('---' + #10 + 'title: A doc' + #10 + 'tags: [x]' + #10 + '---' + #10#10 + '# Head');
  Has(R, '<tt>title:&nbsp;A&nbsp;doc</tt>');
  Has(R, '<h1>Head</h1>');
  HasNot(R, '<hr>');
  { without a key it is a rule and text }
  Has(H('---' + #10 + 'plain' + #10 + '---'), '<hr>');
  { only at the very top }
  HasNot(H('text' + #10 + '---' + #10 + 'a: b' + #10 + '---'), '<tt>a:');
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
