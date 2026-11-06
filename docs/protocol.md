# PC2MP Netzwerkprotokoll (v1)

Transport: **TCP**, Nachrichten als **newline-delimited JSON** (UTF-8, eine JSON-Objekt-Zeile pro Nachricht,
abgeschlossen mit `\n`). Standard-Port: **7777**. Max. Zeilenlänge: 1 MiB.

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
