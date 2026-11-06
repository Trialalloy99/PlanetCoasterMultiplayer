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
    function N.Connect() return true end
    function N.Status() return "connected", 0, 0, 1 end
    function N.LastError() return nil end
    function N.Pump(fn) while #inbox > 0 do fn(table.remove(inbox, 1)) end end
    return N
end
local ignored = {}
local listeners = {}
package.preload["pc2mp.events"] = function()
    local E = { tListeners = listeners }
    function E.IgnoreFor(n, f) ignored[n] = true end
    function E.AddListener(fn) listeners[#listeners + 1] = fn end
    return E
end
local nextPart = 1000
local world = {}   -- partID -> state
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
preload("pc2mp.sync")

local Sync = require("pc2mp.sync")
assert(Sync.Start(), "Start fehlgeschlagen")
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

print("\nALLE SYNC-TESTS OK")
