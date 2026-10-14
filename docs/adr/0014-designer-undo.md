# ADR-014 — Designer Undo

**Status:** Accepted (v1.0)  
**Date:** 2026-10-14

## Context

Until v0.9, `form_*` changes could not be undone from the assistant; the way back
was `editor_revert` or git. Worse, they sat badly with the user's own Ctrl+Z.

**The IDE has a designer undo list.** Each `TDesigner` (`designer/designer.pp`)
keeps a ring of 64 entries in `FUndoList`. Entries are grouped by an id, and one
Ctrl+Z undoes one group. There are three kinds:
- `uopChange`: a property, replayed by name with `SetOrdProp`, `SetStrProp`
  and similar (`ExecuteUndoItem`). `Parent` and `Name` are handled specially.
- `uopAdd` and `uopDelete`: the component streamed as on the clipboard
  (`CopySelectionToStream`). Undo deletes it by name or inserts the stream again.

A plugin reaches the list through IDEIntf: `TComponentEditorDesigner` has
`CanUndo`, `CanRedo`, `Undo`, `Redo`, `AddUndoAction` and `IsUndoLocked`. It
cannot read the list or clear it. The Object Inspector, the component tree and
the designer's own add, delete and paste write entries; property editors do not.

**What the tools recorded in v0.9.** Only `form_delete_component` wrote an
entry, through `DeleteSelection`. `form_set_properties`, `form_add_component`,
`form_arrange`, the collection and menu tools wrote none. So the list could
hold entries that named components an assistant had since renamed or deleted.
The user's next Ctrl+Z then looked them up by name, found nothing and set a
property on nil.

**What the list cannot replay.** `ExecuteUndoItem` handles simple types
(ordinal, enum, set, float, string, Boolean) on a component it finds by name.
It cannot replay these:
- references (`tkClass`) and events (`tkMethod`): it shows "unknown TTypeKind";
- sub-objects (`Font.Color`): the persistent is a `TFont`, not a component, so
  there is no name to find;
- string lists, collection items, and menu structure.

The Object Inspector records the first two anyway, with empty values. That is
an IDE limitation and not changed here.

**Prior art.** The current list is the action-list design from 2012 (FPC bug
22584). In the mailing-list debate of the time:
- Mattias Gaertner noted that full-form snapshots are expensive, and that some
  operations, such as deleting a referenced component, have no simple reverse.
- Martin Friebe argued that designer undo and source-editor undo should stay
  separate.

Delphi's designer undo is documented mainly for restoring deleted components.
No other MCP server with designer undo was found.

## Decision

**1. One list, the IDE's.** The tools write into the designer's own undo list.
There is no separate MCP stack: a second history would not fix the stale
entries above, and it would compete with the user's Ctrl+Z.

**2. `form_undo` and `form_redo`.** They do what Edit > Undo and Redo do while
the designer is active (`TMainIDE.mnuEditUndoClicked`): `Undo` or `Redo` on the
form's designer. They return `status`, `can_undo` and `can_redo`, or an error
when there is nothing to undo or redo.
- **Several clients share the list.** It is one list per form, shared with the
  user and every client. `form_undo` takes back the latest group, whoever made
  it, as an editor does. A shadow log to restrict it to "own" changes would be
  guesswork, because the list cannot be read.

**3. One tool call is one group.** Every changing call records its entries
under one group id, so one Ctrl+Z or one `form_undo` takes back the whole call.

**4. Entry by entry where the list can replay it.** The values are written in
the format the Object Inspector uses (`GetPropValue` in `objectinspector.pp`):

| Tool | Entries |
|---|---|
| `form_set_properties`, simple properties of a component, including `Name` | `uopChange` per property, old and new value |
| `form_set_properties` `Parent` | `uopChange` `'Parent'` with the old and new parent name, as the component tree does |
| `form_add_component` | one `uopAdd` after the name and properties are set, as `TDesigner.AddComponent` does; redo inserts the final state |
| `form_delete_component` | the designer's own `uopDelete` (`DeleteSelection`) |
| `form_arrange` | `uopChange` for each changed Left, Top, Width, Height. Its checks now run before any control is moved, so a call either moves all or nothing |

Menu items get entries like other components. The menu tools record their
deletes and moves (below), so an entry naming an item finds it again.

**5. Replacement steps for the rest.** A change the list cannot replay entry
by entry is recorded as a replacement of the whole component:
- before the change, a `uopDelete` entry streams the component as it is;
- after the change, a `uopAdd` entry streams it again.

Undo deletes the changed component and inserts the old one; redo does the
reverse. A menu item is replaced together with its whole menu. This covers:
- `form_set_properties` when any property in the call needs it (then the whole
  call is one replacement);
- `form_add_collection_item`, `form_delete_collection_item` and
  `form_move_collection_item`;
- `form_add_menu_item`, `form_move_menu_item` (both menus when the item
  changes menu), and `form_delete_component` on a menu item;
