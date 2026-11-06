# Finding: Bau-Aktionen über das Nachrichtensystem erkennen (funktioniert ✔)

Ingame-Test 4 (2026-11-06, agent:maxi). **Das ist der Weg, den wir nutzen.**

## Warum nicht Hierarchy-Hooks?
Wrappen der UndoOperationsHierarchy-Metatable wirkt nur auf Hierarchies, die *wir* erzeugen
(Selbsttest ok), die Editoren des Spiels lösen die Wrapper nie aus (`hierCalls` bleibt 1).
Hierarchies werden außerdem an native APIs übergeben → Proxy-Objekte sind keine Option.
ChangeList/PreviewToken haben keine lesbaren Methoden (nur `__eq`, `__gc`).

## Nachrichtensystem
`api.messaging.RegisterReceiver(api.messaging.MsgType_<Name>, fn(tMessages))` / `UnregisterReceiver`.
- **`PlacementPartCommittedMessage`** → `{ nPlacementPartID }` bei **Erstellen, Ändern (Verschieben/Drehen/
  Skalieren), Löschen und Undo/Redo**. Gleiche PartID bei Änderungen.
  - Löschen: `placement:PlacementPartExists(id)` = false
  - Nach Undo-Wiederherstellung ist die Entity evtl. noch nicht da → ein paar Frames später erneut abfragen.
- `UndoRedoCompletedMessage`, `SceneryPlacedMessage {eType, vPos, sName}`,
  `EntitiesAboutToBeDestroyedMessage {tEntities}` (feuert auch für Preview-Entities → viel Rauschen),
  `ParkZoneCreatedOrDeletedMessage {nZoneID, bZoneDeleted}`.

## Teil beschreiben (tWorldAPIs = api.world.GetWorldAPIs())
- Ressource: `tWorldAPIs.placement:GetPartResourceName(partID)` → z. B. `NAT_Tree_Conifer_Pine_Aleppo_Small_01`
- Entity: `placement:PlacementIDToEntityID(partID)`
- Transform: `api.transform.CalculateWorldTransform(entityID)` → `:GetPos()` (Vector3 `:GetX/Y/Z`),
  `:GetOr():ToPackedAxisAngle()` (Rotation als Vector3)
- Skalierung: `tWorldAPIs.scenery:GetPartScaleData(partID)` → `{nScale, nMinScale, nMaxScale}`
- Anzeigename: `scenery:GetPropName(partID)`

## Nachspielen (pc2mp.replay.lua, noch im Test)
- Erstellen: `hier = editors:CreateUndoOperationsHierarchy()`, `tok = api.entity.CreateRequestCompletionToken()`,
  `co = hier:CreateNewPart(resource, tok)`, warten bis `api.entity.HaveRequestsCompleted(tok)`,
  `eo = hier:StartEditingParts_Scenery({co})[1]`, `eo:SetTransform(TransformQ.FromOrPos(
  Quaternion.FromPackedAxisAngle(Vector3:new(rx,ry,rz)), Vector3:new(x,y,z)))`, `eo:SetScale(s)`,
  dann `api.undo.PreviewChangeList(hier:GetFullUndoChangeList())` → `CanCommitPreview` → `CommitPreview`.
- Ändern: `hier:EditExistingPart(partID, nil, tok)` → warten → `hier:StartEditingPart_Scenery(co)` → wie oben.
- Löschen: `set = scenery:CreateBuildingPartSet(); set:Add(id); hier:DestroyExistingParts(set)` → Commit.
