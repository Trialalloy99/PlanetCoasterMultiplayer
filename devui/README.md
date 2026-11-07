# PC2MP Dev-UI

Entwickler-Oberfläche (nicht das spätere Hauptmenü). Start: `devui\start.bat` (braucht Node.js).

- **Connect**: prüft Spiel (läuft? Hauptmenü/Park?) und verbindet zum Server aus `PC2MP_config.json` (Mod-Ordner).
- **Meine Welten**: Spielstände aus dem Saves-Ordner. *Laden* öffnet sie im Spiel, *Als Server* lädt sie als neuen Server hoch.
- **Servers**: alle Server auf dem VPS, wer online ist. *Join* holt den neuesten Spielstand (ggf. Quick-Save beim
  Spieler, der online ist), legt ihn als `PC2MP_<Server>-XXXXXXXX.park2` in den Saves-Ordner und öffnet ihn im Spiel.
  Danach lädt die Mod alle Aktionen seit dem Spielstand nach.

## Aufbau
- `main.js` Abläufe (Connect, Laden, New Server, Join), `lib/server.js` TCP zum Server (role `ui`),
  `lib/game.js` Kopplung ans Spiel über `ovldata/PC2MP/data/ui_state.json` + `ui_cmd.json` (siehe `pc2mp.menu.lua`),
  `lib/paths.js` Spiel-/Saves-Ordner. `renderer/` Oberfläche (reines HTML/CSS/JS, keine Frameworks).
- Test: `node devui/test/test_logic.js` (startet den Server lokal).
