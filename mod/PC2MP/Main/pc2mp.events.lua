-----------------------------------------------------------------------
--/  PC2MP Events: erkennt Bau-Aktionen über das Nachrichtensystem des Spiels.
--/
--/  PlacementPartCommittedMessage { nPlacementPartID } kommt bei Erstellen, Ändern
--/  (Verschieben/Drehen/Skalieren), Löschen und Undo/Redo. Wir beschreiben das Teil
--/  (Ressource, Position, Rotation, Skalierung) und erzeugen daraus eine Aktion:
--/     { op="upsert", partID, resource, pos={x,y,z}, rot={ax,ay,az}, scale, props }
--/  props = Farben/Lichtmuster/Name (pc2mp.props). Farbänderungen kommen zusätzlich über
--/  MaterialChangedGameMessage {nEntityID}, Umbenennen über UserRenameMessage {id, name}.
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
local Props = require("pc2mp.props")

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

-- bProps: auch Farben/Lichtmuster/Name lesen (teurer; erst nach dem Commit-Gate nötig)
function Events.DescribePart(nPartID, bProps)
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
    if bProps then
        local okP, p = pcall(Props.Describe, tw, nPartID, nEntity)
        if okP then d.props = p end
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

Events.tExcludeResources = { "guestspawner" }

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

---------------------------------------------------------------------
-- Commit-Gate: Nur Teile, die kurz nach einem echten Spieler-Commit
-- (api.undo.CommitPreview außerhalb unserer Replays) gemeldet werden, sind Spieler-Aktionen.
-- Beim Laden eines Parks feuert PlacementPartCommittedMessage für ALLE vorhandenen Teile
-- (z. B. generierte Bäume), ohne dass jemand gebaut hat -> die werden so ignoriert.
---------------------------------------------------------------------
Events.nGateFrames = 90
Events.nLastUserCommitFrame = -100000
Events.nGateDropped = 0

-- Vom Manager gesetzt: true, wenn der aktuelle Code in der Coroutine unseres Replay-Jobs läuft
Events.fnIsReplayCoroutine = function() return false end
-- Vom Manager gesetzt: ClaimOwnPart(nPartID, tDesc) -> true, wenn das Teil zu einem laufenden
-- Replay-Create passt (Ressource + Position); HasOpenCreate() -> ein Create wartet noch auf seine PartID
Events.fnClaimOwnPart = function() return false end
Events.fnHasOpenCreate = function() return false end

function Events.OnCommitPreview()
    if Events.fnIsReplayCoroutine() then return end -- Commit unseres eigenen Replays
    Events.nLastUserCommitFrame = Events.fnNow()
end

function Events.InstallCommitGate()
    api.pc2mp = api.pc2mp or {}
    -- api.undo ist global geteilt: nur einmal wrappen, Ziel-Funktion austauschbar halten
    api.pc2mp.fnOnCommitPreview = Events.OnCommitPreview
    if api.pc2mp.bCommitGate then return true end
    local undo = api.undo
    local fnOrig = undo and undo.CommitPreview
    if type(fnOrig) ~= "function" then
        Log.Write("Events: CommitPreview nicht gefunden, Commit-Gate aus")
        return false
    end
    local ok = pcall(function()
        undo.CommitPreview = function(...)
            local fn = api.pc2mp.fnOnCommitPreview
            if fn then pcall(fn) end
            return fnOrig(...)
        end
    end)
    api.pc2mp.bCommitGate = ok
    Log.Write("Events: Commit-Gate " .. (ok and "aktiv" or "FEHLGESCHLAGEN"))
    return ok
end

function Events.IsUserCommitWindow()
    if not api.pc2mp or not api.pc2mp.bCommitGate then return true end -- ohne Gate: altes Verhalten
    return (Events.fnNow() - Events.nLastUserCommitFrame) <= Events.nGateFrames
end

local function Defer(nPartID, nTry, bGateOk)
    if (nTry or 0) < 60 then
        table.insert(Events.tDeferred, { nPartID = nPartID, nTry = (nTry or 0) + 1, nWait = 5, bGateOk = bGateOk })
        return true
    end
    return false
end

