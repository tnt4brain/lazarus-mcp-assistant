{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
program gen_knowledge_inc;
// Reads lazarus-knowledge.md from the project root and writes
// src/lazarus_knowledge.inc — a Pascal string expression.
// Usage (run from project root):
//   instantfpc tools/gen_knowledge_inc.pas
// Then in mcplayoutpanel.pas:
//   const KnowledgeText: string = {$I lazarus_knowledge.inc};
uses SysUtils, Classes;
var
  MD      : TStringList;
  OutFile : TStringList;
  I       : Integer;
  Line    : string;
  Tail    : string;
begin
  if not FileExists('lazarus-knowledge.md') then
  begin
    WriteLn('Error: lazarus-knowledge.md not found (run from project root)');
    Halt(1);
  end;
  MD      := TStringList.Create;
  OutFile := TStringList.Create;
  try
    MD.LoadFromFile('lazarus-knowledge.md');
    OutFile.Add('(');
    for I := 0 to MD.Count - 1 do
    begin
      Line := StringReplace(MD[I], '''', '''''', [rfReplaceAll]);
      if I < MD.Count - 1 then
        Tail := ' + LineEnding +'
      else
        Tail := ' + LineEnding';
      OutFile.Add('  ''' + Line + '''' + Tail);
    end;
    OutFile.Add(')');
    OutFile.SaveToFile('src' + PathDelim + 'lazarus_knowledge.inc');
    WriteLn('Written: src/lazarus_knowledge.inc (' +
            IntToStr(MD.Count) + ' lines)');
  finally
    MD.Free;
    OutFile.Free;
  end;
end.
