-----------------------------------------------------------------------
--/  PC2MP WorldEdit (#15): Terrain + Wege (Volumes) erfassen und nachspielen.
--/
--/  Terrain (verifiziert im Code, Editors.Terrain.TerrainEditMode): pro Pinsel-Schritt
--/    clh = editors:CreateUndoOperationsHierarchy(); op = clh:GetTerrainEditOperation()
--/    gameterrain:SetTerrainEditOpCollisionFlags(op, b1..b6)
--/    gameterrain:Add<Werkzeug>ToChangeList(op, vPos, nSize, nIntensity, nHardness, ...)
--/    api.undo.PreviewChangeList(clh:GetFullUndoChangeList()) -> ... -> api.undo.CommitPreview(token)
--/  Wege (Editors.Volume.*): volumes:CreateMoveObjectForVolumeOutline / ...Spline, Ergebnis lesbar mit
--/    volumes:GetVolumeOutlinesFromMoveObject(mo) (so macht es auch BlueprintPlacementMode).
--/
--/  Erfassung: Aufrufe seit der letzten Preview werden gesammelt und beim CommitPreview des
--/  zugehörigen Tokens als Aktion gemeldet:
--/    { op = "terrain", flags = {...}, calls = { {m = "AddSmoothToChangeList", a = {...}}, ... } }
--/    { op = "volume", outlines = {...}, calls = {...} }      (Wege, Prototyp)
--/  Vektoren werden als {v3 = {x, y, z}} serialisiert.
--/  Nachspielen: WorldEdit.Apply(tAction, nOffsetX) als Replay-Job.
--/  Spiegel-Test (ohne Server): WorldEdit.bMirror = true -> jede Aktion bei x + nMirrorOffsetX nachbauen.
-----------------------------------------------------------------------
local global = _G
local api = global.api
local type = global.type
local pcall = global.pcall
local pairs = global.pairs
local ipairs = global.ipairs
local tostring = global.tostring
local table = global.table
local coroutine = global.coroutine
local require = global.require
local getmetatable = global.getmetatable
local Log = require("pc2mp.log")

local WorldEdit = {}
WorldEdit.bMirror = false
WorldEdit.nMirrorOffsetX = 25.0
WorldEdit.tListeners = {}
WorldEdit.bLogCalls = true       -- Discovery: erfasste Aufrufe ins Log (gekürzt)

-- Gemeinsamer Zustand (api ist über Environments geteilt)
local function S()
    local s = api.pc2mp_worldedit
    if s == nil then
        s = { tBatch = {}, tByPreview = {}, nCommits = 0 }
        api.pc2mp_worldedit = s
    end
    return s
end

-- ---------------------------------------------------------------- (De)Serialisierung

local function TryVec(v)
    local ok, x = pcall(function() return v:X() end)
    if ok and type(x) == "number" then
        return { v3 = { x, v:Y(), v:Z() } }
    end
    ok, x = pcall(function() return v:GetX() end)
    if ok and type(x) == "number" then
        return { v3 = { x, v:GetY(), v:GetZ() } }
    end
    return nil
end

local function Ser(v, nDepth)
    local t = type(v)
    if t == "number" or t == "boolean" or t == "string" or t == "nil" then return v end
    nDepth = nDepth or 0
    if t == "table" then
        if nDepth > 4 then return "<tiefe>" end
        local vec = TryVec(v)
        if vec then return vec end
        local o, n = {}, 0
        for k, x in pairs(v) do
            n = n + 1
            if n > 2000 then o["__abgeschnitten"] = true; break end
            o[k] = Ser(x, nDepth + 1)
        end
        return o
    end
    local vec = TryVec(v)
    if vec then return vec end
    return { ud = tostring(v) }
end
WorldEdit.Ser = Ser

local Vector3 = nil
local function Deser(v, nOffsetX)
    if type(v) ~= "table" then return v end
    if v.v3 then
        Vector3 = Vector3 or require("Vector3")
        return Vector3:new((v.v3[1] or v.v3["1"]) + (nOffsetX or 0), v.v3[2] or v.v3["2"], v.v3[3] or v.v3["3"])
    end
    local o = {}
    for k, x in pairs(v) do
        local kk = global.tonumber(k) or k   -- api.json macht aus Array-Indizes evtl. Strings
        o[kk] = Deser(x, nOffsetX)
    end
    return o
end
WorldEdit.Deser = Deser

-- ---------------------------------------------------------------- Hooks

local function MethodTable(obj)
    if type(obj) == "table" then
        local mt = getmetatable(obj)
        if type(mt) == "table" and type(mt.__index) == "table" then return mt.__index, obj end
        return obj, obj
    end
    local mt = getmetatable(obj)
    if type(mt) == "table" and type(mt.__index) == "table" then return mt.__index, nil end
    return nil, nil
end

local function IsOwnReplay()
    local okR, Replay = pcall(require, "pc2mp.replay")
    local tJob = okR and Replay and Replay.tCurrent
    return tJob ~= nil and tJob.co ~= nil and coroutine.running() == tJob.co
end

-- Wrappt obj:sName so, dass der Aufruf erfasst wird (sKind = "terrain" | "volume")
local function WrapMethod(obj, sName, sKind, fnRecord)
    local tm, tDirect = MethodTable(obj)
    local tgt = (tDirect and global.rawget(tDirect, sName) ~= nil) and tDirect or tm
    if type(tgt) ~= "table" then return false end
    local fnOrig = tgt[sName]
    if type(fnOrig) ~= "function" then return false end
    if global.rawget(tgt, "__pc2mp_" .. sName) then return true end
    tgt[sName] = function(self, ...)
        local tRet = table.pack(fnOrig(self, ...))
        if not IsOwnReplay() then
            local ok, err = pcall(fnRecord, sKind, sName, { ... }, tRet)
            if not ok then Log.Write("WorldEdit: Erfassung " .. sName .. " Fehler: " .. tostring(err)) end
        end
        return table.unpack(tRet, 1, tRet.n)
    end
    global.rawset(tgt, "__pc2mp_" .. sName, true)
    return true
end

local function Record(sKind, sName, tArgs, tRet)
    local s = S()
    local b = s.tBatch
    b.sKind = b.sKind or sKind
    if sKind == "terrain" and sName == "SetTerrainEditOpCollisionFlags" then
        b.flags = Ser({ table.unpack(tArgs, 2) })      -- ohne op-Handle
        return
    end
    b.calls = b.calls or {}
    local tA = {}
    for i = 1, #tArgs do tA[i] = Ser(tArgs[i]) end
    table.insert(b.calls, { m = sName, a = tA })
    -- Move-Objekte der Wege merken, um beim Commit die fertigen Umrisse zu lesen
    if sKind == "volume" and type(tRet[1]) == "userdata" and sName:find("^CreateMoveObject") then
        b.tMoveObjects = b.tMoveObjects or {}
        table.insert(b.tMoveObjects, tRet[1])
    end
end

local tTerrainMethods = {
    "SetTerrainEditOpCollisionFlags", "AddPushPullToChangeList", "AddPlaneFlattenToChangeList",
    "AddLowerToPlaneToChangeList", "AddSmoothToChangeList", "AddRoughenToChangeList",
    "AddSkirtRevealToChangeList", "AddSkirtRevealFillToChangeList", "AddPaintVoxelColoursToChangeList",
    "AddPaintVoxelColoursTowardsDataToChangeList", "AddAutoPaintVoxelColoursToChangeList",
    "CreateLake", "DestroyLake", "CreateWaterfall",
}
local tVolumeMethods = {
    "CreateMoveObjectForVolumeOutline", "CreateMoveObjectForVolumeSpline", "SetSplinePathData",
    "SetSplineBorderData", "SetSplineControlPoint", "ClearSplineControlPoint",
    "CreateMoveObjectsForControlHandles", "CreateMoveObjectsForSelection", "CreateTrimmedSelection",
    "CreateSelectionAfterTranslation", "SetSplineBuildingOptions", "SetFlexiColoursFromOutline",
}

-- Beim Commit: fertige Umrisse der Wege lesen
local function SnapshotVolumes(b)
    local vol = WorldEdit.tWorldAPIs and WorldEdit.tWorldAPIs.volumes
    if not vol or not b.tMoveObjects then return end
    b.outlines = {}
    for _, mo in ipairs(b.tMoveObjects) do
        local ok, t = pcall(vol.GetVolumeOutlinesFromMoveObject, vol, mo)
        if ok and type(t) == "table" then
            for _, o in ipairs(t) do table.insert(b.outlines, Ser(o)) end
        end
    end
    b.tMoveObjects = nil
end

local function Dispatch(tAction)
    if WorldEdit.bLogCalls then
        local okJ, bOk, sJson = pcall(api.json.Stringify, tAction)
        local sOut = (okJ and bOk and sJson) or "<json-fehler>"
        if #sOut > 1500 then sOut = sOut:sub(1, 1500) .. "...(" .. #sOut .. " Zeichen)" end
        Log.Write("WORLDEDIT " .. sOut)
    end
    for _, fn in ipairs(WorldEdit.tListeners) do
        local ok, err = pcall(fn, tAction)
        if not ok then Log.Write("WorldEdit: Listener Fehler: " .. tostring(err)) end
    end
end

WorldEdit.nPackIdle = 0.4      -- s ohne neuen Terrain-Stempel -> Paket abschicken
WorldEdit.nPackMaxCalls = 400

local function Now()
    local ok, t = pcall(api.time.GetTotalTimeUnscaled)
    return ok and type(t) == "number" and t or 0
end

local function FlushPack()
    local s = S()
    local p = s.tPack
    if p == nil then return end
    s.tPack = nil
    Dispatch({ op = "terrain", flags = p.flags, calls = p.calls })
end

-- Terrain: ein Commit pro Frame -> aufeinanderfolgende Stempel mit gleichen Flags bündeln
local function Emit(b)
    local s = S()
    s.nCommits = s.nCommits + 1
    if b.sKind == "terrain" then
        local okK, bK, sKey = pcall(api.json.Stringify, b.flags or {})
        sKey = (okK and bK and sKey) or "?"
        local p = s.tPack
        if p and (p.sKey ~= sKey or #p.calls + #(b.calls or {}) > WorldEdit.nPackMaxCalls) then
            FlushPack(); p = nil
        end
        if p == nil then
            p = { sKey = sKey, flags = b.flags, calls = {} }
            s.tPack = p
        end
        for _, c in ipairs(b.calls or {}) do table.insert(p.calls, c) end
        p.nLast = Now()
        return
    end
    FlushPack()
    Dispatch({ op = b.sKind, calls = b.calls, outlines = b.outlines })
end

-- pro Frame aus Manager.Advance
function WorldEdit.Tick()
    local p = S().tPack
    if p and Now() - (p.nLast or 0) >= WorldEdit.nPackIdle then FlushPack() end
end

local function HookUndo()
    local undo = api.undo
    if type(undo) ~= "table" or global.rawget(undo, "__pc2mpWorldEdit") then return end
    local fnPreview, fnCommit, fnCancel = undo.PreviewChangeList, undo.CommitPreview, undo.CancelPreview
    undo.PreviewChangeList = function(...)
        local w, p = fnPreview(...)
        if not IsOwnReplay() then
            local s = S()
            if s.tBatch.sKind and p ~= nil then s.tByPreview[p] = s.tBatch end
            s.tBatch = {}
        end
        return w, p
    end
    undo.CommitPreview = function(tok, ...)
        local s = S()
        local b = tok ~= nil and s.tByPreview[tok]
        if b then
            s.tByPreview[tok] = nil
            pcall(SnapshotVolumes, b)       -- vor dem Commit: Move-Objekte existieren noch
        end
        local w = fnCommit(tok, ...)
        if b and not IsOwnReplay() then pcall(Emit, b) end
        return w
    end
    undo.CancelPreview = function(tok, ...)
        if tok ~= nil then S().tByPreview[tok] = nil end
        return fnCancel(tok, ...)
    end
    global.rawset(undo, "__pc2mpWorldEdit", true)
end

function WorldEdit.Install(tWorldAPIs)
    WorldEdit.tWorldAPIs = tWorldAPIs
    HookUndo()
    local nT, nV = 0, 0
    if tWorldAPIs.gameterrain then
        for _, m in ipairs(tTerrainMethods) do
            if WrapMethod(tWorldAPIs.gameterrain, m, "terrain", Record) then nT = nT + 1 end
        end
    end
    if tWorldAPIs.volumes then
        for _, m in ipairs(tVolumeMethods) do
            if WrapMethod(tWorldAPIs.volumes, m, "volume", Record) then nV = nV + 1 end
        end
    end
    Log.Write("WorldEdit installiert: " .. nT .. " Terrain-, " .. nV .. " Wege-Funktionen erfasst"
        .. (WorldEdit.bMirror and (", Spiegel bei x+" .. WorldEdit.nMirrorOffsetX) or ""))
end

function WorldEdit.AddListener(fn) table.insert(WorldEdit.tListeners, fn) end

-- ---------------------------------------------------------------- Nachspielen

local function Yield() coroutine.yield() end

local function PreviewAndCommit(clh, sLabel)
    while api.undo.IsBusy() do Yield() end
    local w, p = api.undo.PreviewChangeList(clh:GetFullUndoChangeList())
    while not api.undo.IsOperationComplete(w) do Yield() end
    local bCan = api.undo.CanCommitPreview(p)
    local n = 0
    while bCan == nil and n < 300 do Yield(); n = n + 1; bCan = api.undo.CanCommitPreview(p) end
    if bCan then
        local wc = api.undo.CommitPreview(p)
        while not api.undo.IsOperationComplete(wc) do Yield() end
        pcall(api.undo.Checkpoint, {})
    else
        local okR, tReasons = pcall(api.undo.GetCommitFailReasons, p)
        Log.Write("WorldEdit: " .. sLabel .. " Commit abgelehnt: " .. Log.ToStr(okR and tReasons or nil))
        local wx = api.undo.CancelPreview(p)
        while not api.undo.IsOperationComplete(wx) do Yield() end
    end
    return bCan == true
end

local function ApplyTerrain(tAction, nOffsetX)
    local tw = WorldEdit.tWorldAPIs
    local gt = tw.gameterrain
    local clh = tw.editors:CreateUndoOperationsHierarchy()
    local op = clh:GetTerrainEditOperation()
    if tAction.flags then
        local f = Deser(tAction.flags)
        gt:SetTerrainEditOpCollisionFlags(op, f[1], f[2], f[3], f[4], f[5], f[6])
    end
    local nApplied = 0
    for _, c in ipairs(tAction.calls or {}) do
        local fn = gt[c.m]
        if type(fn) == "function" and c.m:find("ToChangeList$") then
            local a = Deser(c.a, nOffsetX)
            -- a[1] = op des Absenders -> durch unseren ersetzen
            a[1] = op
            local n = 0
            for k in pairs(a) do if type(k) == "number" and k > n then n = k end end
            fn(gt, table.unpack(a, 1, n))
            nApplied = nApplied + 1
        end
    end
    if nApplied == 0 then return false end
    return PreviewAndCommit(clh, "Terrain")
end

local function ApplyVolume(tAction, nOffsetX)
    local tw = WorldEdit.tWorldAPIs
    local vol = tw.volumes
    if not tAction.outlines or #tAction.outlines == 0 then
        Log.Write("WorldEdit: Weg ohne Umrisse, kann (noch) nicht nachgebaut werden")
        return false
    end
    local clh = tw.editors:CreateUndoOperationsHierarchy()
    clh:BeginVolumeModificationsBlock()
    local composite = clh:CreateCompositeObject({})
    for _, o in ipairs(tAction.outlines) do
        local tOutline = Deser(o, nOffsetX)
        local ok, err = pcall(vol.CreateMoveObjectForVolumeOutline, vol, composite, clh, tOutline,
            tOutline.nClipPriority, tOutline.nGroundedRequest)
        if not ok then Log.Write("WorldEdit: CreateMoveObjectForVolumeOutline Fehler: " .. tostring(err)) end
    end
    clh:EndVolumeModificationsBlock()
    return PreviewAndCommit(clh, "Weg")
end

-- tAction aus Erfassung oder Netzwerk; nOffsetX nur für den Spiegel-Test
function WorldEdit.Apply(tAction, nOffsetX, fnDone)
    local Replay = require("pc2mp.replay")
    local sLabel = "worldedit " .. tostring(tAction.op)
    Replay.Enqueue(sLabel, function()
        if tAction.op == "terrain" then return ApplyTerrain(tAction, nOffsetX) end
        if tAction.op == "volume" then return ApplyVolume(tAction, nOffsetX) end
        return false
    end, fnDone)
end

function WorldEdit.OnMirrorAction(tAction)
    if not WorldEdit.bMirror then return end
    WorldEdit.Apply(tAction, WorldEdit.nMirrorOffsetX, function(bOk, r1)
        Log.Write("WorldEdit: Spiegel " .. tostring(tAction.op) .. " -> " .. tostring(bOk) .. " " .. tostring(r1))
    end)
end

return WorldEdit
