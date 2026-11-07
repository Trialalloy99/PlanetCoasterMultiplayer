-----------------------------------------------------------------------
--/  PC2MP Breakdowns: Defekte von Fahrgeschäften synchronisieren.
--/
--/  Verifiziert im dekompilierten Lua (Stand 2026-11-07), noch NICHT im Spiel getestet:
--/    rides:GetAllRides() -> {nRideID}, rides:GetStationsForRide(nRideID) -> {nStationEntityID}
--/    ridestation:IsBrokenDown(nStation), ridestation:TriggerBreakdown(nStation)
--/      (ScenarioNarrativeManagerEventsHelper.BreakDownSpecificRide)
--/  Es gibt keine Message für Defekte -> alle nPollEvery Frames abfragen.
--/  Entity-IDs sind pro Client verschieden -> Station über ihre Weltposition finden (gleicher Spielstand).
--/  Reparatur macht der Mechaniker auf jedem Client selbst. Zufällige Defekte entstehen auf jedem Client
--/  unabhängig; jeder meldet seine -> am Ende hat jeder alle Defekte.
--/  Aktion: { op = "breakdown", pos = {x,y,z} }
-----------------------------------------------------------------------
local global = _G
local api = global.api
local type = global.type
local pairs = global.pairs
local ipairs = global.ipairs
local pcall = global.pcall
local tostring = global.tostring
local tonumber = global.tonumber
local table = global.table
local math = global.math
local string = global.string
local Log = require("pc2mp.log")

local BD = {}
BD.nPollEvery = 60
BD.nFrame = 0
BD.tBroken = {}       -- nStation -> true (zuletzt gesehen)
BD.tOwnTrigger = {}   -- nStation -> Frame, von uns ausgelöst (nicht erneut melden)
BD.tListeners = {}
BD.nOffsetX = 0       -- Testmodus: Zwilling-Station bei x + Versatz
BD.fnOnEvent = nil
BD.bPrimed = false

local function Call(obj, sMethod, ...)
    if obj == nil then return nil end
    local f = obj[sMethod]
    if type(f) ~= "function" then return nil end
    local ok, a = pcall(f, obj, ...)
    if ok then return a end
    return nil
end

local function Note(s)
    Log.Write("Breakdowns: " .. s)
    if BD.fnOnEvent then pcall(BD.fnOnEvent, s) end
end

local function Pos(nEntity)
    local ok, tr = pcall(api.transform.CalculateWorldTransform, nEntity)
    if not ok or tr == nil then return nil end
    local okP, p = pcall(function() return tr:GetPos() end)
    if not okP or p == nil then return nil end
    local okX, x = pcall(function() return p:GetX() end)
    if okX and type(x) == "number" then return { x, p:GetY(), p:GetZ() } end
    okX, x = pcall(function() return p:X() end)
    if okX and type(x) == "number" then return { x, p:Y(), p:Z() } end
    return nil
end

local function List(t)
    local o = {}
    if type(t) ~= "table" then return o end
    for _, v in pairs(t) do o[#o + 1] = v end
    return o
end

function BD.AllStations()
    local tw = BD.tWorldAPIs
    local out = {}
    if tw == nil or tw.rides == nil then return out end
    for _, nRide in ipairs(List(Call(tw.rides, "GetAllRides"))) do
        for _, nStation in ipairs(List(Call(tw.rides, "GetStationsForRide", nRide))) do out[#out + 1] = nStation end
    end
    return out
end

function BD.Install(tWorldAPIs)
    BD.tWorldAPIs = tWorldAPIs
    BD.tBroken, BD.tOwnTrigger = {}, {}
    BD.bPrimed = false
    BD.nFrame = 0
end

-- Station nahe pos (< nRadius m) finden
function BD.FindStation(pos, nRadius)
    local best, nBest = nil, (nRadius or 2.0) ^ 2
    for _, nStation in ipairs(BD.AllStations()) do
        local p = Pos(nStation)
        if p then
            local dx, dy, dz = p[1] - pos[1], p[2] - pos[2], p[3] - pos[3]
            local d = dx * dx + dy * dy + dz * dz
            if d < nBest then best, nBest = nStation, d end
        end
    end
    return best
end

function BD.Tick()
    BD.nFrame = BD.nFrame + 1
    if BD.tWorldAPIs == nil or BD.nFrame % BD.nPollEvery ~= 0 then return end
    local rs = BD.tWorldAPIs.ridestation
    local tNow = {}
    for _, nStation in ipairs(BD.AllStations()) do
        if Call(rs, "IsBrokenDown", nStation) then
            tNow[nStation] = true
            -- neu kaputt (nicht beim ersten Durchlauf nach dem Laden, nicht von uns ausgelöst)
            if BD.bPrimed and not BD.tBroken[nStation] and BD.tOwnTrigger[nStation] == nil then
                local p = Pos(nStation)
                if p then
                    Note("Fahrgeschäft defekt bei " .. string.format("%.1f/%.1f/%.1f", p[1], p[2], p[3]))
                    for _, fn in ipairs(BD.tListeners) do pcall(fn, { op = "breakdown", pos = p }) end
                end
            end
        end
    end
    for nStation, nFrame in pairs(BD.tOwnTrigger) do
        if not tNow[nStation] and BD.nFrame - nFrame > 600 then BD.tOwnTrigger[nStation] = nil end
    end
    BD.tBroken = tNow
    BD.bPrimed = true
end

-- Defekt vom Mitspieler (bzw. Testmodus) auslösen
function BD.ApplyRemote(a, sFrom)
    local pos = type(a) == "table" and a.pos or nil
    if type(pos) ~= "table" then return false end
    local p = { tonumber(pos[1] or pos["1"]), tonumber(pos[2] or pos["2"]), tonumber(pos[3] or pos["3"]) }
    if p[1] == nil or p[2] == nil or p[3] == nil then return false end
    p[1] = p[1] + (BD.nOffsetX or 0)
    local nStation = BD.FindStation(p, 2.0)
    if nStation == nil then
        Note("keine Station bei der Position von " .. tostring(sFrom) .. " gefunden")
        return false
    end
    local rs = BD.tWorldAPIs.ridestation
    if Call(rs, "IsBrokenDown", nStation) then return true end
    BD.tOwnTrigger[nStation] = BD.nFrame
    local ok, err = pcall(rs.TriggerBreakdown, rs, nStation)
    Note((ok and "Defekt ausgelöst (von " or "Defekt auslösen FEHLER (von ") .. tostring(sFrom) .. ")"
        .. (ok and "" or (": " .. tostring(err))))
    return ok
end

-- Testmodus: Defekt an einem Fahrgeschäft auslösen (das nicht selbst ein Zwilling ist)
function BD.TriggerTest()
    local tw = BD.tWorldAPIs
    if tw == nil then return false, "nicht im Park" end
    local tStations = BD.AllStations()
    if #tStations == 0 then return false, "kein Fahrgeschäft im Park" end
    for _, nStation in ipairs(tStations) do
        if not Call(tw.ridestation, "IsBrokenDown", nStation) then
            local ok, err = pcall(tw.ridestation.TriggerBreakdown, tw.ridestation, nStation)
            if ok then return true, "Defekt ausgelöst (Station " .. tostring(nStation) .. ")" end
            return false, tostring(err)
        end
    end
    return false, "alle Fahrgeschäfte sind schon defekt"
end

return BD
