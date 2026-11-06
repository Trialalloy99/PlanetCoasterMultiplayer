-----------------------------------------------------------------------
--/  PC2MP WorldEdit (#15): Terrain + Wege (Volumes) erfassen und nachspielen.
--/
--/  Terrain (Editors.Terrain.TerrainEditMode, im Spiel bestätigt): pro Pinsel-Schritt
--/    op = clh:GetTerrainEditOperation(); gameterrain:SetTerrainEditOpCollisionFlags(op, b1..b6)
--/    gameterrain:Add<Werkzeug>ToChangeList(op, vPos, nSize, nIntensity, nHardness, ...)
--/    api.undo.PreviewChangeList(...) -> api.undo.CommitPreview(token)
--/  Wege (Editors.Volume.*):
--/    Zeichnen: volumes:CreateMoveObjectForVolumeOutline(composite, clh, tOutline, nPrio, nGrounded)
--/    Spline:   mo = volumes:CreateMoveObjectForVolumeSpline(clh, tStart, bCurve, bClassic, bRightAngled, bStub)
--/              volumes:SetSplinePathData(mo, ...), SetSplineBorderData(mo, ...), SetSplineBuildingOptions(mo, ...)
--/              danach live: mo:SetTransform(Cursor) pro Frame, volumes:SetSplineControlPoint(mo, vPos)
--/              Commit: volumes:GetSplineResultData(mo) -> bCommit, vStart, vEnd
--/
--/  Aktionen:
--/    { op="terrain", flags={...}, calls={ {m="AddSmoothToChangeList", a={...}}, ... } }
--/    { op="volume", outlines={ {outline=..., prio=n, grounded=n}, ... }, splines={ {...}, ... } }
--/  Vektoren als {v3={x,y,z}}. api.json macht aus Arrays Objekte mit String-Schlüsseln ->
--/  Apply() normalisiert die Schlüssel zuerst.
--/  Spiegel-Test (ohne Server): WorldEdit.bMirror -> jede Aktion bei x + nMirrorOffsetX nachbauen.
-----------------------------------------------------------------------
local global = _G
local api = global.api
local type = global.type
local pcall = global.pcall
local pairs = global.pairs
local ipairs = global.ipairs
local tostring = global.tostring
local tonumber = global.tonumber
local table = global.table
local coroutine = global.coroutine
local require = global.require
local getmetatable = global.getmetatable
local Log = require("pc2mp.log")

local WorldEdit = {}
WorldEdit.bMirror = false
WorldEdit.nMirrorOffsetX = 25.0
WorldEdit.tListeners = {}
WorldEdit.bLogCalls = true

local function S()
    local s = api.pc2mp_worldedit
    if s == nil then
        s = { tBatch = {}, tByPreview = {}, tSplineByMo = {}, nCommits = 0 }
        api.pc2mp_worldedit = s
    end
    s.tSplineByMo = s.tSplineByMo or {}
    return s
end

-- ---------------------------------------------------------------- (De)Serialisierung

local function TryVec(v)
    local ok, x = pcall(function() return v:X() end)
    if ok and type(x) == "number" then return { v3 = { x, v:Y(), v:Z() } } end
    ok, x = pcall(function() return v:GetX() end)
    if ok and type(x) == "number" then return { v3 = { x, v:GetY(), v:GetZ() } } end
    return nil
end

local function Ser(v, nDepth)
    local t = type(v)
    if t == "number" or t == "boolean" or t == "string" or t == "nil" then return v end
    nDepth = nDepth or 0
    local vec = TryVec(v)
    if vec then return vec end
    -- Transform? (TransformQ hat :GetPos(), kann Tabelle oder Userdata sein)
    local okP, p = pcall(function() return v:GetPos() end)
    if okP and p ~= nil then
        local pv = TryVec(p)
        if pv then return { tq = pv } end
    end
    if t == "table" then
        if nDepth > 5 then return "<tiefe>" end
        local o, n = {}, 0
        for k, x in pairs(v) do
            n = n + 1
            if n > 4000 then break end
            o[k] = Ser(x, nDepth + 1)
        end
        return o
    end
    return { ud = tostring(v) }
end
WorldEdit.Ser = Ser

-- String-Schlüssel "1","2",... -> Zahlen (api.json liefert Arrays als Objekte)
local function Normalize(v)
    if type(v) ~= "table" then return v end
    local o = {}
    for k, x in pairs(v) do
        local nk = (type(k) == "string" and tonumber(k)) or k
        o[nk] = Normalize(x)
    end
    return o
end
WorldEdit.Normalize = Normalize

local Vector3, TransformQ, Quaternion = nil, nil, nil
local function Vec(t, nOffsetX)
    Vector3 = Vector3 or require("Vector3")
    return Vector3:new(t[1] + (nOffsetX or 0), t[2], t[3])
end

local function Deser(v, nOffsetX)
    if type(v) ~= "table" then return v end
    if v.v3 then return Vec(v.v3, nOffsetX) end
    if v.tq and v.tq.v3 then
        TransformQ = TransformQ or require("TransformQ")
        Quaternion = Quaternion or require("Quaternion")
        return TransformQ.FromOrPos(Quaternion.Identity, Vec(v.tq.v3, nOffsetX))
    end
    local o = {}
    for k, x in pairs(v) do o[k] = Deser(x, nOffsetX) end
    return o
end
WorldEdit.Deser = Deser

local function MaxIndex(t)
    local n = 0
    for k in pairs(t) do if type(k) == "number" and k > n then n = k end end
    return n
end

-- ---------------------------------------------------------------- Hooks

local function MethodTable(obj)
    local mt = getmetatable(obj)
    if type(obj) == "table" then
        if type(mt) == "table" and type(mt.__index) == "table" then return mt.__index, obj end
        return obj, obj
    end
    if type(mt) == "table" and type(mt.__index) == "table" then return mt.__index, nil end
    return nil, nil
end

local function IsOwnReplay()
    local okR, Replay = pcall(require, "pc2mp.replay")
    local tJob = okR and Replay and Replay.tCurrent
    return tJob ~= nil and tJob.co ~= nil and coroutine.running() == tJob.co
end

local function WrapMethod(obj, sName, fnRecord)
    local tm, tDirect = MethodTable(obj)
    local tgt = (tDirect and global.rawget(tDirect, sName) ~= nil) and tDirect or tm
    if type(tgt) ~= "table" then return false end
    local fnOrig = tgt[sName]
    if type(fnOrig) ~= "function" then return false end
    if global.rawget(tgt, "__pc2mp2_" .. sName) then return true end
    tgt[sName] = function(self, ...)
        local tRet = table.pack(fnOrig(self, ...))
        if not IsOwnReplay() then
            local ok, err = pcall(fnRecord, sName, { ... }, tRet)
            if not ok then Log.Write("WorldEdit: Erfassung " .. sName .. " Fehler: " .. tostring(err)) end
        end
        return table.unpack(tRet, 1, tRet.n)
    end
    global.rawset(tgt, "__pc2mp2_" .. sName, true)
    return true
end

local function ArgsFrom(tArgs, nFirst)
    local o = {}
    for i = nFirst, #tArgs do o[#o + 1] = Ser(tArgs[i]) end
    return o
end

-- Terrain: Flags nur merken; als Terrain-Aktion zählt nur ein Batch mit Add*ToChangeList
local function RecordTerrain(sName, tArgs, tRet)
    local b = S().tBatch
    if sName == "SetTerrainEditOpCollisionFlags" then
        b.flags = ArgsFrom(tArgs, 2)
        return
    end
    if not sName:find("ToChangeList$") then return end   -- Seen/Wasserfälle: noch nicht
    b.sKind = "terrain"
    b.calls = b.calls or {}
    local tA = { "op" }
    for i = 2, #tArgs do tA[i] = Ser(tArgs[i]) end
    table.insert(b.calls, { m = sName, a = tA })
end

local function RecordVolume(sName, tArgs, tRet)
    local s = S()
    local b = s.tBatch
    if sName == "CreateMoveObjectForVolumeOutline" then
        -- (composite, clh, tOutline, nClipPriority, nGroundedRequest)
        b.sKind = "volume"
        b.outlines = b.outlines or {}
        table.insert(b.outlines, { outline = Ser(tArgs[3]), prio = tArgs[4], grounded = tArgs[5] })
    elseif sName == "CreateMoveObjectForVolumeSpline" then
        -- (clh, tStart, bCurve, bClassic, bRightAngled, bStub)
        local mo = tRet[1]
        if mo == nil then return end
        local sess = { start = Ser(tArgs[2]), bCurve = tArgs[3], bClassic = tArgs[4], bRightAngled = tArgs[5],
                       bStub = tArgs[6], cps = {}, mo = mo }
        s.tSplineByMo[mo] = sess
        b.sKind = "volume"
        b.tSplines = b.tSplines or {}
        table.insert(b.tSplines, sess)
    else
        local sess = s.tSplineByMo[tArgs[1]]
        if sess == nil then return end
        if sName == "SetSplinePathData" then sess.pathData = ArgsFrom(tArgs, 2)
        elseif sName == "SetSplineBorderData" then sess.borderData = ArgsFrom(tArgs, 2)
        elseif sName == "SetSplineBuildingOptions" then sess.buildOpts = ArgsFrom(tArgs, 2)
        elseif sName == "SetSplineControlPoint" then table.insert(sess.cps, Ser(tArgs[2]))
        elseif sName == "ClearSplineControlPoint" then sess.cps = {}
        end
    end
end

local tTerrainMethods = {
    "SetTerrainEditOpCollisionFlags", "AddPushPullToChangeList", "AddPlaneFlattenToChangeList",
    "AddLowerToPlaneToChangeList", "AddSmoothToChangeList", "AddRoughenToChangeList",
    "AddSkirtRevealToChangeList", "AddSkirtRevealFillToChangeList", "AddPaintVoxelColoursToChangeList",
    "AddPaintVoxelColoursTowardsDataToChangeList", "AddAutoPaintVoxelColoursToChangeList",
}
local tVolumeMethods = {
    "CreateMoveObjectForVolumeOutline", "CreateMoveObjectForVolumeSpline", "SetSplinePathData",
    "SetSplineBorderData", "SetSplineBuildingOptions", "SetSplineControlPoint", "ClearSplineControlPoint",
}

-- Beim Commit: Endpunkte der Splines lesen (Move-Objekte existieren vor dem Commit noch)
local function FinishSplines(b)
    if not b.tSplines then return end
    local vol = WorldEdit.tWorldAPIs and WorldEdit.tWorldAPIs.volumes
    local s = S()
    b.splines = {}
    for _, sess in ipairs(b.tSplines) do
        local mo = sess.mo
        local okE, vEnd = pcall(function() return mo:GetPosition() end)
        local tOut = { start = sess.start, bCurve = sess.bCurve, bClassic = sess.bClassic,
                       bRightAngled = sess.bRightAngled, cps = sess.cps, pathData = sess.pathData,
                       borderData = sess.borderData, buildOpts = sess.buildOpts,
                       ["end"] = okE and Ser(vEnd) or nil }
        if vol then
            local okR, bCommit, vS, vE = pcall(vol.GetSplineResultData, vol, mo)
            if okR then
                tOut.resStart = Ser(vS)
                tOut.resEnd = Ser(vE)
            end
        end
        if not sess.bStub then table.insert(b.splines, tOut) end
        s.tSplineByMo[mo] = nil
    end
    b.tSplines = nil
end

local function Dispatch(tAction)
    if WorldEdit.bLogCalls then
        local okJ, bOk, sJson = pcall(api.json.Stringify, tAction)
        local sOut = (okJ and bOk and sJson) or "<json-fehler>"
        if #sOut > 1200 then sOut = sOut:sub(1, 1200) .. "...(" .. #sOut .. " Zeichen)" end
        Log.Write("WORLDEDIT " .. sOut)
    end
    for _, fn in ipairs(WorldEdit.tListeners) do
        local ok, err = pcall(fn, tAction)
        if not ok then Log.Write("WorldEdit: Listener Fehler: " .. tostring(err)) end
    end
end

WorldEdit.nPackIdle = 0.4
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

local function Emit(b)
    local s = S()
    s.nCommits = s.nCommits + 1
    if b.sKind == "terrain" then
        local okK, bK, sKey = pcall(api.json.Stringify, b.flags or {})
        sKey = (okK and bK and sKey) or "?"
        local p = s.tPack
        if p and (p.sKey ~= sKey or #p.calls + #b.calls > WorldEdit.nPackMaxCalls) then FlushPack(); p = nil end
        if p == nil then
            p = { sKey = sKey, flags = b.flags, calls = {} }
            s.tPack = p
        end
        for _, c in ipairs(b.calls) do table.insert(p.calls, c) end
        p.nLast = Now()
        return
    end
    if b.sKind == "volume" then
        FlushPack()
        local bHas = (b.outlines and #b.outlines > 0) or (b.splines and #b.splines > 0)
        if bHas then Dispatch({ op = "volume", outlines = b.outlines, splines = b.splines }) end
    end
end

function WorldEdit.Tick()
    local p = S().tPack
    if p and Now() - (p.nLast or 0) >= WorldEdit.nPackIdle then FlushPack() end
end

local function DropBatch(b)
    if b and b.tSplines then
        local s = S()
        for _, sess in ipairs(b.tSplines) do s.tSplineByMo[sess.mo] = nil end
    end
end

local function HookUndo()
    local undo = api.undo
    if type(undo) ~= "table" or global.rawget(undo, "__pc2mpWorldEdit2") then return end
    local fnPreview, fnCommit, fnCancel = undo.PreviewChangeList, undo.CommitPreview, undo.CancelPreview
    undo.PreviewChangeList = function(...)
        local w, p = fnPreview(...)
        if not IsOwnReplay() then
            local s = S()
            if s.tBatch.sKind and p ~= nil then s.tByPreview[p] = s.tBatch else DropBatch(s.tBatch) end
            s.tBatch = {}
        end
        return w, p
    end
    undo.CommitPreview = function(tok, ...)
        local s = S()
        local b = tok ~= nil and s.tByPreview[tok] or nil
        if b then
            s.tByPreview[tok] = nil
            pcall(FinishSplines, b)
        end
        local w = fnCommit(tok, ...)
        if b and not IsOwnReplay() then
            local ok, err = pcall(Emit, b)
            if not ok then Log.Write("WorldEdit: Emit Fehler: " .. tostring(err)) end
        end
        return w
    end
    undo.CancelPreview = function(tok, ...)
        if tok ~= nil then
            local s = S()
            DropBatch(s.tByPreview[tok])
            s.tByPreview[tok] = nil
        end
        return fnCancel(tok, ...)
    end
    global.rawset(undo, "__pc2mpWorldEdit2", true)
end

function WorldEdit.Install(tWorldAPIs)
    WorldEdit.tWorldAPIs = tWorldAPIs
    HookUndo()
    local nT, nV = 0, 0
    if tWorldAPIs.gameterrain then
        for _, m in ipairs(tTerrainMethods) do if WrapMethod(tWorldAPIs.gameterrain, m, RecordTerrain) then nT = nT + 1 end end
    end
    if tWorldAPIs.volumes then
        for _, m in ipairs(tVolumeMethods) do if WrapMethod(tWorldAPIs.volumes, m, RecordVolume) then nV = nV + 1 end end
    end
    Log.Write("WorldEdit installiert: " .. nT .. " Terrain-, " .. nV .. " Wege-Funktionen erfasst")
end

function WorldEdit.AddListener(fn) table.insert(WorldEdit.tListeners, fn) end

-- ---------------------------------------------------------------- Nachspielen

local function Yield() coroutine.yield() end
local function YieldN(n) for _ = 1, n do coroutine.yield() end end

local function WaitOp(w)
    local n = 0
    while not api.undo.IsOperationComplete(w) and n < 600 do Yield(); n = n + 1 end
end

local function StartPreview(clh)
    while api.undo.IsBusy() do Yield() end
    local w, p = api.undo.PreviewChangeList(clh:GetFullUndoChangeList())
    WaitOp(w)
    return p
end

local function FinishPreview(p, sLabel)
    if p == nil then
        Log.Write("WorldEdit: " .. sLabel .. ": keine Vorschau (Undo belegt?)")
        return false
    end
    local bCan = api.undo.CanCommitPreview(p)
    local n = 0
    while bCan == nil and n < 300 do Yield(); n = n + 1; bCan = api.undo.CanCommitPreview(p) end
    if bCan then
        WaitOp(api.undo.CommitPreview(p))
        pcall(api.undo.Checkpoint, {})
        return true
    end
    local okR, tReasons = pcall(api.undo.GetCommitFailReasons, p)
    Log.Write("WorldEdit: " .. sLabel .. " Commit abgelehnt: " .. Log.ToStr(okR and tReasons or nil))
    WaitOp(api.undo.CancelPreview(p))
    return false
end

local function ApplyTerrain(t, nOffsetX)
    local tw = WorldEdit.tWorldAPIs
    local gt = tw.gameterrain
    local clh = tw.editors:CreateUndoOperationsHierarchy()
    local op = clh:GetTerrainEditOperation()
    if type(t.flags) == "table" then
        local f = Deser(t.flags)
        gt:SetTerrainEditOpCollisionFlags(op, f[1], f[2], f[3], f[4], f[5], f[6])
    end
    local nApplied = 0
    for i = 1, MaxIndex(t.calls or {}) do
        local c = t.calls[i]
        if c and type(c.m) == "string" and c.m:find("ToChangeList$") and type(gt[c.m]) == "function" then
            local a = Deser(c.a or {}, nOffsetX)
            a[1] = op
            gt[c.m](gt, table.unpack(a, 1, MaxIndex(a)))
            nApplied = nApplied + 1
        end
    end
    if nApplied == 0 then
        Log.Write("WorldEdit: Terrain-Aktion ohne Pinsel-Aufrufe")
        return false
    end
    return FinishPreview(StartPreview(clh), "Terrain (" .. nApplied .. " Stempel)")
end

local function ApplyOutlines(t, nOffsetX)
    local tw = WorldEdit.tWorldAPIs
    local vol = tw.volumes
    local clh = tw.editors:CreateUndoOperationsHierarchy()
    clh:BeginVolumeModificationsBlock()
    local composite = clh:CreateCompositeObject({})
    local n = 0
    for i = 1, MaxIndex(t.outlines) do
        local o = t.outlines[i]
        if o and o.outline then
            local tOutline = Deser(o.outline, nOffsetX)
            local ok, err = pcall(vol.CreateMoveObjectForVolumeOutline, vol, composite, clh, tOutline, o.prio, o.grounded)
            if ok then n = n + 1 else Log.Write("WorldEdit: Umriss-Weg Fehler: " .. tostring(err)) end
        end
    end
    clh:EndVolumeModificationsBlock()
    if n == 0 then return false end
    return FinishPreview(StartPreview(clh), "Weg (Umriss)")
end

local function ApplySpline(sp, nOffsetX)
    local tw = WorldEdit.tWorldAPIs
    local vol = tw.volumes
    TransformQ = TransformQ or require("TransformQ")
    Quaternion = Quaternion or require("Quaternion")
    -- Start: Transform (tq) bzw. Vektor (v3) aus der Erfassung, sonst Startpunkt aus GetSplineResultData
    local s0 = type(sp.start) == "table" and sp.start or {}
    local tStart
    if s0.tq then
        tStart = Deser(s0, nOffsetX)
    elseif s0.v3 then
        tStart = TransformQ.FromOrPos(Quaternion.Identity, Deser(s0, nOffsetX))
    elseif sp.resStart then
        tStart = TransformQ.FromOrPos(Quaternion.Identity, Deser(sp.resStart, nOffsetX))
    else
        Log.Write("WorldEdit: Spline ohne Startpunkt (" .. Log.ToStr(sp.start) .. ")")
        return false
    end
    local vEnd = (sp.resEnd and Deser(sp.resEnd, nOffsetX)) or (sp["end"] and Deser(sp["end"], nOffsetX))
    if vEnd == nil then Log.Write("WorldEdit: Spline ohne Endpunkt"); return false end

    local clh = tw.editors:CreateUndoOperationsHierarchy()
    clh:BeginVolumeModificationsBlock()
    local mo = vol:CreateMoveObjectForVolumeSpline(clh, tStart, sp.bCurve, sp.bClassic, sp.bRightAngled, false)
    if sp.pathData then
        local a = Deser(sp.pathData, nOffsetX)
        vol:SetSplinePathData(mo, table.unpack(a, 1, MaxIndex(a)))
    end
    if sp.borderData then
        local a = Deser(sp.borderData, nOffsetX)
        pcall(vol.SetSplineBorderData, vol, mo, table.unpack(a, 1, MaxIndex(a)))
    end
    if sp.buildOpts then
        local a = Deser(sp.buildOpts, nOffsetX)
        pcall(vol.SetSplineBuildingOptions, vol, mo, table.unpack(a, 1, MaxIndex(a)))
    end
    clh:EndVolumeModificationsBlock()
    local p = StartPreview(clh)
    if p == nil then return FinishPreview(nil, "Weg (Spline)") end
    -- wie VolumeSplineMode: Move-Objekt zu den Kontrollpunkten und zum Ende bewegen
    for i = 1, MaxIndex(sp.cps or {}) do
        local cp = sp.cps[i] and Deser(sp.cps[i], nOffsetX)
        if cp then
            mo:SetTransform(TransformQ.FromOrPos(Quaternion.Identity, cp))
            YieldN(2)
            local okC, bCan = pcall(vol.CanSetSplineControlPoint, vol, mo)
            if not okC or bCan then pcall(vol.SetSplineControlPoint, vol, mo, cp) end
            YieldN(2)
        end
    end
    mo:SetTransform(TransformQ.FromOrPos(Quaternion.Identity, vEnd))
    YieldN(4)
    return FinishPreview(p, "Weg (Spline)")
end

local function ApplyVolume(t, nOffsetX)
    local bAny, bOk = false, true
    if t.outlines and MaxIndex(t.outlines) > 0 then
        bAny = true
        bOk = ApplyOutlines(t, nOffsetX) and bOk
    end
    for i = 1, MaxIndex(t.splines or {}) do
        if t.splines[i] then
            bAny = true
            local okS, r = pcall(ApplySpline, t.splines[i], nOffsetX)
            if not okS then Log.Write("WorldEdit: Spline Fehler: " .. tostring(r)) end
            bOk = (okS and r) and bOk
        end
    end
    if not bAny then Log.Write("WorldEdit: Weg-Aktion ohne Daten") end
    return bAny and bOk
end

-- tAction lokal oder vom Netz (String-Schlüssel) ; nOffsetX nur für den Spiegel-Test
function WorldEdit.Apply(tAction, nOffsetX, fnDone)
    local Replay = require("pc2mp.replay")
    local t = Normalize(tAction)
    Replay.Enqueue("worldedit " .. tostring(t.op), function()
        if t.op == "terrain" then return ApplyTerrain(t, nOffsetX) end
        if t.op == "volume" then return ApplyVolume(t, nOffsetX) end
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
