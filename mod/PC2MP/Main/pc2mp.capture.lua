-----------------------------------------------------------------------
--/  PC2MP Capture: zeichnet jede festgeschriebene Bau-Aktion als JSON-Datensatz auf.
--/
--/  Kette:  Hierarchy-Methoden (CreateNewPart, EditExistingPart, ...)  -> Record
--/          hierarchy:GetFullUndoChangeList() -> changeList            -> Record
--/          api.undo.PreviewChangeList(changeList) -> token             -> Record
--/          api.undo.CommitPreview(token)  => Record + finale Transforms der Edit-Objekte
--/  Ergebnis: Log-Zeile "ACTION {json}" (später: an den Server senden).
-----------------------------------------------------------------------
local global = _G
local api = global.api
local type = global.type
local pairs = global.pairs
local ipairs = global.ipairs
local pcall = global.pcall
local tostring = global.tostring
local getmetatable = global.getmetatable
local setmetatable = global.setmetatable
local table = global.table
local string = global.string
local Log = require("pc2mp.log")

local Capture = {}

-- Geteilter Zustand über alle Lua-Environments (Module werden pro Environment neu geladen).
api.pc2mp = api.pc2mp or {}
local S = api.pc2mp
S.tHierRec = S.tHierRec or setmetatable({}, { __mode = "k" })
S.tClRec = S.tClRec or setmetatable({}, { __mode = "k" })
S.tTokRec = S.tTokRec or setmetatable({}, { __mode = "k" })
S.nNextRec = S.nNextRec or 1
S.nNextAction = S.nNextAction or 1
S.tListeners = S.tListeners or {}

-- Methoden, deren Aufrufe wir im Record mitschreiben (alle anderen werden nur durchgereicht)
local tRecordCalls = {
    CreateNewPart = true, CreateNewParts = true,
    EditExistingPart = true, EditExistingParts = true,
    DestroyExistingPart = true, DestroyExistingParts = true,
    CloneExistingPart = true, CloneExistingParts = true, CloneExistingPartDuplicates = true,
    CreateCompositeObject = true, AddPartsToCompositeObject = true, AddBlueprintToCompositeObject = true,
    CreateParkZone = true, DestroyParkZone = true, ModifyParkZoneShape = true,
    ModifyUtilityConnection = true, RemoveAllConnectionsFromEntity = true,
    BeginVolumeModificationsBlock = true, EndVolumeModificationsBlock = true, RemoveVolume = true,
    SetParkZoneColour = true, SetWaterVolumeColour = true,
    AddCashDelta = true, SetCashPos = true,
}
-- Methoden, die Edit-Objekte liefern (deren finale Transforms wir beim Commit abfragen)
local tEditObjectSources = {
    StartEditingPart_Scenery = true, StartEditingParts_Scenery = true,
    StartEditingPart_Group = true, StartEditingParts_Group = true,
    GetOngoingPartEdit_Scenery = true, GetOngoingPartEdit_Group = true, GetOngoingPartEdits_Group = true,
}

---------------------------------------------------------------------
-- Serialisierung
---------------------------------------------------------------------
local function TryCall(obj, sMethod, ...)
    local ok, a, b, c = pcall(function(...) return obj[sMethod](obj, ...) end, ...)
    if ok then return a, b, c end
    return nil
end

local function Vec(v)
    if v == nil then return nil end
    local x, y, z = TryCall(v, "GetX"), TryCall(v, "GetY"), TryCall(v, "GetZ")
    if type(x) == "number" then return { x, y, z } end
    return nil
end

-- Beliebigen Wert in JSON-taugliche Daten umwandeln
function Capture.Plain(v, nDepth)
    nDepth = nDepth or 0
    local t = type(v)
    if t == "number" or t == "string" or t == "boolean" or t == "nil" then
        return v
    elseif t == "table" then
        if nDepth > 3 then return "<table>" end
        local out = {}
        for k, val in pairs(v) do
            out[tostring(k)] = Capture.Plain(val, nDepth + 1)
        end
        return out
    elseif t == "userdata" then
        local vec = Vec(v)
        if vec then return { vec = vec } end
        local ok, s = pcall(tostring, v)
        return "<" .. (ok and s or "userdata") .. ">"
    end
    return "<" .. t .. ">"
end

