unit FixtureForm;

{ Fixture for the HTTP tool tests (TToolSmoke): read by code_get_outline and
  form_list_components, never modified. }

{$mode objfpc}{$H+}

interface

uses
  Classes, Forms, StdCtrls;

type
  TFixtureForm = class(TForm)
    btnOK: TButton;
    procedure btnOKClick(Sender: TObject);
  private
    FCount: Integer;
  public
    function Twice(AValue: Integer): Integer;
  end;

var
  FixtureFormInst: TFixtureForm;

implementation

{$R *.lfm}

procedure TFixtureForm.btnOKClick(Sender: TObject);
begin
  Inc(FCount);
end;

function TFixtureForm.Twice(AValue: Integer): Integer;
begin
  Result := AValue * 2;
end;

end.
