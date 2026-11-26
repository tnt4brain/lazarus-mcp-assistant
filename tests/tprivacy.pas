{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit TPrivacy;

{ TTestPrivacy: docs/privacy.md against the source.  A unit that opens a socket, or a web address,
  that the page does not list fails here, so a new connection cannot be added without a decision.
  RTL only. }

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TTestPrivacy = class(TTestCase)
  published
    procedure TestNetworkUnitsAreTheListedOnes;
    procedure TestWebAddressesAreTheListedOnes;
    procedure TestPageNamesWhatItLists;
  end;

implementation

uses
  Classes, SysUtils, StrUtils;

const
  { file (lower case) = the network units it may use }
  NET_FILES : array[0..5] of string = (
    'mcpideserver.pas=fphttpserver,ssockets,fphttpclient,sockets',
    'mcpselftest.pas=fphttpclient',
    'mcptoolspackages.pas=fphttpclient,opensslsockets',
    'mcpgitserve.pas=sockets',
    'mcputils.pas=sockets',
    'mcpprogress.pas=fphttpserver');   { writes the stream of a call on the connection the server already has }
  NET_UNITS : array[0..7] of string = (
    'fphttpserver', 'ssockets', 'fphttpclient', 'opensslsockets', 'sockets', 'fpsock',
    'fpwebclient', 'netdb');

  { hosts a web address in the source may name; github.com is text for the model, not a connection }
  HOSTS : array[0..2] of string = ('packages.lazarus-ide.org', '127.0.0.1', 'github.com');

function SrcDir: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + '..' + PathDelim + 'src' + PathDelim;
end;

function Slurp(const AFile: string): string;
var
  L : TStringList;
begin
  L := TStringList.Create;
  try
    L.LoadFromFile(AFile);
    Result := L.Text;
  finally
    L.Free;
  end;
end;

// the source without comments and strings: a unit is "used" when it stands as a word in the code
function CodeOnly(const S: string): string;
var
  I, N : Integer;
  Mode : Char;   // space: code; left brace, left paren and slash: the comment kinds; quote: a string
begin
  Result := '';
  N := Length(S);
  I := 1;
  Mode := ' ';
  while I <= N do
  begin
    case Mode of
      ' ':
        if S[I] = '{' then Mode := '{'
        else if (S[I] = '(') and (I < N) and (S[I + 1] = '*') then begin Mode := '('; Inc(I); end
        else if (S[I] = '/') and (I < N) and (S[I + 1] = '/') then begin Mode := '/'; Inc(I); end
        else if S[I] = '''' then Mode := ''''
        else Result := Result + S[I];
      '{': if S[I] = '}' then Mode := ' ';
      '(': if (S[I] = '*') and (I < N) and (S[I + 1] = ')') then begin Mode := ' '; Inc(I); end;
      '/': if S[I] = #10 then begin Mode := ' '; Result := Result + #10; end;
      '''': if S[I] = '''' then Mode := ' ';
    end;
    Inc(I);
  end;
end;

function HasWord(const AText, AWord: string): Boolean;
var
  P : Integer;
  T : string;
begin
  Result := False;
  T := LowerCase(AText);
  P := Pos(AWord, T);
  while P > 0 do
  begin
    if ((P = 1) or not (T[P - 1] in ['a'..'z', '0'..'9', '_'])) and
       ((P + Length(AWord) > Length(T)) or not (T[P + Length(AWord)] in ['a'..'z', '0'..'9', '_'])) then
      Exit(True);
    P := PosEx(AWord, T, P + 1);
  end;
end;

function AllowedUnits(const AFileLower: string): string;
var
  I, E : Integer;
begin
  Result := '';
  for I := Low(NET_FILES) to High(NET_FILES) do
  begin
    E := Pos('=', NET_FILES[I]);
    if Copy(NET_FILES[I], 1, E - 1) = AFileLower then
      Exit(',' + Copy(NET_FILES[I], E + 1, 200) + ',');
  end;
end;

procedure TTestPrivacy.TestNetworkUnitsAreTheListedOnes;
var
  SR   : TSearchRec;
  Code : string;
  I    : Integer;
  Seen : Integer;
begin
  Seen := 0;
  if FindFirst(SrcDir + '*.pas', faAnyFile, SR) = 0 then
  try
    repeat
      Code := CodeOnly(Slurp(SrcDir + SR.Name));
      for I := Low(NET_UNITS) to High(NET_UNITS) do
        if HasWord(Code, NET_UNITS[I]) then
        begin
          Inc(Seen);
          CheckTrue(Pos(',' + NET_UNITS[I] + ',', AllowedUnits(LowerCase(SR.Name))) > 0,
            SR.Name + ' uses the network unit ' + NET_UNITS[I] +
            ': decide, then add it to docs/privacy.md and to this test');
        end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  CheckTrue(Seen >= 5, 'the scan found the known users: ' + IntToStr(Seen));
end;

procedure TTestPrivacy.TestWebAddressesAreTheListedOnes;
const
  SCHEMES : array[0..1] of string = ('http://', 'https://');
var
  SR      : TSearchRec;
  Text    : string;
  Low_    : string;
  H       : string;
  P, E, I : Integer;
  K       : Integer;
  Ok      : Boolean;
  Found   : Integer;
begin
  Found := 0;
  for K := 0 to 1 do
  begin
    if FindFirst(SrcDir + '*.*', faAnyFile, SR) <> 0 then Continue;
    try
      repeat
        if not ((ExtractFileExt(SR.Name) = '.pas') or (ExtractFileExt(SR.Name) = '.inc')) then Continue;
        Text := Slurp(SrcDir + SR.Name);
        Low_ := LowerCase(Text);
        P := Pos(SCHEMES[K], Low_);
        while P > 0 do
        begin
          E := P + Length(SCHEMES[K]);
          H := '';
          while (E <= Length(Low_)) and (Low_[E] in ['a'..'z', '0'..'9', '.', '-']) do
          begin
            H := H + Low_[E];
            Inc(E);
          end;
          { a bare scheme or a format placeholder names no host }
          if H <> '' then
          begin
            Inc(Found);
            Ok := False;
            for I := Low(HOSTS) to High(HOSTS) do
              if H = HOSTS[I] then Ok := True;
            CheckTrue(Ok, SR.Name + ' names the web address host "' + H +
              '": decide, then add it to docs/privacy.md and to this test');
          end;
          P := PosEx(SCHEMES[K], Low_, P + 1);
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
  CheckTrue(Found >= 2, 'the scan found the known addresses: ' + IntToStr(Found));
end;

procedure TTestPrivacy.TestPageNamesWhatItLists;
var
  Page : string;
  I    : Integer;
begin
  Page := LowerCase(Slurp(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + 'docs' + PathDelim +
    'privacy.md'));
  for I := Low(HOSTS) to High(HOSTS) do
    if HOSTS[I] <> 'github.com' then
      CheckTrue(Pos(HOSTS[I], Page) > 0, 'the page names ' + HOSTS[I]);
  CheckTrue(Pos('mcpgitserve', Page) > 0, 'the page names the git_serve unit');
  CheckTrue(Pos('mcptoolspackages', Page) > 0, 'the page names the package download unit');
  CheckTrue(Pos('mcpideserver', Page) > 0, 'the page names the server unit');
  CheckTrue(Pos('telemetry', Page) > 0, 'the page says there is no telemetry');
end;

initialization
  RegisterTest(TTestPrivacy);
end.
