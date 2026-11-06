# Ingame-Test 2 (2026-11-06, agent:maxi) – Ergebnisse

**Im Spiel verifiziert:**
- `package.loadlib` funktioniert, `PC2MPNative.dll` wird geladen (Pfad `.\Win64\ovldata\PC2MP\PC2MPNative.dll`).
- Stack-Layout aus ACSEDebug (TValue 0x18, tt@+0x10, top@+0x10, ci@+0x20) **stimmt für PC2**:
  Strings lesen ✔, Integer zurückgeben (`ping -> 4242`) ✔.
- Diagnose: `io`, `os`, `debug` = nil; `api.json`, `api.undo`, `api.world` vorhanden;
  `api.debug.WriteStringToFile` funktioniert NICHT (Retail).
- `package.cpath` = Spielordner `?.dll` u. a.
- `tWorldAPIs.editors` ist eine Tabelle ohne direkte Funktionen (Methoden über `:` → `editors:CreateUndoOperationsHierarchy()` funktioniert).
- Wrappen von `api.undo.*` (Lua-Funktionen in der Tabelle ersetzen) funktioniert, Bauen bleibt normal.
  Achtung: Module laufen pro Environment neu → Merker in `api.pc2mp` statt Modul-Variablen.

**Ablauf beim Platzieren eines Objekts (geloggt):**
Während man das Objekt bewegt: ständig `PreviewChangeList(cl)` → `CancelPreview(token)`.
Beim Klick: `CanCommitPreview(token)` → `true`, `CommitPreview(token)`, danach `Checkpoint({})`.
Strg+Z: `api.undo.Undo()`.
→ **Hook-Punkt fürs Senden: `CommitPreview` (+ `Checkpoint`), `Undo`, `Redo`.**
Die ChangeList selbst ist opakes userdata – Inhalt muss über die Hierarchy-Aufrufe (s. u.) oder
anders ausgelesen werden.

**Methoden von UndoOperationsHierarchy (userdata):**
AddBlueprintToCompositeObject, AddCashDelta, AddPartsToCompositeObject, AddVolumeChunkToCompositeObject,
BeginVolumeModificationsBlock, CanAfford, CloneExistingPart, CloneExistingPartDuplicates, CloneExistingParts,
CreateCompositeObject, CreateNewPart, CreateNewParts, CreateParkZone, DestroyExistingPart, DestroyExistingParts,
DestroyParkZone, EditExistingPart, EditExistingParts, EndVolumeModificationsBlock,
GetAllEditedGroupsContainingOnlySnapEdges, GetAllEditedGroupsThatShouldBeDestroyed, GetBoundaryChangeList,
GetCleanupConnectionEntities, GetFullUndoChangeList, GetOngoingPartEdit_Group, GetOngoingPartEdit_Scenery,
GetOngoingPartEdits_Group, GetTerrainEditOperation, IsEditingPlacementPart, IsLoadedBlueprintReadyForEditing,
ModifyParkZoneShape, ModifyUtilityConnection, RemoveAllConnectionsFromEntity, RemoveDLCItems, RemoveVolume,
SetCashAccumulate, SetCashPos, SetErrorOnPathMergeUnchangedModifyVolumes, SetMagicModeModifyVolumes,
SetParkZoneColour, SetPerformTerrainModificationsModifyVolumes, SetUndoChangeListReverseOrder,
SetWaterVolumeColour, StartEditingPart_Group, StartEditingPart_Scenery, StartEditingParts_Group,
StartEditingParts_Scenery, __eq, __gc

**Offen: Crash beim Beenden**
- Beide Tests crashen beim Beenden an **derselben Adresse** `PlanetCoaster2.exe+0x14fdf62` (Null-Read @0x10),
  NACH `Manager Shutdown`. Bauen etc. funktioniert normal.
- Bisect läuft: Test 3 nur mit ACSE + ForgeUtils (ohne PC2MP).