- `form_create_event_handler`. This is not verified: the tool fails in v0.9
  before it changes anything, and is to be fixed separately.

`Name` is kept out of the replacement. The other properties are changed
between the delete and add entries; the rename follows as a `uopChange` entry
of its own. Undo then renames back first, event handlers included, so each
stream it inserts names the same methods as the source.

Some components cannot be replaced, and their results say
`"undoable": false`:
- the form itself (`AddUndoAction` does not stream the root), so
  `Form1.Font.Color`, `Form1.Menu` and `Form1.OnCreate` stay;
- inherited components and components of frames, which `DeleteSelection`
  refuses.

When the whole call cannot be undone, results say `"undoable": false` per
property, and properties that can be undone are still recorded.

**6. Keeping references and positions (`McpRefKeeper`).** Deleting a component
clears every reference other components hold to it: `Label1.FocusControl`,
`Button1.PopupMenu`, `Form1.Menu`, `AnchorSideLeft.Control`. The reinserted
stream holds only the component's own references, and the control goes back at
the end of its parent's controls. This also happens to the IDE's own Ctrl+Z of
a delete; probe C reproduced it.

`McpRefKeeper` hooks `GlobalDesignHook`:
- `PersistentDeleting` notes the references to the component and to its
  children and submenu items, held by the form and by every other component
  (two levels deep, so `AnchorSide*.Control` is included). It also notes the
  control's index among its siblings and its TabOrder.
- `PersistentAdded` restores what was noted for a component of the same name
  and class, but only while the designer replays its undo list (the designer is
  undo-locked inside `ExecuteUndoItem`). It sets a reference only if it is
  still empty. A new component that happens to get a deleted one's name is
  left alone.

It also puts a control back into its parent. The undo entry looks the parent
up with `FindChildControl`, which sees only the form's direct children, so a
control from a panel inside a panel would otherwise land on the form.

It works for every delete, by the user or a tool, so it also fixes the IDE's
own undo of a delete. The notes are capped at 500 each; the oldest are dropped.

## Consequences

- An assistant's change is one Ctrl+Z for the user, and a user's change is one
  `form_undo` for the assistant. The list no longer holds entries that point at
  components the tools renamed.
- **Undo restores the form, not the source.** A component's field leaves and
  comes back with it, and `Name` renames the handlers back. A method that
  `form_create_event_handler` created stays in the unit; undo only unassigns
  the event. This follows Martin Friebe's 2012 position.
- **Replacement is heavier than an entry.** It streams the component and its
  children twice. It also counts against the 64-entry ring with two entries per
  replaced component. A call that writes more entries than the ring holds is
  only partly undone. This is rare, because unchanged values are not recorded.
- **Parent moves.** After `Parent` is undone, the control is the last child of
  its old parent, as with the IDE's own undo of a Parent change.
- **An entry the IDE cannot replay blocks `form_undo`.** Such entries are
  recorded by the Object Inspector for events and references. On Windows,
  `ShowMessage` is a native TaskDialog, which the plugin's dialog hooks cannot
  see, so `form_undo` waits until the user closes it. The same happens to the
  user's own Ctrl+Z.

## Probes (2026-10-14, on a copy of `tests/fixtures/fixtureform`)

| Probe | Result |
|---|---|
| A. delete via MCP, undo, redo | Component, `OnClick` binding and class field come back; redo removes them again |
| B. Caption, Left, Visible, Name in one call; add with properties; Parent; arrange | One step each; Name and the handler are renamed back in the source; Parent undo changes TabOrder (as the IDE's own) |
| C. the form's Caption; Color, Anchors; Align = alClient; references across delete + undo | Root lookup works; values round-trip; Align undo restores the bounds; **references from other components are lost** (IDE behaviour), so `McpRefKeeper` was added |
| D. the same with `McpRefKeeper` | `FocusControl` and two `PopupMenu` references come back, also across redo + undo |
| E. replacement steps | `Font.Color` + Caption, Memo Lines, a StatusBar panel, menu add, delete and move (with `Form1.Menu` kept), an event set through `form_set_properties`: all undone; the form's own `Font.Color` reports `undoable: false` |

`tests/tformundo.pas` (`TTestFormUndo`, 9 tests) covers these on a temp copy
of the fixture form. It adds three cases:
- a control two panels deep, which comes back into its panel;
- `Font.Color` together with `Name`, undone and redone, with a reference to
  the component kept;
- an `AnchorSideTop.Control` reference, written into the copy's `.lfm`
  because the tools cannot set `AnchorSide*` (the IDE hides it from property
  editors), which is restored after a delete and undo.

## Not done

- **The Object Inspector's own entries.** References and events it records
  stay unreplayable. Fixing that means patching `ExecuteUndoItem` in Lazarus.
- **Checkpoints across sessions.** One idea is commits under a private ref
  namespace such as `refs/mcp/forms/<unit>`, to see and restore what
  assistants changed on a form. They would complement this list, not replace
  it. Deferred.
