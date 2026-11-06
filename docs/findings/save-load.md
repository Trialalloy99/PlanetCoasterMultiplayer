# Finding: Spielstände laden/speichern + Mapping-Persistenz (#3, #14)

Stand 2026-11-07, agent:trialalloy. Status: **verifiziert im Code** (dekompiliertes Lua), DLL/Lua **ohne Spiel getestet**,
**nicht im Spiel getestet**.
Quellen: `Managers.ParkLoadSaveManager`, `Helpers.ParkLoadSaveHelper`, `Game.Components.StandaloneScenerySerialisation`.

## Wo liegen Spielstände?
`%USERPROFILE%\Saved Games\Frontier Developments\Planet Coaster 2\<SteamID>\Saves\`
- Parks: `<Name>-<8 Hex>.park2` (~5–7 MB, **eine** Datei), Autosave `-XXXXXXXX.prkauto2`, Blueprints `.blpr2`.
- Steam-Cloud (`steam_autocloud.vdf`) synchronisiert den Ordner.

## Speichern/Laden per Code
Zugang: `tEnvironment:RequireInterface("Interfaces.IParkLoadSaveManager")` (22× im Spielcode).
| Zweck | Aufruf |
|---|---|
| Normaler Speicherplatz | `mgr:SaveParkToSaveToken(api.player.GetGameOwner(), {customname = "..."}, tMetadata, tScreenshot, bWait)` → intern `api.save.RequestSave(owner, {type="park2", oncomplete=fn})`; `oncomplete(t)` liefert `t.save` (Token) |
| Spielstand laden | `mgr:LoadParkFromSaveToken(cSaveToken)` (Token aus `api.save.GetExistingSaves_SortMostRecentFirst`, Typ `"park2"`) |
| In beliebige Datei (Dev) | `mgr:SaveParkToFile(sPfad, bCompressed)` → `worldserialisation:RequestSaveWorldToFile` + `HasSaveToFileCompleted()`; Laden: `RequestLoadParkFromFile(sPfad)` → `IsValidFile`/`LoadWorldFromFile`. VFS-Pfade mit `/run/`-Präfix, Park + **separate** Terrain-Datei. **Vermutlich in Retail abgeschaltet** wie `WriteStringToFile` → ungetestet, nicht darauf bauen. |
| Hilfen | `api.save.IsSaveToken`, `GetSaveCustomName`, `GetSaveIdentifier`, `GetSaveMetadata`, `IsBusy`, `RequestDelete` |

## Sind partIDs nach Speichern + Laden stabil? **Nein.**
Das Spiel nummeriert Entities beim Laden um. Deshalb gibt es `worldserialisation:SaveEntityID(e)` / `LoadEntityID(s)`
(Muster in `StandaloneScenerySerialisation`). Lua-Manager speichern eigene Daten **im Park-Spielstand** über
`worldserialisation:RegisterWorldSerialisationClient(sName, nVersion, fnSave(tSave), fnLoad(tLoad, nVer), fnCanLoadOld)`
(15 Manager im Spiel, z. B. `ParkRatingManager`, `ScenarioManager`).

→ **Lösung (`pc2mp.persist`, Weg 2):** Client `"PC2MPSync"` speichert `{ lastSeq, tEntries = {{netId, entity = SaveEntityID(PlacementIDToEntityID(partID))}} }`.
Beim Laden `LoadEntityID` → nach dem Laden `placement:EntityIDToPlacementID` (`Persist.ResolveLoaded()`).
Damit reist das Mapping **mit dem Spielstand** mit, auch zu Spielern, die später mit dem Host-Spielstand einsteigen.
Offen im Spiel: Lädt ein Spielstand mit PC2MP-Daten auch **ohne** die Mod? (`fnCanLoadOldVersion` ist für uns; unbekannte
Clients ignoriert das Spiel vermutlich, bitte testen.) Registrieren am besten in `Manager.Init` (vor dem Laden).

Weg 1 (zusätzlich, wie in #14 gewünscht): JSON `ovldata/PC2MP/data/state_<park>.json` über die DLL, gedrosselt.

## DLL-Exporte (alle nicht-blockierend außer Hash/Datei-I/O, kleine Dateien)
| Export | Rückgabe |
|---|---|
| `pc2mp_write_file(name, data)` / `pc2mp_read_file(name)` | 1/0 bzw. String\|nil. Nur `data\`, Name `[A-Za-z0-9_.-]` (kein `..`, kein führender Punkt), ≤16 MB, atomar (tmp + `MoveFileEx`) |
| `pc2mp_saves_dir()` | Saves-Ordner des zuletzt benutzten Profils |
| `pc2mp_save_list()` | JSON `[{name,size,mtime}]`, nur `.park2`, neueste zuerst |
| `pc2mp_save_info(name)` | JSON `{name,size,sha256,chunks,chunkSize}` (SHA-256 per BCrypt) |
| `pc2mp_save_read_chunk(name, i)` | base64 von Chunk i (512 KiB roh = `saveChunk` aus `docs/protocol.md`) \| nil |
| `pc2mp_save_write_chunk(name, i, b64)` | 1/0, schreibt nach `data\incoming_<name>.part` |
| `pc2mp_save_finish(name, sha256)` | 1/0, prüft Hash, verschiebt nach Saves. **Überschreibt nie** einen vorhandenen Spielstand |
| `pc2mp_save_abort(name)`, `pc2mp_file_error()` | verwerfen / letzter Fehlertext |

Review-Hinweis aus #12 umgesetzt: Stack-Stempel wird nur geschrieben, wenn `0 <= Zähler - [L-0x10] < 2^30`.

## Empfohlener Ablauf „Einsteigen“
1. Host: `SaveParkToSaveToken(owner, {customname="PC2MP <park>"}, …, true)` → `oncomplete` → `Persist.SaveList()` (neueste Datei)
   → `Persist.SaveInfo` → `saveUpload {seq, name, size, sha256}` + `saveChunk` (Persist.ReadSaveChunk) + `saveEnd`.
2. Neuer Spieler: `saveRequest` → Chunks mit `Persist.WriteSaveChunk` → `Persist.FinishSave(name, sha256)`.
3. **Offen (im Spiel testen):** Erkennt das Spiel eine neu hinzugekommene `.park2` ohne Neustart?
   (`api.save.GetExistingSaves*` neu abfragen; sonst Spiel neu starten.) Dann `LoadParkFromSaveToken(token)`.
4. Nach dem Laden: `Persist.ResolveLoaded()` liefert das Mapping des Hosts (mit neuen partIDs), `hello.lastSeq` = Save-`seq`.

## Tests
- `native\test\run_tests.bat` → `test_files`: Datendateien, abgelehnte Namen (`../`, `a\b`, `.hidden`, …), Spielstand-
  Roundtrip mit 1,3 MB (Liste, SHA-256 = Python, 3 Chunks, falscher Hash abgelehnt, nie überschreiben). Nur in Temp-Ordnern
  (`PC2MP_TEST_SAVES_DIR`, existiert nur im Test-Build).
- `python mod/tests/test_persist.py` (Lua 5.3 via lupa): 18 Checks inkl. Chunk-Fallback und Umnummerierung beim Laden.
