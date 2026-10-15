{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolsPackages;

{ Package management tools: package_get_info, package_find_unit, package_search_online,
  package_add_file, package_remove_file, package_add_dependency,
  package_remove_dependency, package_set_info, project_list_packages, project_add_package,
  project_remove_package, package_install, package_uninstall. }

{$mode objfpc}{$H+}

interface

implementation

uses
  Classes, SysUtils, Contnrs,
  LazIDEIntf, SrcEditorIntf, ProjectIntf, PackageIntf,
  LazFileUtils, FileUtil,
  PackageDependencyIntf,
  PackageDefs, Project,   { IdePackager/IdeProject, linked via IdeDebugger: TPkgDependency }
  PackageSystem,          { PackageGraph }
  ParsedCompilerOpts, SearchPathProcs,  { IdeConfig: unit/include paths }
  CodeToolManager, CodeCache,
  Controls,               { mrOk }
  Laz2_XMLCfg, fphttpclient, opensslsockets, md5, zipper,
  fpjson,
  McpToolContext, McpIdeState, McpConsent, McpToolsCodeTools;

{ ── Schema constants ─────────────────────────────────────────────────────── }

const
  SCHEMA_GET_PACKAGE_INFO_EX =
    '{"type":"object","properties":{"package_name":{"type":"string",' +
    '"description":"Package name as registered in the IDE (e.g. LazMcpAssistant)"},' +
    '"files":{"type":"boolean","description":"Include the package''s files (default false)"}},' +
    '"required":["package_name"]}';

  SCHEMA_LIST_PROJECT_PACKAGES =
    '{"type":"object","properties":{"recursive":{"type":"boolean",' +
    '"description":"Also list every package the project needs indirectly, in compile ' +
    'order, each with its own requirements (default false)"}}}';

  SCHEMA_FIND_UNIT =
    '{"type":"object","properties":{"unit_name":{"type":"string",' +
    '"description":"Unit name, e.g. SynEdit or fpjson"}},"required":["unit_name"]}';

  { package_add_file etc.: the package, by name or by .lpk file }
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
    '"max_version":{"type":"string"}},' +
    '"required":["required_package"]}';

  SCHEMA_PKG_SET_INFO =
    '{"type":"object","properties":{' + PKG_TARGET_PROPS + ',' +
    '"version":{"type":"string","description":"major.minor[.release[.build]], e.g. 1.0"},' +
    '"description":{"type":"string"},' +
    '"author":{"type":"string"},' +
    '"license":{"type":"string"}}}';

  SCHEMA_PKG_REMOVE_DEP =
    '{"type":"object","properties":{' + PKG_TARGET_PROPS + ',' +
    '"required_package":{"type":"string"}},' +
    '"required":["required_package"]}';

  SCHEMA_ADD_PACKAGE_TO_PROJECT =
    '{"type":"object","properties":{"package_name":{"type":"string",' +
    '"description":"Package name to add as a dependency (e.g. LazUtils)"}},' +
    '"required":["package_name"]}';

  SCHEMA_REMOVE_PACKAGE_FROM_PROJECT =
    '{"type":"object","properties":{"package_name":{"type":"string",' +
    '"description":"Package name to remove from project dependencies"}},' +
    '"required":["package_name"]}';

  SCHEMA_INSTALL_PACKAGE =
    '{"type":"object","properties":{"lpk_path":{"type":"string",' +
    '"description":"Absolute path to the .lpk package file to install into the IDE"}},' +
    '"required":["lpk_path"]}';

  SCHEMA_UNINSTALL_PACKAGE =
    '{"type":"object","properties":{"package_name":{"type":"string",' +
    '"description":"Package name to uninstall from the IDE"}},' +
    '"required":["package_name"]}';

  SCHEMA_SEARCH_ONLINE =
    '{"type":"object","properties":{' +
    '"query":{"type":"string","description":"Words that must all occur (case-insensitive) in a package''s name, ' +
      'description, category or .lpk names/descriptions, e.g. \"chart\", \"rich memo\", \"zip\". Empty lists everything."},' +
    '"category":{"type":"string","description":"Only packages whose category contains this text, e.g. Graphics, ' +
      'Networking, DataControls, LazIDEPlugins"},' +
    '"max_results":{"type":"integer","description":"Default 20"}}}';

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
  FileName, Text, Hay, Category : string;
  Words     : TStringArray;
  Root      : TJSONData;
  Cat       : TJSONObject;
  Data      : TJSONObject;
  Files     : TJSONArray;
  F         : TJSONObject;
  Res, FArr : TJSONArray;
  Obj, FObj, PObj : TJSONObject;
  I, J, W, Matches, MaxRes : Integer;
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
    MaxRes   := AParams.Get('max_results', 20);
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
        for J := 0 to Files.Count - 1 do
          if Files[J] is TJSONObject then
            Hay := Hay + ' ' + TJSONObject(Files[J]).Get('Name', '') + ' ' +
                   TJSONObject(Files[J]).Get('Description', '');
      Hay := LowerCase(Hay);
      Ok := True;
      for W := 0 to High(Words) do
        if Pos(Words[W], Hay) = 0 then
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
        for J := 0 to Files.Count - 1 do
        begin
          if not (Files[J] is TJSONObject) then Continue;
          F := TJSONObject(Files[J]);
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
  FileName, Text, Rel, Lpk : string;
  SL     : TStringList;
  Root   : TJSONData;
  Cat, Data, F : TJSONObject;
  Files  : TJSONArray;
  I, J   : Integer;
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
      for J := 0 to Files.Count - 1 do
        if Files[J] is TJSONObject then
        begin
          F := TJSONObject(Files[J]);
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
      for J := 0 to Lpks.Count - 1 do
      begin
        Pkg := PackageEditingInterface.FindPackageWithName(ExtractFileNameOnly(Lpks[J]));
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

{ Fetch AUrl into AStream; HTTPS first, plain HTTP only when OpenSSL is not
  available (the IDE on Windows often has no OpenSSL DLLs). }
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
  AUrl := 'http://' + Copy(AHttpsUrl, Length('https://') + 1, MaxInt);
  ATransport := 'http';
  Result := Get(AUrl, AErr);
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
      if Job.Transport = 'http' then
        Obj.Add('transport_note', 'HTTPS was not available (no OpenSSL in the IDE); the ' +
          'archive came unencrypted and was checked against the catalog''s MD5 only');
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
  Obj, PObj : TJSONObject;
  Arr       : TJSONArray;
  Dep       : TPkgDependency;
  List      : TFPList;
  Pkg       : TLazPackage;
  I         : Integer;
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
        for I := 0 to List.Count - 1 do
        begin
          if not (TObject(List[I]) is TLazPackage) then Continue;
          Pkg  := TLazPackage(List[I]);
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
function PackageInfoJSON(const PkgName: string; WithFiles: Boolean): string;
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
  out AErr: string): Boolean;
