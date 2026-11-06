# Architektur (Entwurf)

```
Spiel (Lua-Mod)                       C++-DLL (native)              Server
──────────────                        ────────────────              ──────
ForgeUtils-HookManager auf            per package.loadlib geladen   Spielstand + Aktionsprotokoll
api.undo / UndoOperationsHierarchy    (wie ACSEDebug.dll)           vergibt globale Netzwerk-IDs
 → Aktion serialisieren   ──────────▶  TCP/WebSocket senden  ────▶  verteilt an alle Clients
 ← Aktion nachspielen     ◀──────────  empfangen, Queue      ◀────
   (CreateNewPart → Transform → PreviewChangeList → CommitPreview)
```

## Grundsätze
- **Command Replication statt Speicher-Sync:** synchronisiert werden Bau-Aktionen auf Lua-Ebene,
  nicht RAM-Inhalte.
- **Netzwerk-IDs:** lokale PartIDs/EntityIDs unterscheiden sich pro Client → Server vergibt globale IDs,
  jeder Client hält eine Mapping-Tabelle.
- **Echo-Schutz:** Aktionen, die von Remote kommen, werden nicht erneut gesendet.
- **Phase 1 nur Bauen:** Szenerie, Wege, Terrain, Fahrgeschäfte. Gäste und Wirtschaft simuliert jeder lokal
  (oder ein Host ist maßgeblich und sendet z. B. das Geld).
- **Persistenz:** Basis-Spielstand + Aktionsprotokoll + regelmäßige Snapshots auf dem Server.
  Wer später einsteigt, lädt den Spielstand und spielt die restlichen Aktionen nach.

## Werkzeuge
- ACSE (PC2-Version, Nexus) + ForgeUtils (GitHub Distantz/ForgeUtils) im Ordner `Win64/ovldata`
- Cobra Tools (OpenNaja/cobra-tools, Python 3.11) zum Entpacken/Packen von OVLs und zum Dekompilieren
- Mod-Vorlage: Distantz/ACSE-Mod-Template
