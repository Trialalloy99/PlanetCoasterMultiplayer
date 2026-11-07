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

## 8. Animierte Szenerie (Schleifentyp, Auslöser) — pc2mp.sequencer
- Lesen: `sequence:IsTriggerTargetPropData(id)`, `GetTriggerTargetPropData(id)` → `{nAnimLoop, nType, ...}`,
  `GetPartTriggerControlled/GetPartTriggerDuration/GetPartTriggerStrobe(id)`
- Setzen in der Edit-Hierarchie: `SetLoopAnim(eo, n)` + `CreateEditOperationForDatastoreChange(clh, id, DatastoreChange_LoopAnim)`,
  `SetTriggerControlledMoveObject(eo, b)`, `SetTriggerBehaviourMoveObject(eo, nType)` (+ `DatastoreChange_Behaviour` /
  `DatastoreChange_TriggerControlled`), direkt: `SetTriggerDurationPart(id, n)`, `SetTriggerStrobePart(id, n)` (kein Commit!
  → wir wrappen beide Setter und `TriggerTargetPropDataChangedMessage {nPartID}`).

## 9. Event-Ablauf-Steuerung (Display-Sequencer) — pc2mp.sequencer
- `sequence:IsSequencerPropData(id)`; Einstellungen `GetSequencerTriggerSettings(id)` (Tabelle: nTriggerMode, nLoopMode,
  bRestrictActivationTimes, n*RestrictedActivationTime, tShowTimes) / `SetSequencerTriggerSettingsMoveObject(eo, t)`
  + `CreateEditOperationForSequencerDatastoreChange(clh, id, SequencerDatastoreChange_TriggerSettings)`
- Musik: `gameaudio:GetSequencerEvent(id)` / `sequence:SetSequencerCustomMusicMoveObject(eo, s)`
- Programm: `GetSequencerTriggerSequence(id)` → natives Objekt. Wurzel = Spuren (`CountItems`, `GetSequenceItemFromIndex(i)`
  → Verzögerung, Spur-Sequenz). Spur: `GetSequenceItems(true).tItemIDs`, `GetItemIsGroup(i)`, Gruppe =
  `GetSequenceItemFromIndex(i)` → Start, Unter-Sequenz; Ereignis: `GetEventItemFromIndex(i)` → PartID,
  `GetEvent{Delay,Type,Duration,Strobe,FadeDuration,FadeToColour,UIColour}WithItemID(id)`.
  Nachbau: `CreateDeepCopy` der Ziel-Sequenz, alles entfernen, `AddBlankSequenceItem(t, nColourInt, bGroup)` → (Sequenz, ItemID),
  `AddEventItem(t, nPart, nUIMode, vUIColour[, nDuration])`, `SetEvent*WithItemID`, `SetSequenceItemWithItemID`,
  `SetSequencerTriggerSequenceMoveObject(eo, oRoot)`. Ereignis-Ziele werden als netId übertragen (Testmodus: Zwilling).
- Nicht übertragen: `GetEventFlexiColoursWithItemID` (Format unklar), Kameras/Lautsprecher der Steuerung.

## 10. Zeit / Wetter (MainHUD, `api.world.GetScript(api.world.GetActive()).mainHUD`)
`ChangeSimulationSpeedSettings(bPause|nil, nIndex|nil)`, `ChangeFixedSunEnabled/ChangeFixedSunTime`,
`EnableApparentTime/ChangeApparentTimeSettings`, `SetWeatherOverride(n)`. Das HUD existiert evtl. erst nach unserem
Manager → Nachversuch alle 60 Frames. **Nicht synchronisierbar gefunden:** die Park-Uhr selbst (nur `park:GetParkDay`,
keine Setz-API; `ScenarioManager.SetParkTime` ist nur ein Szenario-Wert) und das Zufallswetter (keine Lese-API für das
aktuelle Wetter). Mit gleicher Geschwindigkeit/Pause und gemeinsamem Spielstand laufen die Uhren aber gleich schnell.

## 11. Defekte — pc2mp.breakdowns
`rides:GetAllRides()`, `rides:GetStationsForRide(id)`, `ridestation:IsBrokenDown(s)`, `ridestation:TriggerBreakdown(s)`.
Keine Message → alle 60 Frames abfragen; Station über die Weltposition zuordnen. `{op="breakdown", pos}`.
Toiletten/Shops: nur Sauberkeit/Vandalismus (`park:IsVandalised`, keine Setz-API) → `park:RepairAllVandalisedItems()` wird übertragen.