var
  Name, Lpk : string;
  Other     : TLazPackage;
begin
  Result := False;
  APkg   := nil;
  AErr   := '';
  Name := Trim(AParams.Get('package_name', ''));
  Lpk  := Trim(AParams.Get('lpk_path', ''));
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
      AErr := 'Package not loaded: ' + Name + '. Give its lpk_path instead.';
      Exit;
    end;
  end
  else
  begin
    AErr := 'package_name or lpk_path required'; Exit;
  end;
  if APkg.IsVirtual then
  begin AErr := APkg.Name + ' has not been saved yet'; Exit; end;
  if APkg.ReadOnly then
  begin AErr := APkg.Name + ' is read-only (' + APkg.Filename + ')'; Exit; end;
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
      'package_compile does not see it until the package is saved in the package editor.');
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
  List : TFPList;
  I    : Integer;
begin
  Result := Assigned(PackageEditingInterface.IsPackageInstalled(AName));
  if Result then Exit;
  PackageEditingInterface.GetRequiredPackages(PackageEditingInterface, List);
  if List = nil then Exit;
  try
    for I := 0 to List.Count - 1 do
      if (TObject(List[I]) is TIDEPackage) and SameText(TIDEPackage(List[I]).Name, AName) then
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
  PkgName  : string;
  LpkPath  : string;
  IDEPkg   : TIDEPackage;
  FPList   : TFPList;
  PkgList  : TObjectList;
  PkgID    : TLazPackageID;
  PollCmd  : string;
  RefArr   : TJSONArray;
  Obj      : TJSONObject;
  Proj     : TLazProject;
  I        : Integer;
