-----------------------------------------------------------------------
--/  PC2MP Rides: Fahrgeschäfte, Achterbahnen, Schienenfahrgeschäfte, Pools-Rutschen usw. komplett
--/  synchronisieren, indem nach jeder Änderung das ganze Fahrgeschäft als Blaupause exportiert und beim
--/  Mitspieler (Testmodus: Zwilling bei +Versatz) ersetzt wird. Damit kommt alles mit, was eine Blaupause
--/  enthält: Strecke, Stationen, Wagen/Züge, Farben, Muster, Modus/Sequenz, Musik, Auslöser.
--/
--/  Verifiziert im dekompilierten Lua (Stand 2026-11-07), noch NICHT im Spiel getestet:
--/    Export  (GamefaceBlueprintSaveUIMode / ParkLoadSaveManager.SaveBlueprintToFile):
--/      sel = worldserialisation:CreateSaveSelection(); sel:AddEntityID(nRideID)
--/      worldserialisation:RequestSaveBlueprintToFile(sPfad, sel, true); warten bis HasSaveToFileCompleted()
--/    Einsetzen (BlueprintPlacementMode.CreateNew):
--/      worldserialisation:LoadBlueprintFromFile(sPfad); clh = editors:CreateUndoOperationsHierarchy()
--/      warten bis clh:IsLoadedBlueprintReadyForEditing(); mo = clh:CreateCompositeObject({})
--/      clh:AddBlueprintToCompositeObject(mo); mo:SetCompositeOriginToOBBCentre(); mo:SetTransform(T); Commit
--/    Abreißen (SelectAndEditComponent): Flatride: flatrides:RemoveFlatRide(clh, flatrides:GetFlatRideEditToken(id))
--/      Bahn: api.track.RemoveHolder(clh, api.track.GetTrackHolder(id), false)
--/    Verschieben (Korrektur): flatrides:MoveFlatRide(clh, mo, token, TerrainAction, false) bzw.
--/      api.track.MoveTrack(clh, mo, holder); mo:GetTransform()/SetTransform()
--/    Erkennen: RideEditedMessage {rideID} (+ weitere Ride-Messages, Felder werden geloggt),
--/      neue/gelöschte Fahrgeschäfte über rides:GetAllRides() (alle 60 Frames).
--/  Aktionen: { op="ridebp", rid, part, parts, data } (Blaupause in Teilen, base64)
--/            { op="ride", rid, pos, rot, flat, parts }  (nach dem letzten Teil: ersetzen)
--/            { op="ridedel", rid }
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
local coroutine = global.coroutine
local require = global.require
local Log = require("pc2mp.log")

local Rides = {}
Rides.tListeners = {}
Rides.fnOnEvent = nil
Rides.nOffsetX = 0
Rides.bTestMode = false
Rides.nDebounce = 90          -- Frames Ruhe nach der letzten Änderung, bevor exportiert wird
Rides.nPollEvery = 60
Rides.nPartSize = 1000000     -- Zeichen base64 pro Netz-Teil (Server: max. 2 MB pro Zeile)
Rides.nFrame = 0
Rides.tDirty = {}             -- lokale RideID -> Frame der letzten Änderung
Rides.tKnown = {}             -- lokale RideID -> true (zuletzt gesehen)
Rides.tRidOf = {}             -- lokale RideID -> Netz-Kennung (rid)
Rides.tCopyOf = {}            -- rid -> lokale RideID der Kopie (Mitspieler-Ride bzw. Zwilling)
Rides.tIgnoreUntil = {}       -- lokale RideID -> Frame (eigene Änderungen beim Nachspielen ignorieren)
Rides.tParts = {}             -- rid -> { n, parts = {} } (eingehende Blaupause)
Rides.tLoggedMsg = {}
Rides.bBusy = false

local function Note(s)
    Log.Write("Rides: " .. s)
    if Rides.fnOnEvent then pcall(Rides.fnOnEvent, s) end