-- Finale Daten eines Edit-Objekts
function Capture.DescribeEditObject(eo)
    local d = {}
    d.partID = TryCall(eo, "GetPlacementPartID")
    local tr = TryCall(eo, "GetTransform")
    if tr ~= nil then
        d.pos = Vec(TryCall(tr, "GetPos"))
        local q = TryCall(tr, "GetOr")
        if q ~= nil then d.rot = Vec(TryCall(q, "ToPackedAxisAngle")) end
    end
    local sc = TryCall(eo, "GetScale")
    d.scale = (type(sc) == "number") and sc or Capture.Plain(sc)
    d.isGroup = TryCall(eo, "IsCompositeObject")
    d.isGrid = TryCall(eo, "IsGridObject")
    return d
end

---------------------------------------------------------------------
-- Einmalige Discovery: Methodennamen eines nativen Objekts loggen
---------------------------------------------------------------------
S.tLoggedMeta = S.tLoggedMeta or {}
function Capture.LogMethodsOnce(obj, sLabel)
    if S.tLoggedMeta[sLabel] then return end
    S.tLoggedMeta[sLabel] = true
    local mt = getmetatable(obj)
    if type(mt) ~= "table" or type(mt.__index) ~= "table" then
        Log.Write("META " .. sLabel .. ": nicht lesbar (" .. type(mt) .. ")")
        return
    end
    local tNames = {}
    for k, v in pairs(mt.__index) do
        if type(v) == "function" then table.insert(tNames, tostring(k)) end
    end
    table.sort(tNames)
    Log.Write("META " .. sLabel .. ": " .. table.concat(tNames, ", "))
end

---------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------
local function GetRec(clh)
    local rec = S.tHierRec[clh]
    if rec == nil then
        rec = { id = S.nNextRec, calls = {}, editObjects = {} }
        S.nNextRec = S.nNextRec + 1
        S.tHierRec[clh] = rec
    end
    return rec
end

local function AddEditObjects(rec, result)
    if type(result) == "table" then
        for _, eo in ipairs(result) do table.insert(rec.editObjects, eo) end
    elseif result ~= nil then
        table.insert(rec.editObjects, result)
    end
end

-- Methoden der Hierarchy-Metatable wrappen (gilt für alle Hierarchy-Instanzen).
function Capture.HookHierarchy(clhSample)
    if S.bHierarchyHooked then return end
    local mt = getmetatable(clhSample)
    if type(mt) ~= "table" or type(mt.__index) ~= "table" then
        Log.Write("Capture: Hierarchy-Metatable nicht lesbar")
        return
    end
    local idx = mt.__index
    local nWrapped = 0
    for sName, fnOrig in pairs(idx) do
        if type(fnOrig) == "function" and (tRecordCalls[sName] or tEditObjectSources[sName] or sName == "GetFullUndoChangeList") then
            local ok = pcall(function()
                idx[sName] = function(self, ...)
                    S.nHierCalls = (S.nHierCalls or 0) + 1
                    local r1, r2, r3 = fnOrig(self, ...)
                    local okRec, err = pcall(function(...)
                        local rec = GetRec(self)
                        if sName == "GetFullUndoChangeList" then
                            if r1 ~= nil then S.tClRec[r1] = rec end
                        elseif tEditObjectSources[sName] then
                            AddEditObjects(rec, r1)
                        else
                            table.insert(rec.calls, { m = sName, a = Capture.Plain({ ... }) })
                        end
                    end, ...)
                    if not okRec then Log.Write("Capture-Fehler in " .. sName .. ": " .. tostring(err)) end
                    return r1, r2, r3
                end
            end)
            if ok then nWrapped = nWrapped + 1 end
        end
    end
    S.bHierarchyHooked = true
    Log.Write("Capture: " .. nWrapped .. " Hierarchy-Methoden gehookt")
end

local function WrapUndo(sName, fnHook)
    local undo = api.undo
    local fnOrig = undo[sName]
    if type(fnOrig) ~= "function" then return false end
    local ok = pcall(function()
        undo[sName] = function(...) return fnHook(fnOrig, ...) end
    end)
    return ok
end

function Capture.EmitAction(tAction)
    tAction.seq = S.nNextAction
    S.nNextAction = S.nNextAction + 1
    local okJ, bOk, sJson = pcall(api.json.Stringify, tAction)
    if not (okJ and bOk) then
        sJson = "<json fehlgeschlagen: " .. tostring(bOk) .. " " .. tostring(sJson) .. ">"
    end
    Log.Write("ACTION " .. tostring(sJson))
    for _, fn in ipairs(S.tListeners) do pcall(fn, tAction, sJson) end
end

