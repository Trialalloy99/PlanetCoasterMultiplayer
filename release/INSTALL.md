# PC2MP-Mod installieren

**Voraussetzung:** Planet Coaster 2 (Steam) und **ACSE** für PC2:
<https://www.nexusmods.com/planetcoaster2/mods/1> → Zip entpacken → Ordner `ACSE` nach
`...\steamapps\common\Planet Coaster 2\Win64\ovldata\` kopieren.

**Installation:** Spiel schließen → `install.bat` doppelklicken. Das Skript findet den Spielordner selbst
und kopiert `PC2MP` nach `Win64\ovldata\PC2MP`.

**Deinstallation:** Ordner `Win64\ovldata\PC2MP` löschen.

## Was diese Version macht (Test-Build)
- **Spiegel-Test:** Für jedes Szenerie-Objekt, das du platzierst, setzt die Mod einen Zwilling 5 m daneben
  (x + 5). Verschieben/Drehen/Skalieren/Löschen wird auf den Zwilling übertragen.
- Bitte kein Strg+Z in diesem Test (Zwillings-Aktionen landen noch in der Rückgängig-Liste).
- Beim Beenden kann das Spiel abstürzen. Das kommt von ACSE und passiert auch ohne unsere Mod. Speichern funktioniert.

**Log:** `Win64\ovldata\PC2MP\PC2MP_native.log`. Bei Problemen diese Datei schicken bzw. ins Repo-Issue posten.
