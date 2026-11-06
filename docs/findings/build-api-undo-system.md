# Finding: Alle Bau-Aktionen laufen über `api.undo` (ChangeLists)

Status: verifiziert im dekompilierten Lua (Spielversion Stand 2026-11-06), **noch nicht im Spiel getestet**.
Quelle: `Content0/Main.ovl` → u. a. `editors.infrastructure.infrastructureconnectionmode.lua`,
`editors.shared.singlefeatureundoableplacementmodebase.lua`, `editors.scenery.submodeplacement.lua`,
`components.ui.selectandeditcomponent.lua`.

## Ablauf einer Bau-Aktion
1. `hierarchy = editorsAPI:CreateUndoOperationsHierarchy()` (editorsAPI = `tWorldAPIs.editors`)
2. Operationen hinzufügen:
   - `hierarchy:CreateNewPart(sPrefabName, completionToken)` → neues Objekt
   - `hierarchy:EditExistingPart(nPartID, nPuppetIndex, completionToken)` / `EditExistingParts`
   - `hierarchy:DestroyExistingPart(s)(...)`
   - weitere: `CreateCompositeObject`, `AddPartsToCompositeObject`, `CloneExistingPartDuplicates`,
     `SetCashPos`, `AddCashDelta`, `BeginVolumeModificationsBlock` (Terrain), `ModifyUtilityConnection`
   - `completionToken = api.entity.CreateRequestCompletionToken()`; danach per Coroutine warten,
     bis die Edit-Objekte bereit sind, dann z. B. `editObj:SetTransformForSurfacePlacement(pos, up, rot, false)`
3. `waitToken, previewToken = api.undo.PreviewChangeList(hierarchy:GetFullUndoChangeList())`
4. warten bis `api.undo.IsOperationComplete(waitToken)`
5. `api.undo.CanCommitPreview(previewToken)` → `api.undo.CommitPreview(previewToken)` oder `CancelPreview`
6. Danach: `placementAPI:PlacementIDToEntityID(nPartID)` liefert Entity-ID.

Weitere `api.undo`-Funktionen: `Checkpoint`, `Undo`, `Redo`, `CanUndo`, `CanRedo`, `IsBusy`,
`GetMostRecentOperation`, `GetCheckpointData`, `GetUndoneCheckpointData`, `ClearHistory`, `GetCommitFailReasons`.

## Bedeutung für den Multiplayer
- **Ein zentraler Hook-Punkt:** `api.undo.CommitPreview` (bzw. `PreviewChangeList`) abfangen →
  jede Bau-Aktion aller Editoren (Szenerie, Wege, Infrastruktur, Schilder, …) läuft hier durch.
- **Nachspielen auf anderen Clients:** genau das Muster aus
  `InfrastructureConnectionEditMode.CreateConnectionObjects` (CreateNewPart → Transform setzen → Preview → Commit)
  ist eine fertige Vorlage, um ein Objekt per Code zu platzieren.
- **Offene Frage:** Die ChangeList ist ein natives Objekt. Wir müssen herausfinden, ob man ihren Inhalt
  (Prefab-Name, Transform, betroffene PartIDs) aus Lua auslesen kann, oder ob wir stattdessen eine Ebene
  höher in den `hierarchy:CreateNewPart/EditExistingPart/...`-Aufrufen mitschreiben (Wrapper um die Hierarchy).
- **Undo/Redo:** muss ebenfalls synchronisiert oder für Remote-Aktionen getrennt behandelt werden.

## Nächste Schritte
1. Test-Mod: `api.undo.CommitPreview` und `CreateUndoOperationsHierarchy` per ForgeUtils-HookManager wrappen
   und jede Aktion mit Parametern ins Log schreiben.
2. Test-Mod: auf Tastendruck einen Baum per CreateNewPart-Muster an fester Position platzieren.
