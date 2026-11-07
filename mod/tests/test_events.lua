-- Offline-Test für pc2mp.events: Commit-Gate (Park-Laden), Erkennung eigener Replay-Creates, Defer.
-- Ausführen:  tools/cobra-tools/modules/formats/utils/luadec/lua.exe mod/tests/test_events.lua mod/PC2MP/Main
local MAIN = arg[1] or "mod/PC2MP/Main"
local frame = 0
local world = {}      -- partID -> {resource, pos, ready}
local commitFn
api = {
    pc2mp = nil,
    undo = { CommitPreview = function() return "tok" end },
    json = { Stringify = function() return true, "<json>" end },
    transform = {
        CalculateWorldTransform = function(nEntity)
            local p = world[nEntity]
            return {
                GetPos = function() return { GetX = function() return p.pos[1] end, GetY = function() return p.pos[2] end, GetZ = function() return p.pos[3] end } end,
                GetOr = function() return { ToPackedAxisAngle = function() return { GetX = function() return 0 end, GetY = function() return 0 end, GetZ = function() return 0 end } end } end,
            }
        end,
    },
    messaging = {},
}
package.preload["pc2mp.log"] = function()
    return { Write = function(s) end, ToStr = function(v) return tostring(v) end }
end
package.preload["pc2mp.capture"] = function() return {} end
package.preload["pc2mp.props"] = function() return assert(loadfile(MAIN .. "/pc2mp.props.lua"))("pc2mp.props") end
package.preload["pc2mp.events"] = function() return assert(loadfile(MAIN .. "/pc2mp.events.lua"))("pc2mp.events") end
local Events = require("pc2mp.events")

-- Spiel-API-Mocks (Methodenaufruf mit self)
Events.tWorldAPIs = {
    placement = {
        PlacementPartExists = function(_, id) return world[id] ~= nil end,
        GetPartResourceName = function(_, id) return world[id] and world[id].resource end,
        PlacementIDToEntityID = function(_, id) return (world[id] and world[id].ready) and id or nil end,
    },
    scenery = { GetPartScaleData = function() return { nScale = 1 } end },
}
Events.fnNow = function() return frame end
local claimed = {}
local expect = nil   -- simuliert einen laufenden Replay-Create
Events.fnClaimOwnPart = function(id, d)
    if expect and d.resource == expect.resource and math.abs(d.pos[1] - expect.pos[1]) < 1 then
        expect = nil; claimed[#claimed + 1] = id; return true
    end
    return false
end
Events.fnHasOpenCreate = function() return expect ~= nil end
local inReplay = false
Events.fnIsReplayCoroutine = function() return inReplay end
local emitted = {}
Events.AddListener(function(t) emitted[#emitted + 1] = t end)
assert(Events.InstallCommitGate())

local function check(c, msg) if not c then error("FEHLER: " .. msg, 2) end print("ok  " .. msg) end
local function tick(n) for _ = 1, n or 1 do frame = frame + 1; Events.Tick() end end

-- 1. Park-Laden: viele Teile ohne Spieler-Commit -> nichts senden
for i = 1, 50 do world[i] = { resource = "Tree", pos = { i, 0, 0 }, ready = true }; Events.HandlePart(i, 0) end
check(#emitted == 0, "Park-Laden (50 Teile ohne Commit) wird ignoriert")

-- 2. Spieler baut: Commit -> Teil wird gesendet
frame = frame + 200
api.undo.CommitPreview("p")
world[100] = { resource = "Bench", pos = { 5, 0, 5 }, ready = true }
Events.HandlePart(100, 0)
check(#emitted == 1 and emitted[1].op == "upsert" and emitted[1].partID == 100, "Spieler-Commit wird gesendet")

-- 3. Gate-Fenster läuft ab
frame = frame + 200
world[101] = { resource = "Bench", pos = { 6, 0, 6 }, ready = true }
Events.HandlePart(101, 0)
check(#emitted == 1, "ohne frischen Commit kein Senden")

-- 4. Replay-Create: Commit aus Replay-Coroutine öffnet das Gate NICHT; Teil wird als eigenes erkannt
inReplay = true; api.undo.CommitPreview("r"); inReplay = false
expect = { resource = "Rock", pos = { 9, 0, 9 } }
world[102] = { resource = "Rock", pos = { 9, 0, 9 }, ready = true }
Events.HandlePart(102, 0)
check(#emitted == 1 and claimed[1] == 102, "eigenes Replay-Teil erkannt, nicht gesendet")
check(Events.IsIgnored(102), "eigenes Replay-Teil wird danach ignoriert")

-- 5. Spieler baut WÄHREND ein Replay-Create läuft -> wird trotzdem gesendet (kein Zeitfenster mehr)
expect = { resource = "Rock", pos = { 20, 0, 20 } }
api.undo.CommitPreview("p")
world[103] = { resource = "Lamp", pos = { 1, 0, 1 }, ready = true }
Events.HandlePart(103, 0)
check(#emitted == 2 and emitted[2].partID == 103, "Spieler-Teil während laufendem Replay wird gesendet")

-- 6. Replay-Teil, dessen Entity erst später bereit ist -> Defer, dann erkannt
world[104] = { resource = "Rock", pos = { 20, 0, 20 }, ready = false }
Events.HandlePart(104, 0)
check(#emitted == 2 and #claimed == 1, "nicht bereites Teil wird zurückgestellt")
world[104].ready = true
tick(6)
check(claimed[2] == 104 and #emitted == 2, "nach Defer als eigenes erkannt")

-- 7. Spieler löscht sein Teil
api.undo.CommitPreview("p")
world[100] = nil
Events.HandlePart(100, 0)
check(emitted[#emitted].op == "remove" and emitted[#emitted].partID == 100, "Löschen wird gesendet")

-- 8. Spieler verschiebt ein bekanntes Teil (gleiche ID) -> upsert
frame = frame + 200
api.undo.CommitPreview("p")
world[103].pos = { 2, 0, 2 }
Events.HandlePart(103, 0)
check(emitted[#emitted].op == "upsert" and emitted[#emitted].pos[1] == 2, "Verschieben wird gesendet")

print("\nALLE EVENT-TESTS OK")
