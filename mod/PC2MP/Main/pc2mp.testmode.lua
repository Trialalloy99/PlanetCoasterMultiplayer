-----------------------------------------------------------------------
--/  PC2MP Testmodus: alleine testen, ohne zweiten Spieler und ohne Server.
--/
--/  An: alles, was du baust/änderst, wird als "Zwilling" um nOffset Meter (x-Richtung) versetzt
--/  nachgebaut – genau mit dem Code, der sonst Aktionen der Mitspieler nachspielt:
--/    Objekte inkl. Farben/Lichtmuster/Name (pc2mp.mirror + pc2mp.props), Terrain + Wege (pc2mp.worldedit),
--/    Park-Einstellungen/Marketing (pc2mp.gamestate, Loopback: erfassen -> JSON -> wieder anwenden).
--/  Schalter in der Dev-UI (Tab "Testmodus") -> ui_cmd.json {cmd="testmode", on, offset} (pc2mp.menu).
--/  Zustand bleibt in ovldata/PC2MP/data/testmode.json über Neustarts erhalten.
--/  Im Multiplayer (über die Dev-UI gejoint) ist der Testmodus immer aus.
-----------------------------------------------------------------------
local global = _G
local api = global.api
local type = global.type
local pcall = global.pcall
local tostring = global.tostring
local tonumber = global.tonumber
local table = global.table
local ipairs = global.ipairs
local math = global.math
local require = global.require
local Log = require("pc2mp.log")

local TestMode = {}
TestMode.sModVersion = "2026-11-07.7"   -- bei jedem Build hochzählen; erscheint in der Dev-UI
TestMode.sFile = "testmode.json"
TestMode.nDefaultOffset = 25.0
TestMode.nMaxLog = 40

local function S()
    api.pc2mp = api.pc2mp or {}
    local t = api.pc2mp.tTest
    if t == nil then
        t = { on = false, offset = TestMode.nDefaultOffset, count = 0, log = {}, bLoaded = false }
        api.pc2mp.tTest = t
    end
    return t
end

local function Persist()
    local ok, P = pcall(require, "pc2mp.persist")
    return ok and P or nil
end

function TestMode.Load()
    local t = S()
    if t.bLoaded then return t end
    t.bLoaded = true
    local P = Persist()
    local s = P and P.ReadData(TestMode.sFile)
    if type(s) == "string" then
        local okJ, bOk, d = pcall(api.json.Parse, s)
        if okJ and bOk and type(d) == "table" then
            t.on = d.on == true
            t.offset = tonumber(d.offset) or TestMode.nDefaultOffset
        end
    end
    return t
end

function TestMode.IsOn() return TestMode.Load().on == true end
function TestMode.Offset() return TestMode.Load().offset or TestMode.nDefaultOffset end

function TestMode.Note(s)
    local t = S()
    t.count = (t.count or 0) + 1
    table.insert(t.log, s)
    while #t.log > TestMode.nMaxLog do table.remove(t.log, 1) end
end

-- Vom Menü (Dev-UI-Befehl): speichern und, falls im Park, sofort umschalten
function TestMode.Set(bOn, nOffset)
    local t = TestMode.Load()
    t.on = bOn and true or false
    if type(nOffset) == "number" and nOffset >= 1 and nOffset <= 500 then t.offset = nOffset end
    local P = Persist()
    if P then
        local okJ, bOk, s = pcall(api.json.Stringify, { on = t.on, offset = t.offset })
        if okJ and bOk then P.WriteData(TestMode.sFile, s) end
    end
    Log.Write("Testmodus " .. (t.on and "AN" or "aus") .. " (Versatz " .. tostring(t.offset) .. " m)")
    if api.pc2mp.fnTestModeChanged then pcall(api.pc2mp.fnTestModeChanged) end
    return true
end

-- Für ui_state.json
function TestMode.State()
    local t = TestMode.Load()
    -- mp: im Park läuft Multiplayer (Testmodus greift erst nach dem Neuladen des Parks)
    local Sync = api.pc2mp and api.pc2mp.Sync
    return { version = TestMode.sModVersion, on = t.on, offset = t.offset, active = t.bActive == true, count = t.count or 0, log = t.log,
             mp = Sync ~= nil and Sync.bActive == true or nil, room = Sync and Sync.sRoom or nil }
end

---------------------------------------------------------------------
-- Im Park: Spiegel-Listener an-/abhängen (vom Park-Manager aufgerufen)
---------------------------------------------------------------------
local function RemoveFn(tList, fn)
    for i = #tList, 1, -1 do if tList[i] == fn then table.remove(tList, i) end end
end

