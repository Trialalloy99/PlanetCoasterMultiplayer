-----------------------------------------------------------------------
--/  PC2MP Replay: Bau-Aktionen per Code ausführen (Erstellen, Ändern, Löschen).
--/  Jobs laufen als Coroutines und werden pro Frame aus Manager.Advance fortgesetzt
--/  (das Spiel braucht mehrere Frames, bis Teile bereit / Previews fertig sind).
--/
--/  Aktion (Format wie von pc2mp.events erzeugt):
--/    { op="upsert", resource="NAT_Tree_...", pos={x,y,z}, rot={ax,ay,az}, scale=1.0, props={...} }
--/    props (Farben, Lichtmuster, ...) siehe pc2mp.props
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
local Props = require("pc2mp.props")

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

-- Wartet bis fnCond() true ist; nach nMax Frames Abbruch mit Log der Phase (statt stumm zu hängen)
local function WaitUntil(fnCond, sStage, nMax)
    local n = 0
    while not fnCond() do
        n = n + 1
        if n > (nMax or 240) then
            Log.Write("Replay: hängt in Phase '" .. sStage .. "' (" .. n .. " Frames)")
            return false
        end
        Yield()
    end
    return true
end

local function PreviewAndCommit(clh)
    WaitUntil(function() return not api.undo.IsBusy() end, "undo busy")
    local waitToken, previewToken = api.undo.PreviewChangeList(clh:GetFullUndoChangeList())
    if not WaitUntil(function() return api.undo.IsOperationComplete(waitToken) end, "preview") then
        pcall(api.undo.CancelPreview, previewToken)
        return false
    end
    local bCan = api.undo.CanCommitPreview(previewToken)
    if bCan == nil then
        WaitUntil(function()
            bCan = api.undo.CanCommitPreview(previewToken)
            return bCan ~= nil
        end, "CanCommitPreview")
    end
    if bCan == nil then
        pcall(api.undo.CancelPreview, previewToken)
        return false
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
    -- Erwartetes Ergebnis merken: Events erkennt das neue Teil daran (Ressource + Position)
    if Replay.tCurrent then Replay.tCurrent.tExpect = tAction end
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
    local bPropsDone = not Props.NeedsEdit(tAction.props)
    if not bPropsDone and okId and nNewID ~= nil then
        bPropsDone = Props.ApplyInEdit(Replay.tWorldAPIs, clh, eo, nNewID, tAction.props) > 0
    end
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
    if bOk and nNewID ~= nil and tAction.props ~= nil then
        -- Farben/Lichtmuster vor dem Commit nicht gesetzt oder vom Spiel ignoriert -> eigene Edit-Operation
        if bPropsDone and Props.NeedsEdit(tAction.props) then
            local tw = Replay.tWorldAPIs
            local okE, nEnt = pcall(tw.placement.PlacementIDToEntityID, tw.placement, nNewID)
            bPropsDone = Props.Matches(tAction.props, Props.Describe(tw, nNewID, okE and nEnt or nil))
            if not bPropsDone then Log.Write("Replay: Farben nach dem Erstellen fehlen -> Nachbearbeitung") end
        end
        if not bPropsDone then Replay.DoEdit(nNewID, { props = tAction.props }) end
        Props.ApplyDirect(Replay.tWorldAPIs, nNewID, tAction.props)
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
    if tAction.props ~= nil then Props.ApplyInEdit(Replay.tWorldAPIs, clh, eo, nPartID, tAction.props) end
    local bOk = PreviewAndCommit(clh)
    if bOk and tAction.props ~= nil then Props.ApplyDirect(Replay.tWorldAPIs, nPartID, tAction.props) end
    return bOk
end

-- Löschen wie das Spiel selbst (SelectAndEditComponent.QuickDeleteObject):
-- Teile bearbeiten -> "Abriss"-Composite -> aus Gruppe entfernen -> Composite:Destroy() -> Commit
function Replay.DoDestroy(nPartID)
    local tw = Replay.tWorldAPIs
    if not tw.placement:PlacementPartExists(nPartID) then
        Log.Write("Replay: Löschen übersprungen, Teil " .. tostring(nPartID) .. " existiert nicht")
        return true
    end
    local clh = tw.editors:CreateUndoOperationsHierarchy()
    local set = tw.scenery:CreateBuildingPartSet()
    set:Add(nPartID)
    local token = api.entity.CreateRequestCompletionToken()
    local tCOs = clh:EditExistingParts(set, token)
    local nGroupID = tw.scenery_group and tw.scenery_group:TryGetBuildingGroupForPart(nPartID) or nil
    local groupCO = nil
    if nGroupID ~= nil and tw.placement:PlacementPartExists(nGroupID) then
        groupCO = clh:EditExistingPart(nGroupID, nil, token)
    end
    WaitRequests(token)
    local tEOs = clh:StartEditingParts_Scenery(tCOs)
    local comp = clh:CreateCompositeObject({ bDemolishOnly = true })
    clh:AddPartsToCompositeObject(comp, tEOs)
    if groupCO ~= nil then
        local geo = clh:StartEditingPart_Group(groupCO)
        geo:RemoveMember(comp)
        if geo:ShouldDestroyGroup() then
            geo:ClearMembers()
            geo:Destroy()
        end
    end
    local okO, obb = pcall(comp.GetOBB, comp)
    if okO and obb ~= nil then pcall(clh.SetCashPos, clh, obb:Pos()) end
    comp:Destroy()
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

-- Läuft der aufrufende Code in der Coroutine des aktuellen Replay-Jobs?
function Replay.IsReplayCoroutine()
    return Replay.tCurrent ~= nil and Replay.tCurrent.co ~= nil and coroutine.running() == Replay.tCurrent.co
end

local function SameResource(a, b)
    return type(a) == "string" and type(b) == "string" and global.string.lower(a) == global.string.lower(b)
end

-- Gehört ein frisch festgeschriebenes Teil zu einem unserer Creates? (laufender Job oder der
-- letzte, falls die Message erst knapp nach Jobende kommt). Abgleich über Ressource + Position.
function Replay.ClaimOwnPart(nPartID, d)
    for _, tJob in global.ipairs({ Replay.tCurrent or false, Replay.tLastJob or false }) do
        local e = tJob and tJob.tExpect
        if e and not tJob.bClaimed and e.pos and d.pos and SameResource(e.resource, d.resource) then
            local dx, dy, dz = d.pos[1] - e.pos[1], d.pos[2] - e.pos[2], d.pos[3] - e.pos[3]
            if dx * dx + dy * dy + dz * dz < 1.0 then
                local bLate = tJob ~= Replay.tCurrent
                if bLate and (Replay.nFrame - (Replay.nLastJobEndFrame or 0)) > 60 then return false end
                tJob.bClaimed = true
                return true
            end
        end
    end
    return false
end

-- Wartet ein Create noch auf seine PartID?
function Replay.HasOpenCreate()
    local c, l = Replay.tCurrent, Replay.tLastJob
    if c and c.tExpect and not c.bClaimed then return true end
    if l and l.tExpect and not l.bClaimed and (Replay.nFrame - (Replay.nLastJobEndFrame or 0)) <= 60 then return true end
    return false
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
