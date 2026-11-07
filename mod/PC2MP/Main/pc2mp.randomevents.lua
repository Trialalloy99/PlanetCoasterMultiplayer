-----------------------------------------------------------------------
--/  PC2MP RandomEvents: Zufallsereignisse fair auf alle Spieler aufteilen.
--/
--/  Prinzip (Vorgabe Maxi 2026-11-07): Bei N Spielern läuft jedes Zufallsereignis auf jedem Client nur mit 1/N
--/  der normalen Rate. Was passiert, wird an die anderen übertragen. Ergebnis: Die Chance, SELBST einen
--/  Randalierer zu sehen, sinkt auf 1/N, die Gesamtmenge an Folgen (Defekte, zerstörte Sachen) bleibt gleich.
--/    - Ausfälle:    rides:SetBreakdownRateMultiplier(Basis / N)      (Übertragung: pc2mp.breakdowns)
--/    - Taschendiebe: guests:SetMiscreantSpawnLimits(proSpawn * N, minGäste, max(1, ceil(max / N)))
--/    - Vandalen:     guests:SetGroupCanBecomeVandalChance(Basis / N)
--/    - Vandalismus übertragen: ParkObjectVandalisedMessage -> { op="vandal", ref } -> beim Mitspieler
--/      park:Vandalise(e) (nativer Name aus der Exe, ob als Lua-Methode erreichbar wird zur Laufzeit geprüft).
--/  Basiswerte kommen aus Interfaces.IScenarioManager (Get*-Funktionen = Park-/Szenario-Einstellungen), die
--/  Spiel-Felder bleiben unverändert. Alle nReapplyEvery Frames neu gesetzt (falls das Spiel sie zurücksetzt).
--/  Verifiziert im dekompilierten Lua (2026-11-07), im Spiel NICHT getestet.
-----------------------------------------------------------------------
local global = _G
local api = global.api
local type = global.type
local pairs = global.pairs
local ipairs = global.ipairs
local pcall = global.pcall
local tostring = global.tostring
local tonumber = global.tonumber
local math = global.math
local string = global.string
local require = global.require
local Log = require("pc2mp.log")

local RE = {}
RE.nPlayers = 1
RE.nReapplyEvery = 600
RE.nFrame = 0
RE.tListeners = {}
RE.tLogged = {}
RE.tLast = {}            -- zuletzt gesetzte Werte (nur bei Änderung loggen)
RE.tRecentRemote = {}    -- Schlüssel -> Frame: vom Mitspieler übernommener Vandalismus (kein Echo)

local function Note(s) Log.Write("RandomEvents: " .. s) end

local function Call(obj, sMethod, ...)
    if obj == nil then return nil end
    local ok, f = pcall(function() return obj[sMethod] end)
    if not ok or type(f) ~= "function" then return nil end
    local ok2, a = pcall(f, obj, ...)
    if ok2 then return a end
    return nil
end

local function Scenario()
    if RE.oScenario then return RE.oScenario end
    local tEnv = RE.tEnvironment
    if tEnv == nil then
        local okE, ws = pcall(function() return api.world.GetScript(api.world.GetActive()) end)
        tEnv = okE and ws and ws.tEnvironment or nil
    end
    if tEnv == nil then return nil end
    local ok, sm = pcall(tEnv.RequireInterface, tEnv, "Interfaces.IScenarioManager")
    if ok then RE.oScenario = sm end
    return RE.oScenario
end

local function Base(sGetter, sField, nDefault)
    local sm = Scenario()
    local v = Call(sm, sGetter)
    if type(v) ~= "number" and sm ~= nil then
        local ok, f = pcall(function() return sm[sField] end)
        if ok and type(f) == "number" then v = f end
    end
    if type(v) ~= "number" then v = nDefault end
    return v
end

local function SetIfChanged(sKey, fn)
    local ok, err = pcall(fn)
    if not ok and not RE.tLogged[sKey] then
        RE.tLogged[sKey] = true
        Note(sKey .. " setzen fehlgeschlagen: " .. tostring(err))
    end
end

