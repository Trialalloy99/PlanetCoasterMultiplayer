-- Offline-Test für pc2mp.sync mit gemockten Spiel-APIs.
-- Ausführen:  tools/cobra-tools/modules/formats/utils/luadec/lua.exe mod/tests/test_sync.lua mod/PC2MP/Main
local MAIN = arg[1] or "mod/PC2MP/Main"

local function preload(name)
    package.preload[name] = function() return assert(loadfile(MAIN .. "/" .. name .. ".lua"))(name) end
end

-- ---------------------------------------------------------------- Mocks
local sent = {}
local inbox = {}
local log = {}
local world = {}   -- partID -> state (Spielwelt-Mock)
api = {
    pc2mp = nil,
    json = {
        Stringify = function(t) return true, "<json>" end,
        Parse = function(s) return true, {} end,
    },
}
package.preload["pc2mp.log"] = function()
    local L = {}
    function L.Write(s) log[#log + 1] = s end
    function L.ToStr(v) return tostring(v) end
    return L
end
package.preload["pc2mp.net"] = function()
    local N = {}
    function N.Send(m) sent[#sent + 1] = m; return true end
    function N.SetHello(m) N.hello = m; return true end
    function N.ReadConfig() return { host = "127.0.0.1", port = 7790, name = "Test", park = "p" } end
    function N.Info() return "mock" end
    function N.Connect() N.nConnects = (N.nConnects or 0) + 1; return true end
    function N.Disconnect() end
    function N.Status() return "connected", 0, 0, 1 end
    function N.LastError() return nil end
    function N.Pump(fn) while #inbox > 0 do fn(table.remove(inbox, 1)) end end
    return N
end
local ignored = {}
local listeners = {}
package.preload["pc2mp.events"] = function()
    local E = { tListeners = listeners, tKnownOriginals = {} }
    function E.DescribePart(n) local s = world[n]; if not s then return { exists = false } end
        return { exists = true, resource = s.resource, pos = s.pos, rot = s.rot, scale = s.scale } end
    function E.IgnoreFor(n, f) ignored[n] = true end
    function E.AddListener(fn) listeners[#listeners + 1] = fn end
    return E
end
local nextPart = 1000

local replayLog = {}
package.preload["pc2mp.replay"] = function()
    local R = {}
    function R.Enqueue(label, job, done)
        replayLog[#replayLog + 1] = label
        local ok, a, b = pcall(job)
        assert(ok, "Job-Fehler in " .. label .. ": " .. tostring(a))
        if done then done(ok, a, b) end
    end
    function R.DoCreate(t, before)
        nextPart = nextPart + 1
        world[nextPart] = t
        if before then before(nextPart) end
        return nextPart, true
    end
    function R.DoEdit(id, t) assert(world[id], "edit auf unbekanntes Teil " .. tostring(id)); world[id] = t; return true end
    function R.DoDestroy(id) assert(world[id], "destroy auf unbekanntes Teil " .. tostring(id)); world[id] = nil; return true end
    return R
end
local weApplied = {}
package.preload["pc2mp.worldedit"] = function()
    local W = { tListeners = {} }
    function W.Apply(a, off, done) weApplied[#weApplied + 1] = a; if done then done(true) end end
    return W
end
local suStarted = {}
package.preload["pc2mp.saveupload"] = function()
    return { OnSaveStarted = function(n) suStarted[#suStarted + 1] = n end, QuickSave = function() end, Tick = function() end }
end
preload("pc2mp.props")
preload("pc2mp.sync")

local Sync = require("pc2mp.sync")
assert(Sync.Start(), "Start fehlgeschlagen")
local Net = require("pc2mp.net")
for _ = 1, 29 do Sync.Tick() end
assert(not Net.nConnects, "darf erst nach Wartezeit verbinden")
Sync.Tick()
assert(Net.nConnects == 1, "nach 30 Frames verbunden")
local function local_action(t)
    -- der Spieler hat das im Spiel gebaut/geändert/gelöscht -> Spielwelt nachführen
    if t.op == "upsert" then world[t.partID] = t else world[t.partID] = nil end
    for _, fn in ipairs(listeners) do fn(t) end
end
local function check(c, msg) if not c then error("FEHLER: " .. msg, 2) end print("ok  " .. msg) end

-- ---------------------------------------------------------------- 1. lokales Erstellen -> localId
local_action({ op = "upsert", partID = 1, resource = "Tree", pos = { 1, 2, 3 }, rot = { 0, 0, 0 }, scale = 1 })
check(#sent == 1 and sent[1].action.localId == 1 and sent[1].action.netId == nil, "neues Objekt wird mit localId gesendet")
check(sent[1].action.origin == Sync.sInstance, "origin gesetzt")

-- Änderung bevor ids da sind -> nicht doppelt erstellen
local_action({ op = "upsert", partID = 1, resource = "Tree", pos = { 5, 2, 3 }, rot = { 0, 0, 0 }, scale = 1 })
check(#sent == 1, "Änderung vor ids wird zurückgehalten")

-- Echo + ids
inbox[#inbox + 1] = { t = "action", seq = 1, clientId = "c1", action = { op = "upsert", netId = "n1", localId = 1, origin = Sync.sInstance, resource = "Tree", pos = { 1, 2, 3 } } }
inbox[#inbox + 1] = { t = "ids", seq = 1, map = { { localId = 1, netId = "n1" } } }
Sync.Tick()
check(#replayLog == 0, "eigenes Echo wird nicht nachgespielt")
check(#sent == 2 and sent[2].action.netId == "n1" and sent[2].action.pos[1] == 5, "zurückgehaltene Änderung nach ids mit netId gesendet")
check(api.pc2mp.nLastSeq == 1 and Sync and true, "lastSeq aktualisiert")

-- ---------------------------------------------------------------- 2. Remote erstellen / ändern / löschen
inbox[#inbox + 1] = { t = "action", seq = 2, clientId = "c2", action = { op = "upsert", netId = "n2", origin = "other", resource = "Rock", pos = { 9, 9, 9 }, rot = { 0, 0, 0 }, scale = 2 } }
Sync.Tick()
local remotePart = nextPart
check(world[remotePart] and world[remotePart].resource == "Rock", "Remote-Objekt erstellt")
check(ignored[remotePart], "Remote-Objekt-Echo wird ignoriert")
inbox[#inbox + 1] = { t = "action", seq = 3, clientId = "c2", action = { op = "upsert", netId = "n2", origin = "other", pos = { 1, 1, 1 }, rot = { 0, 0, 0 }, scale = 2 } }
Sync.Tick()
check(world[remotePart].pos[1] == 1 and world[remotePart].resource == "Rock", "Remote-Änderung angewendet (Ressource übernommen)")
check(#sent == 2, "Remote-Aktionen werden nicht zurückgesendet")

-- Format, wie api.json.Stringify des Spiels es erzeugt: {"1":x,"2":y,"3":z}
inbox[#inbox + 1] = { t = "action", seq = 3, clientId = "c2", action = { op = "upsert", netId = "n2", origin = "other",
    pos = { ["1"] = 7, ["2"] = 8, ["3"] = 9 }, rot = { ["1"] = 0, ["2"] = 1, ["3"] = 0 }, scale = 2 } }
Sync.Tick()
check(world[remotePart].pos[1] == 7 and world[remotePart].rot[2] == 1, "Positionen im Objekt-Format {\"1\":..} werden verstanden")

-- Lokale Änderung am Remote-Objekt -> geht mit netId n2 raus
local_action({ op = "upsert", partID = remotePart, resource = "Rock", pos = { 2, 2, 2 }, rot = { 0, 0, 0 }, scale = 2 })
check(sent[#sent].action.netId == "n2", "lokale Änderung an fremdem Objekt nutzt dessen netId")

inbox[#inbox + 1] = { t = "action", seq = 4, clientId = "c2", action = { op = "remove", netId = "n2", origin = "other" } }
Sync.Tick()
check(world[remotePart] == nil, "Remote-Löschen angewendet")

-- ---------------------------------------------------------------- 3. Undo nur eigene Aktionen
-- Undo-Stack: [create n1, edit n1, edit n2(local)]
local nBefore = #sent
Sync.Undo() -- edit n2 rückgängig -> n2 ist gelöscht -> wird neu erstellt (Zustand vor meiner Änderung)
check(#sent == nBefore + 1 and sent[#sent].action.netId == "n2" and sent[#sent].action.op == "upsert", "Undo der Änderung an n2 sendet upsert")
Sync.Undo() -- edit n1 rückgängig -> pos zurück auf 1
-- n1 war lokal partID 1 (nicht in world, weil vom Spieler gebaut) -> world mocken
check(sent[#sent].action.netId == "n1" and sent[#sent].action.pos[1] == 1, "Undo der Verschiebung stellt alte Position wieder her")
Sync.Undo() -- create n1 rückgängig -> remove
check(sent[#sent].action.op == "remove" and sent[#sent].action.netId == "n1", "Undo des Erstellens löscht bei allen")
Sync.Redo()
check(sent[#sent].action.op == "upsert" and sent[#sent].action.netId == "n1", "Redo erstellt wieder (gleiche netId)")

-- ---------------------------------------------------------------- 4. Erstellen + Löschen vor ids
local_action({ op = "upsert", partID = 50, resource = "Bench", pos = { 0, 0, 0 }, rot = { 0, 0, 0 }, scale = 1 })
local_action({ op = "remove", partID = 50 })
local n = #sent
inbox[#inbox + 1] = { t = "ids", seq = 9, map = { { localId = 50, netId = "n9" } } }
Sync.Tick()
check(#sent == n + 1 and sent[#sent].action.op == "remove" and sent[#sent].action.netId == "n9", "vor ids gelöschtes Objekt wird nach ids gelöscht")

-- ---------------------------------------------------------------- 5. Persistenz
local st = Sync.GetPersistState()
check(st.map["n2"] ~= nil and st.lastSeq == api.pc2mp.nLastSeq, "GetPersistState enthält netId -> partID und lastSeq")
-- Neustart simulieren: Park geladen, IDs umnummeriert (n2 jetzt partID 7777)
world[7777] = { resource = "Rock", pos = { 3, 3, 3 }, rot = { 0, 0, 0 }, scale = 2 }
Sync.Start()
Sync.OnPersistLoaded({ lastSeq = 42, map = { n2 = 7777 } })
check(api.pc2mp.nLastSeq == 42, "lastSeq aus Spielstand übernommen")
for _ = 1, 30 do Sync.Tick() end
check(Net.hello.lastSeq == 42, "hello nach Neustart mit lastSeq aus Spielstand")
inbox[#inbox + 1] = { t = "action", seq = 43, clientId = "c9", action = { op = "upsert", netId = "n2", origin = "other",
    pos = { 4, 4, 4 }, rot = { 0, 0, 0 }, scale = 2 } }
local nWorld = 0; for _ in pairs(world) do nWorld = nWorld + 1 end
Sync.Tick()
local nWorld2 = 0; for _ in pairs(world) do nWorld2 = nWorld2 + 1 end
check(world[7777].pos[1] == 4 and nWorld == nWorld2, "Remote-Änderung trifft das geladene Teil (kein Duplikat)")

-- ---------------------------------------------------------------- 6. Terrain / Wege (worldedit)
local W = require("pc2mp.worldedit")
local nS = #sent
for _, fn in ipairs(W.tListeners) do fn({ op = "terrain", calls = { { m = "AddSmoothToChangeList" } } }) end
check(#sent == nS + 1 and sent[#sent].action.op == "terrain" and sent[#sent].action.origin == Sync.sInstance, "eigener Terrain-Strich wird gesendet")
inbox[#inbox + 1] = { t = "action", seq = 50, clientId = "c9", action = { op = "volume", origin = "other", outlines = {} } }
inbox[#inbox + 1] = { t = "action", seq = 51, clientId = "c1", action = { op = "terrain", origin = Sync.sInstance } }
Sync.Tick()
check(#weApplied == 1 and weApplied[1].op == "volume", "fremder Weg wird nachgespielt, eigenes Terrain-Echo nicht")

-- ---------------------------------------------------------------- 6b. Farben (props) + Einstellungen (call)
local nS2 = #sent
local tLight = { op = "upsert", partID = 7777, resource = "Light", pos = { 4, 4, 4 }, rot = { 0, 0, 0 }, scale = 2,
                 props = { colours = { { tag = "LightColour", c = { 1, 0, 0 } } } } }
local_action(tLight)
check(#sent == nS2 + 1 and sent[#sent].action.props.colours[1].c[1] == 1, "Farbänderung wird mit props gesendet")
local_action({ op = "upsert", partID = 7777, resource = "Light", pos = { 4, 4, 4 }, rot = { 0, 0, 0 }, scale = 2,
               props = { colours = { { tag = "LightColour", c = { 1, 0, 0 } } } } })
check(#sent == nS2 + 1, "gleicher Zustand nochmal (Commit + Farb-Message) -> nicht doppelt gesendet")
-- vom Netz: Farbe als String-Schlüssel (api.json)
inbox[#inbox + 1] = { t = "action", seq = 60, clientId = "c9", action = { op = "upsert", netId = "n2", origin = "other",
    resource = "Light", pos = { 4, 4, 4 }, rot = { 0, 0, 0 }, scale = 2,
    props = { colours = { ["1"] = { tag = "LightColour", c = { ["1"] = 0, ["2"] = 0, ["3"] = 1 } } }, cookie = "Stars" } } }
Sync.Tick()
check(world[7777].props and world[7777].props.colours[1].c[3] == 1 and world[7777].props.cookie == "Stars",
    "Remote-Farbe + Lichtmuster kommen beim Teil an")
local gsApplied = {}
package.loaded["pc2mp.gamestate"] = { ApplyRemote = function(a, from) gsApplied[#gsApplied + 1] = a end }
inbox[#inbox + 1] = { t = "action", seq = 61, clientId = "c9", action = { op = "call", origin = "other",
    k = "ads.SetAdvertisingActive", a = { 1, true } } }
Sync.Tick()
check(#gsApplied == 1 and gsApplied[1].k == "ads.SetAdvertisingActive", "Werbekampagne vom Mitspieler wird angewendet")

-- ---------------------------------------------------------------- 7. Join über die Dev-UI
api.pc2mp.tJoin = { room = "Freizeitpark", lastSeq = 120 }
Sync.Start()
check(Sync.sRoom == "Freizeitpark" and api.pc2mp.tJoin == nil, "Join: Room aus der UI übernommen")
Sync.OnPersistLoaded({ lastSeq = 7, map = {} })
for _ = 1, 30 do Sync.Tick() end
check(Net.hello.park == "Freizeitpark" and Net.hello.lastSeq == 120, "Join: hello mit Room und Spielstand-Seq vom Server")

print("\nALLE SYNC-TESTS OK")
