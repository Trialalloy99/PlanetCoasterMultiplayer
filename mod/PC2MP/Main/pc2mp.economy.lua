-----------------------------------------------------------------------
--/  PC2MP Economy: Mitarbeiter einstellen/versetzen und Kontostand (Gewinn/Verlust) synchronisieren.
--/
--/  Verifiziert im dekompilierten Lua (Stand 2026-11-07), noch NICHT im Spiel getestet:
--/    Einstellen (Editors.Staff.StaffPlacementMode):
--/      e = staff:GenerateRandomStaff(sPrefab, x, token); staff:SetStaffMemberSuspended(e, true)
--/      ... Spieler setzt ihn ab: api.transform.SetPosition(e, v); staff:SetStaffMemberSuspended(e, false, nPool);
--/      staff:SetStaffMemberParkZone(e, park:GetParkZoneIDFromPoint(v))
--/    -> wir merken uns Prefab/x aus GenerateRandomStaff; beim Absetzen (Suspended=false) senden wir
--/       { op="staff", act="hire"|"move", prefab, x, pos, name }. Name = Kennung des Mitarbeiters auf allen Clients.
--/    WICHTIG (Absturz 2026-11-07): wie das Spiel sofort SetStaffMemberSuspended(e, true), dann warten bis
--/    HaveRequestsCompleted(token) UND staff:HasStaffBrain(e); erst dann absetzen. Pool beim Neueinstellen = nil.
--/    Testmodus: Zwilling NICHT umbenennen (Name ist ein Loc-Token), Zuordnung über Eco.tTwinStaff[Name].
--/    Kontostand: money:GetCash(), money:ModifyCash(n, park.ExpenditureCategory_Uncategorised).
--/      Gäste/Einnahmen laufen auf jedem Client eigenständig -> ein "Kassenwart" (Client mit der kleinsten
--/      Client-ID im Room) sendet seinen Kontostand { op="cash", n }, die anderen gleichen per ModifyCash an.
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
local coroutine = global.coroutine
local require = global.require
local Log = require("pc2mp.log")

local Eco = {}
Eco.tListeners = {}
Eco.fnOnEvent = nil
Eco.nCashEvery = 180         -- Frames zwischen zwei Kontostand-Meldungen (Kassenwart)
Eco.nCashMinDelta = 1
Eco.bCashMaster = false
Eco.nFrame = 0
Eco.tGenerated = {}          -- Staff-Entity -> { prefab, x } (aus GenerateRandomStaff)
Eco.tSeenStaff = {}          -- Staff-Entity -> true (war schon einmal abgesetzt -> "move")
Eco.bApplying = false
Eco.bTwinMode = false        -- Testmodus: Mitarbeiter-Zwillinge über tTwinStaff statt über den Namen
Eco.tTwinStaff = {}          -- Name des Originals -> Entity des Zwillings

local function Note(s)
    Log.Write("Economy: " .. s)
    if Eco.fnOnEvent then pcall(Eco.fnOnEvent, s) end
end

local function Call(obj, sMethod, ...)
    if obj == nil then return nil end
    local f = obj[sMethod]
    if type(f) ~= "function" then return nil end
    local ok, a = pcall(f, obj, ...)
    if ok then return a end
    return nil
end

local function Dispatch(t)
    for _, fn in ipairs(Eco.tListeners) do
        local ok, err = pcall(fn, t)
        if not ok then Log.Write("Economy: Listener Fehler: " .. tostring(err)) end
    end
end

local function ER() return require("pc2mp.entref") end

---------------------------------------------------------------------
-- Haken auf staff:GenerateRandomStaff / SetStaffMemberSuspended
---------------------------------------------------------------------
local function WrapOn(obj, sMethod, fnAfter)
    local tgt = nil
    if type(obj) == "table" then tgt = obj
    else
        local mt = global.getmetatable(obj)
        if type(mt) == "table" and type(mt.__index) == "table" then tgt = mt.__index end
    end
    if tgt == nil then return false end
    if global.rawget(tgt, "__pc2mp_eco_" .. sMethod) then return true end
    local okF, fnOrig = pcall(function() return obj[sMethod] end)
    if not okF or type(fnOrig) ~= "function" then return false end
    global.rawset(tgt, sMethod, function(self, ...)
        local r = table.pack(fnOrig(self, ...))
        local fn = api.pc2mp and api.pc2mp["fnEco_" .. sMethod]
        if fn then pcall(fn, r, ...) end
        return table.unpack(r, 1, r.n)
    end)
    global.rawset(tgt, "__pc2mp_eco_" .. sMethod, fnOrig)
    return true
