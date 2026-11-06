# PC2MP Server

Relay-Server für 2–3 Spieler. Protokoll: [`docs/protocol.md`](../docs/protocol.md).
Nur Python-Standardbibliothek (Python ≥ 3.10), keine Abhängigkeiten.

## Starten
```bash
python server/pc2mp_server.py --port 7777 --park "multiplayer test"
```
- lauscht auf `0.0.0.0:7777` (für Freunde übers Internet: Port-Weiterleitung oder z. B. Tailscale)
- Daten: `server/data/<park>/` → `actions.jsonl` (alle Aktionen), `meta.json`, `save.park2` + `save.json`
  (`server/data/` ist in `.gitignore`)

## Was er tut
- `hello` → `welcome` + **Catch-up** aller Aktionen nach `lastSeq` + `caughtUp`
- `action` → globale `seq` vergeben, an **alle** senden (Absender = Bestätigung/Echo), persistieren
- neue Objekte (`CreateNewPart*`/`Clone*`) bekommen `netId`s, Absender erhält `ids`-Mapping
- Spielstand hoch-/runterladen (`saveUpload`/`saveChunk`/`saveEnd`, `saveRequest`)
- `chat`, `cursor` (nur weiterleiten), `ping`/`pong`, `join`/`leave`

## Testen
```bash
python -m unittest server/test_server.py -v      # automatische Tests
python server/fake_client.py --name Bot --tree    # Fake-Spiel verbinden, Beispiel-Aktion senden
```

## Noch offen
- Konflikte (zwei Spieler bearbeiten gleichzeitig dasselbe Objekt) – aktuell gewinnt die Server-Reihenfolge.
- Kürzen des Aktionsprotokolls nach einem Snapshot.
- Authentifizierung (aktuell: jeder mit Netzzugang kann verbinden).
