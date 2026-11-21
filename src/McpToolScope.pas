{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpToolScope;

{ Which argument of which tool is a path, and what the tool does with it (ADR-034).

  Written by hand, from reading every tool.  The write check (McpWriteAllowed) and limited mode
  work from it, and a test walks the live tools/list against it: a tool that changes something,
  or takes a path, and is in no table fails the test, so a new tool cannot be added without a
  decision about its scope.

  RTL only, so the test program links it. }

{$mode objfpc}{$H+}

interface

type
  TMcpPathUse = (
    puRead,          { the tool reads this file or folder }
    puWrite,         { changes this file; McpWriteAllowed asks before the tool runs }
    puWriteInTool,   { changes this file; the tool asks itself }
    puFolder,        { changes things in this folder; McpWriteAllowed asks }
    puFolderInTool,  { the same, the tool asks itself }
    puNewPlace);     { a folder or project that may not exist yet, or that becomes a root }

  TMcpToolPath = record
    Tool : string;
    Arg  : string;
    Use  : TMcpPathUse;
  end;

function McpToolPathCount: Integer;
function McpToolPathAt(AIndex: Integer): TMcpToolPath;

{ The entries of one tool (for the checks): its paths, in table order. }
function McpToolPathFor(const ATool: string; AIndex: Integer; out APath: TMcpToolPath): Boolean;

{ A tool that is not read-only but names no path, with why that is fine:
    c  changes the open project's own files        d  changes a buffer that is already open
    f  builds or runs code (not limited, ADR-034)   g  writes no file
    p  names packages, not paths: McpWriteAllowed asks for the .lpk of each }
function McpNoPathCount: Integer;
function McpNoPathTool(AIndex: Integer): string;
function McpNoPathCategory(AIndex: Integer): Char;

{ A property that looks like a path and is not one of the file system: a git pathspec, a search
  keyword, a compiler search path with macros, a ref. }
function McpIsNotAPath(const ATool, AArg: string): Boolean;

implementation

const
  { tool, argument, use }
  PATHS : array[0..121] of string = (
    { ---- reads ---- }
    'code_find_declaration|file|R', 'code_find_descendants|file|R', 'code_find_overrides|file|R',
    'code_find_references|file|R', 'code_find_unused|file|R', 'code_get_identifier_info|file|R',
    'code_get_outline|file|R', 'code_get_procedure_ast|file|R', 'code_get_unit_interface|file|R',
    'code_unit_dependencies|file|R', 'editor_open|file|R', 'editor_read_file|file|R',
    'editor_set_cursor|file|R', 'form_get_lfm|file|R', 'form_get_menu|file|R',
    'form_get_properties|file|R', 'form_list_collection_items|file|R',
    'form_list_components|file|R', 'ide_show_markdown|file|R',
    'code_find_descendants|search_dir|R', 'code_find_overrides|search_dir|R',
    'code_find_references|search_dir|R', 'code_find_unused|search_dir|R',
    'code_find_descendants|lpk_path|R', 'code_find_overrides|lpk_path|R',
    'code_find_references|lpk_path|R', 'code_find_unused|lpk_path|R',
    'code_unit_dependencies|lpk_path|R', 'project_list_files|lpk_path|R',
    'project_list_todos|lpk_path|R', 'project_search|lpk_path|R', 'package_get_info|lpk_path|R',
    'package_get_settings|lpk_path|R', 'project_list_directory|directory|R',
    'project_search|directory|R',
    'git_branches|work_dir|R', 'git_log|work_dir|R', 'git_status|work_dir|R',
    'git_diff|work_dir|R', 'git_blame|file|R', 'git_archive|work_dir|R',
    'package_compile|lpk_path|R', 'project_clean|lpk_path|R', 'package_install|lpk_path|R',
    'package_uninstall|lpk_path|R', 'ide_run_tests|test_project|R',
    'debug_set_breakpoint|file|R', 'debug_remove_breakpoint|file|R', 'debug_run_to_line|file|R',
    'editor_save|file|R', 'editor_close|file|R', 'editor_revert|file|R',
    'project_add_file|file|R', 'project_remove_file|file|R', 'project_remove_package|lpk_path|R',
    'package_remove_file|file|R', 'package_add_file|file|R', 'package_move_unit|file|R',
    'git_resolve|file|R',
    { ---- files changed, asked before the tool runs ---- }
    'code_add_to_class|file|W', 'code_add_uses|file|W', 'code_complete|file|W',
    'code_edit_statement|file|W', 'code_extract_method|file|W', 'code_format|file|W',
    'code_insert_in_procedure|file|W', 'code_rename_identifier|file|W',
    'code_replace_procedure_body|file|W',
    'form_add_collection_item|file|W', 'form_add_component|file|W', 'form_add_menu_item|file|W',
    'form_arrange|file|W', 'form_create_event_handler|file|W',
    'form_delete_collection_item|file|W', 'form_delete_component|file|W', 'form_history|file|W',
    'form_move_collection_item|file|W', 'form_move_menu_item|file|W',
    'form_set_properties|file|W',
    'package_add_dependency|lpk_path|W', 'package_add_file|lpk_path|W',
    'package_remove_dependency|lpk_path|W', 'package_remove_file|lpk_path|W',
    'package_save|lpk_path|W', 'package_set_info|lpk_path|W', 'package_set_settings|lpk_path|W',
    'code_rename_identifier|lpk_path|W',
    'git_archive|output|W', 'ide_run_tests|junit_out|W',
    { ---- files changed, the tool asks itself ---- }
    'editor_create_file|file|T', 'editor_edit_text|file|T', 'editor_replace_range|file|T',
    'project_create_unit|file|T',
    { ---- folders changed ---- }
    'git_add|work_dir|F', 'git_branch_delete|work_dir|F', 'git_checkout|work_dir|F',
    'git_cherry_pick|work_dir|F', 'git_commit|work_dir|F', 'git_fetch|work_dir|F',
    'git_merge|work_dir|F', 'git_merge_abort|work_dir|F', 'git_pull|work_dir|F',
    'git_push|work_dir|F', 'git_rebase|work_dir|F', 'git_rebase_abort|work_dir|F',
    'git_rebase_continue|work_dir|F', 'git_reset|work_dir|F', 'git_resolve|work_dir|F',
    'git_squash|work_dir|F', 'git_stash|work_dir|F', 'git_remote|work_dir|F',
    'git_tag|work_dir|F', 'git_serve|work_dir|F', 'package_create|directory|F', 'form_create|directory|I',
    { ---- new places ---- }
    'project_open|file|N', 'project_create|project_dir|N', 'git_clone|target_dir|N',
    'git_init|work_dir|N', 'package_open|lpk_path|N', 'project_add_package|lpk_path|N',
    'form_create|lpk_path|N');

  { not read-only, no path argument }
  NOPATH : array[0..33] of string = (
    'debug_add_watch|g', 'debug_attach|f', 'debug_pause|g', 'debug_remove_watch|g',
    'debug_run|f', 'debug_select_frame|g', 'debug_set_variable|g', 'debug_step|f',
    'debug_stop|g', 'ide_answer_dialog|g', 'ide_rebuild|f', 'package_download|f',
    'project_build|f', 'project_close|g', 'project_run|f', 'project_run_input|f',
    'project_run_output|f', 'project_set_settings|c',
    'debug_set_breakpoint|c', 'debug_remove_breakpoint|c', 'debug_run_to_line|f',
    'editor_save|d', 'editor_close|d', 'editor_revert|d',
    'project_add_file|c', 'project_remove_file|c', 'project_add_package|c',
    'project_remove_package|c', 'package_install|f', 'package_uninstall|f',
    'package_compile|f', 'project_clean|f', 'ide_run_tests|f', 'package_move_unit|p');

  { tool|argument }
  NOTPATH : array[0..15] of string = (
    'git_diff|path', 'git_diff|active_file', 'git_add|paths', 'git_archive|paths',
    'git_stash|paths', 'git_checkout|target', 'git_reset|target', 'package_get_info|files',
    'git_serve|target',
    'project_open|unit_paths', 'package_set_settings|unit_output_dir',
    'package_set_settings|unit_search_path', 'package_set_settings|include_path',
    'package_set_settings|usage_unit_path', 'package_set_settings|usage_include_path',
    'project_set_settings|output_dir');

function Field(const S: string; N: Integer): string;
var
  I, Start, K : Integer;
begin
  K := 0;
  Start := 1;
  for I := 1 to Length(S) + 1 do
    if (I > Length(S)) or (S[I] = '|') then
    begin
      if K = N then Exit(Copy(S, Start, I - Start));
      Inc(K);
      Start := I + 1;
    end;
  Result := '';
end;

function UseOf(const C: string): TMcpPathUse;
begin
  case C of
    'W': Result := puWrite;
    'T': Result := puWriteInTool;
    'F': Result := puFolder;
    'I': Result := puFolderInTool;
    'N': Result := puNewPlace;
  else
    Result := puRead;
  end;
end;

function McpToolPathCount: Integer;
begin
  Result := Length(PATHS);
end;

function McpToolPathAt(AIndex: Integer): TMcpToolPath;
begin
  Result.Tool := Field(PATHS[AIndex], 0);
  Result.Arg  := Field(PATHS[AIndex], 1);
  Result.Use  := UseOf(Field(PATHS[AIndex], 2));
end;

function McpToolPathFor(const ATool: string; AIndex: Integer; out APath: TMcpToolPath): Boolean;
var
  I, K : Integer;
begin
  K := 0;
  for I := 0 to High(PATHS) do
    if Field(PATHS[I], 0) = ATool then
    begin
      if K = AIndex then
      begin
        APath := McpToolPathAt(I);
        Exit(True);
      end;
      Inc(K);
    end;
  Result := False;
end;

function McpNoPathCount: Integer;
begin
  Result := Length(NOPATH);
end;

function McpNoPathTool(AIndex: Integer): string;
begin
  Result := Field(NOPATH[AIndex], 0);
end;

function McpNoPathCategory(AIndex: Integer): Char;
var
  S : string;
begin
  S := Field(NOPATH[AIndex], 1);
  if S = '' then Result := ' ' else Result := S[1];
end;

function McpIsNotAPath(const ATool, AArg: string): Boolean;
var
  I : Integer;
begin
  for I := 0 to High(NOTPATH) do
    if (Field(NOTPATH[I], 0) = ATool) and (Field(NOTPATH[I], 1) = AArg) then Exit(True);
  Result := False;
end;

end.