end

function Eco.Install(tWorldAPIs)
    Eco.tWorldAPIs = tWorldAPIs
    Eco.nFrame = 0
    Eco.tGenerated, Eco.tSeenStaff = {}, {}
    ER().tWorldAPIs = tWorldAPIs
    api.pc2mp = api.pc2mp or {}
    api.pc2mp.fnEco_GenerateRandomStaff = function(r, sPrefab, x)
        if Eco.bApplying then return end
        local e = r[1]
        if e ~= nil then Eco.tGenerated[e] = { prefab = sPrefab, x = x } end
    end
    api.pc2mp.fnEco_SetStaffMemberSuspended = function(_, e, bSuspended)
        if Eco.bApplying or bSuspended ~= false or e == nil then return end
        Eco.OnStaffPlaced(e)
    end
    local n = 0
    if WrapOn(tWorldAPIs.staff, "GenerateRandomStaff") then n = n + 1 end
    if WrapOn(tWorldAPIs.staff, "SetStaffMemberSuspended") then n = n + 1 end
    -- bereits vorhandene Mitarbeiter: Absetzen = Versetzen
    for _, e in ipairs(ER().Staff()) do Eco.tSeenStaff[e] = true end
    Log.Write("Economy installiert: " .. n .. "/2 Personal-Haken")
end

function Eco.OnStaffPlaced(e)
    local tw = Eco.tWorldAPIs
    local p = ER().Pos(e)
    local sName = Call(tw.staff, "GetStaffUIName", e)
    if p == nil or type(sName) ~= "string" then return end
    local g = Eco.tGenerated[e]
    if g ~= nil and not Eco.tSeenStaff[e] then
        Eco.tGenerated[e] = nil
        Eco.tSeenStaff[e] = true
        Note("Mitarbeiter eingestellt: " .. sName)
        Dispatch({ op = "staff", act = "hire", prefab = g.prefab, x = g.x, pos = p, name = sName })
    else
        Eco.tSeenStaff[e] = true
        Dispatch({ op = "staff", act = "move", pos = p, name = sName })
    end
end

---------------------------------------------------------------------
-- Nachspielen
---------------------------------------------------------------------
local function V3(t)
    local x, y, z = tonumber(t[1] or t["1"]), tonumber(t[2] or t["2"]), tonumber(t[3] or t["3"])
    if x == nil or y == nil or z == nil then return nil end
    return require("Vector3"):new(x + (Eco.nOffsetX or 0), y, z)
end

local function Place(e, v, bAlreadySuspended)
    local tw = Eco.tWorldAPIs
    Eco.bApplying = true
    -- wie StaffPlacementMode: nur einen aufgehobenen Mitarbeiter versetzen und wieder absetzen
    if not bAlreadySuspended then pcall(tw.staff.SetStaffMemberSuspended, tw.staff, e, true) end
    pcall(api.transform.SetPosition, e, v)
    pcall(tw.staff.SetStaffMemberSuspended, tw.staff, e, false, nil)
    Eco.bApplying = false
    local zone = Call(tw.park, "GetParkZoneIDFromPoint", v)
    if zone ~= nil then pcall(tw.staff.SetStaffMemberParkZone, tw.staff, e, zone) end
end

