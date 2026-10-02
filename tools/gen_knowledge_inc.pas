{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
program gen_knowledge_inc;
// Emits two Pascal .inc files from the source markdown docs:
//   src/system_prompt.inc   from docs/system-prompt.md
//   src/lazarus_knowledge.inc  from docs/lazarus-knowledge.md
// Usage (run from project root):
//   fpc -MObjFPC -Scghi -FEtools tools\gen_knowledge_inc.pas
//   .\tools\gen_knowledge_inc.exe
uses SysUtils, Classes;

procedure WriteInc(const SrcFile, OutFile: string);
var
  MD      : TStringList;
  Inc     : TStringList;
  I       : Integer;
  Line    : string;
  Tail    : string;
begin
  if not FileExists(SrcFile) then
  begin
    WriteLn('Error: ', SrcFile, ' not found (run from project root)');
    Halt(1);
  end;
  MD  := TStringList.Create;
  Inc := TStringList.Create;
  try
    MD.LoadFromFile(SrcFile);
    Inc.Add('(');
    for I := 0 to MD.Count - 1 do
    begin
      Line := StringReplace(MD[I], '''', '''''', [rfReplaceAll]);
      if I < MD.Count - 1 then
        Tail := ' + LineEnding +'
      else
        Tail := ' + LineEnding';
      Inc.Add('  ''' + Line + '''' + Tail);
    end;
    Inc.Add(')');
    Inc.SaveToFile(OutFile);
    WriteLn('Written: ', OutFile, ' (', MD.Count, ' lines)');
  finally
    MD.Free;
    Inc.Free;
  end;
end;

begin
  WriteInc('docs' + PathDelim + 'system-prompt.md',     'src' + PathDelim + 'system_prompt.inc');
  WriteInc('docs' + PathDelim + 'lazarus-knowledge.md', 'src' + PathDelim + 'lazarus_knowledge.inc');
end.
