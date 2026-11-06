{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpMessages;

{ Our lines in the IDE's Messages window, and telling them from the compiler's.

  Our lines carry SubToolMCPServer as their SubTool, as the FPC parser's lines carry
  SubToolFPC: that, and nothing else, says a line is ours.  They go to one view,
  captioned 'MCP Server', which is only where they are put.  That view has no
  external tool behind it.  A compiler run, on the other hand, has one: its view
  is made from the tool (TExternalToolIDE.CreateView), and the tool, with its
  Data, lives as long as the view does (TAbstractExternalTool.CanFree), so a
  finished compile still says what it was: Data.Kind is IDEToolCompileProject,
  IDEToolCompilePackage or IDEToolCompileIDE.  Main thread only. }

{$mode objfpc}{$H+}

interface

uses
  IDEMsgIntf, IDEExternToolIntf;

const
  MCP_MSG_VIEW     = 'MCP Server';
  SubToolMCPServer = 'MCP Server';

{ A line in our view. }
procedure McpAddMessage(AUrgency: TMessageLineUrgency; const AText: string);

function McpIsOwnView(AView: TExtToolView): Boolean;
function McpIsOwnLine(ALine: TMessageLine): Boolean;

{ The view of the last compile (project, package or IDE) the IDE ran, or nil. }
function McpCompilerView: TExtToolView;

implementation

procedure McpAddMessage(AUrgency: TMessageLineUrgency; const AText: string);
var
  Line : TMessageLine;
begin
  if not Assigned(IDEMessagesWindow) then Exit;
  Line := IDEMessagesWindow.AddCustomMessage(AUrgency, AText, '', 0, 0, MCP_MSG_VIEW);
  if Assigned(Line) then Line.SubTool := SubToolMCPServer;
end;

function McpIsOwnLine(ALine: TMessageLine): Boolean;
begin
  Result := Assigned(ALine) and (ALine.SubTool = SubToolMCPServer);
end;

function McpIsOwnView(AView: TExtToolView): Boolean;
begin
  { by its lines, not by its caption: all of ours are in it, and none of the compiler's }
  Result := Assigned(AView) and (AView.Lines.Count > 0) and McpIsOwnLine(AView.Lines.Items[0]);
end;

function IsCompileKind(const AKind: string): Boolean;
begin
  Result := (AKind = IDEToolCompileProject) or (AKind = IDEToolCompilePackage) or
            (AKind = IDEToolCompileIDE);
end;

function McpCompilerView: TExtToolView;
var
  I    : Integer;
  View : TExtToolView;
begin
  Result := nil;
  if not Assigned(IDEMessagesWindow) then Exit;
  for I := IDEMessagesWindow.ViewCount - 1 downto 0 do
  begin
    View := IDEMessagesWindow.Views[I];
    if Assigned(View.Tool) and (View.Tool.Data is TIDEExternalToolData) and
       IsCompileKind(TIDEExternalToolData(View.Tool.Data).Kind) then
      Exit(View);
  end;
  { no compile tool known: the last view that is not ours, as before }
  for I := IDEMessagesWindow.ViewCount - 1 downto 0 do
    if not McpIsOwnView(IDEMessagesWindow.Views[I]) then
      Exit(IDEMessagesWindow.Views[I]);
end;

end.
