{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpConsent;

{ Human consent before an assistant brings new code into the IDE (ADR-013).

  Installing a package rebuilds the IDE with that package's code, which then
  runs with the user's rights every time Lazarus starts.  So installing any
  .lpk that is not installed yet (from that very file) needs
    1. the setting "Allow Assistants to Install Packages" (off by default,
       Tools > MCP Assistant, or Tools > Options > MCP Assistant), and
    2. a yes in a dialog shown in the IDE for this install.
  The dialog is for the human at the keyboard: it is not one of the dialogs
  McpIdeListeners answers during tool calls, its default button is
  "Don't install", and it answers no by itself after CONSENT_TIMEOUT_S.
  Rebuilding packages that are already installed (ide_rebuild, this plugin's
  own development loop) needs no consent.

  Main thread only. }

{$mode objfpc}{$H+}

interface

{ Does installing ALpkPath bring in code that is not installed yet? }
function McpPackageNeedsConsent(const ALpkPath: string): Boolean;

{ True if ALpkPath may be installed: no consent needed, or the setting is on
  and the user said yes.  Otherwise AReason says why not (for the client). }
function McpConfirmPackageInstall(const ALpkPath, AToolName: string;
  out AReason: string): Boolean;

implementation

uses
  Classes, SysUtils, Controls, Forms, StdCtrls, ExtCtrls, Graphics,
  LazFileUtils, Laz2_XMLCfg, PackageIntf, IDEMsgIntf, IDEExternToolIntf,
  McpIdeState;

const
  CONSENT_TIMEOUT_S = 180;

type
  TMcpConsentForm = class(TForm)
  private
    FLeft     : Integer;
    FCountdown: TLabel;
    procedure Tick(Sender: TObject);
  public
    constructor CreateConsent(const ATitle, ADetails: string);
  end;

constructor TMcpConsentForm.CreateConsent(const ATitle, ADetails: string);
var
  Head    : TLabel;
  Memo    : TMemo;
  Bottom  : TPanel;
  BtnYes  : TButton;
  BtnNo   : TButton;
  Timer   : TTimer;
begin
  inherited CreateNew(nil);
  Caption     := 'MCP Assistant: install a package?';
  Position    := poScreenCenter;
  FormStyle   := fsStayOnTop;
  BorderStyle := bsDialog;
  Width       := 620;
  Height      := 420;

  Head := TLabel.Create(Self);
  Head.Parent      := Self;
  Head.Align       := alTop;
  Head.BorderSpacing.Around := 10;
  Head.WordWrap    := True;
  Head.AutoSize    := True;
  Head.Font.Style  := [fsBold];
  Head.Caption     := ATitle;

  Bottom := TPanel.Create(Self);
  Bottom.Parent     := Self;
  Bottom.Align      := alBottom;
  Bottom.Height     := 46;
  Bottom.BevelOuter := bvNone;

  FCountdown := TLabel.Create(Self);
  FCountdown.Parent := Bottom;
  FCountdown.Align  := alLeft;
  FCountdown.BorderSpacing.Around := 12;
  FCountdown.Layout := tlCenter;

  BtnNo := TButton.Create(Self);
  BtnNo.Parent      := Bottom;
  BtnNo.Align       := alRight;
  BtnNo.BorderSpacing.Around := 8;
  BtnNo.Width       := 130;
  BtnNo.Caption     := 'Don''t install';
  BtnNo.ModalResult := mrNo;
  BtnNo.Default     := True;   { Enter must never approve }
  BtnNo.Cancel      := True;

  BtnYes := TButton.Create(Self);
  BtnYes.Parent      := Bottom;
  BtnYes.Align       := alRight;
  BtnYes.BorderSpacing.Around := 8;
  BtnYes.Width       := 130;
  BtnYes.Caption     := '&Install';
  BtnYes.ModalResult := mrYes;

  Memo := TMemo.Create(Self);
  Memo.Parent     := Self;
  Memo.Align      := alClient;
  Memo.BorderSpacing.Around := 10;
  Memo.ReadOnly   := True;
  Memo.ScrollBars := ssAutoBoth;
  Memo.Text       := ADetails;

  ActiveControl := BtnNo;
  FLeft := CONSENT_TIMEOUT_S;
  Tick(nil);
  Timer := TTimer.Create(Self);
  Timer.Interval := 1000;
  Timer.OnTimer  := @Tick;
end;

procedure TMcpConsentForm.Tick(Sender: TObject);
begin
  if Sender <> nil then
    Dec(FLeft);
  if FLeft <= 0 then
  begin
    ModalResult := mrNo;   { nobody answered: no }
    Exit;
  end;
  FCountdown.Caption := Format('No answer in %d s means "Don''t install".', [FLeft]);
end;

{ ── Package details ──────────────────────────────────────────────────────── }

function LpkDetails(const ALpkPath: string): string;
var
  Cfg  : TXMLConfig;
  Ver  : string;
  I, N : Integer;
  Deps : string;
begin
  Result := '';
  try
    Cfg := TXMLConfig.Create(ALpkPath);
    try
      Ver := Format('%d.%d.%d.%d', [
        Cfg.GetValue('Package/Version/Major', 0), Cfg.GetValue('Package/Version/Minor', 0),
        Cfg.GetValue('Package/Version/Release', 0), Cfg.GetValue('Package/Version/Build', 0)]);
      Deps := '';
      N := Cfg.GetValue('Package/RequiredPkgs/Count', 0);
      for I := 1 to N do
      begin
        if Deps <> '' then Deps := Deps + ', ';
        Deps := Deps + Cfg.GetValue(Format('Package/RequiredPkgs/Item%d/PackageName/Value', [I]), '?');
      end;
      Result :=
        'Package:      ' + Cfg.GetValue('Package/Name/Value', ExtractFileNameOnly(ALpkPath)) + ' ' + Ver + LineEnding +
        'Author:       ' + Cfg.GetValue('Package/Author/Value', '') + LineEnding +
        'License:      ' + Cfg.GetValue('Package/License/Value', '') + LineEnding +
        'Requires:     ' + Deps + LineEnding +
        'Files:        ' + IntToStr(Cfg.GetValue('Package/Files/Count', 0)) + LineEnding +
        'Description:  ' + Cfg.GetValue('Package/Description/Value', '') + LineEnding;
    finally
      Cfg.Free;
    end;
  except
    on E: Exception do
      Result := 'Could not read the package file: ' + E.Message + LineEnding;
  end;
end;

procedure LogToIDE(const AMsg: string);
begin
  if Assigned(IDEMessagesWindow) then
    IDEMessagesWindow.AddCustomMessage(mluImportant, AMsg, '', 0, 0, 'MCP Server');
end;

{ ── Public ───────────────────────────────────────────────────────────────── }

function McpPackageNeedsConsent(const ALpkPath: string): Boolean;
var
  Pkg : TIDEPackage;
begin
  Pkg := PackageEditingInterface.IsPackageInstalled(ExtractFileNameOnly(ALpkPath));
  Result := not (Assigned(Pkg) and
                 (CompareFilenames(Pkg.Filename, ExpandFileNameUTF8(ALpkPath)) = 0));
end;

function McpConfirmPackageInstall(const ALpkPath, AToolName: string;
  out AReason: string): Boolean;
var
  Dlg     : TMcpConsentForm;
  Pkg     : TIDEPackage;
  Details : string;
begin
  AReason := '';
  if not McpPackageNeedsConsent(ALpkPath) then
    Exit(True);

  if not (Assigned(McpSettings) and McpSettings.AllowPackageInstall) then
  begin
    AReason := 'Refused: installing packages that are not installed yet is turned off. ' +
      'Only the user can allow it: Tools > MCP Assistant > Allow Assistants to Install ' +
      'Packages, or the same checkbox in Tools > Options > MCP Assistant. Each install is then confirmed by the user in the IDE. Ask the user; ' +
      'do not try to change the setting yourself.';
    LogToIDE('MCP: refused to install ' + ALpkPath + ' (installing packages is turned off).');
    Exit(False);
  end;

  if not FileExists(ALpkPath) then
  begin
    AReason := 'Package file not found: ' + ALpkPath;
    Exit(False);
  end;

  Details := 'An MCP assistant (tool ' + AToolName + ') asks to install this package ' +
    'into the IDE:' + LineEnding + LineEnding +
    'File:         ' + ALpkPath + LineEnding + LpkDetails(ALpkPath);
  Pkg := PackageEditingInterface.IsPackageInstalled(ExtractFileNameOnly(ALpkPath));
  if Assigned(Pkg) then
    Details := Details + LineEnding + 'NOTE: a package with this name is installed from a ' +
      'different file and would be replaced:' + LineEnding + '              ' + Pkg.Filename + LineEnding;
  Details := Details + LineEnding +
    'Installing rebuilds and restarts Lazarus with this package''s code. That code ' +
    'then runs with your user rights every time Lazarus starts. Install only packages ' +
    'whose source you trust.';

  Dlg := TMcpConsentForm.CreateConsent(
    'An assistant wants to install a package into Lazarus. Do you want this?', Details);
  try
    Result := Dlg.ShowModal = mrYes;
  finally
    Dlg.Free;
  end;
  if Result then
    LogToIDE('MCP: the user allowed installing ' + ALpkPath + '.')
  else
  begin
    AReason := 'The user declined installing ' + ALpkPath +
      ' (or did not answer within ' + IntToStr(CONSENT_TIMEOUT_S) + ' s). Do not retry ' +
      'unless the user asks you to.';
    LogToIDE('MCP: installing ' + ALpkPath + ' was declined.');
  end;
end;

end.
