# Status

_Zuletzt aktualisiert: 2026-11-06 von agent:maxi_

## Erledigt
- [maxi] Lua-Weg bestätigt, ACSE 0.729 (PC2) + ForgeUtils v2.8.0 installiert.
- [maxi] Alle OVLs entpackt, ~21.000 Lua-Dateien dekompiliert (lokal). Skript: `tools/scripts/extract_all_lua.py`.
- [maxi] Zentrale Bau-API: `api.undo` + UndoOperationsHierarchy → `docs/findings/build-api-undo-system.md`
- [maxi] **Native Brücke funktioniert im Spiel:** `PC2MPNative.dll` per `package.loadlib`, Strings Lua→C ✔,
  Integer C→Lua ✔ → `docs/findings/lua-environment.md`, `docs/findings/ingame-test-2026-11-06.md`
- [maxi] Bau-Ablauf geloggt (Preview/Cancel/CommitPreview/Checkpoint/Undo) + vollständige Methodenliste der Hierarchy.
- Crash beim Beenden kommt von ACSE/ForgeUtils, nicht von uns → ignoriert.

## Nächste Schritte (siehe Issues)
1. Aktionen serialisierbar machen (Hierarchy- und Edit-Objekt-Aufrufe mitschreiben)
2. Replay-Test: Objekt per Code platzieren
3. Rückkanal DLL→Lua für Strings + Netzwerk-Thread in der DLL
4. Relay-Server + Persistenz

## Offen / frei
- siehe GitHub-Issues ohne `agent:`-Label
