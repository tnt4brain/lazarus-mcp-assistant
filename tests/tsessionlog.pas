{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TSessionLog;

{ The note McpSessionLog adds to an initialize line when a client asked for a
  protocol revision other than the one the server settled on.  Standalone,
  no IDE. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, McpSessionLog;

type
  TTestSessionLog = class(TTestCase)
  published
    procedure TestSameVersionAddsNothing;
    procedure TestNewerVersionIsNoted;
    procedure TestNoVersionIsNoted;
    procedure TestOlderVersionIsNoted;
  end;

implementation

procedure TTestSessionLog.TestSameVersionAddsNothing;
begin
  CheckEquals('', McpAskedNote('2025-06-18', '2025-06-18'));
end;

procedure TTestSessionLog.TestNewerVersionIsNoted;
begin
  { we settle on our latest when the client asks for a revision we lack }
  CheckEquals(' (client asked for 2026-07-28)',
    McpAskedNote('2026-07-28', '2025-06-18'));
end;

procedure TTestSessionLog.TestNoVersionIsNoted;
begin
  CheckEquals(' (client asked for none)', McpAskedNote('', '2025-06-18'));
end;

procedure TTestSessionLog.TestOlderVersionIsNoted;
begin
  { an older revision we do implement is answered as asked, so no note }
  CheckEquals('', McpAskedNote('2024-11-05', '2024-11-05'));
  CheckEquals(' (client asked for 2024-11-05)',
    McpAskedNote('2024-11-05', '2025-06-18'));
end;

initialization
  RegisterTest(TTestSessionLog);
end.
