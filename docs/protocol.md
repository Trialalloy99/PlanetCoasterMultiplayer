# PC2MP Netzwerkprotokoll (v1)

Transport: **TCP**, Nachrichten als **newline-delimited JSON** (UTF-8, eine JSON-Objekt-Zeile pro Nachricht,
abgeschlossen mit `\n`). Standard-Port: **7790** (VPS-Deployment, siehe server/deploy). Max. Zeilenlänge: 1 MiB.

Jede Nachricht hat ein Feld `"t"` (Typ). Client = Spiel (über `PC2MPNative.dll`), Server = `server/`.

## Verbindungsaufbau
```
C→S {"t":"hello","v":1,"name":"Maxi","park":"multiplayer test","lastSeq":0}
S→C {"t":"welcome","v":1,"clientId":"c2","serverSeq":42,"park":"multiplayer test","clients":[{"clientId":"c1","name":"Finn"}],"hasSave":true}
```
- `lastSeq`: höchste Server-Sequenznummer, die der Client schon kennt (0 = nichts). Der Server schickt danach
  alle `action`s mit `seq > lastSeq` aus dem Protokoll nach (**Catch-up**), dann `{"t":"caughtUp","serverSeq":N}`.
- Versionskonflikt → `{"t":"error","code":"version","msg":...}` und Verbindung wird geschlossen.

## Aktionen (Kern)
```
C→S {"t":"action","cseq":7,"action":{...}}
S→C (an ALLE, auch den Absender) {"t":"action","seq":43,"clientId":"c2","cseq":7,"action":{...}}
```
- `cseq`: laufende Nummer des Clients (damit er seine eigene Bestätigung erkennt → Echo-Schutz).
- `seq`: globale, lückenlose Server-Sequenz = **verbindliche Reihenfolge** für alle.
- Der Absender erhält seine eigene Aktion zurück (Bestätigung) und spielt sie **nicht** erneut ab.
- `action` ist der Datensatz aus der Lua-Mod (`pc2mp.capture`), z. B.
  `{"op":"commit","calls":[{"m":"CreateNewPart","a":{"1":"SceneryTree_Oak_03"}}],"objects":[{"partID":123,"pos":[x,y,z],"rot":[ax,ay,az],"scale":1}]}`
  bzw. `{"op":"undo"}` / `{"op":"redo"}`.

## Netzwerk-IDs
Lokale `partID`s unterscheiden sich pro Client. Der Server vergibt beim Weiterleiten für jedes **neu erzeugte**
Objekt eine globale ID:
- Felder `objects[i].partID` des Absenders werden als `localId` übernommen, der Server fügt `netId` hinzu
  (`"n17"`), und sendet das Mapping zurück: `S→C {"t":"ids","seq":43,"map":[{"localId":123,"netId":"n17"}]}` (nur an den Absender).
- Empfänger merken sich nach dem Nachspielen `netId → eigene partID`.
- Bei `EditExistingPart`/`DestroyExistingPart` übersetzt der **Client vor dem Senden** seine partID → netId
  (Feld `netIds` in der Aktion). Der Server leitet unverändert weiter.
