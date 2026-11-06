-----------------------------------------------------------------------
--/  PC2MP Replay: Bau-Aktionen per Code ausführen (Erstellen, Ändern, Löschen).
--/  Jobs laufen als Coroutines und werden pro Frame aus Manager.Advance fortgesetzt
--/  (das Spiel braucht mehrere Frames, bis Teile bereit / Previews fertig sind).
--/
--/  Aktion (Format wie von pc2mp.events erzeugt):
--/    { op="upsert", resource="NAT_Tree_...", pos={x,y,z}, rot={ax,ay,az}, scale=1.0 }
--/    { op="remove" }
-----------------------------------------------------------------------
local global = _G
local api = global.api
local type = global.type
local pcall = global.pcall
local tostring = global.tostring
local table = global.table
local coroutine = global.coroutine
local require = global.require
local Log = require("pc2mp.log")

local Vector3 = require("Vector3")
local Quaternion = require("Quaternion")
local TransformQ = require("TransformQ")

local Replay = {}
Replay.tQueue = {}
Replay.tCurrent = nil
Replay.tWorldAPIs = nil
Replay.nMaxFramesPerJob = 600

function Replay.Init(tWorldAPIs)
    Replay.tWorldAPIs = tWorldAPIs
    Replay.tQueue = {}
    Replay.tCurrent = nil
end

local function Yield() coroutine.yield() end

local function WaitRequests(token)
    while not api.entity.HaveRequestsCompleted(token) do Yield() end
end

local function WaitOp(waitToken)
    while not api.undo.IsOperationComplete(waitToken) do Yield() end
end

local function MakeTransform(tAction)
    local p, r = tAction.pos, tAction.rot or { 0, 0, 0 }
    local q = Quaternion.FromPackedAxisAngle(Vector3:new(r[1], r[2], r[3]))
    return TransformQ.FromOrPos(q, Vector3:new(p[1], p[2], p[3]))
end

local function PreviewAndCommit(clh)
    while api.undo.IsBusy() do Yield() end
    local waitToken, previewToken = api.undo.PreviewChangeList(clh:GetFullUndoChangeList())
    WaitOp(waitToken)
    local bCan = api.undo.CanCommitPreview(previewToken)
    while bCan == nil do
        Yield()
        bCan = api.undo.CanCommitPreview(previewToken)
    end
    if bCan then
        WaitOp(api.undo.CommitPreview(previewToken))
    else
        local okR, tReasons = pcall(api.undo.GetCommitFailReasons, previewToken)
        Log.Write("Replay: Commit abgelehnt, Gründe: " .. Log.ToStr(okR and tReasons or nil))
        WaitOp(api.undo.CancelPreview(previewToken))
    end
    return bCan
end

local function ApplyTransformAndScale(eo, tAction)
    if tAction.pos then eo:SetTransform(MakeTransform(tAction)) end
    if type(tAction.scale) == "number" then pcall(eo.SetScale, eo, tAction.scale) end
end

-- Erstellt ein neues Teil. Gibt die neue PartID zurück (oder nil).
-- fnBeforeCommit(nNewID) wird vor dem Commit aufgerufen (Echo-Schutz).
function Replay.DoCreate(tAction, fnBeforeCommit)
    local editors = Replay.tWorldAPIs.editors
    local clh = editors:CreateUndoOperationsHierarchy()
    local token = api.entity.CreateRequestCompletionToken()
    local co = clh:CreateNewPart(tAction.resource, token)
    WaitRequests(token)
    local tEOs = clh:StartEditingParts_Scenery({ co })
    local eo = tEOs and tEOs[1]
    if eo == nil then
        Log.Write("Replay: kein EditObject für " .. tostring(tAction.resource))
        return nil
    end
    ApplyTransformAndScale(eo, tAction)
    local okId, nNewID = pcall(eo.GetPlacementPartID, eo)
    Log.Write("Replay: neue PartID vor Commit = " .. tostring(okId) .. " " .. tostring(nNewID))
    if okId and nNewID ~= nil and fnBeforeCommit then pcall(fnBeforeCommit, nNewID) end
    if tAction.pos then
        pcall(clh.SetCashPos, clh, Vector3:new(tAction.pos[1], tAction.pos[2], tAction.pos[3]))
    end
    local bOk = PreviewAndCommit(clh)
    if not (okId and nNewID) then nNewID = nil end
    -- Fallback: PartID kommt über PlacementPartCommittedMessage (wenige Frames nach dem Commit)
    local nWait = 0
    while bOk and nNewID == nil and nWait < 30 do
        nNewID = Replay.CurrentNewPartID()
        if nNewID == nil then
            Yield()
            nWait = nWait + 1
        end
    end
    return bOk and nNewID or nil, bOk
