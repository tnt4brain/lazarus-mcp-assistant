unit McpHeapReport;

{$mode objfpc}{$H+}

{ Reads the report the heaptrc unit prints to stderr when a program ends (project_run with
  heaptrc on): the counts, and the call stack of each block that was not freed.  Pure text
  in, JSON out, no IDE units. }

interface

uses
  Classes, SysUtils, fpjson;

{ True when AText holds a heaptrc report; AReport is then a new object with
  allocated_blocks, allocated_bytes, freed_blocks, freed_bytes, unfreed_blocks,
  unfreed_bytes, leaked (boolean) and leaks (an array of objects with address, size and
  stack, at most MaxLeaks of them).  The caller frees AReport. }
function ParseHeapReport(const AText: string; out AReport: TJSONObject;
  MaxLeaks: Integer = 20): Boolean;

implementation

const
  MARKER = 'Heap dump by heaptrc unit';

{ The decimal number that starts AStr at AFrom, -1 if there is none. }
function NumberAt(const AStr: string; var AFrom: Integer): Int64;
var
  P : Integer;
begin
  P := AFrom;
  while (P <= Length(AStr)) and (AStr[P] in ['0'..'9']) do Inc(P);
  if P = AFrom then Exit(-1);
  Result := StrToInt64Def(Copy(AStr, AFrom, P - AFrom), -1);
  AFrom := P;
end;

{ "N memory blocks allocated : B/H" -> N and B (H is the size with overhead) }
function CountLine(const ALine, AWord: string; out N, B: Int64): Boolean;
var
  P, Q : Integer;
begin
  Result := False;
  P := 1;
  N := NumberAt(ALine, P);
  if N < 0 then Exit;
  Q := Pos(' memory blocks ' + AWord, ALine);
  if Q <> P then Exit;
  P := Pos(':', ALine);
  if P = 0 then Exit;
  Inc(P);
  while (P <= Length(ALine)) and (ALine[P] = ' ') do Inc(P);
  B := NumberAt(ALine, P);
  Result := B >= 0;
end;

function ParseHeapReport(const AText: string; out AReport: TJSONObject;
  MaxLeaks: Integer): Boolean;
var
  Lines   : TStringList;
  P       : Integer;
  L, Line : string;
  N, B    : Int64;
  AllocN, AllocB, FreeN, FreeB, LeakN, LeakB : Int64;
  Leaks   : TJSONArray;
  Leak    : TJSONObject;
  Stack   : TJSONArray;
  Found   : Boolean;
begin
  AReport := nil;
  Result := False;
  if Pos(MARKER, AText) = 0 then Exit;
  AllocN := 0; AllocB := 0; FreeN := 0; FreeB := 0; LeakN := 0; LeakB := 0;
  Lines := TStringList.Create;
  Leaks := TJSONArray.Create;
  Leak := nil;
  Stack := nil;
  try
    Lines.Text := AText;
    Found := False;
    for Line in Lines do
    begin
      L := Trim(Line);
      if not Found then
      begin
        Found := Pos(MARKER, L) > 0;
        Continue;
      end;
      if CountLine(L, 'allocated', N, B) then begin AllocN := N; AllocB := B; end
      else if CountLine(L, 'freed', N, B) then begin FreeN := N; FreeB := B; end
      else if (Pos(' unfreed memory blocks', L) > 0) then
      begin
        P := 1;
        N := NumberAt(L, P);
        P := Pos(':', L);
        if (N >= 0) and (P > 0) then
        begin
          Inc(P);
          while (P <= Length(L)) and (L[P] = ' ') do Inc(P);
          LeakN := N;
          LeakB := NumberAt(L, P);
          if LeakB < 0 then LeakB := 0;
        end;
      end
      else if Pos('Call trace for block ', L) = 1 then
      begin
        if Leaks.Count < MaxLeaks then
        begin
          Leak := TJSONObject.Create;
          Stack := TJSONArray.Create;
          Leak.Add('address', Trim(Copy(L, 22, Pos(' size ', L) - 22)));
          P := Pos(' size ', L);
          if P > 0 then Leak.Add('size', StrToInt64Def(Trim(Copy(L, P + 6, 20)), 0));
          Leak.Add('stack', Stack);
          Leaks.Add(Leak);
        end
        else
        begin
          Leak := nil;
          Stack := nil;
        end;
      end
      else if (Stack <> nil) and (L <> '') and (L[1] = '$') then
        Stack.Add(L);
    end;
    AReport := TJSONObject.Create;
    AReport.Add('allocated_blocks', AllocN);
    AReport.Add('allocated_bytes',  AllocB);
    AReport.Add('freed_blocks',     FreeN);
    AReport.Add('freed_bytes',      FreeB);
    AReport.Add('unfreed_blocks',   LeakN);
    AReport.Add('unfreed_bytes',    LeakB);
    AReport.Add('leaked',           LeakN > 0);
    AReport.Add('leaks',            Leaks);
    Leaks := nil;
    Result := True;
  finally
    Leaks.Free;
    Lines.Free;
  end;
end;

end.
