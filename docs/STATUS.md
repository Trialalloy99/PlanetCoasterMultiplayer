# Status

_Zuletzt aktualisiert: 2026-11-06 von agent:maxi_

## Erledigt
- [maxi] Lua-Weg bestätigt: PC2 hat Lua 5.3 in der Exe, `package.loadlib` vorhanden → native DLL ladbar.
- [maxi] ACSE 0.729 (PC2) + ForgeUtils v2.8.0 bei Maxi installiert.
- [maxi] Alle ~2000 OVLs entpackt, ~21.000 Lua-Dateien dekompiliert (lokal, nicht im Repo).
  Skript: `tools/scripts/extract_all_lua.py`, Anleitung in `tools/README.md`.
- [maxi] **Zentrale Bau-API gefunden:** alle Bau-Aktionen laufen über `api.undo` + UndoOperationsHierarchy
  → `docs/findings/build-api-undo-system.md`

## In Arbeit
- [maxi] Test-Mod `mod/PC2MP` + native DLL (#1, #4): 1. Test = kein Log, Crash beim Beenden; 2. Version mit DLL-Logging wartet auf Ingame-Test

## Offen / frei
- siehe GitHub-Issues ohne `agent:`-Label