begin
  Result := False;

  if (Name = 'package_add_file') or (Name = 'package_remove_file') or
     (Name = 'package_add_dependency') or (Name = 'package_remove_dependency') or
     (Name = 'package_set_info') then
  begin
    Result := True;
    if not Assigned(Ctx.Params) then
    begin
      Ctx.Error := True; Ctx.Result := 'package_name or lpk_path required'; Exit;
    end;
    if Name = 'package_add_file' then
      Ctx.Result := PackageAddFile(Ctx.Params, PkgName)
    else if Name = 'package_remove_file' then
      Ctx.Result := PackageRemoveFile(Ctx.Params, PkgName)
    else if Name = 'package_add_dependency' then
      Ctx.Result := PackageAddDependency(Ctx.Params, PkgName)
    else if Name = 'package_set_info' then
      Ctx.Result := PackageSetInfo(Ctx.Params, PkgName)
    else
      Ctx.Result := PackageRemoveDependency(Ctx.Params, PkgName);
    if PkgName <> '' then
    begin
      Ctx.Error := True; Ctx.Result := PkgName;
    end;
    Exit;
  end;

  if Name = 'package_search_online' then
  begin
    Result := True;
    Ctx.Result := SearchOnlineCatalog(Ctx.Params, PkgName);
    if PkgName <> '' then
    begin
      Ctx.Error := True; Ctx.Result := PkgName;
    end;
    Exit;
  end;

  if Name = 'package_get_info' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('package_name', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'package_name required'; Exit;
    end;
    Ctx.Result := PackageInfoJSON(Ctx.Params.Get('package_name', ''),
                                  Ctx.Params.Get('files', False));
  end

  else if Name = 'project_list_packages' then
  begin
    Result := True;
    if not (LazarusIDE.ActiveProject is TProject) then
    begin
      Ctx.Error := True; Ctx.Result := 'No active project'; Exit;
    end;
    Ctx.Result := ProjectPackagesJSON(TProject(LazarusIDE.ActiveProject),
                    Assigned(Ctx.Params) and Ctx.Params.Get('recursive', False));
  end

  else if Name = 'package_find_unit' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Trim(Ctx.Params.Get('unit_name', '')) = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'unit_name required'; Exit;
    end;
    Ctx.Result := FindUnitJSON(Trim(Ctx.Params.Get('unit_name', '')));
  end

  else if Name = 'project_add_package' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('package_name', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'package_name required'; Exit;
    end;
    PkgName := Ctx.Params.Get('package_name', '');
    Proj := LazarusIDE.ActiveProject;
    if not Assigned(Proj) then
    begin
      Ctx.Error := True; Ctx.Result := 'No active project'; Exit;
    end;
    Proj.AddPackageDependency(PkgName);
    LazarusIDE.DoSaveProject([]);
    PackageEditingInterface.GetRequiredPackages(Proj, FPList, [pirNotRecursive]);
    Obj := TJSONObject.Create;
    try
      RefArr := TJSONArray.Create;
      if Assigned(FPList) then
      begin
        for I := 0 to FPList.Count - 1 do
          RefArr.Add(TIDEPackage(FPList[I]).Name);
        FreeAndNil(FPList);
      end;
      Obj.Add('package_name',        PkgName);
      Obj.Add('project_dependencies', RefArr);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'project_remove_package' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('package_name', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'package_name required'; Exit;
    end;
    PkgName := Ctx.Params.Get('package_name', '');
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
        for I := 0 to FPList.Count - 1 do
          RefArr.Add(TIDEPackage(FPList[I]).Name);
        FreeAndNil(FPList);
      end;
      Obj.Add('package_name',        PkgName);
      Obj.Add('project_dependencies', RefArr);
      Ctx.Result := Obj.AsJSON;
    finally
      Obj.Free;
    end;
  end

  else if Name = 'package_install' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('lpk_path', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'lpk_path required'; Exit;
    end;
    LpkPath := Ctx.Params.Get('lpk_path', '');
    { new code into the IDE needs the user's consent (ADR-013) }
    if not McpConfirmPackageInstall(LpkPath, 'package_install', PkgName) then
    begin
      Ctx.Error := True; Ctx.Result := PkgName; Exit;
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('status',  'rebuilding');
      Obj.Add('message', 'IDE is rebuilding and will restart. Poll with the ' +
                         'command in poll_command until it succeeds.');
      PollCmd := McpPollCommand;
      if PollCmd <> '' then
        Obj.Add('poll_command', PollCmd);
      Ctx.Result          := Obj.AsJSON;
    finally
      Obj.Free;
    end;
    while SourceEditorManagerIntf.UniqueSourceEditorCount > 0 do
      LazarusIDE.DoCloseEditorFile(
        SourceEditorManagerIntf.UniqueSourceEditors[0], [cfQuiet]);
    if Assigned(Ctx.StopServer) then Ctx.StopServer();
    PkgList := TObjectList.Create(True);
    try
      PackageEditingInterface.DoOpenPackageFile(LpkPath, [pofDoNotOpenEditor], False);
      IDEPkg := PackageEditingInterface.FindPackageWithName(
                  ExtractFileNameOnly(LpkPath));
      if Assigned(IDEPkg) then
      begin
        PkgID := TLazPackageID.Create;
        PkgID.AssignID(IDEPkg);
        PkgList.Add(PkgID);
      end;
      PackageEditingInterface.InstallPackages(
        PkgList, [piiifRebuildIDE, piiifSkipChecks, piiifQuiet]);
    finally
      PkgList.Free;
    end;
  end

  else if Name = 'package_uninstall' then
  begin
    Result := True;
    if not Assigned(Ctx.Params) or (Ctx.Params.Get('package_name', '') = '') then
    begin
      Ctx.Error := True; Ctx.Result := 'package_name required'; Exit;
    end;
    PkgName := Ctx.Params.Get('package_name', '');
    IDEPkg := PackageEditingInterface.FindPackageWithName(PkgName);
    if not Assigned(IDEPkg) then
    begin
      Ctx.Error := True; Ctx.Result := 'Package not found: ' + PkgName; Exit;
    end;
    Obj := TJSONObject.Create;
    try
      Obj.Add('status',  'rebuilding');
      Obj.Add('message', 'IDE is rebuilding and will restart. Poll with the ' +
                         'command in poll_command until it succeeds.');
      PollCmd := McpPollCommand;
      if PollCmd <> '' then
        Obj.Add('poll_command', PollCmd);
      Ctx.Result          := Obj.AsJSON;
    finally
      Obj.Free;
    end;
    while SourceEditorManagerIntf.UniqueSourceEditorCount > 0 do
      LazarusIDE.DoCloseEditorFile(
        SourceEditorManagerIntf.UniqueSourceEditors[0], [cfQuiet]);
    if Assigned(Ctx.StopServer) then Ctx.StopServer();
    PackageEditingInterface.UninstallPackage(IDEPkg, False);
    PkgList := TObjectList.Create(True);
    try
      PackageEditingInterface.InstallPackages(
        PkgList, [piiifRebuildIDE, piiifSkipChecks, piiifQuiet]);
    finally
      PkgList.Free;
    end;
  end;
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
  Tools.Add(MakeTool('package_get_info',
    'A package''s load and install status; for a loaded package also its version, ' +
    'requirements (with status: not_found etc.), the packages using it, and optionally its files.',
    SCHEMA_GET_PACKAGE_INFO_EX, MCP_ANN_RO));
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
    SCHEMA_PKG_FILE, MCP_ANN_WRITE));
  Tools.Add(MakeTool('package_remove_file',
    'Remove a file from a package (.lpk); the file stays on disk.',
    SCHEMA_PKG_FILE, MCP_ANN_WRITE));
  Tools.Add(MakeTool('package_add_dependency',
    'Make a package require another one, optionally with version limits. Refused for ' +
    'cycles, unknown packages, and when it would bring a new package into the IDE.',
    SCHEMA_PKG_ADD_DEP, MCP_ANN_WRITE));
  Tools.Add(MakeTool('package_remove_dependency',
    'Remove a requirement from a package (.lpk).',
    SCHEMA_PKG_REMOVE_DEP, MCP_ANN_WRITE));
  Tools.Add(MakeTool('package_set_info',
    'Set a package''s version, description, author and/or license, as on the ' +
    'package options'' Package page; only the given fields change. Returns old and ' +
    'new values. Saves the .lpk when nothing else is unsaved.',
    SCHEMA_PKG_SET_INFO, MCP_ANN_WRITE));
  Tools.Add(MakeTool('project_add_package',
    'Add a package as a dependency to the active project (.lpi). ' +
    'The package must already be loaded in the IDE. No rebuild required. ' +
    'Returns the updated list of project package dependencies.',
    SCHEMA_ADD_PACKAGE_TO_PROJECT, MCP_ANN_WRITE));
  Tools.Add(MakeTool('project_remove_package',
    'Remove a package dependency from the active project (.lpi). ' +
    'No rebuild required. Returns the updated list of project package dependencies.',
    SCHEMA_REMOVE_PACKAGE_FROM_PROJECT, MCP_ANN_WRITE));
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