-- läuft als Replay-Job (Coroutine), weil GenerateRandomStaff asynchron ist
function Eco.ApplyStaff(a, sFrom)
    local tw = Eco.tWorldAPIs
    if tw == nil or type(a) ~= "table" or type(a.pos) ~= "table" or type(a.name) ~= "string" then return false end
    local v = V3(a.pos)
    if v == nil then return false end
    local sName = a.name
    local e
    if Eco.bTwinMode then e = Eco.tTwinStaff[sName] else e = ER().Resolve("staff", { name = sName }) end
    if a.act == "move" or e ~= nil then
        if e == nil then Note("Mitarbeiter '" .. sName .. "' hier nicht gefunden") return false end
        api.pc2mp.bEcoApplying = true
        Place(e, v)
        api.pc2mp.bEcoApplying = false
        Note("Mitarbeiter '" .. sName .. "' versetzt (von " .. tostring(sFrom) .. ")")
        return true
    end
    -- einstellen
    local token = api.entity.CreateRequestCompletionToken()
    Eco.bApplying = true
    local okG, eNew = pcall(tw.staff.GenerateRandomStaff, tw.staff, a.prefab, a.x, token)
    if okG and eNew ~= nil then pcall(tw.staff.SetStaffMemberSuspended, tw.staff, eNew, true) end
    Eco.bApplying = false
    if not okG or eNew == nil then
        Note("Einstellen fehlgeschlagen: " .. tostring(eNew))
        return false
    end
    Eco.tSeenStaff[eNew] = true
    if not coroutine.isyieldable() then
        Note("Einstellen: nicht in einer Coroutine, abgebrochen")
        return false
    end
    -- warten bis Entity + Gehirn bereit sind (sonst nativer Absturz beim Absetzen)
    local n = 0
    while n < 600 do
        local bReady = api.entity.HaveRequestsCompleted(token)
        if bReady and type(tw.staff.HasStaffBrain) == "function" then
            local okB, bBrain = pcall(tw.staff.HasStaffBrain, tw.staff, eNew)
            bReady = okB and bBrain == true
        end
        if bReady then break end
        coroutine.yield()
        n = n + 1
    end
    if n >= 600 then
        Note("Einstellen: Mitarbeiter wurde nicht fertig (kein Gehirn nach 600 Frames), bleibt aufgehoben")
        return false
    end
    for _ = 1, 2 do coroutine.yield() end
    api.pc2mp.bEcoApplying = true
    if Eco.bTwinMode then
        Eco.tTwinStaff[sName] = eNew
    else
        pcall(tw.staff.SetStaffUIName, tw.staff, eNew, sName)
    end
    Place(eNew, v, true)
    api.pc2mp.bEcoApplying = false
    Note("Mitarbeiter '" .. sName .. "' eingestellt (von " .. tostring(sFrom) .. ")")
    return true
end

---------------------------------------------------------------------
-- Kontostand
---------------------------------------------------------------------
function Eco.Tick()
    Eco.nFrame = Eco.nFrame + 1
    if not Eco.bCashMaster or not Eco.bHasPeers or Eco.tWorldAPIs == nil or Eco.nFrame % Eco.nCashEvery ~= 0 then return end
    local n = Call(Eco.tWorldAPIs.money, "GetCash")
    if type(n) ~= "number" then return end
    if Eco.nLastCashSent ~= nil and math.abs(n - Eco.nLastCashSent) < Eco.nCashMinDelta then return end
    Eco.nLastCashSent = n
    Dispatch({ op = "cash", n = n })
end

function Eco.ApplyCash(a, sFrom)
    local tw = Eco.tWorldAPIs
    local nTarget = type(a) == "table" and tonumber(a.n) or nil
    if tw == nil or nTarget == nil or Eco.bCashMaster then return false end
    local nNow = Call(tw.money, "GetCash")
    if type(nNow) ~= "number" then return false end
    local nDiff = nTarget - nNow
    if math.abs(nDiff) < Eco.nCashMinDelta then return true end
    local cat = tw.park and tw.park.ExpenditureCategory_Uncategorised
    local ok = pcall(tw.money.ModifyCash, tw.money, nDiff, cat, false)
    if not ok then ok = pcall(tw.money.ModifyCash, tw.money, nDiff, cat) end
    if ok and math.abs(nDiff) >= 1000 then
        Note("Kontostand an " .. tostring(sFrom) .. " angeglichen (" .. (nDiff > 0 and "+" or "") .. tostring(math.floor(nDiff)) .. ")")
    end
    return ok
end

-- Kassenwart = kleinste Client-ID ("c3" < "c12" numerisch) unter allen im Room
function Eco.UpdateMaster(sMyId, tOthers)
    local function Num(s) return tonumber(tostring(s or ""):match("(%d+)$")) or math.huge end
    local nMine = Num(sMyId)
    local bMaster = sMyId ~= nil
    Eco.bHasPeers = false
    for id in pairs(tOthers or {}) do
        Eco.bHasPeers = true
        if Num(id) < nMine then bMaster = false end
    end
    if bMaster ~= Eco.bCashMaster then
        Eco.bCashMaster = bMaster
        Eco.nLastCashSent = nil
        Note(bMaster and "dieser Client ist Kassenwart (sendet den Kontostand)" or "Kontostand kommt vom Kassenwart")
    end
end

return Eco
