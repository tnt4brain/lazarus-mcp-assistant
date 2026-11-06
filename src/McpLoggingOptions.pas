{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpLoggingOptions;

{ The "Logging" page in Tools > Options > MCP Assistant (ADR-022): whether every tool
  call is logged to a file, which file, and whether each finished call also gets one
  line in the Messages window.  Values live in McpSettings; OK stores them. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, StdCtrls, EditBtn, Forms,
  IDEOptionsIntf, IDEOptEditorIntf;

type
  TMcpLoggingFrame = class(TAbstractIDEOptionsEditor)
  private
    FFileOn   : TCheckBox;
    FFileName : TFileNameEdit;
    FFileNote : TLabel;
    FPane     : TCheckBox;
    FTop      : Integer;
    function AddLabel(const ACaption: string): TLabel;
    procedure Place(AControl: TControl; ASpaceAfter: Integer = 8);
  public
    constructor Create(AOwner: TComponent); override;
    function GetTitle: string; override;
    procedure Setup(ADialog: TAbstractOptionsEditorDialog); override;
    procedure ReadSettings(AOptions: TAbstractIDEOptions); override;
    procedure WriteSettings(AOptions: TAbstractIDEOptions); override;
    class function SupportedOptionsClass: TAbstractIDEOptionsClass; override;
  end;

{ Registers the page in the options group AGroupIndex, after the Tokens page. }
procedure RegisterMcpLoggingPage(AGroupIndex: Integer);

implementation

{$R *.lfm}

uses
  Dialogs, McpIdeState, McpIdeServer;

function TMcpLoggingFrame.AddLabel(const ACaption: string): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Caption  := ACaption;
  Result.WordWrap := True;
  Place(Result, 2);
end;

procedure TMcpLoggingFrame.Place(AControl: TControl; ASpaceAfter: Integer);
begin
  AControl.Align := alTop;
  AControl.BorderSpacing.Bottom := ASpaceAfter;
  AControl.Top   := FTop;
  Inc(FTop, 100);
  AControl.Parent := Self;
end;

constructor TMcpLoggingFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FTop := 0;

  FFileOn := TCheckBox.Create(Self);
  FFileOn.Caption := 'Log every tool call to a file (tool, caller, time, outcome, ' +
                     'argument names and a hash of them; no argument values or results)';
  Place(FFileOn);

  AddLabel('Log file (empty: mcp-tools.log in the Lazarus configuration folder):');
  FFileName := TFileNameEdit.Create(Self);
  FFileName.DialogOptions := FFileName.DialogOptions - [ofFileMustExist];
  Place(FFileName, 2);
  FFileNote := AddLabel('');
  FFileNote.BorderSpacing.Bottom := 16;

  FPane := TCheckBox.Create(Self);
  FPane.Caption := 'Show one line per finished tool call in the Messages window ' +
                   '(view "MCP Server")';
  Place(FPane);
end;

function TMcpLoggingFrame.GetTitle: string;
begin
  Result := 'Logging';
end;

procedure TMcpLoggingFrame.Setup(ADialog: TAbstractOptionsEditorDialog);
begin
end;

procedure TMcpLoggingFrame.ReadSettings(AOptions: TAbstractIDEOptions);
begin
  if not Assigned(McpSettings) then Exit;
  FFileOn.Checked   := McpSettings.ToolCallLog;
  FFileName.Text    := McpSettings.ToolLogFile;
  FFileName.TextHint := 'mcp-tools.log (Lazarus configuration folder)';
  FFileNote.Caption := 'Error texts in the file can hold file paths and user names; ' +
                       'look before you post it. Rotated at 4 MB (3 older files kept).';
  FPane.Checked     := McpSettings.ToolLogPane;
end;

procedure TMcpLoggingFrame.WriteSettings(AOptions: TAbstractIDEOptions);
begin
  if not Assigned(McpSettings) then Exit;
  McpSettings.ToolCallLog := FFileOn.Checked;
  McpSettings.ToolLogFile := Trim(FFileName.Text);
  McpSettings.ToolLogPane := FPane.Checked;
  McpSettings.SaveSettings;
  McpApplyToolLogSetting;   { from the next call on }
end;

class function TMcpLoggingFrame.SupportedOptionsClass: TAbstractIDEOptionsClass;
begin
  Result := nil;
end;

procedure RegisterMcpLoggingPage(AGroupIndex: Integer);
begin
  RegisterIDEOptionsEditor(AGroupIndex, TMcpLoggingFrame, 3);
end;

end.
