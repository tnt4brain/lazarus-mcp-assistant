{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpTokensOptions;

{ The "Tokens" page in Tools > Options > MCP Assistant (ADR-021): the named client
  tokens (add, revoke) and the primary token (regenerate).  The tokens themselves
  live in McpSettings.ClientTokens; changes are stored at once, not with OK. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, StdCtrls, Forms, ComCtrls, ExtCtrls,
  IDEOptionsIntf, IDEOptEditorIntf;

type
  TMcpTokensFrame = class(TAbstractIDEOptionsEditor)
  private
    FTokenList : TListView;
    FRevokeBtn : TButton;
    procedure RefreshTokens;
    procedure TokenSelectionChanged(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure AddTokenClick(Sender: TObject);
    procedure RevokeTokenClick(Sender: TObject);
    procedure RegenerateClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    function GetTitle: string; override;
    procedure Setup(ADialog: TAbstractOptionsEditorDialog); override;
    procedure ReadSettings(AOptions: TAbstractIDEOptions); override;
    procedure WriteSettings(AOptions: TAbstractIDEOptions); override;
    class function SupportedOptionsClass: TAbstractIDEOptionsClass; override;
  end;

{ Registers the page in the options group AGroupIndex, after the General page. }
procedure RegisterMcpTokensPage(AGroupIndex: Integer);

{ Asks for a name, makes a named client token and shows it once: masked, with an eye
  to reveal it and buttons to copy the token or the whole client config.  False if
  cancelled or refused. }
function McpCreateClientToken: Boolean;

implementation

{$R *.lfm}

uses
  Dialogs, Clipbrd, DateUtils, Graphics, Buttons,
  McpIdeState, McpIdeServer, McpTokens, McpDebugLease, McpSessionLog;

function TimeText(AUnix: Int64): string;
begin
  if AUnix <= 0 then
    Result := 'never'
  else
    Result := FormatDateTime('yyyy-mm-dd hh:nn', UnixToDateTime(AUnix, True));
end;

type
  { Shows a new token once: masked, with an eye to reveal it and a button to copy it,
    and a button for the whole client config with this token in it. }
  TNewTokenForm = class(TForm)
  private
    FEdit   : TEdit;
    FEye    : TSpeedButton;
    FNote   : TLabel;
    FToken  : string;
    FConfig : string;
    procedure ShowToken(AShown: Boolean);
    procedure EyeClick(Sender: TObject);
    procedure CopyTokenClick(Sender: TObject);
    procedure CopyConfigClick(Sender: TObject);
  public
    constructor CreateToken(AOwner: TComponent; const AName, AToken, AConfig: string);
  end;

{ A 20x20 eye, or an eye struck through }
function EyeBitmap(AClosed: Boolean): TBitmap;
begin
  Result := TBitmap.Create;
  Result.SetSize(20, 20);
  Result.Transparent      := True;
  Result.TransparentColor := clFuchsia;
  with Result.Canvas do
  begin
    Brush.Color := clFuchsia;
    FillRect(0, 0, 20, 20);
    Pen.Color := clBlack;
    Pen.Width := 1;
    Brush.Color := clWhite;
    Ellipse(1, 5, 19, 15);
    Brush.Color := clBlack;
    Ellipse(7, 6, 13, 14);
    if AClosed then
    begin
      Pen.Width := 2;
      Pen.Color := clRed;
      Line(3, 17, 17, 3);
    end;
  end;
end;

constructor TNewTokenForm.CreateToken(AOwner: TComponent; const AName, AToken,
  AConfig: string);
var
  Intro  : TLabel;
  Row    : TPanel;
  Bottom : TPanel;
  B      : TButton;
begin
  inherited CreateNew(AOwner);
  FToken  := AToken;
  FConfig := AConfig;
  Caption     := 'New token "' + AName + '"';
  Position    := poScreenCenter;
  BorderStyle := bsDialog;
  ClientWidth  := 520;
  ClientHeight := 150;

  Intro := TLabel.Create(Self);
  Intro.Caption := 'This token is shown only now: only a hash of it is kept. Copy it ' +
    'before you close this window; if it is lost, revoke it and make another.';
  Intro.WordWrap := True;
  Intro.Align := alTop;
  Intro.Top   := 0;
  Intro.BorderSpacing.Around := 10;
  Intro.Parent := Self;

  Row := TPanel.Create(Self);
  Row.BevelOuter := bvNone;
  Row.Height := 28;
  Row.Align  := alTop;
  Row.Top    := 1000;
  Row.BorderSpacing.Left  := 10;
  Row.BorderSpacing.Right := 10;
  Row.Parent := Self;

  { rightmost first: Copy, then the eye, then the field takes the rest }
  B := TButton.Create(Self);
  B.Caption := 'Copy';
  B.Width   := 64;
  B.Align   := alRight;
  B.BorderSpacing.Left := 4;
  B.OnClick := @CopyTokenClick;
  B.Parent  := Row;
  FEye := TSpeedButton.Create(Self);
  FEye.Width  := 30;
  FEye.Align  := alRight;
  FEye.BorderSpacing.Left := 4;
  FEye.Flat   := False;
  FEye.Hint   := 'Show or hide the token';
  FEye.ShowHint := True;
  FEye.OnClick  := @EyeClick;
  FEye.Parent   := Row;
  FEdit := TEdit.Create(Self);
  FEdit.ReadOnly := True;
  FEdit.Text     := AToken;
  FEdit.Align    := alClient;
  FEdit.Parent   := Row;
  ShowToken(False);

  FNote := TLabel.Create(Self);
  FNote.Caption := ' ';
  FNote.Align   := alTop;
  FNote.Top     := 2000;
  FNote.BorderSpacing.Left := 10;
  FNote.BorderSpacing.Top  := 4;
  FNote.Parent  := Self;

  Bottom := TPanel.Create(Self);
  Bottom.BevelOuter := bvNone;
  Bottom.Height := 40;
  Bottom.Align  := alBottom;
  Bottom.Parent := Self;
  B := TButton.Create(Self);
  B.Caption := 'Close';
  B.ModalResult := mrOK;
  B.Default := True;
  B.Align   := alRight;
  B.BorderSpacing.Around := 6;
  B.Parent  := Bottom;
  B := TButton.Create(Self);
  B.Caption  := 'Copy the whole MCP server config';
  B.AutoSize := True;
  B.Align    := alLeft;
  B.BorderSpacing.Around := 6;
  B.Enabled  := AConfig <> '';
  B.OnClick  := @CopyConfigClick;
  B.Parent   := Bottom;
  if AConfig = '' then
    FNote.Caption := 'The server is not running: the config can be copied once it is.';
end;

procedure TNewTokenForm.ShowToken(AShown: Boolean);
var
  Bmp : TBitmap;
begin
  if AShown then FEdit.PasswordChar := #0 else FEdit.PasswordChar := '*';
  Bmp := EyeBitmap(AShown);
  try
    FEye.Glyph.Assign(Bmp);
  finally
    Bmp.Free;
  end;
end;

procedure TNewTokenForm.EyeClick(Sender: TObject);
begin
  ShowToken(FEdit.PasswordChar <> #0);
end;

procedure TNewTokenForm.CopyTokenClick(Sender: TObject);
begin
  Clipboard.AsText := FToken;
  FNote.Caption := 'The token is on the clipboard.';
end;

procedure TNewTokenForm.CopyConfigClick(Sender: TObject);
begin
  Clipboard.AsText := FConfig;
  FNote.Caption := 'The MCP server config, with this token, is on the clipboard.';
end;

{ The token is shown here, once, and never again }
procedure ShowNewTokenDialog(const AName, AToken, AConfig: string);
var
  F : TNewTokenForm;
begin
  F := TNewTokenForm.CreateToken(nil, AName, AToken, AConfig);
  try
    F.ShowModal;
  finally
    F.Free;
  end;
end;

function McpCreateClientToken: Boolean;
var
  Name, Tok, Err, Cfg : string;
begin
  Result := False;
  if not Assigned(McpSettings) then Exit;
  Name := 'client-' + IntToStr(McpSettings.ClientTokens.Count + 1);
  if not InputQuery('New client token',
       'A name for the client that will use it (for example laptop or linux-box):', Name) then Exit;
  if not McpSettings.ClientTokens.Add(Name, Tok, Err) then
  begin
    MessageDlg('MCP Assistant', Err, mtError, [mbOK], 0);
    Exit;
  end;
  McpSettings.SaveSettings;
  McpLogSession('token "' + Trim(Name) + '" created');
  { the config needs the running server's address }
  if IsServerRunning then Cfg := McpClientConfigJSON(Tok) else Cfg := '';
  ShowNewTokenDialog(Trim(Name), Tok, Cfg);
  Result := True;
end;


{ TMcpTokensFrame }

constructor TMcpTokensFrame.Create(AOwner: TComponent);
var
  Intro   : TLabel;
  Buttons : TPanel;
  Btn     : TButton;
begin
  inherited Create(AOwner);

  Intro := TLabel.Create(Self);
  Intro.Caption :=
    'Give each client on another machine its own token. A token is shown once, when it ' +
    'is made; only a hash is kept, so a lost one is revoked and replaced. The primary ' +
    'token, which the IDE writes into the config of clients on this machine, is never ' +
    'shown. Changes on this page take effect at once.';
  Intro.WordWrap := True;
  Intro.Align    := alTop;
  Intro.BorderSpacing.Around := 8;
  Intro.Parent   := Self;

  Buttons := TPanel.Create(Self);
  Buttons.BevelOuter := bvNone;
  Buttons.Height     := 36;
  Buttons.Align      := alBottom;
  Buttons.Parent     := Self;

  FTokenList := TListView.Create(Self);
  FTokenList.ViewStyle := vsReport;
  FTokenList.ReadOnly  := True;
  FTokenList.RowSelect := True;
  with FTokenList.Columns.Add do begin Caption := 'Name';      Width := 200; end;
  with FTokenList.Columns.Add do begin Caption := 'Created';   Width := 140; end;
  with FTokenList.Columns.Add do begin Caption := 'Last used'; Width := 140; end;
  with FTokenList.Columns.Add do begin Caption := 'Ends with'; Width := 90;  end;
  FTokenList.OnSelectItem := @TokenSelectionChanged;
  FTokenList.Align := alClient;
  FTokenList.BorderSpacing.Left   := 8;
  FTokenList.BorderSpacing.Right  := 8;
  FTokenList.Parent := Self;

  Btn := TButton.Create(Self);
  Btn.Caption  := 'Add token...';
  Btn.OnClick  := @AddTokenClick;
  Btn.AutoSize := True;
  Btn.BorderSpacing.Around := 6;
  Btn.Align    := alLeft;
  Btn.Parent   := Buttons;
  FRevokeBtn := TButton.Create(Self);
  FRevokeBtn.Caption  := 'Revoke';
  FRevokeBtn.OnClick  := @RevokeTokenClick;
  FRevokeBtn.AutoSize := True;
  FRevokeBtn.Enabled  := False;
  FRevokeBtn.BorderSpacing.Around := 6;
  FRevokeBtn.Align    := alLeft;
  FRevokeBtn.Parent   := Buttons;
  Btn := TButton.Create(Self);
  Btn.Caption  := 'Regenerate primary token...';
  Btn.OnClick  := @RegenerateClick;
  Btn.AutoSize := True;
  Btn.BorderSpacing.Around := 6;
  Btn.Align    := alRight;
  Btn.Parent   := Buttons;
end;

function TMcpTokensFrame.GetTitle: string;
begin
  Result := 'Tokens';
end;

procedure TMcpTokensFrame.Setup(ADialog: TAbstractOptionsEditorDialog);
begin
end;

procedure TMcpTokensFrame.ReadSettings(AOptions: TAbstractIDEOptions);
begin
  RefreshTokens;
end;

procedure TMcpTokensFrame.WriteSettings(AOptions: TAbstractIDEOptions);
begin
  { nothing to write: tokens are stored as they are changed }
end;

class function TMcpTokensFrame.SupportedOptionsClass: TAbstractIDEOptionsClass;
begin
  Result := nil;
end;

procedure TMcpTokensFrame.RefreshTokens;
var
  Items : TMcpClientTokens;
  I     : Integer;
  Item  : TListItem;
begin
  FTokenList.Items.BeginUpdate;
  try
    FTokenList.Items.Clear;
    if Assigned(McpSettings) then
    begin
      Items := McpSettings.ClientTokens.Items;
      for I := 0 to High(Items) do
      begin
        Item := FTokenList.Items.Add;
        Item.Caption := Items[I].Name;
        Item.SubItems.Add(TimeText(Items[I].Created));
        Item.SubItems.Add(TimeText(Items[I].LastUsed));
        Item.SubItems.Add('...' + Items[I].Hint);
      end;
    end;
  finally
    FTokenList.Items.EndUpdate;
  end;
  FRevokeBtn.Enabled := FTokenList.Selected <> nil;
end;

procedure TMcpTokensFrame.TokenSelectionChanged(Sender: TObject; Item: TListItem;
  Selected: Boolean);
begin
  FRevokeBtn.Enabled := FTokenList.Selected <> nil;
end;

procedure TMcpTokensFrame.AddTokenClick(Sender: TObject);
begin
  McpCreateClientToken;
  RefreshTokens;
end;

procedure TMcpTokensFrame.RevokeTokenClick(Sender: TObject);
var
  Items   : TMcpClientTokens;
  I       : Integer;
  TokName : string;
begin
  if not Assigned(McpSettings) or (FTokenList.Selected = nil) then Exit;
  TokName := FTokenList.Selected.Caption;
  if MessageDlg('Revoke token', 'Revoke the token "' + TokName + '"? The client using it is ' +
       'cut off at once, and a debug session it holds ends.', mtConfirmation,
       [mbYes, mbNo], 0) <> mrYes then Exit;
  Items := McpSettings.ClientTokens.Items;
  for I := 0 to High(Items) do
    if Items[I].Name = TokName then
    begin
      McpSettings.ClientTokens.Revoke(Items[I].Id);
      McpForgetTokenSessions(Items[I].Id);
      McpLogSession('token "' + TokName + '" revoked');
      Break;
    end;
  McpSettings.SaveSettings;
  RefreshTokens;
end;

procedure TMcpTokensFrame.RegenerateClick(Sender: TObject);
begin
  if MessageDlg('Regenerate the primary token',
       'Make a new primary token? Clients on this machine that the IDE configures (Launch ' +
       'MCP Assistant, mcp-active.json) get it by themselves; one you configured by hand ' +
       'needs the new token. The server restarts. Named tokens are not affected.',
       mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
  McpRegenerateServerToken;
  ShowMessage('The primary token has been replaced.');
end;

procedure RegisterMcpTokensPage(AGroupIndex: Integer);
begin
  RegisterIDEOptionsEditor(AGroupIndex, TMcpTokensFrame, 2);
end;

end.
