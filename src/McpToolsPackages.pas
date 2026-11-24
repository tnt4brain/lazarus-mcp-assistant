{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsPackages;

{ Package management tools: package_get_info, package_find_unit, package_search_online,
  package_add_file, package_remove_file, package_add_dependency,
  package_remove_dependency, package_set_info, project_list_packages, project_add_package,
  project_remove_package, package_install, package_uninstall. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpjson, PackageDefs;

{ Shared with McpToolsPkgManage. }

{ The package a call names, by package_name or lpk_path; a .lpk not loaded yet
  is loaded without a package editor.  AForEdit: also refuse a package that
  has never been saved or is read-only. }
function TargetPackage(AParams: TJSONObject; out APkg: TLazPackage;
  out AErr: string; AForEdit: Boolean = True): Boolean;

{ Saves the package unless that would write more than this change; the JSON
  tells which. }
function EditResult(APkg: TLazPackage; AWasModified: Boolean; AObj: TJSONObject): string;

{ package_save: the named package or every modified one; AErr = '' on success. }
function PackageSave(AParams: TJSONObject; out AErr: string): string;

{ package_add_file: AParams carries file plus package_name or lpk_path.  AErr =
  '' on success; the result is the JSON. }
function PackageAddFile(AParams: TJSONObject; out AErr: string): string;

{ A package's status and contents.  APkg: the package to describe, else the
  one loaded under PkgName. }
function PackageInfoJSON(const PkgName: string; WithFiles: Boolean;
  APkg: TLazPackage = nil): string;

implementation

uses
  Classes,
  LazIDEIntf, SrcEditorIntf, ProjectIntf, PackageIntf,
  LazFileUtils, FileUtil,
  PackageDependencyIntf,
  Project,                { IdePackager/IdeProject, linked via IdeDebugger: TPkgDependency }
  PackageSystem,          { PackageGraph }
  PackageLinks,           { LazPackageLinks }
  PackageLinkIntf,        { TPackageLink }
  ParsedCompilerOpts, SearchPathProcs,  { IdeConfig: unit/include paths }
  CodeToolManager, CodeCache,
  Controls,               { mrOk }
  Laz2_XMLCfg, fphttpclient, opensslsockets, md5, zipper, process,
  McpToolContext, McpIdeState, McpConsent, McpToolsCodeTools, McpProcess;

{ ── Schema constants ─────────────────────────────────────────────────────── }

const
  SCHEMA_LIST_PROJECT_PACKAGES =
    '{"type":"object","properties":{"recursive":{"type":"boolean",' +
    '"description":"Also list every package the project needs indirectly, in compile ' +
    'order, each with its own requirements (default false)"}}}';

  SCHEMA_FIND_UNIT =
    '{"type":"object","properties":{"unit_name":{"type":"string",' +
    '"description":"Unit name, e.g. SynEdit or fpjson"}},"required":["unit_name"]}';

  { package_add_file etc.: the package, by name or by .lpk file }
  { "one of package_name / lpk_path" is NOT written as oneOf/anyOf in the schema: the
    Anthropic API rejects those at the top level of a tool's input_schema (HTTP 400, and
    Claude Code passes MCP schemas on unchanged, so one such tool breaks the session).
    The rule is in the descriptions ("Or ...") and enforced per call: neither given =
    "package_name or lpk_path required", two that name different packages = refused. }
  PKG_TARGET_PROPS =
    '"package_name":{"type":"string","description":"A package loaded in the IDE"},' +
    '"lpk_path":{"type":"string","description":"Or the .lpk file, loaded for this call ' +
      'without a package editor"}';

  SCHEMA_PKG_FILE =
    '{"type":"object","properties":{' + PKG_TARGET_PROPS + ',' +
    '"file":{"type":"string","description":"Absolute path of the file"}},' +
    '"required":["file"]}';

  SCHEMA_PKG_ADD_DEP =
    '{"type":"object","properties":{' + PKG_TARGET_PROPS + ',' +
    '"required_package":{"type":"string","description":"Name of the package to require"},' +
    '"min_version":{"type":"string","description":"e.g. 1.2"},' +
    '"max_version":{"type":"string","description":"Highest accepted version, same format as min_version"}},' +
    '"required":["required_package"]}';

  SCHEMA_PKG_SAVE =
    '{"type":"object","properties":{' + PKG_TARGET_PROPS + ',' +
    '"save_all":{"type":"boolean","description":"Save every modified package, not only the ' +
    'named one (the IDE writes them all at once); without a package_name or lpk_path this ' +
    'is always so (default false)"}}}';

  SCHEMA_PKG_SET_INFO =
    '{"type":"object","properties":{' + PKG_TARGET_PROPS + ',' +
    '"version":{"type":"string","description":"major.minor[.release[.build]], e.g. 1.0"},' +
    '"description":{"type":"string","description":"The package''s description text"},' +
    '"author":{"type":"string","description":"The package''s author"},' +
    '"license":{"type":"string","description":"The package''s license, free text, e.g. BSD-3-Clause"}}}';

  SCHEMA_PKG_REMOVE_DEP =
    '{"type":"object","properties":{' + PKG_TARGET_PROPS + ',' +
    '"required_package":{"type":"string","description":"Name of the required package to remove"}},' +
    '"required":["required_package"]}';

  { one of package_name / lpk_path, as in every tool that addresses a package }
  SCHEMA_ADD_PACKAGE_TO_PROJECT =
    '{"type":"object","properties":{' +
    '"package_name":{"type":"string","description":"The package to add as a dependency ' +
      '(e.g. LazUtils): loaded in the IDE or known to its package links"},' +
    '"lpk_path":{"type":"string","description":"Or the .lpk file, loaded for this call ' +
      'without a package editor"}}}';

  SCHEMA_REMOVE_PACKAGE_FROM_PROJECT =
    '{"type":"object","properties":{' +
    '"package_name":{"type":"string","description":"The dependency to remove"},' +
    '"lpk_path":{"type":"string","description":"Or the .lpk file of that package"}}}';

  SCHEMA_INSTALL_PACKAGE =
    '{"type":"object","properties":{' +
    '"lpk_path":{"type":"string","description":"The .lpk file to install into the IDE"},' +
    '"package_name":{"type":"string","description":"Or a package the IDE knows (loaded, ' +
      'or in its package links), installed from its .lpk"},' + MCP_REBUILD_FLAGS + '}}';

  SCHEMA_UNINSTALL_PACKAGE =
    '{"type":"object","properties":{' +
    '"package_name":{"type":"string","description":"The installed package to remove"},' +
    '"lpk_path":{"type":"string","description":"Or its .lpk file"},' +
    MCP_REBUILD_FLAGS + '}}';

  SCHEMA_SEARCH_ONLINE =
    '{"type":"object","properties":{' +
    '"query":{"type":"string","description":"Words that must all occur (case-insensitive) in a package''s name, ' +
      'description, category or .lpk names/descriptions, e.g. \"chart\", \"rich memo\", \"zip\". Empty lists everything."},' +
    '"category":{"type":"string","description":"Only packages whose category contains this text, e.g. Graphics, ' +
      'Networking, DataControls, LazIDEPlugins"},' +
    '"limit":{"type":"integer","description":"Most packages to return (default 20; less than 1 also means 20)"}}}';

  OPM_REPOSITORY_URL = 'https://packages.lazarus-ide.org/';

  SCHEMA_DOWNLOAD =
    '{"type":"object","properties":{' +
    '"name":{"type":"string","description":"Package name as package_search_online returns it"},' +
    '"replace":{"type":"boolean","description":"Download again over an earlier download ' +
      '(default false); refused while a package from it is installed or loaded"}},' +
    '"required":["name"]}';

  { reaches the internet }
  MCP_ANN_OPEN = '{"readOnlyHint":false,"destructiveHint":false,"openWorldHint":true}';

  DOWNLOAD_MAX_BYTES = 300 * 1024 * 1024;

{ ── Online Package Manager catalog ───────────────────────────────────────── }

function OpmDir(const ASub: string): string;
begin
  Result := AppendPathDelim(LazarusIDE.GetPrimaryConfigPath) + 'onlinepackagemanager' +
            PathDelim + ASub + PathDelim;
end;

{ The catalog OPM downloaded last (packagelist_<hash of repository URL>.json). }
function OpmCatalogFile: string;
var
  SR   : TSearchRec;
  Best : LongInt;
begin
  Result := '';
  Best   := -1;
  if FindFirst(OpmDir('config') + 'packagelist_*.json', faAnyFile, SR) = 0 then
  try
    repeat
      if SR.Time > Best then
      begin
        Best   := SR.Time;
        Result := OpmDir('config') + SR.Name;
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

{ OPM writes paths as 'Dir\/Sub\/'. }
function OpmPath(const S: string): string;
begin
  Result := StringReplace(S, '\/', PathDelim, [rfReplaceAll]);
  Result := StringReplace(Result, '/', PathDelim, [rfReplaceAll]);
end;

function OpmPackageType(AType: Integer): string;
begin
  case AType of
    0: Result := 'designtime+runtime';
    1: Result := 'designtime';
    2: Result := 'runtime';
    3: Result := 'runtime only';
  else Result := IntToStr(AType);
  end;
end;

function Capped(const S: string; AMax: Integer): string;
begin
  Result := Trim(S);
  if Length(Result) > AMax then
    Result := Copy(Result, 1, AMax) + '...';
end;

{ Search the cached catalog; main thread (install state comes from the IDE). }
function SearchOnlineCatalog(AParams: TJSONObject; out AErr: string): string;
var
  Term : string;
  En : TJSONEnum;
  FileName, Text, Hay, Category : string;
  Words     : TStringArray;
  Root      : TJSONData;
  Cat       : TJSONObject;
  Data      : TJSONObject;
  Files     : TJSONArray;
  F         : TJSONObject;
  Res, FArr : TJSONArray;
  Obj, FObj, PObj : TJSONObject;
  I, Matches, MaxRes       : Integer;
  Ok        : Boolean;
  BaseDir, Lpk, Desc : string;
  SL        : TStringList;
begin
  Result := '';
  AErr   := '';
  FileName := OpmCatalogFile;
  if FileName = '' then
  begin
    AErr := 'No Online Package Manager catalog found. Open Package > Online Package ' +
            'Manager in the IDE once to download it.';
    Exit;
  end;
  SL := TStringList.Create;
  try
    SL.LoadFromFile(FileName);
    Text := SL.Text;
  finally
    SL.Free;
  end;
  if Copy(Text, 1, 3) = #$EF#$BB#$BF then
    Delete(Text, 1, 3);
  Words    := nil;
  Category := '';
  MaxRes   := 20;
  if Assigned(AParams) then   { AParams may be nil: no arguments }
  begin
    Words    := LowerCase(Trim(AParams.Get('query', ''))).Split([' '], TStringSplitOptions.ExcludeEmpty);
    Category := LowerCase(Trim(AParams.Get('category', '')));
    MaxRes   := AParams.Get('limit', 20);
  end;
  if MaxRes < 1 then MaxRes := 20;

  Root := GetJSON(Text);
  Res  := TJSONArray.Create;
  Obj  := TJSONObject.Create;
  try
    if not (Root is TJSONObject) then
    begin
      AErr := 'Unexpected catalog format: ' + FileName; Exit;
    end;
    Cat := TJSONObject(Root);
    Matches := 0;
    I := 0;
    while Cat.Find('PackageData' + IntToStr(I)) is TJSONObject do
    begin
      Data  := TJSONObject(Cat.Find('PackageData' + IntToStr(I)));
      Files := nil;
      if Cat.Find('PackageFiles' + IntToStr(I)) is TJSONArray then
        Files := TJSONArray(Cat.Find('PackageFiles' + IntToStr(I)));
      Inc(I);

      if (Category <> '') and (Pos(Category, LowerCase(Data.Get('Category', ''))) = 0) then
        Continue;
      Hay := Data.Get('Name', '') + ' ' + Data.Get('DisplayName', '') + ' ' +
             Data.Get('Category', '') + ' ' + Data.Get('CommunityDescription', '');
      if Assigned(Files) then
        for En in Files do
          if En.Value is TJSONObject then
            Hay := Hay + ' ' + TJSONObject(En.Value).Get('Name', '') + ' ' +
                   TJSONObject(En.Value).Get('Description', '');
      Hay := LowerCase(Hay);
      Ok := True;
      for Term in Words do
        if Pos(Term, Hay) = 0 then
        begin
          Ok := False; Break;
        end;
      if not Ok then Continue;
      Inc(Matches);
      if Res.Count >= MaxRes then Continue;

      Desc := Data.Get('CommunityDescription', '');
      BaseDir := OpmDir('packages') + OpmPath(Data.Get('PackageBaseDir', ''));
      FObj := TJSONObject.Create;
      Res.Add(FObj);
      FObj.Add('name',      Data.Get('Name', ''));
      if Data.Get('DisplayName', '') <> Data.Get('Name', '') then
        FObj.Add('display_name', Data.Get('DisplayName', ''));
      FObj.Add('category',  Data.Get('Category', ''));
      FArr := TJSONArray.Create;
      if Assigned(Files) then
        for En in Files do
        begin
          if not (En.Value is TJSONObject) then Continue;
          F := TJSONObject(En.Value);
          if Desc = '' then Desc := F.Get('Description', '');
          Lpk  := F.Get('Name', '');
          PObj := TJSONObject.Create;
          FArr.Add(PObj);
          PObj.Add('lpk',        Lpk);
          PObj.Add('version',    F.Get('VersionAsString', ''));
          PObj.Add('type',       OpmPackageType(F.Get('PackageType', 0)));
          if F.Get('Description', '') <> '' then
            PObj.Add('description', Capped(F.Get('Description', ''), 200));
          PObj.Add('license',    Capped(F.Get('License', ''), 80));
          PObj.Add('lazarus',    F.Get('LazCompatibility', ''));
          PObj.Add('fpc',        F.Get('FPCCompatibility', ''));
          PObj.Add('widgetsets', F.Get('SupportedWidgetSet', ''));
          PObj.Add('depends_on', F.Get('DependenciesAsString', ''));
          PObj.Add('installed',
            Assigned(PackageEditingInterface.IsPackageInstalled(ChangeFileExt(Lpk, ''))));
          Lpk := BaseDir + OpmPath(F.Get('RelativeFilePath', '')) + Lpk;
          if FileExists(Lpk) then
            PObj.Add('downloaded_lpk', Lpk);   { ready for package_install }
        end;
      FObj.Add('description', Capped(Desc, 400));
      FObj.Add('homepage',   Data.Get('HomePageURL', ''));
      FObj.Add('archive',    OPM_REPOSITORY_URL + Data.Get('RepositoryFileName', ''));
      FObj.Add('archive_date', FormatDateTime('yyyy-mm-dd', Data.Get('RepositoryDate', 0.0)));
      if Data.Get('ExternalDependecies', '') <> '' then
        FObj.Add('external_dependencies', Data.Get('ExternalDependecies', ''));
      if Data.Get('OrphanedPackage', 0) <> 0 then
        FObj.Add('orphaned', True);
      FObj.Add('packages', FArr);
    end;
    Obj.Add('catalog_file', FileName);
    Obj.Add('catalog_date', FormatDateTime('yyyy-mm-dd', FileDateToDateTime(FileAge(FileName))));
    Obj.Add('catalog_packages', I);
    Obj.Add('matches', Matches);
    Obj.Add('results', Res);
    Res := nil;
    Result := Obj.AsJSON;
  finally
    Res.Free;
    Obj.Free;
    Root.Free;
  end;
end;

{ ── package_download (ADR-013 "Downloads") ───────────────────────────────── }

type
  { One download: Prepare runs on the main thread (catalog, OPM folders, IDE
    state); the rest runs on the HTTP worker thread. }
  TOpmDownload = class
  public
    InName     : string;
    InReplace  : Boolean;
    Err        : string;
    PkgName    : string;
    ZipName    : string;
    Md5        : string;
    Size       : Int64;
    Target     : string;   { packages folder + PackageBaseDir }
    PackagesDir: string;
    ArchiveDir : string;
    Lpks       : TStringList;   { .lpk paths below Target, as the catalog lists them }
    Url        : string;
    Transport  : string;
    constructor Create;
    destructor Destroy; override;
    procedure Prepare;
    procedure Run;
  end;

constructor TOpmDownload.Create;
begin
  inherited Create;
  Lpks := TStringList.Create;
end;

destructor TOpmDownload.Destroy;
begin
  Lpks.Free;
  inherited Destroy;
end;

{ A relative path that stays inside its folder: no drive, no root, no '..'. }
function SafeRelPath(const S: string): Boolean;
var
  Parts : TStringArray;
  P     : string;
begin
  Result := False;
  if (S = '') or (Pos(':', S) > 0) or (S[1] in ['/', '\']) then Exit;
  Parts := StringReplace(S, '\', '/', [rfReplaceAll]).Split(['/']);
  for P in Parts do
    if P = '..' then Exit;
  Result := True;
end;

function OpmFolder(const AKey, ADefault: string): string;
var
  Cfg : TXMLConfig;
  FN  : string;
begin
  Result := '';
  FN := OpmDir('config') + 'options.xml';
  if FileExists(FN) then
  try
    Cfg := TXMLConfig.Create(FN);
    try
      Result := Cfg.GetValue('Folders/' + AKey + '/Value', '');
    finally
      Cfg.Free;
    end;
  except
    Result := '';
  end;
  if Result = '' then Result := ADefault;
  Result := AppendPathDelim(Result);
end;

procedure TOpmDownload.Prepare;
var
  En : TJSONEnum;
  Item : string;
  FileName, Text, Rel, Lpk : string;
  SL     : TStringList;
  Root   : TJSONData;
  Cat, Data, F : TJSONObject;
  Files  : TJSONArray;
  I      : Integer;
  Pkg    : TIDEPackage;
begin
  Err := '';
  FileName := OpmCatalogFile;
  if FileName = '' then
  begin
    Err := 'No Online Package Manager catalog found. Open Package > Online Package ' +
           'Manager in the IDE once to download it.';
    Exit;
  end;
  SL := TStringList.Create;
  try
    SL.LoadFromFile(FileName);
    Text := SL.Text;
  finally
    SL.Free;
  end;
  if Copy(Text, 1, 3) = #$EF#$BB#$BF then Delete(Text, 1, 3);
  Root := GetJSON(Text);
  try
    if not (Root is TJSONObject) then
    begin Err := 'Unexpected catalog format: ' + FileName; Exit; end;
    Cat  := TJSONObject(Root);
    Data := nil;
    I := 0;
    while Cat.Find('PackageData' + IntToStr(I)) is TJSONObject do
    begin
      if SameText(TJSONObject(Cat.Find('PackageData' + IntToStr(I))).Get('Name', ''), InName) then
      begin
        Data := TJSONObject(Cat.Find('PackageData' + IntToStr(I)));
        Break;
      end;
      Inc(I);
    end;
    if Data = nil then
    begin
      Err := InName + ' is not in the catalog; package_search_online shows the names';
      Exit;
    end;
    PkgName := Data.Get('Name', '');
    ZipName := Data.Get('RepositoryFileName', '');
    Md5     := LowerCase(Trim(Data.Get('RepositoryFileHash', '')));
    Size    := Data.Get('RepositoryFileSize', Int64(0));
    Rel     := OpmPath(Data.Get('PackageBaseDir', ''));
    if (ZipName = '') or (ZipName <> ExtractFileName(ZipName)) or not SafeRelPath(ZipName) or
       not SafeRelPath(Rel) or (Length(Md5) <> 32) then
    begin
      Err := 'The catalog entry of ' + PkgName + ' has no usable archive name, folder ' +
             'or MD5 hash; use the Online Package Manager';
      Exit;
    end;
    if Size > DOWNLOAD_MAX_BYTES then
    begin
      Err := Format('%s is %d MB; download it with the Online Package Manager',
                    [PkgName, Size div (1024 * 1024)]);
      Exit;
    end;
    PackagesDir := OpmFolder('LocalRepositoryPackages', OpmDir('packages'));
    ArchiveDir  := OpmFolder('LocalRepositoryArchive', OpmDir('archive'));
    Target      := AppendPathDelim(PackagesDir + Rel);
    Url         := OPM_REPOSITORY_URL + ZipName;

    if Cat.Find('PackageFiles' + IntToStr(I)) is TJSONArray then
    begin
      Files := TJSONArray(Cat.Find('PackageFiles' + IntToStr(I)));
      for En in Files do
        if En.Value is TJSONObject then
        begin
          F := TJSONObject(En.Value);
          Rel := OpmPath(F.Get('RelativeFilePath', ''));
          Lpk := F.Get('Name', '');
          if ((Rel = '') or SafeRelPath(Rel)) and SafeRelPath(Lpk) then
            Lpks.Add(Target + Rel + Lpk);
        end;
    end;

    if DirectoryExists(Target) then
    begin
      if not InReplace then
      begin
        Err := PkgName + ' is downloaded already, in ' + Target + '. Install its .lpk ' +
               'with package_install, or pass replace=true to download it again.';
        Exit;
      end;
      { new sources under an installed or loaded package would reach the IDE
        at the next rebuild without consent (ADR-013) }
      for Item in Lpks do
      begin
        Pkg := PackageEditingInterface.FindPackageWithName(ExtractFileNameOnly(Item));
        if Assigned(Pkg) and (Pos(LowerCase(Target), LowerCase(Pkg.Filename)) = 1) then
        begin
          Err := Pkg.Name + ' is installed or loaded from ' + Target + '; its sources ' +
                 'can''t be replaced while it is. Uninstall it first, or update it with ' +
                 'the Online Package Manager.';
          Exit;
        end;
      end;
    end;
  finally
    Root.Free;
  end;
end;

{ The curl executable: Windows 10 and later ship one in System32 (SChannel and the
  system certificate store), macOS and most Linux systems have one on the PATH. }
function FindCurl: string;
begin
  Result := '';
  {$IFDEF MSWINDOWS}
  Result := GetEnvironmentVariable('SystemRoot') + '\System32\curl.exe';
  if FileExists(Result) then Exit;
  {$ENDIF}
  Result := FindDefaultExecutablePath('curl');
end;

{ Fetch AUrl through the curl executable into AStream. }
function CurlGet(const AUrl: string; AStream: TMemoryStream; out AErr: string): Boolean;
var
  Exe, Tmp, Msg : string;
  Code          : Integer;
begin
  Result := False;
  AErr := '';
  Exe := FindCurl;
  if Exe = '' then
  begin
    AErr := 'no curl executable found';
    Exit;
  end;
  Tmp := GetTempFileName(GetTempDir, 'mcpdl');
  try
    { the archive goes to the file (-o), so what curl prints is only its error text }
    case McpRunCapture(Exe, ['-fsSL', '--max-time', '120', '--connect-timeout', '15',
                             '-o', Tmp, AUrl], '', Msg, Code) of
      reNotStarted:
        begin
          AErr := 'curl could not run: ' + Msg;
          Exit;
        end;
    end;
    if (Code = 0) and FileExists(Tmp) then
    begin
      AStream.Clear;
      AStream.LoadFromFile(Tmp);
      Result := True;
    end
    else
    begin
      Msg := Trim(Msg);
      if Msg = '' then Msg := 'exit code ' + IntToStr(Code);
      AErr := 'curl: ' + Msg;
    end;
  finally
    if FileExists(Tmp) then DeleteFile(Tmp);
  end;
end;

{ Fetch AUrl into AStream over HTTPS: in-process, and through the curl executable
  when the IDE has no OpenSSL (on Windows it often has none). Never plain HTTP. }
function FetchArchive(const AHttpsUrl: string; AStream: TMemoryStream;
  out AUrl, ATransport, AErr: string): Boolean;

  function Get(const U: string; out E: string): Boolean;
  var
    C : TFPHTTPClient;
  begin
    E := '';
    AStream.Clear;
    C := TFPHTTPClient.Create(nil);
    try
      C.AllowRedirect  := True;
      C.ConnectTimeout := 15000;
      C.IOTimeout      := 60000;
      try
        C.Get(U, AStream);
        Result := C.ResponseStatusCode = 200;
        if not Result then
          E := Format('%s answered %d %s', [U, C.ResponseStatusCode, C.ResponseStatusText]);
      except
        on X: Exception do
        begin
          E := X.Message;
          Result := False;
        end;
      end;
    finally
      C.Free;
    end;
  end;

begin
  AUrl := AHttpsUrl;
  ATransport := 'https';
  Result := Get(AUrl, AErr);
  if Result or (Pos('openssl', LowerCase(AErr)) = 0) then Exit;
  { no TLS library in the IDE: the curl executable brings its own }
  ATransport := 'https (curl)';
  if CurlGet(AUrl, AStream, AErr) then
    Exit(True);
  { never downgrade to plain HTTP: the server answers HTTPS (checked 2026-11-22),
    and an archive that comes unencrypted could be swapped together with its MD5 }
  AErr := 'No TLS available: this IDE has no OpenSSL libraries and curl failed (' + AErr +
    '). Install the OpenSSL DLLs next to the IDE or put curl on the PATH, or install ' +
    'the package through the IDE''s Online Package Manager. Nothing was downloaded over plain HTTP.';
  Result := False;
end;

procedure TOpmDownload.Run;
var
  Mem     : TMemoryStream;
  Zip     : TUnZipper;
  ZipFile, TmpDir, Src, Name, Top, First : string;
  I, P    : Integer;
  Marker  : TJSONObject;
  SL      : TStringList;
  HttpsUrl: string;
begin
  Err := '';
  HttpsUrl := Url;   { not Url itself: an out parameter is cleared on entry }
  Mem := TMemoryStream.Create;
  try
    if not FetchArchive(HttpsUrl, Mem, Url, Transport, Err) then
    begin
      Err := 'Download failed: ' + Err; Exit;
    end;
    if LowerCase(MD5Print(MD5Buffer(Mem.Memory^, Mem.Size))) <> Md5 then
    begin
      Err := Format('The archive''s MD5 does not match the catalog (%d bytes from %s); ' +
                    'nothing was saved', [Mem.Size, Url]);
      Exit;
    end;
    ForceDirectories(ArchiveDir);
    ZipFile := ArchiveDir + ZipName;
    Mem.SaveToFile(ZipFile);
  finally
    Mem.Free;
  end;

  TmpDir := PackagesDir + '.mcp-tmp-' + ChangeFileExt(ZipName, '') + PathDelim;
  if DirectoryExists(TmpDir) then DeleteDirectory(TmpDir, False);
  Zip := TUnZipper.Create;
  try
    Zip.FileName := ZipFile;
    Zip.Examine;
    { every entry must stay inside the folder; one top folder common to all
      entries is dropped, as the Online Package Manager does }
    Top := '';
    for I := 0 to Zip.Entries.Count - 1 do
    begin
      Name := StringReplace(Zip.Entries[I].ArchiveFileName, '\', '/', [rfReplaceAll]);
      if not SafeRelPath(Name) then
      begin
        Err := 'The archive has an unsafe entry, ' + Name + '; nothing was extracted';
        Exit;
      end;
      P := Pos('/', Name);
      if P = 0 then First := '' else First := Copy(Name, 1, P);
      if I = 0 then Top := First
      else if First <> Top then Top := '';
    end;
    ForceDirectories(TmpDir);
    Zip.OutputPath := TmpDir;
    try
      Zip.UnZipAllFiles;
    except
      on X: Exception do
      begin
        Err := 'Extracting ' + ZipFile + ' failed: ' + X.Message;
        DeleteDirectory(TmpDir, False);
        Exit;
      end;
    end;
  finally
    Zip.Free;
  end;

  Src := TmpDir + StringReplace(Top, '/', PathDelim, [rfReplaceAll]);
  if DirectoryExists(Target) then
    DeleteDirectory(Target, False);
  ForceDirectories(ExtractFilePath(ChompPathDelim(Target)));
  if not RenameFile(ChompPathDelim(Src), ChompPathDelim(Target)) and
     not CopyDirTree(Src, Target, [cffOverwriteFile, cffCreateDestDirectory]) then
  begin
    Err := 'Could not move the extracted files to ' + Target;
    DeleteDirectory(TmpDir, False);
    Exit;
  end;
  if DirectoryExists(TmpDir) then DeleteDirectory(TmpDir, False);

  { read by the consent dialog (McpConsent.DownloadSource) }
  Marker := TJSONObject.Create;
  SL := TStringList.Create;
  try
    Marker.Add('tool', 'package_download');
    Marker.Add('source', 'the Online Package Manager repository');
    Marker.Add('url', Url);
    Marker.Add('transport', Transport);
    Marker.Add('md5', Md5);
    Marker.Add('date', FormatDateTime('yyyy-mm-dd hh:nn', Now));
    SL.Text := Marker.FormatJSON;
    SL.SaveToFile(Target + MCP_DOWNLOAD_MARKER);
  finally
    SL.Free;
    Marker.Free;
  end;
end;

{ Worker thread: the main thread only reads the catalog and the IDE's state. }
function DispatchPackagesBlockingTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  Job : TOpmDownload;
  Obj : TJSONObject;
  Arr : TJSONArray;
  I   : Integer;
begin
  Result := Name = 'package_download';
  if not Result then Exit;
  if not Assigned(Ctx.Params) or (Trim(Ctx.Params.Get('name', '')) = '') then
  begin
    Ctx.Error := True; Ctx.Result := 'name required'; Exit;
  end;
  Job := TOpmDownload.Create;
  try
    Job.InName    := Trim(Ctx.Params.Get('name', ''));
    Job.InReplace := Ctx.Params.Get('replace', False);
    TThread.Synchronize(nil, @Job.Prepare);
    if Job.Err = '' then
      Job.Run;
    if Job.Err <> '' then
    begin
      Ctx.Error := True; Ctx.Result := Job.Err; Exit;
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('package', Job.PkgName);
      Obj.Add('url', Job.Url);
      Obj.Add('transport', Job.Transport);
      Obj.Add('md5_verified', True);
      Obj.Add('directory', Job.Target);
      Arr := TJSONArray.Create;
      for I := 0 to Job.Lpks.Count - 1 do
        if FileExists(Job.Lpks[I]) then
          Arr.Add(Job.Lpks[I]);
      Obj.Add('lpk_files', Arr);
      Obj.Add('next', 'Nothing is installed yet. Install with package_install and an ' +
        'lpk_path from lpk_files; the user has to allow installs and confirm in the IDE.');
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  finally
    Job.Free;
  end;
end;

{ ── Dependencies (IDE package graph) ─────────────────────────────────────── }

function DepStatus(Dep: TPkgDependency): string;
begin
  if Assigned(Dep.RequiredPackage) then Exit('ok');
  if Dep.DependencyType = pdtFPMake then Exit('fpmake');
  case Dep.LoadPackageResult of
    lprAvailableOnline: Result := 'available_online';
    lprNotFound:        Result := 'not_found';
    lprLoadError:       Result := 'load_error';
  else                  Result := 'unresolved';
  end;
end;

function OwnerName(AOwner: TObject): string;
begin
  if AOwner is TLazPackage then
    Result := TLazPackage(AOwner).Name
  else if AOwner is TProject then
    Result := 'project ' + ExtractFileName(TProject(AOwner).ProjectInfoFile)
  else
    Result := 'IDE';
end;

{ One requirement as declared in the .lpi/.lpk, plus what it resolved to. }
function DepJSON(Dep: TPkgDependency): TJSONObject;
var
  Pkg: TLazPackage;
begin
  Result := TJSONObject.Create;
  Result.Add('name', Dep.PackageName);
  if pdfMinVersion in Dep.Flags then
    Result.Add('min_version', Dep.MinVersion.AsString);
  if pdfMaxVersion in Dep.Flags then
    Result.Add('max_version', Dep.MaxVersion.AsString);
  Result.Add('status', DepStatus(Dep));
  Pkg := Dep.RequiredPackage;
  if Assigned(Pkg) then
  begin
    Result.Add('version', Pkg.Version.AsString);
    Result.Add('file', Pkg.Filename);
    Result.Add('type', LazPackageTypeIdents[Pkg.PackageType]);
    Result.Add('installed', Pkg.Installed <> pitNope);
  end;
end;

function DepNames(First: TPkgDependency): TJSONArray;
begin
  Result := TJSONArray.Create;
  while Assigned(First) do
  begin
    if Assigned(First.RequiredPackage) then
      Result.Add(First.PackageName)
    else
      Result.Add(First.PackageName + ' (' + DepStatus(First) + ')');
    First := First.NextRequiresDependency;
  end;
end;

function ProjectPackagesJSON(Proj: TProject; Recursive: Boolean): string;
var
  Ptr : Pointer;
  Obj, PObj : TJSONObject;
  Arr       : TJSONArray;
  Dep       : TPkgDependency;
  List      : TFPList;
  Pkg       : TLazPackage;
begin
  Obj := TJSONObject.Create;
  try
    Obj.Add('project', Proj.ProjectInfoFile);
    Arr := TJSONArray.Create;
    Obj.Add('requires', Arr);
    Dep := Proj.FirstRequiredDependency;
    while Assigned(Dep) do
    begin
      Arr.Add(DepJSON(Dep));
      Dep := Dep.NextRequiresDependency;
    end;
    if Recursive then
    begin
      PackageEditingInterface.GetRequiredPackages(Proj, List, [pirCompileOrder]);
      Arr := TJSONArray.Create;
      Obj.Add('compile_order', Arr);
      if Assigned(List) then
      try
        for Ptr in List do
        begin
          if not (TObject(Ptr) is TLazPackage) then Continue;
          Pkg  := TLazPackage(Ptr);
          PObj := TJSONObject.Create;
          Arr.Add(PObj);
          PObj.Add('name', Pkg.Name);
          PObj.Add('version', Pkg.Version.AsString);
          PObj.Add('file', Pkg.Filename);
          PObj.Add('requires', DepNames(Pkg.FirstRequiredDependency));
        end;
      finally
        List.Free;
      end;
    end;
    Result := Obj.AsJSON;
  finally
    Obj.Free;
  end;
end;

{ package_get_info: install state, plus requirements, users and files of a loaded package. }
function PackageInfoJSON(const PkgName: string; WithFiles: Boolean;
  APkg: TLazPackage): string;
var
  Obj, FObj : TJSONObject;
  Arr       : TJSONArray;
  IDEPkg    : TIDEPackage;
  Pkg       : TLazPackage;
  Dep       : TPkgDependency;
  F         : TLazPackageFile;
  I         : Integer;
begin
  Obj := TJSONObject.Create;
  try
    Obj.Add('package_name', PkgName);
    IDEPkg := PackageEditingInterface.IsPackageInstalled(PkgName);
    Obj.Add('is_installed', Assigned(IDEPkg));
    if Assigned(IDEPkg) then
      Obj.Add('package_file', IDEPkg.Filename);
    IDEPkg := APkg;
    if IDEPkg = nil then
      IDEPkg := PackageEditingInterface.FindPackageWithName(PkgName);
    Obj.Add('is_loaded', Assigned(IDEPkg));
    if IDEPkg is TLazPackage then
    begin
      Pkg := TLazPackage(IDEPkg);
      Obj.Add('loaded_file', Pkg.Filename);
      Obj.Add('version', Pkg.Version.AsString);
      Obj.Add('type', LazPackageTypeIdents[Pkg.PackageType]);
      if Pkg.Description <> '' then
        Obj.Add('description', Capped(Pkg.Description, 400));
      if Pkg.Modified then
        Obj.Add('modified', True);
      if Pkg.ReadOnly then
        Obj.Add('read_only', True);
      if Pkg.Missing then
        Obj.Add('lpk_missing', True);
      Obj.Add('saved', not Pkg.IsVirtual);
      if Pkg.Author <> '' then Obj.Add('author', Pkg.Author);
      if Pkg.License <> '' then Obj.Add('license', Capped(Pkg.License, 200));
      Obj.Add('unit_output_dir', Pkg.CompilerOptions.UnitOutputDirectory);
      Obj.Add('unit_search_path', Pkg.CompilerOptions.OtherUnitFiles);
      Obj.Add('include_path',     Pkg.CompilerOptions.IncludePath);
      if Pkg.CompilerOptions.CustomOptions <> '' then
        Obj.Add('custom_options', Pkg.CompilerOptions.CustomOptions);
      Arr := TJSONArray.Create;
      Obj.Add('requires', Arr);
      Dep := Pkg.FirstRequiredDependency;
      while Assigned(Dep) do
      begin
        Arr.Add(DepJSON(Dep));
        Dep := Dep.NextRequiresDependency;
      end;
      Arr := TJSONArray.Create;
      Obj.Add('required_by', Arr);
      Dep := Pkg.FirstUsedByDependency;
      while Assigned(Dep) do
      begin
        Arr.Add(OwnerName(Dep.Owner));
        Dep := Dep.NextUsedByDependency;
      end;
      Obj.Add('file_count', Pkg.FileCount);
      if WithFiles then
      begin
        Arr := TJSONArray.Create;
        Obj.Add('files', Arr);
        for I := 0 to Pkg.FileCount - 1 do
        begin
          F := Pkg.Files[I];
          FObj := TJSONObject.Create;
          Arr.Add(FObj);
          FObj.Add('file', F.GetShortFilename(False));
          FObj.Add('type', PkgFileTypeIdents[F.FileType]);
          if F.Unit_Name <> '' then
            FObj.Add('unit', F.Unit_Name);
          if (F.FileType in PkgFileRealUnitTypes) and not F.InUses then
            FObj.Add('in_uses', False);
          if (F is TPkgFile) and TPkgFile(F).HasRegisterProc then
            FObj.Add('register', True);
        end;
      end;
    end;
    Result := Obj.AsJSON;
  finally
    Obj.Free;
  end;
end;

{ Which loaded packages list a unit; whether the active project can see them. }
function FindUnitJSON(const AUnit: string): string;
var
  Obj, PObj : TJSONObject;
  Arr       : TJSONArray;
  Pkg       : TIDEPackage;
  F         : TLazPackageFile;
  Proj      : TLazProject;
  DepOwner  : TObject;
  I, J      : Integer;
begin
  Obj := TJSONObject.Create;
  try
    Obj.Add('unit_name', AUnit);
    Arr := TJSONArray.Create;
    Obj.Add('packages', Arr);
    Proj := LazarusIDE.ActiveProject;
    for I := 0 to PackageEditingInterface.GetPackageCount - 1 do
    begin
      Pkg := PackageEditingInterface.GetPackages(I);
      for J := 0 to Pkg.FileCount - 1 do
      begin
        F := Pkg.Files[J];
        if not (F.FileType in PkgFileUnitTypes) or
           (CompareText(F.Unit_Name, AUnit) <> 0) and
           (CompareText(ExtractFileNameOnly(F.Filename), AUnit) <> 0) then
          Continue;
        PObj := TJSONObject.Create;
        Arr.Add(PObj);
        PObj.Add('package', Pkg.Name);
        PObj.Add('package_file', Pkg.Filename);
        PObj.Add('unit_file', F.GetFullFilename);
        PObj.Add('installed', Assigned(PackageEditingInterface.IsPackageInstalled(Pkg.Name)));
        if Assigned(Proj) then
          PObj.Add('project_requires',
            PackageEditingInterface.IsOwnerDependingOnPkg(Proj, Pkg.Name, DepOwner));
        Break;
      end;
    end;
    if Arr.Count = 0 then
      Obj.Add('hint', 'No loaded package lists this unit. It may be an FPC unit ' +
        '(check the unit path), or the package is not loaded: try package_search_online.');
    Result := Obj.AsJSON;
  finally
    Obj.Free;
  end;
end;

{ ── Package editing ──────────────────────────────────────────────────────── }

{ The package a package_add_file etc. call names, by package_name or
  lpk_path.  A .lpk not loaded yet is opened without a package editor; one
  whose name is already loaded from another file is refused (opening it would
  ask whether to replace the loaded one). }
function TargetPackage(AParams: TJSONObject; out APkg: TLazPackage;
  out AErr: string; AForEdit: Boolean): Boolean;
var
  Name, Lpk : string;
  Other     : TLazPackage;
  Link      : TPackageLink;
begin
  Result := False;
  APkg   := nil;
  AErr   := '';
  Name := Trim(AParams.Get('package_name', ''));
  Lpk  := Trim(AParams.Get('lpk_path', ''));
  if (Lpk <> '') and (Name <> '') and not SameText(ExtractFileNameOnly(Lpk), Name) then
  begin
    AErr := 'package_name ' + Name + ' and lpk_path ' + Lpk + ' name different packages; ' +
            'give one of them';
    Exit;
  end;
  if Lpk <> '' then
  begin
    if not FilenameIsAbsolute(Lpk) or not FileExists(Lpk) then
    begin AErr := 'No such .lpk: ' + Lpk; Exit; end;
    APkg := PackageGraph.FindPackageWithFilename(Lpk);
    if APkg = nil then
    begin
      Other := PackageGraph.FindPackageWithName(ExtractFileNameOnly(Lpk), nil);
      if Assigned(Other) then
      begin
        AErr := Format('A package %s is already loaded from %s; it can''t be ' +
                       'loaded from %s too', [Other.Name, Other.Filename, Lpk]);
        Exit;
      end;
      PackageEditingInterface.DoOpenPackageFile(Lpk, [pofDoNotOpenEditor], False);
      APkg := PackageGraph.FindPackageWithFilename(Lpk);
      if APkg = nil then
      begin AErr := 'Could not load ' + Lpk; Exit; end;
    end;
  end
  else if Name <> '' then
  begin
    APkg := PackageGraph.FindPackageWithName(Name, nil);
    if APkg = nil then
    begin
      { The IDE unloads a package nothing holds (no editor, not installed, not
        required), so one that package_create or package_open just loaded may be gone
        again by the next call: open it from its package link. }
      Link := LazPackageLinks.FindLinkWithPkgName(Name);
      if Assigned(Link) and FileExists(Link.LPKFilename) then
      begin
        PackageEditingInterface.DoOpenPackageFile(Link.LPKFilename,
          [pofDoNotOpenEditor], False);
        APkg := PackageGraph.FindPackageWithFilename(Link.LPKFilename);
      end;
    end;
    if APkg = nil then
    begin
      AErr := 'Package not loaded: ' + Name + '. Give its lpk_path instead.';
      Exit;
    end;
  end
  else
  begin
    AErr := 'package_name or lpk_path required'; Exit;
  end;
  if not AForEdit then Exit(True);
  if APkg.IsVirtual then
  begin AErr := APkg.Name + ' has not been saved yet'; Exit; end;
  if APkg.ReadOnly then
  begin AErr := APkg.Name + ' is read-only (' + APkg.Filename + ')'; Exit; end;
  Result := True;
end;

{ The package name a project_add_package / project_remove_package call means:
  package_name, or the package of lpk_path (loaded for the call when ALoad, as
  adding needs the IDE to know it).  AErr = '' on success. }
function SelectedPackageName(AParams: TJSONObject; ALoad: Boolean;
  out AName, AErr: string): Boolean;
var
  Pkg : TLazPackage;
  Lpk : string;
begin
  Result := False;
  AErr := '';
  AName := '';
  if not Assigned(AParams) then begin AErr := 'package_name or lpk_path required'; Exit; end;
  Lpk := Trim(AParams.Get('lpk_path', ''));
  if Lpk = '' then
  begin
    AName := Trim(AParams.Get('package_name', ''));
    if AName = '' then begin AErr := 'package_name or lpk_path required'; Exit; end;
    Exit(True);
  end;
  if ALoad then
  begin
    if not TargetPackage(AParams, Pkg, AErr, False) then Exit;
    AName := Pkg.Name;
    Exit(True);
  end;
  { removing: the file names the package; mismatch with package_name is refused as above }
  if (Trim(AParams.Get('package_name', '')) <> '') and
     not SameText(ExtractFileNameOnly(Lpk), Trim(AParams.Get('package_name', ''))) then
  begin
    AErr := 'package_name ' + AParams.Get('package_name', '') + ' and lpk_path ' + Lpk +
            ' name different packages; give one of them';
    Exit;
  end;
  Pkg := PackageGraph.FindPackageWithFilename(Lpk);
  if Assigned(Pkg) then AName := Pkg.Name else AName := ExtractFileNameOnly(Lpk);
  Result := True;
end;

{ Save APkg the way the package editor's Save button does, unless that would
  write more than this change or ask the user something: DoSaveAllPackages
  saves every modified package and the package's modified editor files, and
  asks about files missing on disk.  '' = saved, else why not. }
function SavePackage(APkg: TLazPackage; AWasModified: Boolean): string;
var
  I     : Integer;
  Other : TIDEPackage;
  F     : TLazPackageFile;
  FN    : string;
  Ed    : TSourceEditorInterface;
begin
  if AWasModified then
    Exit(APkg.Name + ' already had unsaved changes in the IDE, and saving would ' +
         'write them too');
  for I := 0 to PackageEditingInterface.GetPackageCount - 1 do
  begin
    Other := PackageEditingInterface.GetPackages(I);
    if (Other <> APkg) and Other.Modified then
      Exit('package ' + Other.Name + ' has unsaved changes, and saving would write them too');
  end;
  for I := 0 to APkg.FileCount - 1 do
  begin
    F  := APkg.Files[I];
    FN := F.GetFullFilename;
    if (F.FileType = pftVirtualUnit) or (Pos('$(', FN) > 0) then Continue;
    if not FileExists(FN) then
      Exit('the package''s file ' + FN + ' is missing on disk');
    Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(FN);
    if Assigned(Ed) and Ed.Modified then
      Exit(FN + ' has unsaved editor changes, and saving would write them too');
  end;
  if (PackageEditingInterface.DoSaveAllPackages([]) <> mrOk) or APkg.Modified then
    Exit('saving failed');
  Result := '';
end;

{ package_save: write the .lpk of the named package (or, without a name, of every
  modified package) to disk.  The IDE writes every modified package at once, so a
  named package is refused while another one is modified, unless save_all is true.
  Anything that would make the IDE ask a question (a package never saved, read-only,
  a file missing on disk, an editor of its files with unsaved text) is refused and
  named.  AErr = '' on success; the result is the JSON. }
function PackageSave(AParams: TJSONObject; out AErr: string): string;
var
  Target, Pkg : TLazPackage;
  Mods        : TStringList;
  I, J        : Integer;
  Other       : TIDEPackage;
  F           : TLazPackageFile;
  FN, Why     : string;
  Ed          : TSourceEditorInterface;
  SaveAll     : Boolean;
  Obj         : TJSONObject;
  Arr         : TJSONArray;
begin
  AErr := '';
  Result := '';
  Target := nil;
  SaveAll := Assigned(AParams) and AParams.Get('save_all', False);
  if Assigned(AParams) and (AParams.Get('package_name', '') + AParams.Get('lpk_path', '') <> '') then
  begin
    if not TargetPackage(AParams, Target, AErr, False) then Exit;
  end
  else
    SaveAll := True;
  Obj := TJSONObject.Create;
  Mods := TStringList.Create;
  try
    for I := 0 to PackageEditingInterface.GetPackageCount - 1 do
    begin
      Other := PackageEditingInterface.GetPackages(I);
      if Other.Modified then Mods.AddObject(Other.Name, Other);
    end;
    { nothing to write: the target is not modified, or (no target) nothing is }
    if (Mods.Count = 0) or ((Target <> nil) and (Mods.IndexOfObject(Target) < 0)) then
    begin
      if Target <> nil then Obj.Add('package', Target.Name);
      Obj.Add('saved', True);
      Obj.Add('nothing_to_save', True);
      Exit(Obj.AsJSON);
    end;
    if not SaveAll then
      for I := 0 to Mods.Count - 1 do
        if Mods.Objects[I] <> Target then
        begin
          AErr := 'Saving ' + Target.Name + ' would save ' + Mods[I] + ' too (the IDE writes ' +
            'every modified package at once). Pass save_all=true to save them all, or save ' +
            'that one first.';
          Exit;
        end;
    for I := 0 to Mods.Count - 1 do
    begin
      Pkg := TLazPackage(Mods.Objects[I]);
      Why := '';
      if Pkg.IsVirtual then Why := 'has never been saved: use the package editor''s Save as'
      else if Pkg.ReadOnly then Why := 'is read-only (' + Pkg.Filename + ')'
      else if Assigned(GMcpPackageCheck) and not GMcpPackageCheck(Pkg.Name, '', Why) then
        Why := 'is outside the folders the write tools may change: ' + Why
      else
        for J := 0 to Pkg.FileCount - 1 do
        begin
          F  := Pkg.Files[J];
          FN := F.GetFullFilename;
          if (F.FileType = pftVirtualUnit) or (Pos('$(', FN) > 0) then Continue;
          if not FileExists(FN) then begin Why := 'file ' + FN + ' is missing on disk'; Break; end;
          Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(FN);
          if Assigned(Ed) and Ed.Modified then
          begin
            Why := 'file ' + FN + ' has unsaved editor changes (editor_save it first; saving the ' +
              'package would write them too)';
            Break;
          end;
        end;
      if Why <> '' then
      begin
        AErr := 'Not saved: package ' + Pkg.Name + ' ' + Why + '. Nothing was written.';
        Exit;
      end;
    end;
    PackageEditingInterface.DoSaveAllPackages([]);
    Arr := TJSONArray.Create;
    Obj.Add('saved', True);
    for I := 0 to Mods.Count - 1 do
    begin
      Pkg := TLazPackage(Mods.Objects[I]);
      if Pkg.Modified then
      begin
        Obj.Delete('saved');
        Obj.Add('saved', False);
        Obj.Add('still_unsaved', Pkg.Name);
        Break;
      end;
      Arr.Add(Pkg.Name);
    end;
    Obj.Add('packages', Arr);
    Result := Obj.AsJSON;
  finally
    Mods.Free;
    Obj.Free;
  end;
end;

{ Result of a package edit: saved, or why not and what that means. }
function EditResult(APkg: TLazPackage; AWasModified: Boolean; AObj: TJSONObject): string;
var
  Why : string;
begin
  AObj.Add('package', APkg.Name);
  AObj.Add('lpk', APkg.Filename);
  Why := SavePackage(APkg, AWasModified);
  AObj.Add('saved', Why = '');
  if Why <> '' then
  begin
    AObj.Add('not_saved_because', Why);
    AObj.Add('note', 'The change is in the IDE only: the .lpk on disk is unchanged, so ' +
      'package_compile does not see it until the package is saved (package_save).');
  end;
  Result := AObj.AsJSON;
end;

{ Add AAdd (search paths) to the package's unit or include path, as the
  package editor offers to; returns what was added, relative to the package. }
function ExtendPath(APkg: TLazPackage; AAdd: string; AUnits: Boolean): string;
var
  Opt : TParsedCompilerOptString;
begin
  Result := '';
  if AAdd = '' then Exit;
  if AUnits then Opt := pcosUnitPath else Opt := pcosIncludePath;
  AAdd := RemoveSearchPaths(AAdd, APkg.CompilerOptions.ParsedOpts.GetParsedValue(Opt));
  if AAdd = '' then Exit;
  AAdd := CreateRelativeSearchPath(AAdd, APkg.Directory);
  if (AAdd = '') or (AAdd = '.') then Exit;
  if AUnits then
    APkg.CompilerOptions.MergeToUnitPaths(AAdd)
  else
    APkg.CompilerOptions.MergeToIncludePaths(AAdd);
  Result := AAdd;
end;

function PackageAddFile(AParams: TJSONObject; out AErr: string): string;
var
  Pkg      : TLazPackage;
  FN, UName, Added : string;
  FType    : TPkgFileType;
  Code     : TCodeBuffer;
  WasMod   : Boolean;
  UnitPaths, IncPaths : string;
  PF       : TPkgFile;
  Obj      : TJSONObject;
begin
  Result := '';
  if not TargetPackage(AParams, Pkg, AErr) then Exit;
  FN := AParams.Get('file', '');
  if not FilenameIsAbsolute(FN) then
  begin AErr := 'file must be an absolute path'; Exit; end;
  if DirectoryExists(FN) then
  begin AErr := FN + ' is a directory'; Exit; end;
  if not FileExists(FN) then
  begin AErr := 'No such file: ' + FN; Exit; end;
  if Assigned(Pkg.FindPkgFile(FN, True, False)) then
  begin AErr := FN + ' is already in ' + Pkg.Name; Exit; end;
  FType := FileNameToPkgFileType(FN);
  if FType = pftUnit then
  begin
    Code := McpLoadCode(FN, True);
    UName := '';
    if Assigned(Code) then
      UName := CodeToolBoss.GetSourceName(Code, False);
    if UName = '' then
    begin AErr := 'No unit name found in ' + FN; Exit; end;
  end;
  WasMod    := Pkg.Modified;
  UnitPaths := '';
  IncPaths  := '';
  if not Pkg.AddFileByName(FN, UnitPaths, IncPaths) then
  begin AErr := 'The IDE did not add ' + FN; Exit; end;
  Obj := TJSONObject.Create;
  try
    PF := Pkg.FindPkgFile(FN, True, False);
    Obj.Add('file', FN);
    Obj.Add('type', PkgFileTypeIdents[FType]);
    if Assigned(PF) and (PF.Unit_Name <> '') then
      Obj.Add('unit', PF.Unit_Name);
    if Assigned(PF) and (pffHasRegisterProc in PF.Flags) then
      Obj.Add('has_register_proc', True);
    { AddFileByName collects every non-unit file's directory as an include
      path; only include files need one }
    if FType = pftUnit then
      Added := ExtendPath(Pkg, UnitPaths, True)
    else if FType = pftInclude then
      Added := ExtendPath(Pkg, IncPaths, False)
    else
      Added := '';
    if Added <> '' then
      if FType = pftUnit then
        Obj.Add('unit_path_added', Added)
      else
        Obj.Add('include_path_added', Added);
    Result := EditResult(Pkg, WasMod, Obj);
  finally
    Obj.Free;
  end;
end;

function PackageRemoveFile(AParams: TJSONObject; out AErr: string): string;
var
  Pkg    : TLazPackage;
  PF     : TPkgFile;
  FN     : string;
  WasMod : Boolean;
  Obj    : TJSONObject;
begin
  Result := '';
  if not TargetPackage(AParams, Pkg, AErr) then Exit;
  FN := AParams.Get('file', '');
  PF := Pkg.FindPkgFile(FN, True, False);
  if PF = nil then
  begin AErr := FN + ' is not in ' + Pkg.Name; Exit; end;
  WasMod := Pkg.Modified;
  Pkg.RemoveFile(PF);   { the file stays on disk }
  Obj := TJSONObject.Create;
  try
    Obj.Add('removed', FN);
    Result := EditResult(Pkg, WasMod, Obj);
  finally
    Obj.Free;
  end;
end;

{ True if the package is compiled into the IDE: installed, or required by an
  installed package (jcfbase by jcfidelazarus), which the IDE does not mark
  as installed.  Passing the package manager itself as the owner lists all of
  them. }
function PackageIsInIDE(const AName: string): Boolean;
var
  Ptr : Pointer;
  List : TFPList;
begin
  Result := Assigned(PackageEditingInterface.IsPackageInstalled(AName));
  if Result then Exit;
  PackageEditingInterface.GetRequiredPackages(PackageEditingInterface, List);
  if List = nil then Exit;
  try
    for Ptr in List do
      if (TObject(Ptr) is TIDEPackage) and SameText(TIDEPackage(Ptr).Name, AName) then
        Exit(True);
  finally
    List.Free;
  end;
end;

function PackageAddDependency(AParams: TJSONObject; out AErr: string): string;
var
  Pkg      : TLazPackage;
  Dep, Old : TPkgDependency;
  ReqName, S : string;
  WasMod   : Boolean;
  Obj      : TJSONObject;
begin
  Result := '';
  if not TargetPackage(AParams, Pkg, AErr) then Exit;
  ReqName := Trim(AParams.Get('required_package', ''));
  if not IsValidPkgName(ReqName) then
  begin AErr := 'Not a package name: ' + ReqName; Exit; end;
  if SameText(ReqName, Pkg.Name) then
  begin AErr := 'A package can''t require itself'; Exit; end;
  Old := Pkg.FindDependencyByName(ReqName);
  if Assigned(Old) then
  begin
    AErr := Pkg.Name + ' already requires ' + ReqName + '; remove it first to change ' +
            'its version limits';
    Exit;
  end;
  { ADR-013: a package in the IDE that starts requiring one that isn't would
    bring it in at the next rebuild, past the user's consent }
  if PackageIsInIDE(Pkg.Name) and not PackageIsInIDE(ReqName) then
  begin
    AErr := Pkg.Name + ' is installed in the IDE and ' + ReqName + ' is not: the next ' +
            'rebuild would bring ' + ReqName + ' into the IDE. Install it first ' +
            '(package_install, which needs the user''s consent).';
    Exit;
  end;
  Dep := TPkgDependency.Create;
  Dep.DependencyType := pdtLazarus;
  Dep.PackageName    := ReqName;
  S := Trim(AParams.Get('min_version', ''));
  if S <> '' then
  begin
    if not Dep.MinVersion.ReadString(S) then
    begin Dep.Free; AErr := 'Bad min_version: ' + S; Exit; end;
    Dep.Flags := Dep.Flags + [pdfMinVersion];
  end;
  S := Trim(AParams.Get('max_version', ''));
  if S <> '' then
  begin
    if not Dep.MaxVersion.ReadString(S) then
    begin Dep.Free; AErr := 'Bad max_version: ' + S; Exit; end;
    Dep.Flags := Dep.Flags + [pdfMaxVersion];
  end;
  WasMod := Pkg.Modified;
  PackageGraph.AddDependencyToPackage(Pkg, Dep);
  { roll back what doesn't resolve, or would close a cycle }
  if Dep.RequiredPackage = nil then
    AErr := ReqName + ' could not be resolved (' + DepStatus(Dep) + ')'
  else if Assigned(PackageGraph.FindDependencyRecursively(
            Dep.RequiredPackage.FirstRequiredDependency, Pkg.Name)) then
    AErr := ReqName + ' requires ' + Pkg.Name + ' already: that would be a cycle'
  else if not Dep.IsCompatible(Dep.RequiredPackage.Version) then
    AErr := ReqName + ' ' + Dep.RequiredPackage.Version.AsString +
            ' is outside the version limits';
  if AErr <> '' then
  begin
    PackageGraph.RemoveDependencyFromPackage(Pkg, Dep, False);
    if not WasMod then Pkg.Modified := False;
    Exit;
  end;
  Obj := TJSONObject.Create;
  try
    Obj.Add('added', DepJSON(Dep));
    Result := EditResult(Pkg, WasMod, Obj);
  finally
    Obj.Free;
  end;
end;

function PackageRemoveDependency(AParams: TJSONObject; out AErr: string): string;
var
  Pkg     : TLazPackage;
  Dep     : TPkgDependency;
  ReqName : string;
  WasMod  : Boolean;
  Obj     : TJSONObject;
begin
  Result := '';
  if not TargetPackage(AParams, Pkg, AErr) then Exit;
  ReqName := Trim(AParams.Get('required_package', ''));
  Dep := Pkg.FindDependencyByName(ReqName);
  if Dep = nil then
  begin AErr := Pkg.Name + ' does not require ' + ReqName; Exit; end;
  WasMod := Pkg.Modified;
  PackageGraph.RemoveDependencyFromPackage(Pkg, Dep, True);
  Obj := TJSONObject.Create;
  try
    Obj.Add('removed', ReqName);
    Result := EditResult(Pkg, WasMod, Obj);
  finally
    Obj.Free;
  end;
end;

{ package_set_info: version, description, author and license, as on the
  package options' Package page.  Only the given fields change. }
function PackageSetInfo(AParams: TJSONObject; out AErr: string): string;
var
  Pkg      : TLazPackage;
  NewVer   : TPkgVersion;
  S        : string;
  WasMod   : Boolean;
  Obj, Old, New : TJSONObject;
begin
  Result := '';
  if not TargetPackage(AParams, Pkg, AErr) then Exit;
  if (AParams.IndexOfName('version') < 0) and (AParams.IndexOfName('description') < 0) and
     (AParams.IndexOfName('author') < 0) and (AParams.IndexOfName('license') < 0) then
  begin
    AErr := 'Give at least one of version, description, author, license'; Exit;
  end;
  NewVer := TPkgVersion.Create;
  Obj    := TJSONObject.Create;
  try
    S := Trim(AParams.Get('version', ''));
    if AParams.IndexOfName('version') >= 0 then
      if not NewVer.ReadString(S) then
      begin
        AErr := 'Bad version (major.minor[.release[.build]]): ' + S; Exit;
      end;
    Old := TJSONObject.Create;
    Obj.Add('old', Old);
    New := TJSONObject.Create;
    Obj.Add('new', New);
    WasMod := Pkg.Modified;
    if AParams.IndexOfName('version') >= 0 then
    begin
      Old.Add('version', Pkg.Version.AsString);
      Pkg.Version.Assign(NewVer);
      New.Add('version', Pkg.Version.AsString);
    end;
    if AParams.IndexOfName('description') >= 0 then
    begin
      Old.Add('description', Pkg.Description);
      Pkg.Description := AParams.Get('description', '');
      New.Add('description', Pkg.Description);
    end;
    if AParams.IndexOfName('author') >= 0 then
    begin
      Old.Add('author', Pkg.Author);
      Pkg.Author := AParams.Get('author', '');
      New.Add('author', Pkg.Author);
    end;
    if AParams.IndexOfName('license') >= 0 then
    begin
      Old.Add('license', Pkg.License);
      Pkg.License := AParams.Get('license', '');
      New.Add('license', Pkg.License);
    end;
    if Old.AsJSON = New.AsJSON then
    begin
      Obj.Add('package', Pkg.Name);
      Obj.Add('unchanged', True);
      Result := Obj.AsJSON;
    end
    else
      Result := EditResult(Pkg, WasMod, Obj);
  finally
    Obj.Free;
    NewVer.Free;
  end;
end;

{ ── Dispatch ─────────────────────────────────────────────────────────────── }

function DispatchPackagesTool(const Name: string; var Ctx: TMcpToolCall): Boolean;
var
  Ptr : Pointer;
  PkgName  : string;
  PkgErr   : string;
  FPList   : TFPList;
  RefArr   : TJSONArray;
  Obj      : TJSONObject;
  Proj     : TLazProject;
begin
  Result := False;

  case Name of
    'package_add_file', 'package_remove_file', 'package_add_dependency', 'package_remove_dependency', 'package_set_info', 'package_save':
    begin
      Result := True;
      if not Assigned(Ctx.Params) and (Name <> 'package_save') then
      begin
        Ctx.Error := True; Ctx.Result := 'package_name or lpk_path required'; Exit;
      end;
      case Name of
        'package_save':              Ctx.Result := PackageSave(Ctx.Params, PkgName);
        'package_add_file':          Ctx.Result := PackageAddFile(Ctx.Params, PkgName);
        'package_remove_file':       Ctx.Result := PackageRemoveFile(Ctx.Params, PkgName);
        'package_add_dependency':    Ctx.Result := PackageAddDependency(Ctx.Params, PkgName);
        'package_set_info':          Ctx.Result := PackageSetInfo(Ctx.Params, PkgName);
      else
        Ctx.Result := PackageRemoveDependency(Ctx.Params, PkgName);
      end;
      if PkgName <> '' then
      begin
        Ctx.Error := True; Ctx.Result := PkgName;
      end;
      Exit;
    end;

    'package_search_online':
    begin
      Result := True;
      Ctx.Result := SearchOnlineCatalog(Ctx.Params, PkgName);
      if PkgName <> '' then
      begin
        Ctx.Error := True; Ctx.Result := PkgName;
      end;
      Exit;
    end;

    'project_list_packages':
    begin
      Result := True;
      if not (LazarusIDE.ActiveProject is TProject) then
      begin
        Ctx.Error := True; Ctx.Result := 'No active project'; Exit;
      end;
      Ctx.Result := ProjectPackagesJSON(TProject(LazarusIDE.ActiveProject),
                      Assigned(Ctx.Params) and Ctx.Params.Get('recursive', False));
    end;

    'package_find_unit':
    begin
      Result := True;
      if not Assigned(Ctx.Params) or (Trim(Ctx.Params.Get('unit_name', '')) = '') then
      begin
        Ctx.Error := True; Ctx.Result := 'unit_name required'; Exit;
      end;
      Ctx.Result := FindUnitJSON(Trim(Ctx.Params.Get('unit_name', '')));
    end;

    'project_add_package':
    begin
      Result := True;
      if not SelectedPackageName(Ctx.Params, True, PkgName, PkgErr) then
      begin
        Ctx.Error := True; Ctx.Result := PkgErr; Exit;
      end;
      Proj := LazarusIDE.ActiveProject;
      if not Assigned(Proj) then
      begin
        Ctx.Error := True; Ctx.Result := 'No active project'; Exit;
      end;
      { a name the IDE can't resolve leaves a "Broken dependency" dialog that fails
        every later build silently }
      if (PackageGraph.FindPackageWithName(PkgName, nil) = nil) and
         (LazPackageLinks.FindLinkWithPkgName(PkgName) = nil) then
      begin
        Ctx.Error := True;
        Ctx.Result := 'Package not found: ' + PkgName + '. It is neither loaded nor known ' +
          'to the IDE''s package links (package_download and open its .lpk first)';
        Exit;
      end;
      Proj.AddPackageDependency(PkgName);
      LazarusIDE.DoSaveProject([]);
      PackageEditingInterface.GetRequiredPackages(Proj, FPList, [pirNotRecursive]);
      Obj := TJSONObject.Create;
      try
        RefArr := TJSONArray.Create;
        if Assigned(FPList) then
        begin
          for Ptr in FPList do
            RefArr.Add(TIDEPackage(Ptr).Name);
          FreeAndNil(FPList);
        end;
        Obj.Add('package_name',        PkgName);
        Obj.Add('project_dependencies', RefArr);
        Ctx.Result := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    end;

    'project_remove_package':
    begin
      Result := True;
      if not SelectedPackageName(Ctx.Params, False, PkgName, PkgErr) then
      begin
        Ctx.Error := True; Ctx.Result := PkgErr; Exit;
      end;
      Proj := LazarusIDE.ActiveProject;
      Proj := LazarusIDE.ActiveProject;
      if not Assigned(Proj) then
      begin
        Ctx.Error := True; Ctx.Result := 'No active project'; Exit;
      end;
      if not Proj.RemovePackageDependency(PkgName) then
      begin
        Ctx.Error := True;
        Ctx.Result := 'Package not found in project: ' + PkgName;
        Exit;
      end;
      LazarusIDE.DoSaveProject([]);
      PackageEditingInterface.GetRequiredPackages(Proj, FPList, [pirNotRecursive]);
      Obj := TJSONObject.Create;
      try
        RefArr := TJSONArray.Create;
        if Assigned(FPList) then
        begin
          for Ptr in FPList do
            RefArr.Add(TIDEPackage(Ptr).Name);
          FreeAndNil(FPList);
        end;
        Obj.Add('package_name',        PkgName);
        Obj.Add('project_dependencies', RefArr);
        Ctx.Result := Obj.AsJSON;
      finally
        Obj.Free;
      end;
    end;
  end;

  { package_install, package_uninstall: the rebuild in McpToolsBuild }
end;

{ ── Schema registration ──────────────────────────────────────────────────── }

procedure RegisterPackagesSchemas(Tools: TJSONArray);
begin
  Tools.Add(MakeTool('package_search_online',
    'Search the Online Package Manager''s catalog of community packages (local ' +
    'cache, no network). Finds packages, not component classes: for installed ' +
    'classes use form_search_palette. A result''s downloaded_lpk can go to package_install.',
    SCHEMA_SEARCH_ONLINE, MCP_ANN_RO));
  Tools.Add(MakeTool('package_download',
    'Download a package from the Online Package Manager repository into OPM''s ' +
    'packages folder: MD5 checked against the catalog, archive checked before ' +
    'extracting. Installs nothing; returns the .lpk files for package_install.',
    SCHEMA_DOWNLOAD, MCP_ANN_OPEN));
  Tools.Add(MakeTool('project_list_packages',
    'The active project''s required packages as in Project Inspector: version ' +
    'limits, the resolved .lpk, and status (ok, not_found, ...). recursive=true adds the ' +
    'whole dependency graph in compile order.',
    SCHEMA_LIST_PROJECT_PACKAGES, MCP_ANN_RO));
  Tools.Add(MakeTool('package_find_unit',
    'Which loaded packages contain a unit, and whether the active project depends on ' +
    'them. Use for "Can''t find unit" errors.',
    SCHEMA_FIND_UNIT, MCP_ANN_RO));
  Tools.Add(MakeTool('package_add_file',
    'Add a file to a package (.lpk), as the package editor''s Add does: unit name ' +
    'and Register procedure are detected; the unit or include path is extended if ' +
    'needed. Saves the .lpk when nothing else is unsaved.',
    SCHEMA_PKG_FILE, MCP_ANN_WRITE_IDEM));
  Tools.Add(MakeTool('package_remove_file',
    'Remove a file from a package (.lpk); the file stays on disk.',
    SCHEMA_PKG_FILE, MCP_ANN_DEST_IDEM));
  Tools.Add(MakeTool('package_add_dependency',
    'Make a PACKAGE (.lpk) require another one, optionally with version limits; for the ' +
    'open project use project_add_package. Refused for ' +
    'cycles, unknown packages, and when it would bring a new package into the IDE.',
    SCHEMA_PKG_ADD_DEP, MCP_ANN_WRITE_IDEM));
  Tools.Add(MakeTool('package_remove_dependency',
    'Remove a requirement from a package (.lpk).',
    SCHEMA_PKG_REMOVE_DEP, MCP_ANN_DEST_IDEM));
  Tools.Add(MakeTool('package_save',
    'Write unsaved packages (.lpk) to disk: the named one, or every modified one. The ' +
    'package tools save their own change when nothing else is unsaved; use this when they ' +
    'answered saved:false, or before ide_rebuild. Refused, naming the cause and writing ' +
    'nothing, when the IDE would have to ask: a package never saved, read-only, a file ' +
    'missing on disk, an editor of its files with unsaved text.',
    SCHEMA_PKG_SAVE, MCP_ANN_WRITE_IDEM));
  Tools.Add(MakeTool('package_set_info',
    'Set a package''s version, description, author and/or license, as on the ' +
    'package options'' Package page; only the given fields change. Returns old and ' +
    'new values. Saves the .lpk when nothing else is unsaved.',
    SCHEMA_PKG_SET_INFO, MCP_ANN_WRITE_IDEM));
  Tools.Add(MakeTool('project_add_package',
    'Add a package as a dependency to the active PROJECT (.lpi); to make a package ' +
    'require another one use package_add_dependency. ' +
    'The package must already be loaded in the IDE. No rebuild required. ' +
    'Returns the updated list of project package dependencies.',
    SCHEMA_ADD_PACKAGE_TO_PROJECT, MCP_ANN_WRITE_IDEM));
  Tools.Add(MakeTool('project_remove_package',
    'Remove a package dependency from the active project (.lpi). ' +
    'No rebuild required. Returns the updated list of project package dependencies.',
    SCHEMA_REMOVE_PACKAGE_FROM_PROJECT, MCP_ANN_DEST_IDEM));
  Tools.Add(MakeTool('package_install',
    'Install a package into the IDE (design-time / palette); the IDE rebuilds and ' +
    'restarts. A package not installed yet needs the user''s consent. Run ' +
    'package_compile first.',
    SCHEMA_INSTALL_PACKAGE, MCP_ANN_DEST));
  Tools.Add(MakeTool('package_uninstall',
    'Uninstall a package from the Lazarus IDE. ' +
    'Triggers an IDE rebuild and restart. Returns {"status":"rebuilding","poll_command":"..."}.',
    SCHEMA_UNINSTALL_PACKAGE, MCP_ANN_DEST));
end;

initialization
  RegisterMcpGroup(@DispatchPackagesTool);
  RegisterMcpBlockingGroup(@DispatchPackagesBlockingTool);
  RegisterMcpSchemas(@RegisterPackagesSchemas);

end.
