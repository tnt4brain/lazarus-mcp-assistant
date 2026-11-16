{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsMarkdown;

{ ide_show_markdown (ADR-024): show a Markdown document to the user in an IDE window.
  Runs on the main thread, answers at once, and the window never takes the focus. }

{$mode objfpc}{$H+}

interface

implementation

uses
  Classes, SysUtils, fpjson, LazUTF8, LazFileUtils, MacroIntf,
  McpToolContext, McpMarkdown, McpMarkdownView;

const
  MCP_MD_MAX_TEXT  = 256 * 1024;   { bytes of text, the Base64 of data: images apart }
  MCP_MD_MAX_TITLE = 80;           { characters }
  MCP_MD_MAX_TOTAL = 48 * 1024 * 1024;

const
  SCHEMA_SHOW_MARKDOWN =
    '{"type":"object","properties":{' +
    '"markdown":{"type":"string","description":"The document, Markdown (at most 256 KB of text). Give this or file"},' +
    '"file":{"type":"string","description":"Or a Markdown file on the IDE''s machine, absolute or relative to the project directory (at most 8 MB): its tab shows the file, follows it when it changes (the open editor''s text while it is open, else the disk), and is reused for the same file instead of a new tab"},' +
    '"title":{"type":"string","description":"With markdown: the tab''s title (at most 80 characters)"},' +
    '"tab":{"type":"string","description":"With markdown: the id a previous call returned, that tab''s document is replaced. Without it, or if that tab is closed, a new tab opens"}}}';

{ A bad argument comes back as a tool error. }
procedure Fail(var Ctx: TMcpToolCall; const AMsg: string);
begin
  Ctx.Error := True;
  Ctx.Result := AMsg;
end;

function DispatchMarkdownTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  Md, Title, Tab, BaseDir, TabId, Err, FileName : string;
  Obj : TJSONObject;
begin
  Result := Name = 'ide_show_markdown';
  if not Result then Exit;
  if Ctx.Params = nil then
  begin
    Fail(Ctx, 'markdown (the document) or file (a Markdown file) is required');
    Exit;
  end;
  { either-or, checked here: a oneOf at the top of the schema is rejected by the API }
  FileName := Trim(Ctx.Params.Get('file', ''));
  if (FileName <> '') and (Ctx.Params.Find('markdown') <> nil) then
  begin
    Fail(Ctx, 'give markdown or file, not both');
    Exit;
  end;
  if FileName <> '' then
  begin
    BaseDir := '$(ProjPath)';
    if not Assigned(IDEMacros) or not IDEMacros.SubstituteMacros(BaseDir) then
      BaseDir := '';
    if not FilenameIsAbsolute(FileName) then
    begin
      if BaseDir = '' then
      begin
        Fail(Ctx, 'file is relative and the project has no directory: give an absolute path');
        Exit;
      end;
      FileName := CleanAndExpandFilename(IncludeTrailingPathDelimiter(BaseDir) + FileName);
    end;
    if not McpMarkdownOpenFile(FileName, '', TabId, Err) then
    begin
      Fail(Ctx, 'Could not show the file: ' + Err);
      Exit;
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('shown', True);
      Obj.Add('tab', TabId);
      Obj.Add('file', FileName);
      Obj.Add('follows_file', True);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
    Exit;
  end;
  if (Ctx.Params.Find('markdown') = nil) or
     (Ctx.Params.Find('markdown').JSONType <> jtString) then
  begin
    Fail(Ctx, 'markdown (the document, as a string) or file (a Markdown file) is required');
    Exit;
  end;
  Md := Ctx.Params.Get('markdown', '');
  Title := Ctx.Params.Get('title', '');
  Tab := Ctx.Params.Get('tab', '');
  if Length(Md) > MCP_MD_MAX_TOTAL then
  begin
    Fail(Ctx, 'markdown is too large');
    Exit;
  end;
  if MdTextSize(Md) > MCP_MD_MAX_TEXT then
  begin
    Fail(Ctx, 'markdown holds more than 256 KB of text (the Base64 of data: images does not count): ' +
              'shorten it or split it into several tabs');
    Exit;
  end;
  if UTF8Length(Title) > MCP_MD_MAX_TITLE then
  begin
    Fail(Ctx, 'title is longer than 80 characters');
    Exit;
  end;
  BaseDir := '$(ProjPath)';
  if not Assigned(IDEMacros) or not IDEMacros.SubstituteMacros(BaseDir) then
    BaseDir := '';
  if not McpMarkdownShow(Md, Title, Tab, BaseDir, TabId, Err) then
  begin
    Fail(Ctx, 'Could not show the document: ' + Err);
    Exit;
  end;
  Obj := TJSONObject.Create;
  try
    Obj.Add('shown', True);
    Obj.Add('tab', TabId);
    Ctx.Result := Obj.AsJSON;
  finally
    Obj.Free;
  end;
end;

procedure RegisterMarkdownSchemas(Tools: TJSONArray);
begin
  Tools.Add(MakeTool('ide_show_markdown',
    'Show a Markdown document to the user in a window of the IDE, rendered (headings, lists, ' +
    'tables, code, links, images). Use it for long, structured output (a report, a plan, a ' +
    'table, code) and keep the chat reply short; not for a short answer. Returns at once; the ' +
    'window does not take the focus, and nothing comes back from it. A later call with the ' +
    'returned tab replaces that tab''s document; without it a new tab opens (at most 8). ' +
    'For a document that lives in a file give file instead of the text: one tab per file, kept ' +
    'up to date as the file or its editor changes, and no text to send each time. ' +
    'Supported: headings, emphasis, strikethrough, inline and fenced code, lists and task ' +
    'lists, block quotes (also > [!note] alerts and >>> blocks), GFM tables, http(s) links ' +
    '(also reference links and bare addresses), footnotes, description lists, rules, ' +
    '[[_TOC_]] and #heading links, :emoji:, <kbd>, <sub>, <sup>, <br>; <!-- comments --> are ' +
    'hidden. Other raw HTML is shown as text. Images: a ' +
    'local path (relative to the project directory; png, jpg, gif, bmp, at most 8 MB) or a ' +
    'data:image/(png|jpeg|gif|bmp);base64 URI (at most 4 MB decoded; the way to show a ' +
    'picture when the assistant runs on another machine); http(s) images are not fetched and ' +
    'show as their alt text.',
    SCHEMA_SHOW_MARKDOWN, MCP_ANN_RO));
end;

initialization
  RegisterMcpGroup(@DispatchMarkdownTool);
  RegisterMcpSchemas(@RegisterMarkdownSchemas);

end.
