# PC2MP-Mod installieren

**Voraussetzung:** Planet Coaster 2 (Steam) und **ACSE** für PC2:
<https://www.nexusmods.com/planetcoaster2/mods/1> → Zip entpacken → Ordner `ACSE` nach
`...\steamapps\common\Planet Coaster 2\Win64\ovldata\` kopieren.

**Installation:** Spiel schließen → `install.bat` doppelklicken. Das Skript findet den Spielordner,
kopiert `PC2MP` nach `Win64\ovldata\PC2MP` und fragt nach **Server-Adresse**, **Name** und **Park-Name**.
Die Werte landen in `Win64\ovldata\PC2MP\PC2MP_config.json` (nur lokal). Ohne Server-Adresse läuft der
lokale Spiegel-Test (Zwilling 5 m daneben).

**Deinstallation:** Ordner `Win64\ovldata\PC2MP` löschen.

## Multiplayer (v0.2, Szenerie)
- **Alle** starten einen **neuen, leeren Park** (gleiche Karte/Vorlage) und verbinden sich mit demselben Server.
  Was schon auf dem Server liegt, wird beim Laden nachgebaut. (Bestehende Parks weiterspielen kommt mit #14.)
- Synchronisiert: Szenerie-Objekte platzieren, verschieben, drehen, skalieren, löschen.
- **Strg+Z / Strg+Y** machen nur **deine eigenen** Aktionen rückgängig, und das bei allen.
- Noch nicht synchronisiert: Wege, Terrain, Fahrgeschäfte, Achterbahnen, Geld, Gäste.
- Beim Beenden kann das Spiel abstürzen. Das kommt von ACSE, Speichern funktioniert.

**Log:** `Win64\ovldata\PC2MP\PC2MP_native.log` (Zeilen mit `Sync:` zeigen Verbindung und Aktionen).
