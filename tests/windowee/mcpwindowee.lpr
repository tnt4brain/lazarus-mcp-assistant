{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
program mcpwindowee;

{ GUI program for the opt-in window tests (tests/twindows.pas): a form with
  a button, an edit and a label (no window handle).  The timer's handler is
  where the tests pause it in the debugger, by the MARK: comment. }

{$mode objfpc}{$H+}

uses
  Interfaces, Forms, StdCtrls, ExtCtrls;

type
  TMainForm = class(TForm)
  private
    FTicks : Integer;
    procedure Tick(Sender: TObject);
  public
    constructor CreateMain;
  end;

constructor TMainForm.CreateMain;
begin
  CreateNew(nil);
  Caption := 'MCP Windowee';
  SetBounds(200, 200, 320, 160);
  with TButton.Create(Self) do
  begin
    Parent := Self;
    Caption := 'Push me';
    SetBounds(16, 16, 96, 28);
  end;
  with TEdit.Create(Self) do
  begin
    Parent := Self;
    Text := 'edit text';
    SetBounds(16, 56, 160, 24);
  end;
  with TLabel.Create(Self) do
  begin
    Parent := Self;
    Caption := 'a label';
    SetBounds(16, 96, 80, 16);
  end;
  with TTimer.Create(Self) do
  begin
    Interval := 100;
    OnTimer := @Tick;
  end;
end;

procedure TMainForm.Tick(Sender: TObject);
begin
  Inc(FTicks);   // MARK:tick
end;

var
  MainForm : TMainForm;

begin
  Application.Initialize;
  MainForm := TMainForm.CreateMain;
  MainForm.Show;
  Application.Run;
  MainForm.Free;
end.
