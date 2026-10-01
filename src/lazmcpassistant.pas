{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit LazMcpAssistant;

{$warn 5023 off : no warning about unused units}
interface

uses
  McpProcessWorker, McpIdeListeners, McpIdeState, McpLayoutPanel, 
  McpIdeServer, LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('McpLayoutPanel', @McpLayoutPanel.Register);
end;

initialization
  RegisterPackage('LazMcpAssistant', @Register);
end.
