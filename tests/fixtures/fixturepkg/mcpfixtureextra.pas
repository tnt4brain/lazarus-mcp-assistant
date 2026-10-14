unit McpFixtureExtra;

{ Not part of the fixture package: tests/tpackageedit.pas adds it with
  package_add_file and removes it again. It has a Register procedure, which
  the tool should detect. }

{$mode objfpc}{$H+}

interface

procedure Register;

implementation

procedure Register;
begin
end;

end.