## 12. Gäste
Gäste werden im nativen Code simuliert (Zufall, tausende Entities). Keine Lua-API zum Setzen von Gäste-Zuständen
gefunden → nicht synchronisierbar ohne nativen Eingriff. Was die Gäste beeinflusst (Preise, Werbung, Sandbox-Regeln,
Zeit, Park offen/zu, Szenerie) ist synchron, die Gäste selbst laufen auf jedem Client eigenständig.

## Beobachtung im Spiel (2026-11-07, Finn, Testmodus)
Licht `bl_animated_light` (4 Farben) und 3D-Schrift-Farben: Zwilling + Farbänderungen ✔. Park-Setter 11/11 ✔.
Nebenwirkung: zwei vorhandene Bus-Gästespawner (`facility_guestspawner_coach`, PartID 3/4) wurden ebenfalls gespiegelt
(sie wurden irgendwann im Commit-Fenster festgeschrieben) → sollte ausgeschlossen werden.

## 13. Läden, Mitarbeiter, Kontostand — pc2mp.entref / pc2mp.gamestate / pc2mp.economy
- Entity-IDs sind pro Client verschieden → `pc2mp.entref`: Läden/Orte über Position (`facilities:GetAllFacilityEntityIDs`,
  `staff:GetAllStaffBuildingEntityIDs`, Fahrgeschäft-Stationen), Sortiment über `facilities:GetShopInventoryEntityID(fac)`,
  Mitarbeiter über den Namen (`staff:GetAllStaffEntities`, `GetStaffUIName`/`SetStaffUIName`).
- Läden: `facilities:SetOpen(e, b)`, `SetShouldAutoHire(e, b)`, `SetShopItemPrice(inv, i, n)`, `SetAllShopItemPrice(inv, n)`,
  `SetShopItemSold(inv, i, b)`, `SetShopIsFairPrice(inv, b)`, `SetShopItemCustomName(inv, i, s)` (FacilityInfoPopUpGameface).
  „Offen, aber kein Mitarbeiter“ ist kein eigener Zustand, sondern folgt aus offen + Personal.
- Mitarbeiter: `staff:FireStaffMember(e)`, `SetStaffUIName`, `SetStaffMemberSalaryTier`, `SetStaffMemberMonthlySalary`,
  `ScheduleAssignSpecificLocation(e, nSchedule, eOrt)`, `SetStaffMemberParkZone`.
  Einstellen (StaffPlacementMode): `GenerateRandomStaff(prefab, x, token)` → `SetStaffMemberSuspended(e, true)` →
  Absetzen: `api.transform.SetPosition`, `SetStaffMemberSuspended(e, false, pool)`, `SetStaffMemberParkZone`.
  → `{op="staff", act="hire"|"move", prefab, x, pos, name}`; der Mitspieler bekommt denselben Namen.
- Kontostand: `money:GetCash()`, `money:ModifyCash(n, park.ExpenditureCategory_Uncategorised[, false])`; keine SetCash-API.
  Kassenwart = kleinste Client-ID im Room (welcome.clients + join/leave), sendet alle 180 Frames `{op="cash", n}`,
  die anderen gleichen die Differenz an. Die Aufschlüsselung (Einnahmen/Ausgaben je Kategorie) bleibt lokal.

## 14. Gäste — Recherche
Aus Lua gibt es keine API zum Erzeugen/Entfernen/Versetzen einzelner Gäste oder zum Abschalten ihrer KI
(guests: nur `SetGuestNeed`, Spawn-Regeln/-Gewichte, `RequestSuspendGroup`/`StartUnsuspendGroup`, `SetPeepHidden`).
Der Algorithmus ist nativer C++-Code in der Denuvo-geschützten Exe → nicht auf dem Server ausführbar.
Möglicher Weg (eigenes Projekt): Host simuliert Gäste; bei den anderen Spawn aus (`SetParkOpenForGuests(false)` bzw.
Spawn-Gewichte 0) und „Puppen“ per `api.entity.InstantiatePrefab` + Positions-Stream; dafür nötig: natives RE der Gäste-Entities.