-- Raten für N Spieler setzen (N = 1 -> normale Raten)
function RE.Apply()
    local tw = RE.tWorldAPIs
    if tw == nil then return end
    local n = math.max(1, RE.nPlayers or 1)
    local f = 1 / n
    local nBreak = Base("GetBreakdownRateMultiplier", "nBreakdownRateMultiplier", 1)
    local nPer = Base("GetSecurityNumGuestsPerPickpocketSpawn", "nSecurityNumGuestsPerPickpocketSpawn", 250)
    local nMin = Base("GetSecurityMinGuestsBeforePickpocketSpawn", "nSecurityMinGuestsBeforePickpocketSpawn", 150)
    local nMax = Base("GetSecurityMaxPickpocketsInPark", "nSecurityMaxPickpocketsInPark", 10)
    local nVandal = Base("GetSecurityGroupCanBecomeVandalChance", "nSecurityGroupCanBecomeVandalChance", 0.1)
    local t = {
        breakdown = nBreak * f,
        perSpawn = math.floor(nPer * n + 0.5),
        maxPP = (n > 1) and math.max(1, math.ceil(nMax * f)) or nMax,
        vandal = nVandal * f,
    }
    SetIfChanged("SetBreakdownRateMultiplier", function() tw.rides:SetBreakdownRateMultiplier(t.breakdown) end)
    SetIfChanged("SetMiscreantSpawnLimits", function() tw.guests:SetMiscreantSpawnLimits(t.perSpawn, nMin, t.maxPP) end)
    SetIfChanged("SetGroupCanBecomeVandalChance", function() tw.guests:SetGroupCanBecomeVandalChance(t.vandal) end)
    local sSig = string.format("%d|%.3f|%d|%d|%.3f", n, t.breakdown, t.perSpawn, t.maxPP, t.vandal)
    if RE.sLastSig ~= sSig then
        RE.sLastSig = sSig
        Note(string.format("%d Spieler -> Ausfallrate x%.2f, Taschendieb alle %d Gäste (max %d), Vandalen-Chance %.3f",
            n, t.breakdown, t.perSpawn, t.maxPP, t.vandal))
    end
end

function RE.SetPlayers(n)
    n = math.max(1, math.floor(tonumber(n) or 1))
    if n == RE.nPlayers then return end
    RE.nPlayers = n
    RE.Apply()
end

---------------------------------------------------------------------
-- Vandalismus übertragen
---------------------------------------------------------------------
local function Dispatch(t)
    for _, fn in ipairs(RE.tListeners) do
        local ok, err = pcall(fn, t)
        if not ok then Note("Listener Fehler: " .. tostring(err)) end
    end
end

local function EntityFromMsg(m)
    if type(m) ~= "table" then return nil end
    for _, k in ipairs({ "nEntityID", "entityID", "nObjectID", "objectID", "nParkObjectID", "nID", "id" }) do
        if type(m[k]) == "number" then return m[k] end
    end
    for _, v in pairs(m) do if type(v) == "number" then return v end end
    return nil
end

local function PosOf(e)
    local ok, tr = pcall(api.transform.CalculateWorldTransform, e)
    if not ok or tr == nil then return nil end
    local okP, p = pcall(function() local v = tr:GetPos(); return { v:GetX(), v:GetY(), v:GetZ() } end)
    return okP and p or nil
end

-- Entity -> gemeinsame Beschreibung: netId (Szenerie aus dem Sync) oder Position
function RE.RefOf(e)
    local tw = RE.tWorldAPIs
    local nPart = Call(tw.placement, "EntityIDToPlacementID", e)
    local S = api.pc2mp and api.pc2mp.Sync
    if nPart ~= nil and S and S.tByPart and S.tByPart[nPart] and S.tByPart[nPart].netId then
        return { netId = S.tByPart[nPart].netId, pos = PosOf(e) }
    end
    local p = PosOf(e)
    return p and { pos = p } or nil
end

