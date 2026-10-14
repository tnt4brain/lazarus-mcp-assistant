{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
program mcpdebuggee;

{ Debuggee for the opt-in debugger tests (tests/tdebugger.pas).  Open
  tests/debuggee/mcpdebuggee.lpi as the IDE's project, then run the tests.
  The tests find their lines by the MARK: comments; a console program, so
  nothing waits for a click after the exception. }

{$mode objfpc}{$H+}

uses
  SysUtils;

var
  Counter : Integer = 0;

procedure Work;
begin
  Counter := 41;   // MARK:work
  Inc(Counter);    // MARK:inc
end;

begin
  Work;
  Sleep(3000);     // MARK:sleep - keeps the program running for the lock test
  raise Exception.Create('mcp debuggee exception');   // MARK:raise
end.
