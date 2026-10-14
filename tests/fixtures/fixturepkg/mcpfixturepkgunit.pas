unit McpFixturePkgUnit;

{ Part of the fixture package for tests/tpackageedit.pas. }

{$mode objfpc}{$H+}

interface

function FixtureValue: Integer;

implementation

function FixtureValue: Integer;
begin
  Result := 1;
end;

end.
