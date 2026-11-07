-----------------------------------------------------------------------
--/  PC2MP EntRef: Entity-IDs sind auf jedem Client anders. Für Einstellungen an Läden, Mitarbeitern
--/  und Orten wird die Entity deshalb über etwas Gemeinsames beschrieben:
--/    facility  Laden/Toilette/... -> Position     (facilities:GetAllFacilityEntityIDs)
--/    shopinv   Sortiment eines Ladens -> Position des Ladens (facilities:GetShopInventoryEntityID(fac))
--/    staff     Mitarbeiter -> Name                (staff:GetAllStaffEntities, GetStaffUIName)
--/    ride      Fahrgeschäft -> Position der Ride-Entity   (rides:GetAllRides)
--/    station   Station eines Fahrgeschäfts -> Position    (rides:GetStationsForRide)
--/    pool      Pool -> Position                           (pools:GetAllPools)
--/    place     Arbeitsort (Laden, Personalgebäude, Fahrgeschäft-Station) -> Position
--/  Voraussetzung: beide Clients haben denselben Spielstand + synchronisierten Bau (gleiche Positionen).
--/  Verifiziert im dekompilierten Lua (Stand 2026-11-07), noch NICHT im Spiel getestet.
-----------------------------------------------------------------------
local global = _G
local api = global.api
local type = global.type
local pairs = global.pairs
local ipairs = global.ipairs
local pcall = global.pcall
local tostring = global.tostring
local tonumber = global.tonumber

local ER = {}
ER.nRadius = 1.5

local function Call(obj, sMethod, ...)
    if obj == nil then return nil end
    local f = obj[sMethod]
    if type(f) ~= "function" then return nil end
    local ok, a = pcall(f, obj, ...)
    if ok then return a end
    return nil
end

local function TW() return ER.tWorldAPIs or api.world.GetWorldAPIs() end

local function Values(t)
    local o = {}
    if type(t) == "table" then for _, v in pairs(t) do o[#o + 1] = v end end
    return o
end

function ER.Pos(nEntity)
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

function ER.Facilities() return Values(Call(TW().facilities, "GetAllFacilityEntityIDs")) end
function ER.Staff() return Values(Call(TW().staff, "GetAllStaffEntities")) end

function ER.Rides() return Values(Call(TW().rides, "GetAllRides")) end
function ER.Stations()
    local o = {}
    for _, nRide in ipairs(ER.Rides()) do
        for _, s in ipairs(Values(Call(TW().rides, "GetStationsForRide", nRide))) do o[#o + 1] = s end
    end
    return o
end

function ER.Places()
    local tw = TW()
    local o = ER.Facilities()
    for _, e in ipairs(Values(Call(tw.staff, "GetAllStaffBuildingEntityIDs"))) do o[#o + 1] = e end
    for _, nRide in ipairs(Values(Call(tw.rides, "GetAllRides"))) do
        for _, s in ipairs(Values(Call(tw.rides, "GetStationsForRide", nRide))) do o[#o + 1] = s end
    end
    return o
end

local function Nearest(tList, pos)
    if type(pos) ~= "table" then return nil end
    local p = { tonumber(pos[1] or pos["1"]), tonumber(pos[2] or pos["2"]), tonumber(pos[3] or pos["3"]) }
    if p[1] == nil or p[2] == nil or p[3] == nil then return nil end
    p[1] = p[1] + (ER.nOffsetX or 0)
    local best, nBest = nil, ER.nRadius * ER.nRadius
    for _, e in ipairs(tList) do
        local q = ER.Pos(e)
        if q then
            local dx, dy, dz = q[1] - p[1], q[2] - p[2], q[3] - p[3]
            local d = dx * dx + dy * dy + dz * dz
            if d < nBest then best, nBest = e, d end
        end
    end
    return best
end

-- Entity -> gemeinsame Beschreibung (nil = nicht beschreibbar)
function ER.Ref(sKind, nEntity)
    if nEntity == nil then return nil end
    if sKind == "staff" then
        local s = Call(TW().staff, "GetStaffUIName", nEntity)
        if type(s) == "string" and s ~= "" then return { name = s } end
        return nil
    end
    if sKind == "shopinv" then
        for _, fac in ipairs(ER.Facilities()) do
            if Call(TW().facilities, "GetShopInventoryEntityID", fac) == nEntity then
                local p = ER.Pos(fac)
                return p and { pos = p } or nil
            end
        end
        return nil
    end
    local p = ER.Pos(nEntity)
    return p and { pos = p } or nil
end

-- gemeinsame Beschreibung -> lokale Entity
function ER.Resolve(sKind, tRef)
    if type(tRef) ~= "table" then return nil end
    if sKind == "staff" then
        if type(tRef.name) ~= "string" then return nil end
        if ER.fnStaffMap then return ER.fnStaffMap(tRef.name) end  -- Testmodus: Zwillings-Mitarbeiter
        local sName = tRef.name .. (ER.sNameSuffix or "")
        for _, e in ipairs(ER.Staff()) do
            if Call(TW().staff, "GetStaffUIName", e) == sName then return e end
        end
        return nil
    end
    if sKind == "facility" then return Nearest(ER.Facilities(), tRef.pos) end
    if sKind == "shopinv" then
        local fac = Nearest(ER.Facilities(), tRef.pos)
        return fac and Call(TW().facilities, "GetShopInventoryEntityID", fac) or nil
    end
    if sKind == "place" then return Nearest(ER.Places(), tRef.pos) end
    if sKind == "ride" then return Nearest(ER.Rides(), tRef.pos) end
    if sKind == "pool" then return Nearest(Values(Call(TW().pools, "GetAllPools")), tRef.pos) end
    if sKind == "station" then return Nearest(ER.Stations(), tRef.pos) end
    return nil
end

return ER
