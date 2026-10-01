{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpProcessWorker;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Process, fpjson, jsonparser;

type
  { Event triggered on the main thread when a full JSON-RPC chunk returns }
  TMcpResponseEvent = procedure(const ResponseJSON: TJSONObject) of object;
  { Event triggered if the daemon crashes or fails to launch }
  TMcpErrorEvent = procedure(const ErrorMessage: string) of object;

  TMcpProcessThread = class(TThread)
  private
    FProcess: TProcess;
    FExecutablePath: string;
    FArguments: TStringList;
    FInputPayload: string;
    FResponseData: string;
    FOnSuccess: TMcpResponseEvent;
    FOnError: TMcpErrorEvent;
    FResponseObj: TJSONObject;
    FErrorMsg: string;
    procedure DoSuccess;
    procedure DoError;
  protected
    procedure Execute; override;
  public
    constructor Create(
      const ExePath: string; 
      Args: TStringList; 
      const JSONPayload: string; 
      OnSuccessEvent: TMcpResponseEvent;
      OnErrorEvent: TMcpErrorEvent
    );
    destructor Destroy; override;
  end;

implementation

constructor TMcpProcessThread.Create(
  const ExePath: string; 
  Args: TStringList; 
  const JSONPayload: string; 
  OnSuccessEvent: TMcpResponseEvent;
  OnErrorEvent: TMcpErrorEvent
);
begin
  inherited Create(True); // Create suspended so properties can be verified
  FreeOnTerminate := True;
  FExecutablePath := ExePath;
  FInputPayload := JSONPayload + #10; // Newline terminates standard JSON-RPC streams
  FOnSuccess := OnSuccessEvent;
  FOnError := OnErrorEvent;
  
  FArguments := TStringList.Create;
  if Assigned(Args) then 
    FArguments.Assign(Args);
end;

procedure TMcpProcessThread.Execute;
var
  Buffer: string;
  BytesRead, Available: LongInt;
begin
  FProcess := TProcess.Create(nil);
  try
    FProcess.Executable := FExecutablePath;
    FProcess.Parameters.Assign(FArguments);
    // poUsePipes: Enables background stream reading/writing
    // poNoConsole: Hides ugly terminal windows on Windows/Linux
    FProcess.Options := [poUsePipes, poNoConsole];
    
    try
      FProcess.Execute;
    except
      on E: Exception do
      begin
        FErrorMsg := 'Failed to run MCP process: ' + E.Message;
        Synchronize(@DoError);
        Exit;
      end;
    end;

    // 1. Write prompt/payload payload down the pipe
    if FInputPayload <> '' then
      FProcess.Input.WriteBuffer(FInputPayload[1], Length(FInputPayload));
    
    // Close input if it's a one-shot process runner
    FProcess.CloseInput;

    // 2. Continuous non-blocking read loop while the process calculates
    FResponseData := '';
    while FProcess.Running and not Terminated do
    begin
      Available := FProcess.Output.NumBytesAvailable;
      if Available > 0 then
      begin
        SetLength(Buffer, Available);
        BytesRead := FProcess.Output.Read(Buffer[1], Available);
        SetLength(Buffer, BytesRead);
        FResponseData := FResponseData + Buffer;
      end;
      Sleep(10); // Keep thread friendly, avoid pegging a CPU core 100%
    end;

    // Flush any leftover tail bytes
    Available := FProcess.Output.NumBytesAvailable;
    if Available > 0 then
    begin
      SetLength(Buffer, Available);
      FProcess.Output.Read(Buffer[1], Available);
      FResponseData := FResponseData + Buffer;
    end;

    // 3. Thread-safe execution delivery
    if FResponseData <> '' then
    begin
      try
        FResponseObj := GetJSON(FResponseData) as TJSONObject;
        Synchronize(@DoSuccess);
      except
        on E: Exception do
        begin
          FErrorMsg := 'Malformed JSON-RPC received: ' + E.Message;
          Synchronize(@DoError);
        end;
      end;
    end;
    
  finally
    FProcess.Free;
  end;
end;

procedure TMcpProcessThread.DoSuccess;
begin
  if Assigned(FOnSuccess) and Assigned(FResponseObj) then
    FOnSuccess(FResponseObj);
end;

procedure TMcpProcessThread.DoError;
begin
  if Assigned(FOnError) then
    FOnError(FErrorMsg);
end;

destructor TMcpProcessThread.Destroy;
begin
  FArguments.Free;
  if Assigned(FResponseObj) then 
    FResponseObj.Free;
  inherited Destroy;
end;

end.
