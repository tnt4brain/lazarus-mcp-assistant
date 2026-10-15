unit FixtureComplete;

{ Fixture for code_complete (TTestCodeComplete): each test completes in the
  editor buffer only and reverts, so this file stays as it is on disk. }

{$mode objfpc}{$H+}

interface

type
  TCompleteMe = class
  private
    FDone: Boolean;
  public
    procedure NoBodyYet(A: Integer);
    property Size: Integer read FSize write SetSize;
    property Done: Boolean read FDone;
  end;

procedure ForwardOnly(const S: string);

implementation

procedure UsesALocal;
begin
  Counter := 5;
  Writeln(Counter);
end;

end.
