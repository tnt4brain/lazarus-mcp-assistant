{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsMarkdown;

{ ide_show_markdown (ADR-024): show a Markdown document to the user in an IDE window.
  Runs on the main thread, answers at once, and the window never takes the focus. }

{$mode objfpc}{$H+}

interface

implementation

uses
  Classes, SysUtils, fpjson, LazUTF8, MacroIntf,
  McpToolContext, McpMarkdown, McpMarkdownView;

const
  MCP_MD_MAX_TEXT  = 256 * 1024;   { bytes of text, the Base64 of data: images apart }
  MCP_MD_MAX_TITLE = 80;           { characters }
  MCP_MD_MAX_TOTAL = 48 * 1024 * 1024;

const
  SCHEMA_SHOW_MARKDOWN =
    '{"type":"object","properties":{' +
    '"markdown":{"type":"string","description":"The document, Markdown (at most 256 KB of text)"},' +
    '"title":{"type":"string","description":"The tab''s title (at most 80 characters)"},' +
    '"tab":{"type":"string","description":"The id a previous call returned: that tab''s document is replaced. Without it, or if that tab is closed, a new tab opens"}},' +
    '"required":["markdown"]}';

{ A bad argument comes back as a tool error. }
procedure Fail(var Ctx: TMcpToolCall; const AMsg: string);
begin
  Ctx.Error := True;
  Ctx.Result := AMsg;
end;

function DispatchMarkdownTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  Md, Title, Tab, BaseDir, TabId, Err : string;
  Obj : TJSONObject;
begin
  Result := Name = 'ide_show_markdown';
  if not Result then Exit;
  if (Ctx.Params = nil) or (Ctx.Params.Find('markdown') = nil) or
     (Ctx.Params.Find('markdown').JSONType <> jtString) then
  begin
    Fail(Ctx, 'markdown is required: the document, as a string');
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
    'Supported: ATX headings, emphasis, strikethrough, inline and fenced code, lists, ' +
    'block quotes, GFM tables, http(s) links, rules. Raw HTML is shown as text. Images: a ' +
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
