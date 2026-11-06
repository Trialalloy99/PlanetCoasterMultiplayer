-----------------------------------------------------------------------
--/  PC2MP Events: zweiter, unabhängiger Capture-Weg über das Nachrichtensystem
--/  des Spiels (api.messaging). Liefert z. B. nPlacementPartID bei jedem Commit.
-----------------------------------------------------------------------
local global = _G
local api = global.api
local type = global.type
local pairs = global.pairs
local ipairs = global.ipairs
local pcall = global.pcall
local tostring = global.tostring
local table = global.table
local Log = require("pc2mp.log")
local Capture = require("pc2mp.capture")

local Events = {}
Events.tReceivers = {}

local tMsgNames = {
    "PlacementPartCommittedMessage",
    "SceneryPlacedMessage",
    "EntitiesAboutToBeDestroyedMessage",
    "UndoRedoCompletedMessage",
    "ParkZoneCreatedOrDeletedMessage",
}

local function TryCall(obj, sMethod, ...)
    if obj == nil then return nil end
    local ok, a, b = pcall(function(...) return obj[sMethod](obj, ...) end, ...)
    if ok then return a, b end
    return nil
end

local function Vec(v)
    if v == nil then return nil end
    local x = TryCall(v, "GetX")
    if type(x) == "number" then return { x, TryCall(v, "GetY"), TryCall(v, "GetZ") } end
    return nil
end

-- Alles, was wir über ein platziertes Teil herausfinden können
function Events.DescribePart(nPartID)
    local d = { partID = nPartID }
    local placement = Events.tWorldAPIs and Events.tWorldAPIs.placement
    local scenery = Events.tWorldAPIs and Events.tWorldAPIs.scenery
    d.resource = TryCall(placement, "GetPartResourceName", nPartID)
    d.propName = TryCall(scenery, "GetPropName", nPartID)
    d.exists = TryCall(placement, "PlacementPartExists", nPartID)
    local nEntity = TryCall(placement, "PlacementIDToEntityID", nPartID)
    d.entityID = nEntity
    if nEntity ~= nil and api.transform and api.transform.CalculateWorldTransform then
        local okT, tr = pcall(api.transform.CalculateWorldTransform, nEntity)
        if okT and tr ~= nil then
            Capture.LogMethodsOnce(tr, "WorldTransform")
            d.pos = Vec(TryCall(tr, "GetPos"))
            local q = TryCall(tr, "GetOr")
            if q ~= nil then d.rot = Vec(TryCall(q, "ToPackedAxisAngle")) end
            local sc = TryCall(tr, "GetScale")
            d.scale = (type(sc) == "number") and sc or Vec(sc)
        end
    end
    return d
end

local function OnMessage(sName, tMessages)
    local okAll, err = pcall(function()
        local tOut = {}
        for _, tMsg in pairs(tMessages or {}) do
            local tPlain = Capture.Plain(tMsg)
            if type(tMsg) == "table" and tMsg.nPlacementPartID ~= nil then
                tPlain.part = Events.DescribePart(tMsg.nPlacementPartID)
            end
            table.insert(tOut, tPlain)
        end
        local okJ, bOk, sJson = pcall(api.json.Stringify, tOut)
        Log.Write("EVENT " .. sName .. " " .. ((okJ and bOk) and sJson or Log.ToStr(tOut)))
    end)
    if not okAll then Log.Write("EVENT-Fehler " .. sName .. ": " .. tostring(err)) end
end

function Events.Register(tWorldAPIs)
    Events.tWorldAPIs = tWorldAPIs
    local msg = api.messaging
    if type(msg) ~= "table" or type(msg.RegisterReceiver) ~= "function" then
        Log.Write("Events: api.messaging fehlt")
        return
    end
    for _, sName in ipairs(tMsgNames) do
        local nType = msg["MsgType_" .. sName]
        if nType ~= nil then
            local fn = function(tMessages) OnMessage(sName, tMessages) end
            local ok, err = pcall(msg.RegisterReceiver, nType, fn)
            if ok then
                table.insert(Events.tReceivers, { nType, fn })
            else
                Log.Write("Events: RegisterReceiver " .. sName .. " fehlgeschlagen: " .. tostring(err))
            end
        else
            Log.Write("Events: MsgType_" .. sName .. " existiert nicht")
        end
    end
    Log.Write("Events: " .. #Events.tReceivers .. " Empfänger registriert")
end

function Events.Unregister()
    local msg = api.messaging
    for _, t in ipairs(Events.tReceivers) do
        pcall(msg.UnregisterReceiver, t[1], t[2])
    end
    Events.tReceivers = {}
end

return Events
