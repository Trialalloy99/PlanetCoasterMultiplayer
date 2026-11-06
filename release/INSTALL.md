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
**Alle brauchen dieselbe Startwelt** (neue Sandbox-Parks werden zufällig generiert und sind nie gleich!):
1. Server-Daten leeren (Maxi/Claude).
2. Spieler A legt einen neuen Park an, **speichert sofort** (ohne zu bauen) und lädt ihn hoch:
   `python server/save_tool.py upload --host <server-ip> "<Saves-Ordner>\<park>.park2"`
   (Saves-Ordner: `python server/save_tool.py savesdir`)
3. Spieler B lädt ihn herunter (landet direkt im eigenen Saves-Ordner):
   `python server/save_tool.py download --host <server-ip>`
4. Beide laden **diesen** Spielstand. Ab dann wird gebaut und synchronisiert.
**Weiterspielen (ab v0.3):** Einfach im Spiel speichern. Die Zuordnungen der Objekte stecken im Park-Spielstand, und beim nächsten Laden holt die Mod nur verpasste Aktionen nach (kein doppeltes Bauen).
- Synchronisiert: Szenerie-Objekte platzieren, verschieben, drehen, skalieren, löschen; **Terrain** (alle Pinsel) und **Wege zeichnen** (neu, noch experimentell).
- **Strg+Z / Strg+Y** machen nur **deine eigenen** Aktionen rückgängig, und das bei allen.
- Noch nicht synchronisiert: Wege löschen/ändern, Wasser, Fahrgeschäfte, Achterbahnen, Geld, Gäste, Tageszeit.
- Strg+Z gilt nur für Szenerie (nicht für Terrain/Wege).
- Beim Beenden kann das Spiel abstürzen. Das kommt von ACSE, Speichern funktioniert.

**Log:** `Win64\ovldata\PC2MP\PC2MP_native.log` (Zeilen mit `Sync:` zeigen Verbindung und Aktionen).
