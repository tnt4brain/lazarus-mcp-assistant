unit FixtureFormat;

{ Fixture for code_format (TTestCodeFormat): formatted in a temp copy only. }

{$mode objfpc}{$H+}

interface

function Twice(A: Integer): Integer;
procedure Messy;

implementation

function Twice(A: Integer): Integer;
begin
  Result := A * 2;
end;

procedure Messy;
var i:integer;
begin
for i:=1 to 3 do
if i>1 then
writeln(i)
else    writeln( 'one' );
end;

end.