end

function Replay.DoEdit(nPartID, tAction)
    local clh = Replay.tWorldAPIs.editors:CreateUndoOperationsHierarchy()
    local token = api.entity.CreateRequestCompletionToken()
    local co = clh:EditExistingPart(nPartID, nil, token)
    WaitRequests(token)
    local eo = clh:StartEditingPart_Scenery(co)
    if eo == nil then
        Log.Write("Replay: Edit ohne EditObject, Part " .. tostring(nPartID))
        return false
    end
    ApplyTransformAndScale(eo, tAction)
    return PreviewAndCommit(clh)
end

function Replay.DoDestroy(nPartID)
    local tw = Replay.tWorldAPIs
    local clh = tw.editors:CreateUndoOperationsHierarchy()
    local set = tw.scenery:CreateBuildingPartSet()
    set:Add(nPartID)
    local tDel = clh:DestroyExistingParts(set)
    pcall(clh.StartEditingParts_Scenery, clh, tDel)
    return PreviewAndCommit(clh)
end

-- Job einreihen. fnJob läuft als Coroutine; fnDone(ok, result...) danach.
function Replay.Enqueue(sLabel, fnJob, fnDone)
    table.insert(Replay.tQueue, { sLabel = sLabel, fnJob = fnJob, fnDone = fnDone })
end

Replay.nFrame = 0
Replay.nLastJobEndFrame = -1000
Replay.nSuppressFrames = 15

-- true, solange ein eigener Job läuft oder gerade beendet wurde
-- (Events in diesem Fenster stammen sehr wahrscheinlich von uns selbst).
function Replay.IsSuppressing()
    return Replay.tCurrent ~= nil or (Replay.nFrame - Replay.nLastJobEndFrame) <= Replay.nSuppressFrames
end

function Replay.Tick()
    Replay.nFrame = Replay.nFrame + 1
    if Replay.tCurrent == nil then
        local tJob = table.remove(Replay.tQueue, 1)
        if tJob == nil then return end
        tJob.co = coroutine.create(tJob.fnJob)
        tJob.nFrames = 0
        Replay.tCurrent = tJob
        Log.Write("Replay: starte " .. tJob.sLabel)
    end
    local tJob = Replay.tCurrent
    tJob.nFrames = tJob.nFrames + 1
    local ok, r1, r2 = coroutine.resume(tJob.co)
    local bDead = coroutine.status(tJob.co) == "dead"
    if not ok then
        Log.Write("Replay: Fehler in " .. tJob.sLabel .. ": " .. tostring(r1))
    end
    if bDead or not ok or tJob.nFrames > Replay.nMaxFramesPerJob then
        if tJob.nFrames > Replay.nMaxFramesPerJob and not bDead then
            Log.Write("Replay: Timeout in " .. tJob.sLabel)
        end
        Replay.tCurrent = nil
        Replay.tLastJob = tJob
        Replay.nLastJobEndFrame = Replay.nFrame
        Log.Write("Replay: fertig " .. tJob.sLabel .. " ok=" .. tostring(ok) .. " -> " .. Log.Args(r1, r2)
            .. " (" .. tJob.nFrames .. " Frames)")
        if tJob.fnDone then pcall(tJob.fnDone, ok and bDead, r1, r2) end
    end
end

-- Von Events aufgerufen: ein Teil wurde während eines eigenen Jobs festgeschrieben.
-- Gehört zum laufenden Job, oder (wenn das Event erst knapp nach Jobende kommt) zum letzten.
function Replay.OnOwnPart(nPartID)
    local tJob = Replay.tCurrent or Replay.tLastJob
    if tJob == nil then return end
    tJob.tNewPartIDs = tJob.tNewPartIDs or {}
    table.insert(tJob.tNewPartIDs, nPartID)
    if tJob ~= Replay.tCurrent and tJob.fnLatePart then pcall(tJob.fnLatePart, nPartID) end
end

-- Erste neue PartID des laufenden Jobs (innerhalb einer Job-Funktion aufrufen)
function Replay.CurrentNewPartID()
    local t = Replay.tCurrent and Replay.tCurrent.tNewPartIDs
    return t and t[1] or nil
end

function Replay.IsBusy()
    return Replay.tCurrent ~= nil or #Replay.tQueue > 0
end

return Replay