-- nTry: 0 = frisch aus der Message; bGateOk: Ergebnis des Commit-Gates beim ersten Eintreffen
function Events.HandlePart(nPartID, nTry, bGateOk)
    if Events.IsIgnored(nPartID) then return end
    local bKnown = Events.tKnownOriginals[nPartID]
    if (nTry or 0) == 0 then
        bGateOk = bKnown or Events.IsUserCommitWindow()
    end
    local d = Events.DescribePart(nPartID)

    -- 1. Gehört das Teil zu einem unserer Replay-Creates? (Ressource + Position, kein Zeitfenster)
    if d.exists and not bKnown then
        if d.pos ~= nil and d.resource ~= nil then
            if Events.fnClaimOwnPart(nPartID, d) then
                Events.IgnoreFor(nPartID, 120)
                if Events.fnOnOwnPart then pcall(Events.fnOnOwnPart, nPartID) end
                return
            end
        elseif Events.fnHasOpenCreate() then
            Defer(nPartID, nTry, bGateOk) -- noch nicht beschreibbar, könnte unser Create sein
            return
        end
    end

    -- 2. Commit-Gate: ohne Spieler-Commit (z. B. Park-Laden) ignorieren
    if not bGateOk then
        Events.nGateDropped = Events.nGateDropped + 1
        if Events.nGateDropped <= 3 or Events.nGateDropped % 500 == 0 then
            Log.Write("Events: Teil " .. tostring(nPartID) .. " ohne Spieler-Commit ignoriert (gesamt "
                .. Events.nGateDropped .. ")")
        end
        return
    end

    -- Teile, die nie gespiegelt/gesendet werden (z. B. Bus-Gästespawner am Eingang: ein zweiter erzeugt extra Gäste)
    if d.resource ~= nil then
        local sLow = string.lower(d.resource)
        for _, sPat in ipairs(Events.tExcludeResources) do
            if sLow:find(sPat, 1, true) then return end
        end
    end

    -- 3. Spieler-Aktion
    if not d.exists then
        Events.tKnownOriginals[nPartID] = nil
        Emit({ op = "remove", partID = nPartID })
    elseif d.pos == nil or d.resource == nil then
        if not Defer(nPartID, nTry, bGateOk) then
            Log.Write("Events: Teil " .. tostring(nPartID) .. " bleibt unvollständig: " .. Log.ToStr(d))
        end
    else
        Events.tKnownOriginals[nPartID] = true
        local okP, p = pcall(Props.Describe, Events.tWorldAPIs, nPartID,
            TryCall(Events.tWorldAPIs and Events.tWorldAPIs.placement, "PlacementIDToEntityID", nPartID))
        d.props = okP and p or nil
        Emit({ op = "upsert", partID = nPartID, resource = d.resource, pos = d.pos, rot = d.rot, scale = d.scale,
               props = d.props })
    end
end

---------------------------------------------------------------------
-- Eigenschaften ohne PlacementPartCommittedMessage (Farbe, Name): Teil als "dirty" merken.
-- Farben ändern sich auch in der Vorschau des Farbwählers -> erst nach einem Spieler-Commit
-- (frühestens nDirtyCommitSlack Frames vor der Änderung) melden; Umbenennen sofort.
---------------------------------------------------------------------
Events.tDirty = {}         -- PartID -> { nFrame, bForce }
Events.nDirtyCommitSlack = 30
Events.nDirtyMaxAge = 1800

function Events.MarkDirty(nPartID, bForce)
    if nPartID == nil or Events.IsIgnored(nPartID) then return end
    local e = Events.tDirty[nPartID]
    if e == nil then
        Events.tDirty[nPartID] = { nFrame = Events.fnNow(), bForce = bForce }
    else
        e.nFrame = Events.fnNow()
        e.bForce = e.bForce or bForce
    end
end

local function ProcessDirty()
    local nNow = Events.fnNow()
    for nPartID, e in pairs(Events.tDirty) do
        local bCommitted = Events.nLastUserCommitFrame >= e.nFrame - Events.nDirtyCommitSlack
        local bBusy = false
        if api.undo and type(api.undo.IsBusy) == "function" then
            local okB, b = pcall(api.undo.IsBusy)
            bBusy = okB and b
        end
        if (e.bForce or bCommitted) and not bBusy and nNow - e.nFrame >= 3 then
            Events.tDirty[nPartID] = nil
            -- nur Teile, die wir schon kennen oder die gerade vom Spieler kommen
            local ok, err = pcall(Events.HandlePart, nPartID, 1, true)
            if not ok then Log.Write("Events-Fehler (dirty): " .. tostring(err)) end
        elseif nNow - e.nFrame > Events.nDirtyMaxAge then
            Events.tDirty[nPartID] = nil
        end
    end
end