(Details werden mit Issue #8/#9 konkretisiert; der Server behandelt `action` ansonsten als undurchsichtige Nutzlast.)

## Spielstand (Persistenz / Einsteigen)
```
C→S {"t":"saveUpload","seq":43,"name":"multiplayer test.park2","size":4429570,"sha256":"..."}
C→S {"t":"saveChunk","i":0,"data":"<base64, max 512 KiB roh>"} ...
C→S {"t":"saveEnd"}
S→C {"t":"saveStored","seq":43}
C→S {"t":"saveRequest"}
S→C {"t":"saveBegin","seq":43,"name":...,"size":...,"sha256":...}, {"t":"saveChunk",...}*, {"t":"saveEnd"}
```
- `seq` = Server-Sequenz, bis zu der der Spielstand alle Aktionen enthält. Ein neuer Client lädt den Spielstand und
  holt mit `hello.lastSeq = <save seq>` nur die Aktionen danach nach.
- Der Server kann das Aktionsprotokoll bis zum ältesten benötigten Snapshot kürzen (später).

## Sonstiges
```
C→S {"t":"ping","time":123}                 S→C {"t":"pong","time":123}
C→S {"t":"chat","text":"hi"}                S→alle {"t":"chat","clientId":"c2","name":"Maxi","text":"hi"}
C→S {"t":"cursor","pos":[x,y,z]}            S→andere {"t":"cursor","clientId":"c2","pos":[x,y,z]}   (nicht gespeichert)
S→alle {"t":"join","clientId":"c3","name":"..."} / {"t":"leave","clientId":"c3"}
S→C {"t":"error","code":"...","msg":"..."}
```

## Persistenz auf dem Server (Dateien in `server/data/<park>/`)
- `actions.jsonl` – jede weitergeleitete `action`-Nachricht (mit `seq`) als Zeile, append-only.
- `meta.json` – `serverSeq`, `nextNetId`, Info zum letzten Spielstand.
- `save.park2` (+ `save.json` mit `seq`, `sha256`).

## Aktionsformat der Mod (v1, pc2mp.sync)
```
{"op":"upsert","localId":1185,"origin":"<instanz>","resource":"NAT_Tree_...","pos":[x,y,z],"rot":[ax,ay,az],"scale":1.0}
   -> Server vergibt netId ("n1"), Absender bekommt {"t":"ids","map":[{"localId":1185,"netId":"n1"}]}
{"op":"upsert","netId":"n1","origin":"...","resource":...,"pos":...,"rot":...,"scale":...}   (Änderung)
{"op":"remove","netId":"n1","origin":"..."}
```
- `origin` = zufällige Kennung der Spielsitzung; Clients ignorieren Aktionen mit eigenem origin (auch im Catch-up).
- `rot` = Rotation als „packed axis angle“ (`Quaternion:ToPackedAxisAngle()` / `Quaternion.FromPackedAxisAngle`).
- Undo/Redo werden NICHT als eigene Ops gesendet, sondern als der resultierende upsert/remove.
- `upsert` kann `props` enthalten (Farben inkl. Lichtfarbe, Lichtmuster, Atmosphäre, Name, pc2mp.props):
  `"props":{"colours":[{"tag":"<SemanticTag>","c":[r,g,b]}],"cookie":"<Muster>","atmos":2,"name":"..."}`
- Park-Einstellungen, Sandbox-Einstellungen, Werbung (pc2mp.gamestate):
  `{"op":"call","k":"ads.SetAdvertisingActive","a":[1,true],"n":2}`. Nur Schlüssel aus der Whitelist
  `pc2mp.gamestate.tTargets` werden angewendet. Siehe `docs/findings/props-settings.md`.

## Rooms / Dev-UI (seit #21)
Der Server hält mehrere **Rooms** (= Welten, in der UI „Servers“), je Ordner `data/<name>/` mit `actions.jsonl`, `meta.json`,
`save.park2` + `save.json`, `backups/` (letzte 5 Spielstände). Neue Rooms vergeben netIds mit Präfix (`r3f9a1cn1`).
- **Spiel-Client:** `hello.park` = Room-Name (wird angelegt, falls neu). Die Mod setzt ihn beim Join aus der UI.
- **UI-Client:** `{"t":"hello","v":1,"name":"Maxi","role":"ui"}` → `welcome{role:"ui"}` + `rooms`.
```
C→S {"t":"listRooms"}       S→C {"t":"rooms","rooms":[{"name","online":[..],"serverSeq","hasSave","saveSeq","saveTime","saveSize","pending","saving"}]}
                            (wird an alle UIs bei jeder Änderung geschickt)
UI→S {"t":"saveUpload","room":"X","create":true,...} + saveChunk* + saveEnd   → S→UI {"t":"saveStored","seq":0,"room":"X"}
UI→S {"t":"saveRequest","room":"X"}                                            → saveBegin{room,...}, saveChunk*, saveEnd
UI→S {"t":"joinPrepare","room":"X"}
   niemand online:  S→UI {"t":"saveReady","room":"X","hasSave":true,"saveSeq":N,"fresh":false,"pending":K}
   jemand online:   S→UI {"t":"waitingForSave","room":"X","saver":"Finn"}
                    S→Spieler {"t":"quickSave","seq":N,"by":"Maxi"}  → Spieler lädt hoch (saveUpload/saveChunk/saveEnd)
                    oder {"t":"quickSaveFailed","msg":..}; Timeout 90 s → letzter Spielstand
                    S→UI saveReady{fresh:true}
```
- Während eines Quick-Saves hält der Server neue `action`s zurück und spielt sie danach mit seq > saveSeq ein.
- Spieler laden nach **jedem** Speichern automatisch hoch (`pc2mp.saveupload`): `saveUpload{seq = lastSeq des Spiels}`;
  der Server nimmt `min(seq, serverSeq)` bzw. beim Quick-Save die seq zum Zeitpunkt der Anfrage.
