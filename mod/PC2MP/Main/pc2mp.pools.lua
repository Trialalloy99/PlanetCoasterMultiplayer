-----------------------------------------------------------------------
--/  PC2MP Pools: Pool-Becken (Volumen) synchronisieren, egal mit welchem Werkzeug gebaut
--/  (Zeichnen, Stempel, Pinsel, Griffe, Verschieben). Statt jedes Werkzeug abzufangen:
--/    alle nPollEvery Frames pools:GetAllPools() -> Volumen-ID -> volumes:GetVolumeOutline(id)
--/    Umriss geändert -> { op="pool", key, prev, outline } ; Nachbau mit pc2mp.worldedit (CreateMoveObjectForVolumeOutline)
--/  Volumen-ID: volumes:GetVolumeIDFromEntityID(pool, false), sonst volumes:Raycast senkrecht über dem Pool.
--/  Alte Kopie entfernen: clh:BeginVolumeModificationsBlock(); clh:RemoveVolume(id, false) (VolumeEditHelper).
--/  Verifiziert im dekompilierten Lua (2026-11-07), noch NICHT im Spiel getestet. Felder werden geloggt.
-----------------------------------------------------------------------
local global = _G
local api = global.api
local type = global.type
local pairs = global.pairs
local ipairs = global.ipairs
local pcall = global.pcall
local tostring = global.tostring
local tonumber = global.tonumber
local math = global.math
local string = global.string
local require = global.require
local Log = require("pc2mp.log")

local Pools = {}
Pools.tListeners = {}
Pools.fnOnEvent = nil
Pools.nPollEvery = 120
Pools.nOffsetX = 0
Pools.nFrame = 0
Pools.tState = {}      -- Pool-Entity -> { key, sig, vol, centre }
Pools.tCopies = {}     -- key -> { centre } der Kopie (Mitspieler/Zwilling)
Pools.tIgnore = {}     -- Pool-Entity -> true (unsere Kopien)
Pools.bLogged = false

local function Note(s)
    Log.Write("Pools: " .. s)
    if Pools.fnOnEvent then pcall(Pools.fnOnEvent, s) end
end

local function Call(obj, m, ...)
    if obj == nil then return nil end
    local f = obj[m]
    if type(f) ~= "function" then return nil end
    local r = global.table.pack(pcall(f, obj, ...))
    if not r[1] then return nil end
    return global.table.unpack(r, 2, r.n)
end

local function Vec(v)
    if v == nil then return nil end
    local ok, x = pcall(function() return v:GetX() end)
    if ok and type(x) == "number" then return { x, v:GetY(), v:GetZ() } end
    ok, x = pcall(function() return v:X() end)
    if ok and type(x) == "number" then return { x, v:Y(), v:Z() } end
    return nil
end

local function EntPos(e)
    local ok, tr = pcall(api.transform.CalculateWorldTransform, e)
    if not ok or tr == nil then return nil end
    return Vec(Call(tr, "GetPos"))
end

function Pools.Install(tWorldAPIs)
    Pools.tWorldAPIs = tWorldAPIs
    Pools.nFrame = 0
    Pools.tState, Pools.tIgnore = {}, {}
    Pools.bPrimed = false
    local n = 0
    for _ in pairs(Pools.All()) do n = n + 1 end
    Log.Write("Pools installiert: " .. n .. " Pools im Park")
end

