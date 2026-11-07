# Finding: Objekt-Eigenschaften, Wegtyp, Park-Einstellungen, Marketing

Stand 2026-11-07, agent:trialalloy. **Verifiziert im dekompilierten Lua + Namen in der Exe, noch NICHT im Spiel getestet.**
Umsetzung: `pc2mp.props`, `pc2mp.gamestate`, `pc2mp.testmode` (Branch `trialalloy/props-settings`).

## 1. Farben (auch Lichtfarbe) = FlexiColour
Lichter haben keine eigene Farb-API: die Lichtfarbe ist ein FlexiColour-Kanal wie bei jeder Szenerie.
- Lesen: `tWorldAPIs.scenery_flexicolour:GetFlexiColourForPartID(nPartID)`
  → `{ [sSemanticTag] = { [i] = { vColour = Vector3 | "ambiguous" } } }`
- Setzen (Muster aus `Editors.Scenery.SubModeSelect.SetFlexiColour`):
  ```lua
  local co = clh:EditExistingParts(partSet, token)  -- warten bis HaveRequestsCompleted
  clh:StartEditingParts_Scenery(co)
  scenery_flexicolour:SetFlexiColourForPartSet(clh, partSet, sSemanticTag, Vector3:new(r, g, b))
  -- danach PreviewChangeList -> CommitPreview wie gewohnt
  ```
- Message bei Änderung: `MaterialChangedGameMessage { nEntityID }` (feuert auch während der Vorschau des
  Farbwählers → wir melden erst nach einem Spieler-Commit).
- Exe enthält außerdem `SetFlexiColourForPartID`, `GetDefaultFlexiColourForPartID` (nicht aus Lua benutzt).

## 2. Licht-Einstellungen
- Lichtmuster (Spotlight-Cookie): `scenery:IsCustomisableLight(nEntityID)`, `scenery:GetLightCookieName(nPartID)`,
  `scenery:SetLightCookieName(editObject, sName)` (in einer Edit-Hierarchie, `AnimatedSceneryInfoPopUpGameface`).
- Exe kennt `GetLightIntensity`/`SetLightIntensity` (`CustomLightIntensity`), aber kein Lua-Aufrufer → Signatur unbekannt, nicht umgesetzt.
- Atmosphäre: `scenery:GetSceneryAtmosphereType(nPartID, true)` / `SetSceneryAtmosphereType(nPartID, n)` (direkt, ohne Undo, ohne Message).
- Name: `scenery:GetRawNameOverride(nPartID)` / `OverridePropName(nPartID, s)`; `UserRenameMessage {eType, name, id}`.

## 3. Wege: Typ, Belag, Rand, Farben, Extras
- Die Editor-Einstellungen sind globale „Volatile Config“ (`volumes:SetVCOutlineType/SetVCEdgeType/SetVCAddRails/...`,
  alle Getter `GetVC*` existieren in der Exe). **Sie werden beim Nachbauen aber nicht gebraucht**, weil die Editoren
  die Werte explizit übergeben:
  - Spline: `volumes:SetSplinePathData(mo, sOutlineType, sRenderType, sEdgeType, nRadius, nDepth, nClipPriority,
    nGroundedRequest, bDeploySupports, vOutlineColour, vEdgeColour)` + `SetSplineBorderData(...)` (gleiche Form)
  - Umriss: die Outline-Tabelle enthält `sOutlineType`, `sRenderType`, `vOutlineColour`, pro Punkt `sEdgeType`, `vEdgeColour`
  → pc2mp.worldedit erfasst das schon (#15). **Bug behoben:** der Spiegel-Versatz (+x) wurde auch auf Farb-Vektoren
  angewendet (Weg-Farbe im Testmodus falsch). Jetzt werden Schlüssel mit „Colour“ nie verschoben.
- Weg-Extras (Bänke/Lampen entlang des Splines): `scenery_volumeextras:GetVC_Path_Spline({})` → `{bActive,
  sSceneryResourceName, nPlacementStyle, nSegmentSize, nDegreesRotationFromForward}`; der Lua-Helper
  `Editors.Scenery.VolumeExtraPlacementHelper` erzeugt sie mit `clh:CreateNewParts(...)` **in derselben Hierarchie**
  → sie kommen als normale `PlacementPartCommittedMessage` und werden wie Szenerie gesynct (kein Doppel, weil unser
  Weg-Replay den Helper nicht ausführt).
- Noch nicht erfasst: Wege löschen/radieren (`volumes:EraseDrawing`, `clh:RemoveVolume`), Wege verschieben
  (`CreateMoveObjectsForSelection`).

## 4. Park-Einstellungen (tWorldAPIs.park, native)
Aus `Editors.Park.GamefaceParkOptionsEventHandler`, `MainHUDGameface.OpenClosePark`:
`SetParkOpenForGuests(b)`, `SetParkName(s)`, `SetParkEntranceAdultTicketPrice(n)`, `SetParkEntrancePriceState(n)`,
`SetFastPassTicketPrice(n)`, `SetFastPassTicketPriceState(n)`, `SetPoolPassPrice(n)`, `SetPoolPassPriceState(n)`.
`ScenarioManager` ruft einige davon beim Laden → die ersten 300 Frames werden nicht gesendet.

## 5. Sandbox-/Welt-Einstellungen
`Interfaces.ISandboxSettingsManager:SetSandboxSettings(tSettings)` (Pausemenü `SandboxPauseMenuHUD`), Tabelle aus
einfachen Werten (`bEnabledRain`, `nDifficulty`, …, siehe `Helpers.SandboxSettings.SettingsData`).

## 6. Marketing / Werbekampagnen
Die Kampagnen-Funktionen in `Managers.MarketingManager` (`StartMarketingCampaign` usw.) sind in PC2 **leere Stubs**.
Echte Werbung (`Editors.Park.MarketingEventHandlerGameface`):
`Interfaces.IGuestBucketManager:SetAdvertisingActive(nBucketIndex, b)` und `SetCurrentCostPerHour(nBucketIndex, n)`
(→ `MarketingUpdateMessage`). Gästegruppen (Buckets) kommen aus dem Spielstand, Index ist also auf allen Clients gleich.

## 7. Interfaces abfangen
`Environment:RequireInterface` liefert im Debug-Build einen unveränderlichen Proxy
(`getmetatable(proxy).tObject` = echtes Objekt), im Release-Build das Objekt selbst (`Environment.Utils`).
Methoden deshalb auf dem echten Objekt per `rawset` überschreiben, nicht auf dem Proxy.

## Protokoll
- `upsert` hat optional `props = { colours = {{tag, c={r,g,b}}...}, cookie, atmos, name }`
- neu: `{ op = "call", k = "<Schlüssel aus pc2mp.gamestate.tTargets>", a = {Argumente}, n = Anzahl }`
  Nur Schlüssel aus der Whitelist werden angewendet. Der Server reicht beides unverändert durch.

## Bekannte Lücke
Objekte aus dem Basis-Spielstand (vor dem Multiplayer gebaut) haben keine netId. Ändert man sie (auch die Farbe),
schickt Sync ein `upsert` mit `localId` → beim Mitspieler entsteht ein Duplikat. Betrifft Verschieben schon vorher.
