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

{ git_clone (ADR-013, "Clones"): may this address be cloned into this folder?
  Asked for every clone, with no setting to switch it off; the answer is the
  user's in a dialog.  Otherwise AReason says why not (for the client). }
function McpConfirmClone(const AUrl, ATargetDir, ABranch, AToolName: string;
  ADepth: Integer; out AReason: string): Boolean;

const
  { written by package_download into the package's folder; the dialog shows it }
  MCP_DOWNLOAD_MARKER = 'mcp-download.json';

implementation

uses
  Classes, SysUtils, Controls, Forms, StdCtrls, ExtCtrls, Graphics,
  LazFileUtils, Laz2_XMLCfg, PackageIntf, IDEMsgIntf, IDEExternToolIntf,
  fpjson, jsonparser,
  McpIdeState;

const
  CONSENT_TIMEOUT_S = 180;

type
  TMcpConsentForm = class(TForm)
  private
    FLeft     : Integer;
    FCountdown: TLabel;
    FNoCaption: string;
    procedure Tick(Sender: TObject);
  public
    constructor CreateConsent(const ATitle, ADetails: string;
      const AFormCaption: string = 'MCP Assistant: install a package?';
      const AYesCaption: string = '&Install';
      const ANoCaption: string = 'Don''t install');
  end;

constructor TMcpConsentForm.CreateConsent(const ATitle, ADetails: string;
  const AFormCaption, AYesCaption, ANoCaption: string);
var
  Head    : TLabel;
  Memo    : TMemo;
  Bottom  : TPanel;
  BtnYes  : TButton;
  BtnNo   : TButton;
  Timer   : TTimer;
begin
  inherited CreateNew(nil);
  Caption     := AFormCaption;
  FNoCaption  := ANoCaption;
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
  BtnNo.Caption     := ANoCaption;
  BtnNo.ModalResult := mrNo;
  BtnNo.Default     := True;   { Enter must never approve }
  BtnNo.Cancel      := True;

  BtnYes := TButton.Create(Self);
  BtnYes.Parent      := Bottom;
  BtnYes.Align       := alRight;
  BtnYes.BorderSpacing.Around := 8;
  BtnYes.Width       := 130;
  BtnYes.Caption     := AYesCaption;
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
  FCountdown.Caption := Format('No answer in %d s means "%s".', [FLeft, FNoCaption]);
end;

{ ── Package details ──────────────────────────────────────────────────────── }

{ Items of an .lpk list: Count + Item1.. (older files) or plain Item nodes. }
function ListCount(ACfg: TXMLConfig; const APath: string; out ALegacy: Boolean): Integer;
begin
  ALegacy := ACfg.IsLegacyList(APath);
  Result  := ACfg.GetListItemCount(APath, 'Item', ALegacy);
end;

function LpkDetails(const ALpkPath: string): string;
var
  Cfg    : TXMLConfig;
  Ver    : string;
  I, N   : Integer;
  Legacy : Boolean;
  Deps   : string;
begin
  Result := '';
  try
    Cfg := TXMLConfig.Create(ALpkPath);
    try
      Ver := Format('%d.%d.%d.%d', [
        Cfg.GetValue('Package/Version/Major', 0), Cfg.GetValue('Package/Version/Minor', 0),
        Cfg.GetValue('Package/Version/Release', 0), Cfg.GetValue('Package/Version/Build', 0)]);
      Deps := '';
      N := ListCount(Cfg, 'Package/RequiredPkgs/', Legacy);
      for I := 0 to N - 1 do
      begin
        if Deps <> '' then Deps := Deps + ', ';
        Deps := Deps + Cfg.GetValue('Package/RequiredPkgs/' +
          TXMLConfig.GetListItemXPath('Item', I, Legacy, True) + '/PackageName/Value', '?');
      end;
      Result :=
        'Package:      ' + Cfg.GetValue('Package/Name/Value', ExtractFileNameOnly(ALpkPath)) + ' ' + Ver + LineEnding +
        'Author:       ' + Cfg.GetValue('Package/Author/Value', '') + LineEnding +
        'License:      ' + Cfg.GetValue('Package/License/Value', '') + LineEnding +
        'Requires:     ' + Deps + LineEnding +
        'Files:        ' + IntToStr(ListCount(Cfg, 'Package/Files/', Legacy)) + LineEnding +
        'Description:  ' + Cfg.GetValue('Package/Description/Value', '') + LineEnding;
    finally
      Cfg.Free;
    end;
  except
    on E: Exception do
      Result := 'Could not read the package file: ' + E.Message + LineEnding;
  end;
end;

{ Where the package came from, if package_download fetched it: the marker in
  the .lpk's folder or one of the folders above it (the .lpk often sits in a
  subfolder of the download). '' if there is none. }
function DownloadSource(const ALpkPath: string): string;
var
  Dir, FN, Transport : string;
  I    : Integer;
  SL   : TStringList;
  D    : TJSONData;
  O    : TJSONObject;
begin
  Result := '';
  Dir := ExtractFilePath(ExpandFileNameUTF8(ALpkPath));
  for I := 0 to 4 do
  begin
    FN := Dir + MCP_DOWNLOAD_MARKER;
    if FileExists(FN) then Break;
    FN := '';
    Dir := ExtractFilePath(ChompPathDelim(Dir));
    if Dir = '' then Break;
  end;
  if FN = '' then Exit;
  SL := TStringList.Create;
  try
    try
      SL.LoadFromFile(FN);
      D := GetJSON(SL.Text);
    except
      Exit('Source:       ' + FN + ' could not be read' + LineEnding);
    end;
  finally
    SL.Free;
  end;
  try
    if not (D is TJSONObject) then Exit;
    O := TJSONObject(D);
    if Copy(O.Get('transport', ''), 1, 5) = 'https' then
      Transport := 'HTTPS'
    else
      Transport := 'HTTP (unencrypted)';
    Result :=
      'Source:       downloaded by an assistant (package_download) on ' + O.Get('date', '?') +
        ' from' + LineEnding +
      '              ' + O.Get('url', '?') + LineEnding +
      '              ' + O.Get('source', '?') + ', over ' + Transport + LineEnding +
      '              the archive''s MD5 matched the repository catalog' + LineEnding;
  finally
    D.Free;
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
    'File:         ' + ALpkPath + LineEnding + DownloadSource(ALpkPath) + LpkDetails(ALpkPath);
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

function McpConfirmClone(const AUrl, ATargetDir, ABranch, AToolName: string;
  ADepth: Integer; out AReason: string): Boolean;
var
  Dlg     : TMcpConsentForm;
  Details : string;
begin
  AReason := '';
  Details := 'An MCP assistant (tool ' + AToolName + ') asks to clone this repository:' +
    LineEnding + LineEnding +
    'From:         ' + AUrl + LineEnding +
    'Into:         ' + ATargetDir + LineEnding;
  if ABranch <> '' then
    Details := Details + 'Branch:       ' + ABranch + LineEnding;
  if ADepth > 0 then
    Details := Details + 'History:      only the last ' + IntToStr(ADepth) + ' commit(s)' + LineEnding;
  if Pos('http://', LowerCase(AUrl)) = 1 then
    Details := Details + LineEnding + 'NOTE: this address is plain HTTP, not encrypted.' + LineEnding;
  Details := Details + LineEnding +
    'Cloning downloads the repository''s files into that folder. Nothing is built, ' +
    'run or opened. Opening a Lazarus project or package and building it can run ' +
    'commands the project defines, so open only what you trust.';

  Dlg := TMcpConsentForm.CreateConsent(
    'An assistant wants to clone a repository onto your disk. Do you want this?',
    Details, 'MCP Assistant: clone a repository?', '&Clone', 'Don''t clone');
  try
    Result := Dlg.ShowModal = mrYes;
  finally
    Dlg.Free;
  end;
  if Result then
    LogToIDE('MCP: the user allowed cloning ' + AUrl + ' into ' + ATargetDir + '.')
  else
  begin
    AReason := 'The user declined cloning ' + AUrl + ' (or did not answer within ' +
      IntToStr(CONSENT_TIMEOUT_S) + ' s). Do not retry unless the user asks you to.';
    LogToIDE('MCP: cloning ' + AUrl + ' was declined.');
  end;
end;

end.