function Capture.HookUndoAPI()
    if S.bUndoHooked then return end
    if type(api.undo) ~= "table" then
        Log.Write("Capture: api.undo fehlt")
        return
    end
    S.bUndoHooked = true

    WrapUndo("PreviewChangeList", function(fnOrig, cl, ...)
        Capture.LogMethodsOnce(cl, "ChangeList")
        local waitToken, previewToken = fnOrig(cl, ...)
        if previewToken ~= nil then Capture.LogMethodsOnce(previewToken, "PreviewToken") end
        local rec = S.tClRec[cl]
        if rec == nil and not S.bLoggedMiss then
            S.bLoggedMiss = true
            Log.Write("DIAG: ChangeList ohne Record. hierCalls=" .. tostring(S.nHierCalls)
                .. " cl=" .. Log.ToStr(cl) .. " extraArgs=" .. Log.Args(...))
        end
        if rec ~= nil and previewToken ~= nil then S.tTokRec[previewToken] = rec end
        return waitToken, previewToken
    end)

    WrapUndo("CommitPreview", function(fnOrig, token, ...)
        local rec = S.tTokRec[token]
        local tObjs = {}
        if rec ~= nil then
            -- Transforms VOR dem Commit lesen (Edit-Objekte können danach ungültig sein)
            for i, eo in ipairs(rec.editObjects) do
                if i == 1 then
                    Capture.LogMethodsOnce(eo, "EditObject")
                    local tr = TryCall(eo, "GetTransform")
                    if tr ~= nil then Capture.LogMethodsOnce(tr, "Transform") end
                end
                local okD, d = pcall(Capture.DescribeEditObject, eo)
                table.insert(tObjs, okD and d or { error = tostring(d) })
            end
        end
        local w = fnOrig(token, ...)
        local okE, err = pcall(Capture.EmitAction, {
            op = "commit",
            rec = rec and rec.id or nil,
            calls = rec and rec.calls or nil,
            objects = tObjs,
            unknown = (rec == nil) or nil,
            hc = S.nHierCalls or 0,
        })
        if not okE then Log.Write("EmitAction Fehler: " .. tostring(err)) end
        return w
    end)

    WrapUndo("Undo", function(fnOrig, ...)
        pcall(Capture.EmitAction, { op = "undo" })
        return fnOrig(...)
    end)
    WrapUndo("Redo", function(fnOrig, ...)
        pcall(Capture.EmitAction, { op = "redo" })
        return fnOrig(...)
    end)
    Log.Write("Capture: api.undo gehookt")
end

-- Im Park aufrufen: Test-Hierarchy erzeugen, um an die Metatable zu kommen.
function Capture.Install(tWorldAPIs)
    Capture.HookUndoAPI()
    local editors = tWorldAPIs and tWorldAPIs.editors
    if editors == nil then
        Log.Write("Capture: editors API fehlt")
        return
    end
    local ok, clh = pcall(function() return editors:CreateUndoOperationsHierarchy() end)
    if ok and clh ~= nil then
        Capture.HookHierarchy(clh)
        -- Selbsttest: wirkt das Metatable-Wrapping auf eine NEUE Hierarchy?
        local okT, sRes = pcall(function()
            local clh2 = editors:CreateUndoOperationsHierarchy()
            local nBefore = S.nHierCalls or 0
            local cl2 = clh2:GetFullUndoChangeList()
            local mt1, mt2 = getmetatable(clh), getmetatable(clh2)
            local apis2 = api.world.GetWorldAPIs()
            return "wrapperAufgerufen=" .. tostring((S.nHierCalls or 0) > nBefore)
                .. " recGesetzt=" .. tostring(S.tHierRec[clh2] ~= nil)
                .. " clRec=" .. tostring(cl2 ~= nil and S.tClRec[cl2] ~= nil)
                .. " gleicheMetatable=" .. tostring(global.rawequal(mt1, mt2))
                .. " mtType=" .. type(mt1)
                .. " gleicheEditorsTabelle=" .. tostring(global.rawequal(apis2 and apis2.editors, editors))
                .. " gleicheWorldAPIs=" .. tostring(global.rawequal(apis2, tWorldAPIs))
                .. " hatMetatableFeld=" .. tostring(type(mt1) == "table" and global.rawget(mt1, "__metatable") ~= nil)
        end)
        Log.Write("SELBSTTEST " .. tostring(okT) .. " " .. tostring(sRes))
    else
        Log.Write("Capture: CreateUndoOperationsHierarchy fehlgeschlagen: " .. tostring(clh))
    end
end

-- Andere Module (Netzwerk) können sich für Aktionen registrieren.
function Capture.AddListener(fn)
    table.insert(S.tListeners, fn)
end

return Capture