function Pools.All()
    local o = {}
    local t = Call(Pools.tWorldAPIs and Pools.tWorldAPIs.pools, "GetAllPools")
    if type(t) == "table" then for _, e in pairs(t) do o[#o + 1] = e end end
    return o
end

-- Volumen-ID eines Pools
function Pools.VolumeOf(ePool)
    local vol = Pools.tWorldAPIs.volumes
    local id = Call(vol, "GetVolumeIDFromEntityID", ePool, false)
    if id ~= nil then return id, "entity" end
    local p = EntPos(ePool)
    if p == nil then return nil, "keine Position" end
    local Vector3 = require("Vector3")
    local nDist, nVolume = Call(vol, "Raycast", Vector3:new(p[1], p[2] + 30, p[3]), Vector3:new(0, -1, 0))
    if nVolume ~= nil then return nVolume, "raycast" end
    return nil, "nicht gefunden"
end

local function Centre(tOutline)
    local sx, sy, sz, n = 0, 0, 0, 0
    for i = 1, 4096 do
        local pt = tOutline[i]
        if pt == nil then break end
        local v = Vec(pt.vPos)
        if v then sx, sy, sz, n = sx + v[1], sy + v[2], sz + v[3], n + 1 end
    end
    if n == 0 then return nil end
    return { sx / n, sy / n, sz / n }
end

local function Key(c) return string.format("%d_%d_%d", math.floor(c[1] + 0.5), math.floor(c[2] + 0.5), math.floor(c[3] + 0.5)) end

function Pools.Tick()
    Pools.nFrame = Pools.nFrame + 1
    if Pools.tWorldAPIs == nil or Pools.nFrame % Pools.nPollEvery ~= 0 then return end
    local okR, Replay = pcall(require, "pc2mp.replay")
    if okR and Replay.IsBusy and Replay.IsBusy() then return end
    local WorldEdit = require("pc2mp.worldedit")
    local tSeen = {}
    for _, e in ipairs(Pools.All()) do
        tSeen[e] = true
        if not Pools.tIgnore[e] then
            local nVol, sHow = Pools.VolumeOf(e)
            local tOutline = nVol and Call(Pools.tWorldAPIs.volumes, "GetVolumeOutline", nVol) or nil
            if not Pools.bLogged then
                Pools.bLogged = true
                Log.Write("Pools: erster Pool " .. tostring(e) .. " -> Volumen " .. tostring(nVol) .. " (" .. tostring(sHow)
                    .. "), Umriss " .. (type(tOutline) == "table" and ("Typ " .. tostring(tOutline.sOutlineType) .. ", Belag "
                    .. tostring(tOutline.sRenderType)) or "fehlt"))
            end
            if type(tOutline) == "table" then
                local tSer = WorldEdit.Ser(tOutline)
                local okJ, bOk, sSig = pcall(api.json.Stringify, tSer)
                sSig = (okJ and bOk) and sSig or tostring(#tSer)
                local c = Centre(tOutline)
                local st = Pools.tState[e]
                if c and (st == nil or st.sig ~= sSig) then
                    -- ist das eine unserer Kopien? (Position = Kopie-Position)
                    local bCopy = false
                    for _, cp in pairs(Pools.tCopies) do
                        if cp.centre and math.abs(cp.centre[1] - c[1]) < 1.5 and math.abs(cp.centre[3] - c[3]) < 1.5 then bCopy = true end
                    end
                    if bCopy then
                        Pools.tIgnore[e] = true
                    else
                        local sKey = st and st.key or Key(c)
                        Pools.tState[e] = { key = sKey, sig = sSig, centre = c }
                        if Pools.bPrimed then
                            Note((st and "Pool geändert" or "Pool gebaut") .. " (" .. sKey .. ", Typ " .. tostring(tOutline.sOutlineType) .. ")")
                            Pools.Dispatch({ op = "pool", key = sKey, outline = tSer,
                                             prio = tOutline.nClipPriority, grounded = tOutline.nGroundedRequest })
                        end
                    end
                end
            end
        end
    end
    for e, st in pairs(Pools.tState) do
        if not tSeen[e] then
            Pools.tState[e] = nil
            Note("Pool abgerissen (" .. st.key .. ")")
            Pools.Dispatch({ op = "pooldel", key = st.key })
        end
    end
    Pools.bPrimed = true
end

function Pools.Dispatch(t)
    for _, fn in ipairs(Pools.tListeners) do
        local ok, err = pcall(fn, t)
        if not ok then Log.Write("Pools: Listener Fehler: " .. tostring(err)) end
    end
end

-- Kopie entfernen (Replay-Job)
local function RemoveCopy(sKey)
    local cp = Pools.tCopies[sKey]
    if cp == nil or cp.centre == nil then return true end
    local vol = Pools.tWorldAPIs.volumes
    local Vector3 = require("Vector3")
    local _, nVolume = Call(vol, "Raycast", Vector3:new(cp.centre[1], cp.centre[2] + 30, cp.centre[3]), Vector3:new(0, -1, 0))
    if nVolume == nil then return true end
    local clh = Pools.tWorldAPIs.editors:CreateUndoOperationsHierarchy()
    clh:BeginVolumeModificationsBlock()
    pcall(clh.RemoveVolume, clh, nVolume, false)
    clh:EndVolumeModificationsBlock()
    local w, p = api.undo.PreviewChangeList(clh:GetFullUndoChangeList())
    local n = 0
    while not api.undo.IsOperationComplete(w) and n < 600 do global.coroutine.yield(); n = n + 1 end
    if api.undo.CanCommitPreview(p) then
        local wc = api.undo.CommitPreview(p)
        n = 0
        while not api.undo.IsOperationComplete(wc) and n < 600 do global.coroutine.yield(); n = n + 1 end
        return true
    end
    pcall(api.undo.CancelPreview, p)
    return false
end

-- Mitspieler-Pool bzw. Zwilling setzen/ersetzen
function Pools.Apply(a, sFrom)
    if type(a) ~= "table" or a.key == nil then return end
    local sKey = tostring(a.key)
    local Replay = require("pc2mp.replay")
    local WorldEdit = require("pc2mp.worldedit")
    if a.op == "pooldel" then
        Replay.Enqueue("pool remove " .. sKey, function() return RemoveCopy(sKey) end)
        Pools.tCopies[sKey] = nil
        Note("Pool entfernt (" .. sKey .. ", von " .. tostring(sFrom) .. ")")
        return
    end
    local tOutline = WorldEdit.Normalize(a.outline)
    local c = Centre(WorldEdit.Deser(tOutline, Pools.nOffsetX))
    Replay.Enqueue("pool remove old " .. sKey, function() return RemoveCopy(sKey) end)
    Pools.tCopies[sKey] = { centre = c }
    WorldEdit.Apply({ op = "volume", outlines = { { outline = tOutline, prio = a.prio, grounded = a.grounded } } },
        Pools.nOffsetX, function(bOk, r1)
            Note("Pool " .. sKey .. " nachgebaut -> " .. tostring(bOk and r1 ~= false) .. " (von " .. tostring(sFrom) .. ")")
        end)
end

return Pools
