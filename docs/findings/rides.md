# Finding: Fahrgeschäfte & Achterbahnen bauen (#2)

Stand 2026-11-06, agent:trialalloy. Status: **verifiziert im Code** (dekompiliertes Lua), **nicht im Spiel getestet**.
Quellen: `Editors.FlatRide.FlatRidePlacementMode`, `Editors.TrackStation.TrackPlacementMode`,
`Editors.Track.TrackEditSelection`, `Editors.Track.TrackEditMode`, `Editors.Shared.SingleFeatureUndoablePlacementModeBase`.

**Antwort auf die Issue-Frage: Ja, alles läuft über `api.undo`** (`CreateUndoOperationsHierarchy` → `PreviewChangeList`
→ `CommitPreview` → `Checkpoint`). Der `CommitPreview`-Hook aus #1 sieht also auch Ride-Bau. Die Parameter sind aber
**native Tokens** (userdata), die man nicht serialisieren kann. Fürs Netzwerk müssen wir eine Ebene höher mitschreiben.

## Flatrides (z. B. Karussell)
```lua
cFlatRideInfo = flatrides:CreateFlatRideEditToken(sRideName)      -- neu
cFlatRideInfo = flatrides:GetFlatRideEditToken(rideEntityID)      -- verschieben
-- CreateNew(hierarchy):
hierarchy:AddCashDelta(-nPlacementCost, park.ExpenditureCategory_RideConstruction)
moveObject = hierarchy:CreateCompositeObject({})
flatrides:AddFlatRide(hierarchy, moveObject, cFlatRideInfo, editors.TerrainActionType_PathJoinPartFlatten, bTerrainEveryFrame)
moveObject:AlignCompositeRotation()
-- MoveExisting(hierarchy): wie oben, aber flatrides:MoveFlatRide(...) +
--   SceneryUtils.EditPartsAttachedToBelongingOrPlatformOwner(rideID, hierarchy, moveObject, true)
```
`flatrides = tWorldAPIs.flatrides`, Kosten über `RideDatabaseUtils.GetRideBuildCost(sRideName)`.
Danach setzt der Placement-Mode-Base die Transform des `moveObject` (wie bei Szenerie) und committed.
Nach dem Platzieren: Ein-/Ausgang (`GamefaceEntranceExitPlacement`, `ridestation:HasRideGate`) sind **eigene** Bauaktionen.

→ **Serialisierbar:** `{ sRideName, transform (Pos+Rot des moveObject) }`, beim Verschieben die Ride-Entity
(Netzwerk-ID). Das entspricht dem Szenerie-Muster von Maxi (#8).

## Achterbahnen / Tracked Rides: zwei Ebenen
**1. Ganze Bahn platzieren/verschieben** (`TrackPlacementMode`, nutzt ebenfalls `SingleFeatureUndoablePlacementModeBase`):
```lua
nCash = TrackEditCostCalculator.MoneyDeltaToBuildEntireTrack(cTrack)
hierarchy:AddCashDelta(nCash, park.ExpenditureCategory_RideConstruction)
moveObject = hierarchy:CreateCompositeObject({})
api.track.AddAndMoveTrack(hierarchy, moveObject, cTrack)   -- neu (z. B. aus Blueprint)
api.track.MoveTrack(hierarchy, moveObject, cTrack)         -- bestehende verschieben
```

**2. Stückweise bauen im Track-Editor** (`TrackEditSelection`): jede Aktion = eine eigene ChangeList:
```lua
sel = api.track.CreateSelection(track, startT, endT, sElementName, tTrackParams, tFlexiColours, bReversed, tLocalFlexicolour)
-- BeginPreview(fnAddOperations):
hierarchy = worldapi.editors:CreateUndoOperationsHierarchy()
api.track.AddSelection(hierarchy, sel, api.track.PreviewAdd, bTunnelling, bTunnelling, ignoreSelection)
hierarchy:AddCashDelta(moneyDelta, ...); hierarchy:SetCashPos(vPos)
waitToken, previewToken = api.undo.PreviewChangeList(hierarchy:GetFullUndoChangeList())
-- beim Bestätigen: api.undo.CanCommitPreview → api.undo.CommitPreview(previewToken) → api.undo.Checkpoint({})
```
Weitere Varianten im selben Muster: `CreateStation`, `CreateSpecial` (Loopings usw.), `CreateModifiedBankSelection`,
`CreateTranslatedSelection`, `CreateRescaledSelection`, `CreateSmoothedSelection`, `CreateModifiedStartSelection`,
`CreateTrainOnTrack`, `DeleteTrack`, Auto-Complete (`TrackAutoComplete`). Parameter sind Spline-Positionen
(`startT`/`endT`/`midT`), Element-Namen, Track-Params-Tabellen und Farben, also **meist serialisierbar**.
`track` ist aber ein natives Handle (Mapping über die Track-Entity-ID nötig).

## Empfehlung fürs Netzwerk
- Phase 1: Flatrides wie Szenerie behandeln (Name + Transform).
- Achterbahnen: **nicht** jede Editor-Operation nachspielen, sondern nach dem Commit den **gesamten Track-Zustand**
  übertragen (Blueprint-artig) und auf der Gegenseite per `AddAndMoveTrack` bzw. Ersetzen anwenden.
  Noch offen: Wie bekommt man einen Track serialisiert (`api.track`/Blueprint-API)? Nächster Forschungsschritt.
- Hook-Punkte: `TrackEditSelection.BeginPreview` (bekommt alle Parameter als Closure) bzw. die `api.track.Create*`-Aufrufe.
