{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit McpRefKeeper;

{ Keeps references to deleted components, and puts them back when the
  component returns.

  The designer's undo of a delete (Ctrl+Z, form_undo) reinserts the component
  from a stream.  The stream holds the component's own references, but the
  references other components held to it (Label1.FocusControl,
  Button1.PopupMenu, Form1.Menu, AnchorSideLeft.Control) were cleared on
  delete and are not in any undo entry.  The reinserted control also lands at the end of its parent's controls, so
  its z-order and TabOrder change.  This unit listens to the design hook:
    - PersistentDeleting: notes who refers to the component and its children,
      and the control's place among its siblings;
    - PersistentAdded, while the designer replays its undo list: when a
      component of that name and class is back, sets the noted references
      again (if still empty) and puts the control back in its place.
  It works for any delete, by the user or by a tool, and so also for the undo
  steps that replace a whole component (McpToolsForms, "Undo by snapshot"). }

{$mode objfpc}{$H+}

interface

procedure InitializeRefKeeper;
procedure FinalizeRefKeeper;

implementation

uses
  Classes, SysUtils, TypInfo, Controls, Forms, Menus, PropEdits, ComponentEditors;

const
  MaxEntries = 500;   { oldest notes are dropped beyond this }
  MaxDepth   = 2;     { AnchorSideLeft.Control is depth 1 }

type
  TRefEntry = class
    Root        : TComponent;  { compared, never dereferenced unless alive }
    RootName    : string;
    Holder      : string;      { component holding the reference; '' = root }
    Path        : string;      { FocusControl, AnchorSideLeft.Control }
    Target      : string;
    TargetClass : string;
  end;

  { Where a deleted control was among its parent's controls: the reinserted
    control is appended at the end (z-order, and so TabOrder, change). }
  TPosEntry = class
    Root     : TComponent;
    RootName : string;
    Name     : string;
    Parent   : string;
    Index    : Integer;
    TabOrder : Integer;   { -1: not a TWinControl }
  end;

  TRefKeeper = class
  private
    FEntries : TFPList;
    FPos     : TFPList;
    procedure Note(ARoot: TComponent; const AHolder, APath: string; ATarget: TComponent);
    procedure Scan(ARoot: TComponent; AObj: TPersistent; const AHolder, APrefix: string;
                   ADeleted: TFPList; ADepth: Integer);
    procedure Restore(AEntry: TRefEntry; ATarget: TComponent);
    procedure NotePos(ARoot: TComponent; AControl: TControl);
    procedure RestorePos(AComp: TComponent);
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnDeleting(APersistent: TPersistent);
    procedure OnAdded(APersistent: TPersistent; Select: Boolean);
  end;

var
  Keeper : TRefKeeper = nil;

{ Is AChild AComp itself or inside it (child control, submenu item)? }
function Contains(AComp, AChild: TComponent): Boolean;
var
  MI : TMenuItem;
begin
  Result := AChild = AComp;
  if Result then Exit;
  if (AComp is TWinControl) and (AChild is TControl) then
    Exit(TWinControl(AComp).IsParentOf(TControl(AChild)));
  if AChild is TMenuItem then
  begin
    if (AComp is TMenu) and (TMenuItem(AChild).GetParentMenu = TMenu(AComp)) then
      Exit(True);
    MI := TMenuItem(AChild).Parent;
    while Assigned(MI) do
    begin
      if MI = AComp then Exit(True);
      MI := MI.Parent;
    end;
  end;
end;

constructor TRefKeeper.Create;
begin
  inherited Create;
  FEntries := TFPList.Create;
  FPos     := TFPList.Create;
end;

destructor TRefKeeper.Destroy;
var
  I : Integer;
begin
  for I := 0 to FEntries.Count - 1 do
    TRefEntry(FEntries[I]).Free;
  FEntries.Free;
  for I := 0 to FPos.Count - 1 do
    TPosEntry(FPos[I]).Free;
  FPos.Free;
  inherited Destroy;
end;

procedure TRefKeeper.NotePos(ARoot: TComponent; AControl: TControl);
var
  E : TPosEntry;
  I : Integer;
begin
  if (AControl.Parent = nil) or (AControl.Parent.Name = '') then Exit;
  for I := FPos.Count - 1 downto 0 do
  begin
    E := TPosEntry(FPos[I]);
    if (E.Root = ARoot) and (E.Name = AControl.Name) then
    begin
      E.Free;
      FPos.Delete(I);
    end;
  end;
  if FPos.Count >= MaxEntries then
  begin
    TPosEntry(FPos[0]).Free;
    FPos.Delete(0);
  end;
  E := TPosEntry.Create;
  E.Root     := ARoot;
  E.RootName := ARoot.Name;
  E.Name     := AControl.Name;
  E.Parent   := AControl.Parent.Name;
  E.Index    := AControl.Parent.GetControlIndex(AControl);
  E.TabOrder := -1;
  if AControl is TWinControl then
    E.TabOrder := TWinControl(AControl).TabOrder;
  FPos.Add(E);
end;

procedure TRefKeeper.RestorePos(AComp: TComponent);
var
  E    : TPosEntry;
  I    : Integer;
  Ctl  : TControl;
  Root : TComponent;
  P    : TComponent;
begin
  if not (AComp is TControl) then Exit;
  Ctl  := TControl(AComp);
  Root := AComp.Owner;
  if (Root = nil) or (Ctl.Parent = nil) then Exit;
  for I := FPos.Count - 1 downto 0 do
  begin
    E := TPosEntry(FPos[I]);
    if (E.Root <> Root) or (E.RootName <> Root.Name) or (E.Name <> Ctl.Name) then Continue;
    { The undo entry finds the parent with FindChildControl, which only sees
      the form's direct children: a control from a panel in a panel lands on
      the form.  Left/Top in the stream are relative to the old parent. }
    if E.Parent <> Ctl.Parent.Name then
    begin
      if SameText(E.Parent, Root.Name) then
        P := Root
      else
        P := Root.FindComponent(E.Parent);
      if (P is TWinControl) and not ((Ctl is TWinControl) and
         TWinControl(Ctl).IsParentOf(TWinControl(P))) then
        Ctl.Parent := TWinControl(P);
    end;
    if E.Parent = Ctl.Parent.Name then
    begin
      if E.Index < Ctl.Parent.ControlCount then
        Ctl.Parent.SetControlIndex(Ctl, E.Index);
      if (E.TabOrder >= 0) and (Ctl is TWinControl) then
        TWinControl(Ctl).TabOrder := E.TabOrder;
    end;
    E.Free;
    FPos.Delete(I);
  end;
end;

procedure TRefKeeper.Note(ARoot: TComponent; const AHolder, APath: string;
  ATarget: TComponent);
var
  E : TRefEntry;
  I : Integer;
begin
  { a newer note for the same reference replaces the older one }
  for I := FEntries.Count - 1 downto 0 do
  begin
    E := TRefEntry(FEntries[I]);
    if (E.Root = ARoot) and (E.Holder = AHolder) and SameText(E.Path, APath) then
    begin
      E.Free;
      FEntries.Delete(I);
    end;
  end;
  if FEntries.Count >= MaxEntries then
  begin
    TRefEntry(FEntries[0]).Free;
    FEntries.Delete(0);
  end;
  E := TRefEntry.Create;
  E.Root        := ARoot;
  E.RootName    := ARoot.Name;
  E.Holder      := AHolder;
  E.Path        := APath;
  E.Target      := ATarget.Name;
  E.TargetClass := ATarget.ClassName;
  FEntries.Add(E);
end;

{ Note every component reference in AObj's published properties that points
  into ADeleted; sub-objects (AnchorSide*, Constraints, ...) are searched too. }
procedure TRefKeeper.Scan(ARoot: TComponent; AObj: TPersistent;
  const AHolder, APrefix: string; ADeleted: TFPList; ADepth: Integer);
var
  List  : PPropList;
  Count : Integer;
  I     : Integer;
  V     : TObject;
begin
  Count := GetPropList(AObj.ClassInfo, [tkClass], nil);
  if Count = 0 then Exit;
  GetMem(List, Count * SizeOf(PPropInfo));
  try
    GetPropList(AObj.ClassInfo, [tkClass], List);
    for I := 0 to Count - 1 do
    begin
      V := GetObjectProp(AObj, List^[I]);
      if V = nil then Continue;
      if V is TComponent then
      begin
        if ADeleted.IndexOf(V) >= 0 then
          Note(ARoot, AHolder, APrefix + List^[I]^.Name, TComponent(V));
      end
      else if (V is TPersistent) and not (V is TCollection) and (ADepth < MaxDepth) then
        Scan(ARoot, TPersistent(V), AHolder, APrefix + List^[I]^.Name + '.',
             ADeleted, ADepth + 1);
    end;
  finally
    FreeMem(List);
  end;
end;

procedure TRefKeeper.OnDeleting(APersistent: TPersistent);
var
  C, Root, X : TComponent;
  Deleted    : TFPList;
  I          : Integer;
begin
  if not (APersistent is TComponent) then Exit;
  C    := TComponent(APersistent);
  Root := C.Owner;
  if (Root = nil) or not (csDesigning in Root.ComponentState) or (C.Name = '') then Exit;
  Deleted := TFPList.Create;
  try
    for I := 0 to Root.ComponentCount - 1 do
      if Contains(C, Root.Components[I]) then
        Deleted.Add(Root.Components[I]);
    if Deleted.IndexOf(C) < 0 then
      Deleted.Add(C);
    if C is TControl then
      NotePos(Root, TControl(C));
    Scan(Root, Root, '', '', Deleted, 0);
    for I := 0 to Root.ComponentCount - 1 do
    begin
      X := Root.Components[I];
      if (Deleted.IndexOf(X) < 0) and (X.Name <> '') then
        Scan(Root, X, X.Name, '', Deleted, 0);
    end;
  finally
    Deleted.Free;
  end;
end;

{ Set AEntry's reference to ATarget if the holder still exists and the
  reference is still empty (nobody has chosen something else meanwhile). }
procedure TRefKeeper.Restore(AEntry: TRefEntry; ATarget: TComponent);
var
  Obj   : TObject;
  Rest  : string;
  P     : Integer;
  Info  : PPropInfo;
begin
  if AEntry.Holder = '' then
    Obj := AEntry.Root
  else
    Obj := AEntry.Root.FindComponent(AEntry.Holder);
  if Obj = nil then Exit;
  Rest := AEntry.Path;
  P := Pos('.', Rest);
  while P > 0 do
  begin
    Info := GetPropInfo(Obj, Copy(Rest, 1, P - 1));
    if (Info = nil) or (Info^.PropType^.Kind <> tkClass) then Exit;
    Obj := GetObjectProp(Obj, Info);
    if Obj = nil then Exit;
    Delete(Rest, 1, P);
    P := Pos('.', Rest);
  end;
  Info := GetPropInfo(Obj, Rest);
  if (Info = nil) or (Info^.PropType^.Kind <> tkClass) or (Info^.SetProc = nil) then Exit;
  if GetObjectProp(Obj, Info) <> nil then Exit;
  if not ATarget.InheritsFrom(GetTypeData(Info^.PropType)^.ClassType) then Exit;
  SetObjectProp(Obj, Info, ATarget);
  if Obj is TPersistent then
    GlobalDesignHook.Modified(TPersistent(Obj));
end;

procedure TRefKeeper.OnAdded(APersistent: TPersistent; Select: Boolean);
var
  C, Root, T : TComponent;
  E          : TRefEntry;
  I          : Integer;
  D          : TIDesigner;
begin
  if not (APersistent is TComponent) then Exit;
  C    := TComponent(APersistent);
  Root := C.Owner;
  if Root = nil then Exit;
  { only while the designer replays its undo list (TDesigner.ExecuteUndoItem
    holds the undo lock): a new component that happens to get a deleted
    one's name is left alone }
  D := FindRootDesigner(C);
  if not ((D is TComponentEditorDesigner) and TComponentEditorDesigner(D).IsUndoLocked) then
    Exit;
  RestorePos(C);
  for I := FEntries.Count - 1 downto 0 do
  begin
    E := TRefEntry(FEntries[I]);
    if (E.Root <> Root) or (E.RootName <> Root.Name) then Continue;
    T := Root.FindComponent(E.Target);
    if (T = nil) or (T.ClassName <> E.TargetClass) or not Contains(C, T) then Continue;
    try
      Restore(E, T);
    except
      { a reference the holder rejects now: drop the note }
    end;
    E.Free;
    FEntries.Delete(I);
  end;
end;

procedure InitializeRefKeeper;
begin
  if Assigned(Keeper) or (GlobalDesignHook = nil) then Exit;
  Keeper := TRefKeeper.Create;
  GlobalDesignHook.AddHandlerPersistentDeleting(@Keeper.OnDeleting);
  GlobalDesignHook.AddHandlerPersistentAdded(@Keeper.OnAdded);
end;

procedure FinalizeRefKeeper;
begin
  if not Assigned(Keeper) then Exit;
  if Assigned(GlobalDesignHook) then
    GlobalDesignHook.RemoveAllHandlersForObject(Keeper);
  FreeAndNil(Keeper);
end;

finalization
  FinalizeRefKeeper;
end.