-- bWanted: Testmodus soll laufen (an und nicht im Multiplayer)
function TestMode.ApplyInPark(bWanted)
    local t = S()
    local Events = require("pc2mp.events")
    local Mirror = require("pc2mp.mirror")
    local WorldEdit = require("pc2mp.worldedit")
    local GameState = require("pc2mp.gamestate")
    local nOff = TestMode.Offset()
    Mirror.nOffsetX = nOff
    WorldEdit.nMirrorOffsetX = nOff
    Mirror.fnOnEvent = TestMode.Note
    WorldEdit.fnOnEvent = TestMode.Note
    GameState.fnOnEvent = function(s) if t.bActive then TestMode.Note(s) end end
    RemoveFn(Events.tListeners, Mirror.OnAction)
    if bWanted then
        -- Ablaufsteuerung im Zwilling soll auf die Zwillinge der Objekte zeigen
        local Props = require("pc2mp.props")
        Props.fnPartToRef = function(n) return n end
        Props.fnRefToPart = function(r) return Mirror.tTwinOf[global.math.tointeger(tonumber(r)) or r] end
        Mirror.bEnabled = true
        table.insert(Events.tListeners, Mirror.OnAction)
        WorldEdit.bMirror = true
        WorldEdit.tListeners = { WorldEdit.OnMirrorAction }
        GameState.tListeners = { GameState.LoopbackListener }
        GameState.tWeatherListeners = {}
        -- Defekte: auf das gespiegelte Fahrgeschäft (falls es einen Zwilling gibt) übertragen
        local BD = require("pc2mp.breakdowns")
        BD.nOffsetX = nOff
        BD.fnOnEvent = function(s) if t.bActive then TestMode.Note(s) end end
        BD.tListeners = { function(a) BD.ApplyRemote(a, "Testmodus") end }
        -- Läden/Personal: Einstellungen wirken im Test auf den Zwilling (Laden bei +Versatz, Mitarbeiter "... (Test)")
        local ER = require("pc2mp.entref")
        local Eco = require("pc2mp.economy")
        ER.nOffsetX, ER.sNameSuffix = nOff, nil
        Eco.nOffsetX, Eco.sNameSuffix, Eco.bTwinMode = nOff, nil, true
        ER.fnStaffMap = function(sName) return Eco.tTwinStaff[sName] end
        Eco.fnOnEvent = function(s) if t.bActive then TestMode.Note(s) end end
        Eco.bCashMaster, Eco.bHasPeers, Eco.nCashEvery = true, true, 900
        local Replay = require("pc2mp.replay")
        local Pools = require("pc2mp.pools")
        Pools.nOffsetX = nOff
        Pools.fnOnEvent = function(s) if t.bActive then TestMode.Note(s) end end
        Pools.tListeners = { function(a) Pools.Apply(a, "Testmodus") end }
        local Clock = require("pc2mp.clock")
        Clock.fnOnEvent = TestMode.Note
        -- Fahrgeschäfte/Achterbahnen: Blaupause lokal als Zwilling bei +Versatz einsetzen (live bei jeder Änderung)
        local Rides = require("pc2mp.rides")
        Rides.bTestMode, Rides.nOffsetX = true, nOff
        Rides.fnOnEvent = function(s) if t.bActive then TestMode.Note(s) end end
        Rides.tListeners = { function(a)
            if a.op == "ride" then Rides.ApplyLocal(a, "Testmodus")
            elseif a.op == "ridedel" then Rides.ApplyRemote(a, "Testmodus") end
        end }
        Eco.tListeners = { function(a)
            if a.op == "cash" then
                TestMode.Note("Kontostand " .. tostring(math.floor(a.n)) .. " würde an Mitspieler gesendet")
            elseif a.op == "staff" then
                Replay.Enqueue("test staff " .. tostring(a.act), function() return Eco.ApplyStaff(a, "Testmodus") end)
            end
        end }
        if not t.bActive then TestMode.Note("Testmodus aktiv: Zwilling bei x+" .. tostring(nOff) .. " m") end
    else
        Mirror.bEnabled = false
        if t.bActive then
            -- nur das zurücknehmen, was der Testmodus selbst gesetzt hat (im Multiplayer setzt Sync eigene Listener)
            WorldEdit.bMirror = false
            WorldEdit.tListeners = {}
            GameState.tListeners = {}
            require("pc2mp.breakdowns").tListeners = {}
            local Rides = require("pc2mp.rides")
            Rides.tListeners, Rides.bTestMode, Rides.nOffsetX = {}, false, 0
            local Pools = require("pc2mp.pools")
            Pools.tListeners, Pools.nOffsetX = {}, 0
            local Eco = require("pc2mp.economy")
            Eco.tListeners, Eco.bCashMaster, Eco.nOffsetX, Eco.sNameSuffix, Eco.bTwinMode = {}, false, 0, nil, false
            local ER = require("pc2mp.entref")
            ER.nOffsetX, ER.sNameSuffix, ER.fnStaffMap = 0, nil, nil
            TestMode.Note("Testmodus aus")
        end
    end
    t.bActive = bWanted and true or false
    Log.Write("Testmodus im Park: " .. (t.bActive and ("aktiv, Versatz " .. tostring(nOff)) or "aus"))
end

function TestMode.OnParkLeft()
    S().bActive = false
end

return TestMode