function Events.Tick()
    if global.next(Events.tDirty) ~= nil then ProcessDirty() end
    if #Events.tDeferred == 0 then return end
    local tNow = Events.tDeferred
    Events.tDeferred = {}
    for _, t in ipairs(tNow) do
        t.nWait = t.nWait - 1
        if t.nWait <= 0 then
            Events.HandlePart(t.nPartID, t.nTry, t.bGateOk)
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

local function PartFromEntity(nEntityID)
    local placement = Events.tWorldAPIs and Events.tWorldAPIs.placement
    return TryCall(placement, "EntityIDToPlacementID", nEntityID)
end

local function OnMaterialChanged(tMessages)
    for _, tMsg in pairs(tMessages or {}) do
        if type(tMsg) == "table" and tMsg.nEntityID ~= nil then
            local nPart = PartFromEntity(tMsg.nEntityID)
            if nPart ~= nil then Events.MarkDirty(nPart, false) end
        end
    end
end

local function OnUserRename(tMessages)
    for _, tMsg in pairs(tMessages or {}) do
        if type(tMsg) == "table" and type(tMsg.id) == "number" then
            local placement = Events.tWorldAPIs and Events.tWorldAPIs.placement
            if TryCall(placement, "PlacementPartExists", tMsg.id) then Events.MarkDirty(tMsg.id, true) end
        end
    end
end

local function OnTriggerPropData(tMessages)
    for _, tMsg in pairs(tMessages or {}) do
        if type(tMsg) == "table" and type(tMsg.nPartID) == "number" then Events.MarkDirty(tMsg.nPartID, true) end
    end
end

-- Direkte Setter ohne Commit (Animation: "alle X Sekunden", Dauer) -> Teil als geändert merken
Events.tDirectSetters = { sequence = { "SetTriggerDurationPart", "SetTriggerStrobePart" } }
function Events.HookDirectSetters(tWorldAPIs)
    api.pc2mp = api.pc2mp or {}
    api.pc2mp.fnPartSetterCalled = function(nPartID)
        local okS, S = pcall(require, "pc2mp.sequencer")
        if okS and S and S.bApplying then return end
        if Events.fnIsReplayCoroutine() then return end
        if type(nPartID) == "number" then Events.MarkDirty(nPartID, true) end
    end
    local n = 0
    for sApi, tMethods in pairs(Events.tDirectSetters) do
        local obj = tWorldAPIs and tWorldAPIs[sApi]
        for _, sM in ipairs(tMethods) do
            local tgt = nil
            if type(obj) == "table" then tgt = obj
            else
                local mt = global.getmetatable(obj)
                if type(mt) == "table" and type(mt.__index) == "table" then tgt = mt.__index end
            end
            if tgt ~= nil and not global.rawget(tgt, "__pc2mp_ev_" .. sM) then
                local okF, fnOrig = pcall(function() return obj[sM] end)
                if okF and type(fnOrig) == "function" then
                    global.rawset(tgt, sM, function(self, nPartID, ...)
                        local r = table.pack(fnOrig(self, nPartID, ...))
                        local fn = api.pc2mp and api.pc2mp.fnPartSetterCalled
                        if fn then pcall(fn, nPartID) end
                        return table.unpack(r, 1, r.n)
                    end)
                    global.rawset(tgt, "__pc2mp_ev_" .. sM, fnOrig)
                    n = n + 1
                end
            elseif tgt ~= nil then
                n = n + 1
            end
        end
    end
    Log.Write("Events: " .. n .. " direkte Setter überwacht")
end

local function OnUndoRedo(_tMessages)
    Log.Write("EVENT UndoRedoCompleted")
end

function Events.Register(tWorldAPIs)
    Events.tWorldAPIs = tWorldAPIs
    local okH, errH = pcall(Events.HookDirectSetters, tWorldAPIs)
    if not okH then Log.Write("Events: direkte Setter Fehler: " .. tostring(errH)) end
    local msg = api.messaging
    if type(msg) ~= "table" or type(msg.RegisterReceiver) ~= "function" then
        Log.Write("Events: api.messaging fehlt")
        return
    end
    local tHandlers = {
        PlacementPartCommittedMessage = OnPartCommitted,
        UndoRedoCompletedMessage = OnUndoRedo,
        MaterialChangedGameMessage = OnMaterialChanged,
        UserRenameMessage = OnUserRename,
        TriggerTargetPropDataChangedMessage = OnTriggerPropData,
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
