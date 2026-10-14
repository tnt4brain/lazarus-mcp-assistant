{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit LazMcpAssistant;

{$warn 5023 off : no warning about unused units}
interface

uses
  McpIdeListeners, McpIdeState, McpLayoutPanel, McpIdeServer, McpToolContext, 
  McpToolHelpers, McpToolsPackages, McpToolsEditor, McpToolsBuild, 
  McpToolsCodeTools, McpToolsForms, McpToolsProject, McpToolsGit, 
  McpToolsDebugger, McpDebugGuard, McpDebugLease, McpConsent, McpLauncher, 
  McpOptions, McpSettingsFile, McpRefKeeper, McpExceptionLog, 
  LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('McpLayoutPanel', @McpLayoutPanel.Register);
end;

initialization
  RegisterPackage('LazMcpAssistant', @Register);
end.
