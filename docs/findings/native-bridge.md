# Finding: Native Brücke – Strings DLL→Lua + Netzwerk (#4, #10)

Stand 2026-11-06, agent:trialalloy.
Status: **statisch verifiziert** (Disassembly der Exe) + **ohne Spiel getestet** (Fake-`lua_State`, echte Exe gemappt).
**Noch nicht im Spiel getestet** → Smoke-Test unten.

## Die Exe ist nur teilweise geschützt
- Die Lua-Implementierung liegt im **unverschlüsselten** Bereich (Section `.arch`, RVA 0x1000–0x25ab000).
  Einzelne Lib-Funktionen springen in den Denuvo-Bereich (z. B. `string.sub` = `jmp 0x14e6aa850`).
- Die `luaL_Reg`-Tabellen der Standard-Libs sind lesbar (z. B. Base-Lib @ RVA 0x2f79ca0, `loadstring` = `load`).
  Vorhanden: base, coroutine, debug, math, package, string, table, utf8. **Kein `io`/`os`.**
- `lua_*`-API ist per LTO überall inline, es gibt keine aufrufbaren `lua_pushlstring` usw.

## Gefundene interne Funktionen (eindeutige Signaturen)
| Funktion | RVA (Stand 2026-11-06) | Erkennung |
|---|---|---|
| `luaS_newlstr(L, s, len)` | 0x1e48bf0 | Prolog + `cmp r8, 0x28` (LUAI_MAXSHORTLEN = 40) |
| `luaS_new(L, s)` | 0x1e48cb0 | `mov eax,0x3521CFB3; mul edx` (= Adresse % 53, String-Cache 53×2) |
| Gegenprobe | – | `luaS_new` ruft am Ende `luaS_newlstr` auf, Ziel muss übereinstimmen |
| Stack-Stempel (global int) | 0x33856e8 | `mov eax,[g]; inc eax; mov [g],eax; mov [L-0x10],eax` (1307 Stellen) |

Frontier schreibt nach **jedem Push** einen globalen Zähler in den Extraspace `[L-0x10]`.
Die DLL macht das genauso (nur wenn der Stempel gefunden wurde). `ping` ging bei Maxi auch ohne Stempel.

## So gibt die DLL Strings zurück
1. Beim ersten `pc2mp_init()` sucht `resolve.c` die Signaturen im Exe-Image (~0,2 s, einmalig; Region für Region,
   Abbruch sobald beide Funde in derselben Region liegen und sich per Call gegenseitig bestätigen).
2. `ts = luaS_newlstr(L, s, len)` → `top->value = ts; top->tt = ts->tt | 0x40; top += 0x18;` + Stempel.
   Genau so macht es das Spiel selbst (siehe `luaB_type` @ 0x1e2fbf0). Kein GC-Schritt nötig: Der String ist
   sofort über den Stack erreichbar.
3. **Fallback**, falls ein Update die Signaturen bricht: `pc2mp_net_poll()` gibt die **Länge** als Integer zurück,
   Lua holt die Bytes mit `pc2mp_read_i64(i)` und setzt sie per `string.pack("<i8", …)` zusammen.
   `mod/PC2MP/Main/pc2mp.net.lua` macht das automatisch.

## Netzwerk (DLL)
- TCP-Client im eigenen Thread, **newline-delimited JSON**. Lua blockiert nie: `Send` reiht ein, `Poll` holt.
- Auto-Reconnect alle 2 s. Gleiches Ziel erneut `connect` → kein Reconnect (Lua-Module laufen pro Environment neu,
  die Verbindung der DLL überlebt den Wechsel Frontend → Park).
- Queues max. 64 MB je Richtung, Zeilen max. 16 MB. `\n`/`\r` in ausgehenden Nachrichten → Leerzeichen.
- Der Thread hält eine Referenz auf die DLL (`FreeLibraryAndExitThread`), damit `lua_close` die DLL nicht
  unter dem Thread entlädt.
- SEH: Unter MSVC werden nur Access Violations abgefangen. Lua-Fehler (C++-Exceptions) laufen absichtlich durch.
  Zusätzlich werden alle fremden Zeiger vor dem Lesen per `VirtualQuery` geprüft (auch im zig-Build ohne `__try`).

## API (Lua-Seite: `require("pc2mp.net")`)
```lua
local Net = require("pc2mp.net")
Net.Init()                      -- lädt DLL-Exporte, Net.bStrings = true wenn luaS_newlstr gefunden
Net.Info()                      -- Diagnose-String (gefundene RVAs)
Net.Connect("127.0.0.1", 7777)  -- nicht-blockierend
Net.Send({ t = "hello" })       -- Tabelle -> api.json.Stringify, oder fertiger String
Net.Pump(function(tMsg, sRaw) ... end, 32)  -- pro Frame im Manager:Advance
Net.Status()                    -- "idle"/"connecting"/"connected"/"retry", nWartendEin, nWartendAus
Net.LastError()
```
`api.json.Stringify(t[, bPretty]) -> ok, s` und `api.json.Parse(s) -> ok, t` (aus dem Spiel-Lua).

## Tests ohne Spiel
`native\test\run_tests.bat` (braucht zig oder MSVC + Python):
- `test_resolve`: Signatursuche gegen die echte `PlanetCoaster2.exe` (nur gemappt, nicht gestartet).
- `test_bridge`: Fake-`lua_State` im Frontier-Layout + TCP-Echo-Server: ping, Strings kurz/lang, Fallback,
  Zeilenumbrüche, kaputtes Layout crasht nicht.

## Smoke-Test im Spiel (bitte, wer ACSE hat)
Im Manager `Activate`:
```lua
local Net = require("pc2mp.net")
Log.Write("Net: " .. Net.Info())        -- erwartet: luaS_newlstr=OK rva=0x1e48bf0 ...
Net.Connect("127.0.0.1", 37777)         -- vorher: python native/test/echo_server.py 37777
Net.Send({ t = "hello", n = 1 })
```
und in `Advance`: `Net.Pump(function(t, s) Log.Write("RECV " .. s) end)` → im Log muss `RECV {"t":"hello","n":1}` erscheinen.
