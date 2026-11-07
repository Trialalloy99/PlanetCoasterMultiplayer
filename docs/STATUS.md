# Status

_Zuletzt aktualisiert: 2026-11-07 von agent:trialalloy_

## Erledigt
- [maxi] Lua-Weg bestätigt, ACSE 0.729 (PC2) + ForgeUtils v2.8.0 installiert.
- [maxi] Alle OVLs entpackt, ~21.000 Lua-Dateien dekompiliert (lokal). Skript: `tools/scripts/extract_all_lua.py`.
- [maxi] Zentrale Bau-API: `api.undo` + UndoOperationsHierarchy → `docs/findings/build-api-undo-system.md`
- [maxi] **Native Brücke funktioniert im Spiel:** `PC2MPNative.dll` per `package.loadlib`, Strings Lua→C ✔,
  Integer C→Lua ✔ → `docs/findings/lua-environment.md`, `docs/findings/ingame-test-2026-11-06.md`
- [maxi] Bau-Ablauf geloggt (Preview/Cancel/CommitPreview/Checkpoint/Undo) + vollständige Methodenliste der Hierarchy.
- Crash beim Beenden kommt von ACSE/ForgeUtils, nicht von uns → ignoriert.

- [maxi] **Server fertig (v1)** (#11): `server/pc2mp_server.py`, Protokoll `docs/protocol.md`, 6 Tests grün,
  `server/fake_client.py` zum Testen ohne Spiel.
- [trialalloy] **#2 Rides erforscht:** Flatrides + Achterbahnen laufen auch über `api.undo` (Parameter sind native
  Tokens → eine Ebene höher mitschreiben) → `docs/findings/rides.md`
- [trialalloy] **#10 Netzwerk-DLL fertig (PR #12, Ingame-Test offen):** `luaS_newlstr` per Signatur zur Laufzeit
  gefunden → Strings DLL→Lua (Fallback: Chunks). TCP-Thread (NDJSON, Auto-Reconnect, Hello bei jedem Connect),
  Lua-Wrapper `pc2mp.net.lua`. Getestet gegen echte Exe (gemappt) + echten Server inkl. Neustart
  → `docs/findings/native-bridge.md`

- [trialalloy] **PR #16 Crash-Fix:** Einfügen mehrerer Objekte → nativer Absturz in `api.undo.IsOperationComplete`
  (ungültiger Token, Replay-Preview parallel zur Spiel-Operation). Neues `pc2mp.undoguard` (keine Änderung an replay/events/sync).
- [trialalloy] **PR #17 Persistenz (#14/#3):** DLL-Datei- + Spielstand-Transfer-Exporte, `pc2mp.persist`
  (JSON + worldserialisation-Client im Spielstand; partIDs sind nach dem Laden NICHT stabil) → `docs/findings/save-load.md`

- [trialalloy] **PR #18 Wege + Terrain (#15):** `pc2mp.worldedit` erfasst Terrain-Pinselstriche (gebündelt) und Wege
  (Volume-Umrisse), spielt sie nach (Spiegel x+25 ohne Config). Offline getestet, **wartet auf Ingame-Test durch agent:maxi**
  (Anleitung im PR), danach Einbau in `pc2mp.sync`.
- [trialalloy] Ingame bestätigt (Finn, v0.2.1-mp): `luaS_newlstr=OK`, `Sync: verbunden als c4`, Catch-up ok.
  Exit-Absturz `exe+0x14fdf62` = ACSE (bekannt).
- Neu: #19 Zeit synchronisieren (Geschwindigkeit/Pause, Tageszeit, Wetter) → agent:trialalloy

- [trialalloy] **PR #20 WorldEdit-Fixes, im Spiel bestätigt (Spiegel x+25):** Terrain 16/17, Wege (Spline) 5/5 nachgebaut.
  Behebt: Netz-Aktionen nie angewendet (api.json-String-Schlüssel), leere Terrain-Aktionen, Spline-Wege ohne Daten.
  Persistenz (#14) im Spiel bestätigt: 619 Zuordnungen im Spielstand. → **gemergt von agent:maxi, Release v0.4.1-mp** (alle Mod-Tests grün).

## In Arbeit
- [trialalloy] **Objekt-Eigenschaften + Einstellungen + Testmodus** (Branch `trialalloy/props-settings`, offline getestet,
  **Ingame-Test offen**): Farben/Lichtfarbe, Lichtmuster, Name in `upsert.props`; Park öffnen/Name/Preise,
  Sandbox-Einstellungen, Werbung (GuestBucketManager) als `op="call"`; Wege-Spiegel verschob Farben (Bug behoben);
  Dev-UI-Tab „Testmodus“ (Zwilling im eigenen Park, kein zweiter Spieler nötig) → `docs/findings/props-settings.md`
- [maxi] **#21 Dev-UI + zentraler Server (Rooms)**, gemergt: Hauptmenü-Steuerung im Spiel bestätigt (Welten auflisten,
  per Befehl laden). Server mit Rooms live auf dem VPS. `devui/` (Electron), Join, New Server, Auto-Upload nach Speichern,
  Quick-Save beim Join (`pc2mp.saveupload`) – **Join/Upload/Quick-Save im Spiel noch NICHT getestet.**
  Offen: ob das Spiel einen neu heruntergeladenen Spielstand ohne Neustart erkennt; „letzter Spieler speichert beim Verlassen“.
- [maxi] #8 Capture-Modul `mod/PC2MP/Main/pc2mp.capture.lua` (ACTION-JSON pro Commit) – gebaut, wartet auf Ingame-Test
- [trialalloy] PR #12 → Ingame-Smoke-Test (braucht jemanden mit ACSE, Anleitung in native-bridge.md), danach #3 Save/Load

## Nächste Schritte
1. #9 Replay-Test: Objekt per Code aus ACTION-Datensatz platzieren
2. PR #12 mergen → Lua-Mod ↔ Server verbinden (`Net.SetHello` + `Net.Pump` im Manager)

## Offen / frei
- siehe GitHub-Issues ohne `agent:`-Label
