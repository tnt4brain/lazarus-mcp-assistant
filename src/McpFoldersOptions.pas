{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpFoldersOptions;

{ The "Directories" page in Tools > Options > MCP Assistant (ADR-034): the folders the tools may
  work in.  An empty list is no limit; with one or more folders, limited mode is on.  Folders are
  picked, never typed, so none can be relative or mistyped.  OK stores them. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, StdCtrls, Dialogs, Forms, Graphics,
  IDEOptionsIntf, IDEOptEditorIntf;

type
  TMcpFoldersFrame = class(TAbstractIDEOptionsEditor)
  private
    FState   : TLabel;
    FList    : TListBox;
    FAdd     : TButton;
    FRemove  : TButton;
    FNote    : TLabel;
    FPick    : TSelectDirectoryDialog;
    FTop     : Integer;
    function AddLabel(const ACaption: string): TLabel;
    procedure Place(AControl: TControl; ASpaceAfter: Integer = 8);
    procedure AddClicked(Sender: TObject);
    procedure RemoveClicked(Sender: TObject);
    procedure ListChanged(Sender: TObject);
    procedure UpdateState;
  public
    constructor Create(AOwner: TComponent); override;
    function GetTitle: string; override;
    procedure Setup(ADialog: TAbstractOptionsEditorDialog); override;
    procedure ReadSettings(AOptions: TAbstractIDEOptions); override;
    procedure WriteSettings(AOptions: TAbstractIDEOptions); override;
    class function SupportedOptionsClass: TAbstractIDEOptionsClass; override;
  end;

{ Registers the page in the options group AGroupIndex, after the Logging page. }
procedure RegisterMcpFoldersPage(AGroupIndex: Integer);

implementation

{$R *.lfm}

uses
  LazFileUtils, McpIdeState, McpLimitedMode;

function TMcpFoldersFrame.AddLabel(const ACaption: string): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Caption  := ACaption;
  Result.WordWrap := True;
  Place(Result, 2);
end;

procedure TMcpFoldersFrame.Place(AControl: TControl; ASpaceAfter: Integer);
begin
  AControl.Align := alTop;
  AControl.BorderSpacing.Bottom := ASpaceAfter;
  AControl.Top   := FTop;
  Inc(FTop, 100);
  AControl.Parent := Self;
end;

constructor TMcpFoldersFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FTop := 0;

  FState := AddLabel('');
  FState.Font.Style := [fsBold];
  FState.BorderSpacing.Bottom := 8;
  AddLabel('Folders the tools may work in. With none, nothing is limited. With one or more, the ' +
           'tools change files, create projects and read files only inside them, apart from ' +
           'what an assistant has to read (the open project, the loaded packages, the Lazarus ' +
           'and FPC sources) and the temp folder.').BorderSpacing.Bottom := 8;

  FList := TListBox.Create(Self);
  FList.Height := 140;
  FList.OnClick := @ListChanged;
  Place(FList, 6);

  FAdd := TButton.Create(Self);
  FAdd.Caption := 'Add folder...';
  FAdd.Align := alTop;
  FAdd.AutoSize := True;
  FAdd.OnClick := @AddClicked;
  Place(FAdd, 4);
  FRemove := TButton.Create(Self);
  FRemove.Caption := 'Remove selected';
  FRemove.Align := alTop;
  FRemove.AutoSize := True;
  FRemove.OnClick := @RemoveClicked;
  Place(FRemove, 12);

  FNote := AddLabel('This limits the file access of the tools. It does not limit what a program ' +
                    'that a tool builds or runs does. Only you can change this list; the tools ' +
                    'cannot, and the IDE''s settings folder is never written by them.');

  FPick := TSelectDirectoryDialog.Create(Self);
  FPick.Title := 'Folder the tools may work in';
end;

procedure TMcpFoldersFrame.UpdateState;
begin
  if FList.Items.Count > 0 then
    FState.Caption := 'Limited mode is on (' + IntToStr(FList.Items.Count) + ' folder(s)).'
  else
    FState.Caption := 'Limited mode is off: the tools are not limited to folders.';
  FRemove.Enabled := FList.ItemIndex >= 0;
end;

procedure TMcpFoldersFrame.ListChanged(Sender: TObject);
begin
  UpdateState;
end;

procedure TMcpFoldersFrame.AddClicked(Sender: TObject);
var
  C, Why : string;
begin
  if not FPick.Execute then Exit;
  if not McpLimitCleanFolder(FPick.FileName, C, Why) then
  begin
    MessageDlg('MCP Assistant', 'That folder cannot be used: ' + Why, mtWarning, [mbOK], 0);
    Exit;
  end;
  if FList.Items.IndexOf(C) < 0 then FList.Items.Add(C);
  UpdateState;
end;

procedure TMcpFoldersFrame.RemoveClicked(Sender: TObject);
begin
  if FList.ItemIndex >= 0 then FList.Items.Delete(FList.ItemIndex);
  UpdateState;
end;

function TMcpFoldersFrame.GetTitle: string;
begin
  Result := 'Directories';
end;

procedure TMcpFoldersFrame.Setup(ADialog: TAbstractOptionsEditorDialog);
begin
end;

procedure TMcpFoldersFrame.ReadSettings(AOptions: TAbstractIDEOptions);
begin
  if not Assigned(McpSettings) then Exit;
  FList.Items.Assign(McpSettings.AllowedFolders);
  UpdateState;
end;

procedure TMcpFoldersFrame.WriteSettings(AOptions: TAbstractIDEOptions);
begin
  if not Assigned(McpSettings) then Exit;
  McpSettings.AllowedFolders.Assign(FList.Items);
  McpSettings.SaveSettings;
  McpLimitSetFoldersFrom(McpSettings.AllowedFolders);   { from the next call on }
end;

class function TMcpFoldersFrame.SupportedOptionsClass: TAbstractIDEOptionsClass;
begin
  Result := nil;
end;

procedure RegisterMcpFoldersPage(AGroupIndex: Integer);
begin
  RegisterIDEOptionsEditor(AGroupIndex, TMcpFoldersFrame, 4);
end;

end.