end

local function Call(obj, sMethod, ...)
    if obj == nil then return nil end
    local f = obj[sMethod]
    if type(f) ~= "function" then return nil end
    local r = table.pack(pcall(f, obj, ...))
    if not r[1] then return nil end
    return table.unpack(r, 2, r.n)
end

local function Values(t)
    local o = {}
    if type(t) == "table" then for _, v in pairs(t) do o[#o + 1] = v end end
    return o
end

local function Native(sFn, ...)
    local okP, P = pcall(require, "pc2mp.persist")
    if not okP then return nil end
    local f = P.Native and P.Native(sFn)
    if f == nil then return nil end
    local ok, r = pcall(f, ...)
    return ok and r or nil
end

local function DataDir()
    if Rides.sDataDir == nil then Rides.sDataDir = Native("pc2mp_data_dir") end
    return Rides.sDataDir
end

local function Yield(n) for _ = 1, (n or 1) do coroutine.yield() end end

local function TW() return Rides.tWorldAPIs end

function Rides.AllRides()
    return Values(Call(TW().rides, "GetAllRides"))
end

local function IsFlat(nRide)
    local b = Call(TW().rides, "IsFlatRide", nRide)
    if b ~= nil then return b == true end
    return Call(TW().flatrides, "GetFlatRideEditToken", nRide) ~= nil
end

local function Vec(v)
    if v == nil then return nil end
    local ok, x = pcall(function() return v:GetX() end)
    if ok and type(x) == "number" then return { x, v:GetY(), v:GetZ() } end
    ok, x = pcall(function() return v:X() end)
    if ok and type(x) == "number" then return { x, v:Y(), v:Z() } end
    return nil
end

local function RideTransform(nRide)
    local ok, tr = pcall(api.transform.CalculateWorldTransform, nRide)
    if not ok or tr == nil then return nil end
    local p = Vec(Call(tr, "GetPos"))
    local q = Call(tr, "GetOr")
    local r = q and Vec(Call(q, "ToPackedAxisAngle")) or nil
    if p == nil then return nil end
    return { pos = p, rot = r or { 0, 0, 0 } }
end
Rides.RideTransform = RideTransform

local function MakeTransform(pos, rot)
    local Vector3, Quaternion, TransformQ = require("Vector3"), require("Quaternion"), require("TransformQ")
    local q = Quaternion.FromPackedAxisAngle(Vector3:new(rot[1], rot[2], rot[3]))
    return TransformQ.FromOrPos(q, Vector3:new(pos[1], pos[2], pos[3]))
end

---------------------------------------------------------------------
-- Erkennen
---------------------------------------------------------------------
local function RideIdFromMsg(m)
    if type(m) ~= "table" then return nil end
    for _, k in ipairs({ "rideID", "nRideID", "nRideEntityID", "rideEntityID", "nRide", "nEntityID", "entityID" }) do
        if type(m[k]) == "number" then return m[k] end
    end
    local nStation = m.nStationID or m.stationID or m.nStationEntityID
    if type(nStation) == "number" then
        for _, r in ipairs(Rides.AllRides()) do
            for _, s in ipairs(Values(Call(TW().rides, "GetStationsForRide", r))) do if s == nStation then return r end end
        end
    end
    return nil
end

function Rides.MarkDirty(nRide, sWhy, bFromPoll)
    if nRide == nil then return end
    local nIgnore = Rides.tIgnoreUntil[nRide]
    if nIgnore and Rides.nFrame <= nIgnore then return end
    -- eigene Kopien: während/kurz nach unserem Einsetzen nie; im Testmodus Zwillinge gar nicht
    local bCopy = false
    for _, n in pairs(Rides.tCopyOf) do if n == nRide then bCopy = true end end
    if bCopy and (Rides.bTestMode or Rides.bBusy or Rides.nFrame <= (Rides.nQuietUntil or 0)) then return end
    if not bFromPoll and not Rides.tKnown[nRide] and (Rides.bBusy or Rides.nFrame <= (Rides.nQuietUntil or 0)) then return end
    if Rides.tDirty[nRide] == nil and sWhy then Log.Write("Rides: Änderung an " .. tostring(nRide) .. " (" .. sWhy .. ")") end
    Rides.tDirty[nRide] = Rides.nFrame
end

Rides.tWatched = { "RideEditedMessage", "FlatRideCreatedMessage", "RideMaterialChangedMessage", "TrainTypeChangedMessage",
    "TrainAddedRemovedMessage", "TrainsAddedRemovedMessage", "RideVariationChangedMessage", "ExtraTrainTypeOptionChangedMessage",
    "TrackBehaviourAddedRemovedMessage", "NonStopTrainCountChangedMessage", "MusicTrackChangedMessage" }

function Rides.Install(tWorldAPIs)
    Rides.tWorldAPIs = tWorldAPIs
    Rides.nFrame = 0
    Rides.tDirty, Rides.tIgnoreUntil, Rides.tParts = {}, {}, {}
    Rides.tKnown = {}
    for _, r in ipairs(Rides.AllRides()) do Rides.tKnown[r] = true end
    local msg = api.messaging
    Rides.tReceivers = Rides.tReceivers or {}
    for _, t in ipairs(Rides.tReceivers) do pcall(msg.UnregisterReceiver, t[1], t[2]) end
    Rides.tReceivers = {}
    local n = 0
    for _, sName in ipairs(Rides.tWatched) do
        local nType = msg and msg["MsgType_" .. sName]
        if nType ~= nil then
            local fn = function(tMessages)
                for _, m in pairs(tMessages or {}) do
                    local nRide = RideIdFromMsg(m)
                    if not Rides.tLoggedMsg[sName] then
                        Rides.tLoggedMsg[sName] = true
                        Log.Write("Rides: " .. sName .. " Felder: " .. Log.ToStr(m))
                    end
                    if nRide ~= nil then Rides.MarkDirty(nRide, sName) end
                end
            end
            if pcall(msg.RegisterReceiver, nType, fn) then
                Rides.tReceivers[#Rides.tReceivers + 1] = { nType, fn }
                n = n + 1
            end
        end
    end
    Log.Write("Rides installiert: " .. n .. " Nachrichten, " .. #Rides.AllRides() .. " Fahrgeschäfte im Park, Datenordner "
        .. tostring(DataDir()))
end

local function NewRid(nRide)
    local sInst = (api.pc2mp and api.pc2mp.sInstance) or "local"
    return (Rides.bTestMode and "test" or sInst) .. ":" .. tostring(nRide)
end

local function IsCopy(nRide)
    for _, n in pairs(Rides.tCopyOf) do if n == nRide then return true end end
    return false
end

-- Gesperrt, solange der Spieler im Editor eine Vorschau offen hat
local function UndoBusy()
    local ok, b = pcall(api.undo.IsBusy)
    return ok and b == true
end

function Rides.Tick()
    Rides.nFrame = Rides.nFrame + 1
    if TW() == nil then return end
    -- Abfrage nicht während eines eigenen Jobs (die Kopie wäre sonst kurz "neu")
    if Rides.nFrame % Rides.nPollEvery == 0 and not Rides.bBusy then
        local tNow = {}
        for _, r in ipairs(Rides.AllRides()) do
            tNow[r] = true
            if not Rides.tKnown[r] and not IsCopy(r) then Rides.MarkDirty(r, "neu", true) end
        end
        for r in pairs(Rides.tKnown) do
            if not tNow[r] then
                Rides.tDirty[r] = nil
                local rid = Rides.tRidOf[r]
                if rid ~= nil and not (Rides.tIgnoreUntil[r] and Rides.nFrame <= Rides.tIgnoreUntil[r]) then
                    Note("Fahrgeschäft abgerissen (" .. rid .. ")")
                    Rides.Dispatch({ op = "ridedel", rid = rid })
                end
                Rides.tRidOf[r] = nil
            end
        end
        Rides.tKnown = tNow
    end
    if Rides.bBusy or UndoBusy() then return end
    for nRide, nFrame in pairs(Rides.tDirty) do
        if Rides.nFrame - nFrame >= Rides.nDebounce then
            Rides.tDirty[nRide] = nil
            Rides.ExportAndSend(nRide)
            return -- eins pro Frame
        end
    end
end

function Rides.Dispatch(t)
    for _, fn in ipairs(Rides.tListeners) do
        local ok, err = pcall(fn, t)
        if not ok then Log.Write("Rides: Listener Fehler: " .. tostring(err)) end
    end
end

---------------------------------------------------------------------
-- Export
---------------------------------------------------------------------
local function FileName(rid) return "ride_" .. tostring(rid):gsub("[^%w]", "_") .. ".blueprint" end

-- als Replay-Job: Blaupause schreiben, dann Aktion(en) verteilen
function Rides.ExportAndSend(nRide)
    if not Rides.tKnown[nRide] then return end
    local rid = Rides.tRidOf[nRide]
    if rid == nil then
        rid = NewRid(nRide)
        Rides.tRidOf[nRide] = rid
    end
    local tr = RideTransform(nRide)
    local sDir = DataDir()
    if tr == nil or sDir == nil then
        Note("Export übersprungen (Position " .. tostring(tr ~= nil) .. ", Datenordner " .. tostring(sDir) .. ")")
        return
    end
    local sFile = FileName(rid)
    local bFlat = IsFlat(nRide)
    local Replay = require("pc2mp.replay")
    Rides.bBusy = true
    Replay.Enqueue("ride export " .. rid, function()
        local ws = TW().worldserialisation
        local sel = Call(ws, "CreateSaveSelection")
        if sel == nil then Note("CreateSaveSelection fehlgeschlagen"); return false end
        if not pcall(sel.AddEntityID, sel, nRide) then Note("AddEntityID fehlgeschlagen"); return false end
        if not pcall(ws.RequestSaveBlueprintToFile, ws, sDir .. sFile, sel, true) then
            Note("Blaupause speichern fehlgeschlagen"); return false
        end
        local n = 0
        while not Call(ws, "HasSaveToFileCompleted") and n < 600 do Yield(); n = n + 1 end
        if n >= 600 then Note("Blaupause speichern: Zeitüberschreitung"); return false end
        return true
    end, function(bOk, r1)
        Rides.bBusy = false
        if not (bOk and r1) then return end
        local tAction = { op = "ride", rid = rid, pos = tr.pos, rot = tr.rot, flat = bFlat, file = sFile }
        Note((bFlat and "Fahrgeschäft" or "Bahn") .. " exportiert (" .. rid .. ")")
        Rides.Dispatch(tAction)
    end)
end

-- Fürs Netz: Blaupause in Teilen (base64) + Abschluss-Aktion. fnSend(tAction) pro Teil.
function Rides.SendOverNet(tAction, fnSend)
    local s = Native("pc2mp_read_file_b64", tAction.file)
    if type(s) ~= "string" or #s == 0 then Note("Blaupause lesen fehlgeschlagen (" .. tostring(tAction.file) .. ")"); return false end
    local nParts = math.max(1, math.ceil(#s / Rides.nPartSize))
    for i = 1, nParts do
        fnSend({ op = "ridebp", rid = tAction.rid, part = i, parts = nParts,
                 data = s:sub((i - 1) * Rides.nPartSize + 1, i * Rides.nPartSize) })
    end
    fnSend({ op = "ride", rid = tAction.rid, pos = tAction.pos, rot = tAction.rot, flat = tAction.flat, parts = nParts })
    Note("gesendet: " .. tAction.rid .. " (" .. math.floor(#s / 1024) .. " KB, " .. nParts .. " Teil(e))")
    return true
end

---------------------------------------------------------------------
-- Einsetzen beim Mitspieler / Zwilling
---------------------------------------------------------------------
local function PreviewAndCommit(clh, sLabel)
    local n = 0
    while UndoBusy() and n < 600 do Yield(); n = n + 1 end
    local w, p = api.undo.PreviewChangeList(clh:GetFullUndoChangeList())
    n = 0
    while not api.undo.IsOperationComplete(w) and n < 900 do Yield(); n = n + 1 end
    local bCan = api.undo.CanCommitPreview(p)
    n = 0
    while bCan == nil and n < 300 do Yield(); n = n + 1; bCan = api.undo.CanCommitPreview(p) end
    if bCan then
        local wc = api.undo.CommitPreview(p)
        n = 0
        while not api.undo.IsOperationComplete(wc) and n < 900 do Yield(); n = n + 1 end
        pcall(api.undo.Checkpoint, {})
        return true
    end
    local okR, tReasons = pcall(api.undo.GetCommitFailReasons, p)
    Note(sLabel .. ": Commit abgelehnt " .. Log.ToStr(okR and tReasons or nil))
    pcall(api.undo.CancelPreview, p)
    return false
end

function Rides.RemoveRide(nRide)
    local tw = TW()
    if not Rides.tKnown[nRide] and Call(tw.rides, "IsFlatRide", nRide) == nil then
        -- evtl. schon weg
    end
    Rides.tIgnoreUntil[nRide] = Rides.nFrame + 600
    local clh = tw.editors:CreateUndoOperationsHierarchy()
    if IsFlat(nRide) then
        local tok = Call(tw.flatrides, "GetFlatRideEditToken", nRide)
        if tok == nil then return false end
        if not pcall(tw.flatrides.RemoveFlatRide, tw.flatrides, clh, tok) then return false end
        local okSU, SceneryUtils = pcall(require, "Editors.Scenery.Utils.SceneryUtils")
        if okSU and SceneryUtils.DeletePartsAttachedToBelongingOrPlatformOwner then
            pcall(SceneryUtils.DeletePartsAttachedToBelongingOrPlatformOwner, nRide, clh, false)
        end
    else
        local okH, holder = pcall(api.track.GetTrackHolder, nRide)
        if not okH or holder == nil then return false end
        if not pcall(api.track.RemoveHolder, clh, holder, false) then return false end
    end
    local bOk = PreviewAndCommit(clh, "Abreißen")
    Rides.nQuietUntil = Rides.nFrame + 120
    return bOk
end

-- Verschiebt eine (neu eingesetzte) Kopie um dPos, damit sie exakt an der Zielposition steht
local function MoveBy(nRide, dPos)
    local tw = TW()
    local clh = tw.editors:CreateUndoOperationsHierarchy()
    local mo = clh:CreateCompositeObject({})
    local ok
    if IsFlat(nRide) then
        local tok = Call(tw.flatrides, "GetFlatRideEditToken", nRide)
        ok = tok ~= nil and pcall(tw.flatrides.MoveFlatRide, tw.flatrides, clh, mo, tok,
            tw.editors.TerrainActionType_PathJoinPartFlatten, false)
    else
        local okH, holder = pcall(api.track.GetTrackHolder, nRide)
        ok = okH and holder ~= nil and pcall(api.track.MoveTrack, clh, mo, holder)
    end
    if not ok then return false end
    Yield(2)
    local T = Call(mo, "GetTransform")
    local p = T and Vec(Call(T, "GetPos")) or nil
    if p == nil then return false end
    local Vector3, TransformQ = require("Vector3"), require("TransformQ")
    pcall(mo.SetTransform, mo, TransformQ.FromOrPos(T:GetOr(), Vector3:new(p[1] + dPos[1], p[2] + dPos[2], p[3] + dPos[3])))
    return PreviewAndCommit(clh, "Ausrichten")
end

local function NewRideAfter(tBefore)
    local tSet = {}
    for _, r in ipairs(tBefore) do tSet[r] = true end
    for _, r in ipairs(Rides.AllRides()) do if not tSet[r] then return r end end
    return nil
end

-- im Replay-Job: alte Kopie ersetzen
function Rides.PlaceFromFile(rid, sFile, tTarget, sFrom)
    local tw = TW()
    local sDir = DataDir()
    if sDir == nil then Note("kein Datenordner"); return false end
    -- 1. alte Kopie abreißen
    local nOld = Rides.tCopyOf[rid]
    if nOld ~= nil and Rides.tKnown[nOld] then
        if not Rides.RemoveRide(nOld) then Note("alte Kopie von " .. rid .. " ließ sich nicht abreißen") end
        Rides.tRidOf[nOld] = nil
        Yield(5)
    end
    Rides.tCopyOf[rid] = nil
    -- 2. Blaupause laden und einsetzen
    local tBefore = Rides.AllRides()
    if not Call(tw.worldserialisation, "LoadBlueprintFromFile", sDir .. sFile) then
        Note("Blaupause laden fehlgeschlagen (" .. sFile .. ")")
        return false
    end
    local clh = tw.editors:CreateUndoOperationsHierarchy()
    local n = 0
    while not Call(clh, "IsLoadedBlueprintReadyForEditing") and n < 900 do Yield(); n = n + 1 end
    if n >= 900 then Note("Blaupause wurde nicht bereit"); return false end
    local mo = clh:CreateCompositeObject({})
    clh:AddBlueprintToCompositeObject(mo)
    if Call(mo, "IsEmpty") then Note("Blaupause ist leer"); return false end
    pcall(mo.DecayCompositeAlignmentType, mo, mo.CompositeAlignmentType_ItemAligned)
    pcall(mo.SetCompositeOriginToOBBCentre, mo)
    local T0 = Call(mo, "GetTransform")
    Log.Write("Rides: Blaupause geladen, Composite-Position " .. Log.ToStr(T0 and Vec(Call(T0, "GetPos"))))
    pcall(mo.SetTransform, mo, MakeTransform(tTarget.pos, tTarget.rot))
    if not PreviewAndCommit(clh, "Einsetzen") then return false end
    Yield(5)
    local nNew = NewRideAfter(tBefore)
    if nNew == nil then Note("eingesetzt, aber neues Fahrgeschäft nicht gefunden"); return false end
    Rides.tIgnoreUntil[nNew] = Rides.nFrame + 600
    Rides.tKnown[nNew] = true
    Rides.tCopyOf[rid] = nNew
    Rides.tRidOf[nNew] = rid
    -- 3. Lage prüfen und korrigieren (Blaupausen werden um ihren Mittelpunkt platziert)
    local tr = RideTransform(nNew)
    if tr then
        local d = { tTarget.pos[1] - tr.pos[1], tTarget.pos[2] - tr.pos[2], tTarget.pos[3] - tr.pos[3] }
        local nDist = math.sqrt(d[1] * d[1] + d[2] * d[2] + d[3] * d[3])
        if nDist > 0.05 then
            Log.Write(string.format("Rides: Kopie liegt %.2f m daneben -> verschiebe", nDist))
            MoveBy(nNew, d)
            tr = RideTransform(nNew)
        end
        local dr = 0
        for i = 1, 3 do dr = dr + math.abs((tTarget.rot[i] or 0) - (tr.rot[i] or 0)) end
        if dr > 0.01 then Log.Write("Rides: Drehung weicht ab: Ziel " .. Log.ToStr(tTarget.rot) .. ", ist " .. Log.ToStr(tr.rot)) end
    end
    Rides.tIgnoreUntil[nNew] = Rides.nFrame + 120
    Rides.nQuietUntil = Rides.nFrame + 120
    Rides.tDirty[nNew] = nil
    Note("Kopie von " .. rid .. " eingesetzt (von " .. tostring(sFrom) .. ")")
    return true
end

local function V3(t)
    if type(t) ~= "table" then return nil end
    local x, y, z = tonumber(t[1] or t["1"]), tonumber(t[2] or t["2"]), tonumber(t[3] or t["3"])
    if x == nil or y == nil or z == nil then return nil end
    return { x, y, z }
end

-- Testmodus: lokal exportierte Datei direkt als Zwilling einsetzen
function Rides.ApplyLocal(tAction, sFrom)
    local pos, rot = V3(tAction.pos), V3(tAction.rot) or { 0, 0, 0 }
    if pos == nil then return end
    pos[1] = pos[1] + (Rides.nOffsetX or 0)
    local Replay = require("pc2mp.replay")
    Rides.bBusy = true
    Replay.Enqueue("ride place " .. tostring(tAction.rid), function()
        return Rides.PlaceFromFile(tAction.rid, tAction.file, { pos = pos, rot = rot }, sFrom)
    end, function() Rides.bBusy = false end)
end

-- Netz: Teile sammeln, beim Abschluss Datei schreiben und einsetzen
function Rides.ApplyRemote(a, sFrom)
    if type(a) ~= "table" or a.rid == nil then return end
    local rid = tostring(a.rid)
    if a.op == "ridebp" then
        local t = Rides.tParts[rid]
        if t == nil or t.n ~= tonumber(a.parts) then t = { n = tonumber(a.parts) or 1, parts = {} }; Rides.tParts[rid] = t end
        t.parts[tonumber(a.part) or 1] = a.data
        return
    end
    if a.op == "ridedel" then
        local nCopy = Rides.tCopyOf[rid]
        if nCopy == nil then
            -- vielleicht unser eigenes Fahrgeschäft, das der Mitspieler abgerissen hat
            for r, x in pairs(Rides.tRidOf) do if x == rid then nCopy = r end end
        end
        if nCopy ~= nil then
            local Replay = require("pc2mp.replay")
            Replay.Enqueue("ride remove " .. rid, function() return Rides.RemoveRide(nCopy) end)
            Rides.tCopyOf[rid] = nil
            Note("Abriss von " .. rid .. " (von " .. tostring(sFrom) .. ")")
        end
        return
    end
    if a.op == "ride" then
        local t = Rides.tParts[rid]
        local nParts = tonumber(a.parts) or 1
        if t == nil then Note("Blaupause für " .. rid .. " fehlt"); return end
        local tAll = {}
        for i = 1, nParts do
            if t.parts[i] == nil then Note("Blaupause für " .. rid .. " unvollständig (" .. i .. "/" .. nParts .. ")"); return end
            tAll[i] = t.parts[i]
        end
        Rides.tParts[rid] = nil
        local sFile = FileName("in_" .. rid)
        if Native("pc2mp_write_file_b64", sFile, table.concat(tAll)) ~= 1 then Note("Blaupause schreiben fehlgeschlagen"); return end
        -- eigenes Fahrgeschäft vom Mitspieler geändert? Dann ersetzen wir unser Original
        if Rides.tCopyOf[rid] == nil then
            for r, x in pairs(Rides.tRidOf) do if x == rid then Rides.tCopyOf[rid] = r end end
        end
        local pos, rot = V3(a.pos), V3(a.rot) or { 0, 0, 0 }
        if pos == nil then return end
        local Replay = require("pc2mp.replay")
        Replay.Enqueue("ride place " .. rid, function()
            return Rides.PlaceFromFile(rid, sFile, { pos = pos, rot = rot }, sFrom)
        end)
    end
end

return Rides