function RE.ResolveRef(r)
    if type(r) ~= "table" then return nil end
    local tw = RE.tWorldAPIs
    local S = api.pc2mp and api.pc2mp.Sync
    if r.netId and S and S.tByNet and S.tByNet[r.netId] and S.tByNet[r.netId].partID then
        local e = Call(tw.placement, "PlacementIDToEntityID", S.tByNet[r.netId].partID)
        if e ~= nil then return e end
    end
    if type(r.pos) ~= "table" then return nil end
    local p = { tonumber(r.pos[1] or r.pos["1"]), tonumber(r.pos[2] or r.pos["2"]), tonumber(r.pos[3] or r.pos["3"]) }
    if p[1] == nil then return nil end
    local okER, ER = pcall(require, "pc2mp.entref")
    if not okER then return nil end
    local best, nBest = nil, 1.0
    for _, e in ipairs(ER.Places and ER.Places() or {}) do
        local q = PosOf(e)
        if q then
            local d = math.sqrt((q[1] - p[1]) ^ 2 + (q[2] - p[2]) ^ 2 + (q[3] - p[3]) ^ 2)
            if d < nBest then best, nBest = e, d end
        end
    end
    return best
end

local function Key(r)
    if r.netId then return "n:" .. tostring(r.netId) end
    local p = r.pos or {}
    return string.format("p:%d_%d_%d", math.floor((tonumber(p[1] or p["1"]) or 0) + 0.5),
        math.floor((tonumber(p[2] or p["2"]) or 0) + 0.5), math.floor((tonumber(p[3] or p["3"]) or 0) + 0.5))
end

function RE.OnVandalised(tMessages)
    for _, m in pairs(tMessages or {}) do
        if not RE.tLogged.msg then
            RE.tLogged.msg = true
            Note("ParkObjectVandalisedMessage Felder: " .. Log.ToStr(m))
        end
        local e = EntityFromMsg(m)
        local r = e and RE.RefOf(e) or nil
        if r then
            local k = Key(r)
            local nRemote = RE.tRecentRemote[k]
            if nRemote and RE.nFrame - nRemote < 600 then
                RE.tRecentRemote[k] = nil -- Echo unseres Nachbaus
            else
                Note("Vandalismus an " .. k .. " -> an Mitspieler")
                Dispatch({ op = "vandal", ref = r })
            end
        end
    end
end

function RE.ApplyRemote(a, sFrom)
    if type(a) ~= "table" or a.op ~= "vandal" then return false end
    local e = RE.ResolveRef(a.ref)
    if e == nil then Note("Vandalismus von " .. tostring(sFrom) .. ": Objekt hier nicht gefunden") return false end
    if Call(RE.tWorldAPIs.park, "IsVandalised", e) == true then return true end
    RE.tRecentRemote[Key(a.ref)] = RE.nFrame
    local tw = RE.tWorldAPIs
    for _, sApi in ipairs({ "park", "facilities", "scenery" }) do
        local obj = tw[sApi]
        local ok, f = pcall(function() return obj and obj.Vandalise end)
        if ok and type(f) == "function" then
            local okV, err = pcall(f, obj, e)
            if okV then Note("Vandalismus von " .. tostring(sFrom) .. " übernommen (" .. sApi .. ":Vandalise)") return true end
            Note(sApi .. ":Vandalise Fehler: " .. tostring(err))
        end
    end
    if not RE.tLogged.novandalise then
        RE.tLogged.novandalise = true
        Note("Vandalise ist als Lua-Funktion nicht erreichbar -> Vandalismus wird nur angezeigt, nicht übernommen")
    end
    return false
end

---------------------------------------------------------------------
function RE.Install(tWorldAPIs, tEnvironment)
    RE.tWorldAPIs = tWorldAPIs
    RE.tEnvironment = tEnvironment
    RE.oScenario = nil
    RE.nFrame = 0
    RE.sLastSig = nil
    local msg = api.messaging
    if RE.tReceiver then pcall(msg.UnregisterReceiver, RE.tReceiver[1], RE.tReceiver[2]) end
    RE.tReceiver = nil
    local nType = msg and msg.MsgType_ParkObjectVandalisedMessage
    if nType ~= nil and pcall(msg.RegisterReceiver, nType, RE.OnVandalised) then
        RE.tReceiver = { nType, RE.OnVandalised }
    end
    Note("installiert (Vandalismus-Nachricht " .. (RE.tReceiver and "ja" or "NEIN") .. ")")
end

function RE.Tick()
    RE.nFrame = RE.nFrame + 1
    if RE.tWorldAPIs == nil then return end
    if RE.nFrame == 120 or (RE.nPlayers > 1 and RE.nFrame % RE.nReapplyEvery == 0) then RE.Apply() end
end

return RE
