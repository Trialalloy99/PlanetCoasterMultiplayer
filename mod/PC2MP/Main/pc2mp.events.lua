-----------------------------------------------------------------------
--/  PC2MP Events: erkennt Bau-Aktionen über das Nachrichtensystem des Spiels.
--/
--/  PlacementPartCommittedMessage { nPlacementPartID } kommt bei Erstellen, Ändern
--/  (Verschieben/Drehen/Skalieren), Löschen und Undo/Redo. Wir beschreiben das Teil
--/  (Ressource, Position, Rotation, Skalierung) und erzeugen daraus eine Aktion:
--/     { op="upsert", partID, resource, pos={x,y,z}, rot={ax,ay,az}, scale }
--/     { op="remove", partID }
--/  Listener (Spiegel-Test, später Netzwerk) bekommen diese Aktionen.
-----------------------------------------------------------------------
local global = _G
local api = global.api
local type = global.type
local pairs = global.pairs
local ipairs = global.ipairs
local pcall = global.pcall
local tostring = global.tostring
local string = global.string
local table = global.table
local Log = require("pc2mp.log")
local Capture = require("pc2mp.capture")

local Events = {}
Events.tReceivers = {}
Events.tListeners = {}
Events.tDeferred = {}      -- Teile, deren Entity noch nicht bereit ist
Events.tIgnore = {}        -- PartIDs, die wir selbst erzeugt haben (kein Echo)
Events.nNextSeq = 1

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

function Events.DescribePart(nPartID)
    local d = { partID = nPartID }
    local tw = Events.tWorldAPIs
    local placement, scenery = tw and tw.placement, tw and tw.scenery
    d.exists = TryCall(placement, "PlacementPartExists", nPartID)
    if not d.exists then return d end
    d.resource = TryCall(placement, "GetPartResourceName", nPartID)
    local tScale = TryCall(scenery, "GetPartScaleData", nPartID)
    if type(tScale) == "table" then d.scale = tScale.nScale end
    local nEntity = TryCall(placement, "PlacementIDToEntityID", nPartID)
    if nEntity ~= nil then
        local okT, tr = pcall(api.transform.CalculateWorldTransform, nEntity)
        if okT and tr ~= nil then
            d.pos = Vec(TryCall(tr, "GetPos"))
            local q = TryCall(tr, "GetOr")
            if q ~= nil then d.rot = Vec(TryCall(q, "ToPackedAxisAngle")) end
        end
    end
    return d
end

local function Emit(tAction)
    tAction.seq = Events.nNextSeq
    Events.nNextSeq = Events.nNextSeq + 1
    local okJ, bOk, sJson = pcall(api.json.Stringify, tAction)
    sJson = (okJ and bOk) and sJson or Log.ToStr(tAction)
    Log.Write("ACTION " .. sJson)
    for _, fn in ipairs(Events.tListeners) do
        local ok, err = pcall(fn, tAction, sJson)
        if not ok then Log.Write("Listener-Fehler: " .. tostring(err)) end
    end
end

-- Wird vom Manager gesetzt: function() -> true, wenn eigene Replay-Jobs laufen
Events.fnIsSuppressing = nil
-- PartIDs, die der Spieler selbst erzeugt/geändert hat (dürfen nie unterdrückt werden)
Events.tKnownOriginals = {}

-- Frame-Zähler (vom Manager gesetzt), für zeitlich begrenztes Ignorieren
Events.fnNow = function() return 0 end

-- Events für nPartID die nächsten nFrames ignorieren (Echo unserer eigenen Replays).
-- nFrames = nil -> für immer (Spiegel-Zwillinge).
function Events.IgnoreFor(nPartID, nFrames)
    if nPartID == nil then return end
    Events.tIgnore[nPartID] = nFrames and (Events.fnNow() + nFrames) or true
end

function Events.IsIgnored(nPartID)
    local e = Events.tIgnore[nPartID]
    if e == true then return true end
    if e ~= nil and Events.fnNow() <= e then return true end
    if e ~= nil then Events.tIgnore[nPartID] = nil end
    return false
end

function Events.HandlePart(nPartID, nTry)
    if Events.IsIgnored(nPartID) then return end
    if not Events.tKnownOriginals[nPartID] and Events.fnIsSuppressing and Events.fnIsSuppressing() then
        Log.Write("Events: Teil " .. tostring(nPartID) .. " während Replay -> als eigenes ignoriert")
        Events.IgnoreFor(nPartID, 30)
        -- Dem laufenden Replay-Job melden (so erfährt ein Create-Job die neue PartID)
        if Events.fnOnOwnPart then pcall(Events.fnOnOwnPart, nPartID) end
        return
    end
    Events.tKnownOriginals[nPartID] = true
    local d = Events.DescribePart(nPartID)
    if not d.exists then
        Emit({ op = "remove", partID = nPartID })
    elseif d.pos == nil or d.resource == nil then
        -- z. B. nach Undo: Entity existiert noch nicht -> in ein paar Frames erneut
        if (nTry or 0) < 60 then
            table.insert(Events.tDeferred, { nPartID = nPartID, nTry = (nTry or 0) + 1, nWait = 5 })
        else
            Log.Write("Events: Teil " .. tostring(nPartID) .. " bleibt unvollständig: " .. Log.ToStr(d))
        end
    else
        Emit({ op = "upsert", partID = nPartID, resource = d.resource, pos = d.pos, rot = d.rot, scale = d.scale })
    end
end

function Events.Tick()
    if #Events.tDeferred == 0 then return end
    local tNow = Events.tDeferred
    Events.tDeferred = {}
    for _, t in ipairs(tNow) do
        t.nWait = t.nWait - 1
        if t.nWait <= 0 then
            Events.HandlePart(t.nPartID, t.nTry)
        else
            table.insert(Events.tDeferred, t)
        end
    end
end

local function OnPartCommitted(tMessages)
    for _, tMsg in pairs(tMessages or {}) do
        if type(tMsg) == "table" and tMsg.nPlacementPartID ~= nil then
            local ok, err = pcall(Events.HandlePart, tMsg.nPlacementPartID, 0)
            if not ok then Log.Write("Events-Fehler: " .. tostring(err)) end
        end
    end
end

local function OnUndoRedo(_tMessages)
    Log.Write("EVENT UndoRedoCompleted")
end

function Events.Register(tWorldAPIs)
    Events.tWorldAPIs = tWorldAPIs
    local msg = api.messaging
    if type(msg) ~= "table" or type(msg.RegisterReceiver) ~= "function" then
        Log.Write("Events: api.messaging fehlt")
        return
    end
    local tHandlers = {
        PlacementPartCommittedMessage = OnPartCommitted,
        UndoRedoCompletedMessage = OnUndoRedo,
    }
    for sName, fn in pairs(tHandlers) do
        local nType = msg["MsgType_" .. sName]
        if nType ~= nil then
            local ok, err = pcall(msg.RegisterReceiver, nType, fn)
            if ok then table.insert(Events.tReceivers, { nType, fn })
            else Log.Write("Events: Register " .. sName .. " fehlgeschlagen: " .. tostring(err)) end
        end
    end
    Log.Write("Events: " .. #Events.tReceivers .. " Empfänger registriert")
end

function Events.Unregister()
    for _, t in ipairs(Events.tReceivers) do
        pcall(api.messaging.UnregisterReceiver, t[1], t[2])
    end
    Events.tReceivers = {}
end

function Events.AddListener(fn)
    table.insert(Events.tListeners, fn)
end

return Events
