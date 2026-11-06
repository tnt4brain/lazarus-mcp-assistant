{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpImageInfo;

{ What the Markdown viewer checks about an image before any decoder sees it (ADR-024):
  the kind from the magic number, and the size from the header.  Plain RTL. }

{$mode objfpc}{$H+}

interface

const
  MCP_IMG_MAX_FILE_BYTES = 8 * 1024 * 1024;   { a picture file }
  MCP_IMG_MAX_DATA_BYTES = 4 * 1024 * 1024;   { a data: URI, decoded }
  MCP_IMG_MAX_PIXELS     = 16 * 1000 * 1000;  { 16 megapixels }

{ AKind: png, jpeg, gif or bmp, from the magic number; AWidth and AHeight from the header.
  False when the bytes are none of these or the header is cut off. }
function McpImageHeader(const AData: string; out AKind: string;
  out AWidth, AHeight: Integer): Boolean;

{ True when the bytes are a picture of the kind ADeclared ('' = any) within the pixel limit. }
function McpImageAcceptable(const AData, ADeclared: string; out AKind, AWhy: string): Boolean;

implementation

uses
  SysUtils;

function Byte_(const S: string; I: Integer): Integer;
begin
  Result := Ord(S[I]);
end;

function BE16(const S: string; I: Integer): Integer;
begin
  Result := (Byte_(S, I) shl 8) or Byte_(S, I + 1);
end;

function LE16(const S: string; I: Integer): Integer;
begin
  Result := Byte_(S, I) or (Byte_(S, I + 1) shl 8);
end;

function BE32(const S: string; I: Integer): Int64;
begin
  Result := (Int64(Byte_(S, I)) shl 24) or (Byte_(S, I + 1) shl 16) or
            (Byte_(S, I + 2) shl 8) or Byte_(S, I + 3);
end;

function LE32S(const S: string; I: Integer): Int64;
begin
  Result := Int64(LongInt(LongWord(Byte_(S, I)) or (LongWord(Byte_(S, I + 1)) shl 8) or
            (LongWord(Byte_(S, I + 2)) shl 16) or (LongWord(Byte_(S, I + 3)) shl 24)));
end;

function McpImageHeader(const AData: string; out AKind: string;
  out AWidth, AHeight: Integer): Boolean;
var
  N, P, M, Len : Integer;
  W, H : Int64;
begin
  Result := False;
  AKind := '';
  AWidth := 0;
  AHeight := 0;
  N := Length(AData);
  if N < 10 then Exit;
  W := 0;
  H := 0;
  if (Copy(AData, 1, 8) = #$89'PNG'#13#10#26#10) then
  begin
    if (N < 24) or (Copy(AData, 13, 4) <> 'IHDR') then Exit;
    AKind := 'png';
    W := BE32(AData, 17);
    H := BE32(AData, 21);
  end
  else if (Copy(AData, 1, 6) = 'GIF87a') or (Copy(AData, 1, 6) = 'GIF89a') then
  begin
    AKind := 'gif';
    W := LE16(AData, 7);
    H := LE16(AData, 9);
  end
  else if Copy(AData, 1, 2) = 'BM' then
  begin
    if N < 26 then Exit;
    AKind := 'bmp';
    if LE32S(AData, 15) = 12 then
    begin
      W := LE16(AData, 19);
      H := LE16(AData, 21);
    end
    else
    begin
      if N < 26 then Exit;
      W := LE32S(AData, 19);
      H := Abs(LE32S(AData, 23));     { a negative height is a top-down bitmap }
    end;
  end
  else if (Byte_(AData, 1) = $FF) and (Byte_(AData, 2) = $D8) then
  begin
    AKind := 'jpeg';
    P := 3;
    while P + 3 <= N do
    begin
      if Byte_(AData, P) <> $FF then begin AKind := ''; Exit; end;
      M := Byte_(AData, P + 1);
      if M = $FF then begin Inc(P); Continue; end;        { fill byte }
      if (M = $D8) or (M = $01) or ((M >= $D0) and (M <= $D7)) then
      begin
        Inc(P, 2);                                        { markers without a length }
        Continue;
      end;
      if (M >= $C0) and (M <= $CF) and (M <> $C4) and (M <> $C8) and (M <> $CC) then
      begin
        if P + 8 > N then begin AKind := ''; Exit; end;
        H := BE16(AData, P + 5);
        W := BE16(AData, P + 7);
        Break;
      end;
      Len := BE16(AData, P + 2);
      if Len < 2 then begin AKind := ''; Exit; end;
      Inc(P, 2 + Len);
    end;
    if W = 0 then begin AKind := ''; Exit; end;
  end
  else
    Exit;
  if (W <= 0) or (H <= 0) or (W > 100000) or (H > 100000) then
  begin
    AKind := '';
    Exit;
  end;
  AWidth := W;
  AHeight := H;
  Result := True;
end;

function McpImageAcceptable(const AData, ADeclared: string; out AKind, AWhy: string): Boolean;
var
  W, H : Integer;
begin
  Result := False;
  AWhy := '';
  if not McpImageHeader(AData, AKind, W, H) then
  begin
    AWhy := 'not a PNG, JPEG, GIF or BMP picture';
    Exit;
  end;
  if (ADeclared <> '') and (ADeclared <> AKind) then
  begin
    AWhy := 'the bytes are ' + AKind + ', not ' + ADeclared;
    Exit;
  end;
  if Int64(W) * H > MCP_IMG_MAX_PIXELS then
  begin
    AWhy := 'picture too large (' + IntToStr(W) + 'x' + IntToStr(H) + ')';
    Exit;
  end;
  Result := True;
end;

end.
