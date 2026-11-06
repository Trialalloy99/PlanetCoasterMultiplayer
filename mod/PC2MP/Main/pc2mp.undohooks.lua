-----------------------------------------------------------------------
--/  PC2MP: Hooks auf das Undo/ChangeList-System des Spiels.
--/  Phase 1 (Discovery): nur mitloggen, nichts verändern.
-----------------------------------------------------------------------
local global = _G
local api = global.api
local type = global.type
local pairs = global.pairs
local pcall = global.pcall
local tostring = global.tostring
local getmetatable = global.getmetatable
local table = global.table
local Log = require("pc2mp.log")

local UndoHooks = {}
UndoHooks.bUndoWrapped = false
UndoHooks.tWrappedMetatables = {}

local function WrapFunctionInTable(tTarget, sKey, sLabel)
    local fnOrig = tTarget[sKey]
    if type(fnOrig) ~= "function" then
        return false
    end
    local ok = pcall(function()
        tTarget[sKey] = function(...)
            Log.Write("CALL " .. sLabel .. "(" .. Log.Args(...) .. ")")
            local tRet = table.pack(fnOrig(...))
            Log.Write("  RET " .. sLabel .. " -> " .. Log.Args(table.unpack(tRet, 1, tRet.n)))
            return table.unpack(tRet, 1, tRet.n)
        end
    end)
    return ok
end

-- Alle Methoden eines nativen Objekts (über dessen Metatable) einmalig wrappen
-- und die verfügbaren Methodennamen loggen.
function UndoHooks.WrapObjectMethods(obj, sLabel, tSkip)
    local mt = getmetatable(obj)
    if type(mt) ~= "table" then
        Log.Write("META " .. sLabel .. ": keine Metatable lesbar (type=" .. type(mt) .. ")")
        return
    end
    local idx = mt.__index
    if type(idx) ~= "table" then
        Log.Write("META " .. sLabel .. ": __index ist " .. type(idx))
        return
    end
    if UndoHooks.tWrappedMetatables[idx] then
        return
    end
    UndoHooks.tWrappedMetatables[idx] = true
    local tNames = {}
    for k, v in pairs(idx) do
        if type(v) == "function" then
            table.insert(tNames, tostring(k))
        end
    end
    table.sort(tNames)
    Log.Write("META " .. sLabel .. " Methoden: " .. table.concat(tNames, ", "))
    -- Bewusst KEIN Wrapping der nativen Metatable mehr: Verdacht auf Absturz beim Beenden.
end

-- api.undo.* wrappen (globale Tabelle, früh möglich).
function UndoHooks.WrapUndoAPI()
    -- Merker in api ablegen: Module werden pro Environment neu geladen, api ist global geteilt.
    api.pc2mp = api.pc2mp or {}
    if api.pc2mp.bUndoWrapped then return end
    local undo = api.undo
    Log.Write("api.undo type=" .. type(undo))
    if type(undo) ~= "table" then return end
    api.pc2mp.bUndoWrapped = true
    local tNames = {
        "PreviewChangeList", "CommitPreview", "CancelPreview", "CanCommitPreview",
        "Checkpoint", "Undo", "Redo", "Operation_Undo", "ClearHistory",
    }
    for _, sName in global.ipairs(tNames) do
        local bOk = WrapFunctionInTable(undo, sName, "api.undo." .. sName)
        Log.Write("wrap api.undo." .. sName .. " -> " .. tostring(bOk))
    end
    UndoHooks.bUndoWrapped = true
end

-- Nur lesen: Typ der Editors-API und Methodennamen loggen, nichts ersetzen.
function UndoHooks.InspectEditorsAPI(tWorldAPIs)
    local editors = tWorldAPIs and tWorldAPIs.editors
    Log.Write("tWorldAPIs.editors type=" .. type(editors))
    if editors == nil then return end
    if type(editors) == "table" then
        local tNames = {}
        for k, v in pairs(editors) do
            if type(v) == "function" then table.insert(tNames, tostring(k)) end
        end
        table.sort(tNames)
        Log.Write("editors Funktionen: " .. table.concat(tNames, ", "))
    end
    UndoHooks.WrapObjectMethods(editors, "editorsAPI")
    -- Eine Hierarchy zum Ansehen erzeugen (wird nie committed, nur Methoden auflisten)
    local okH, clh = pcall(function() return editors:CreateUndoOperationsHierarchy() end)
    Log.Write("Test-Hierarchy: ok=" .. tostring(okH) .. " " .. Log.ToStr(clh))
    if okH and clh ~= nil then
        UndoHooks.WrapObjectMethods(clh, "Hierarchy")
    end
end

-- (Alt, derzeit ungenutzt) Editors-World-API wrappen.
function UndoHooks.WrapEditorsAPI(tWorldAPIs)
    local editors = tWorldAPIs and tWorldAPIs.editors
    Log.Write("tWorldAPIs.editors type=" .. type(editors))
    if editors == nil then return end
    local target = editors
    if type(editors) ~= "table" then
        local mt = getmetatable(editors)
        target = (type(mt) == "table" and type(mt.__index) == "table") and mt.__index or nil
    end
    if target == nil then
        Log.Write("editors API nicht wrapbar")
        return
    end
    local fnOrig = target.CreateUndoOperationsHierarchy
    if type(fnOrig) ~= "function" or UndoHooks.bEditorsWrapped then
        Log.Write("CreateUndoOperationsHierarchy type=" .. type(fnOrig))
        return
    end
    local ok = pcall(function()
        target.CreateUndoOperationsHierarchy = function(...)
            local clh = fnOrig(...)
            Log.Write("NEW UndoOperationsHierarchy " .. Log.ToStr(clh))
            -- Methoden der Hierarchy (CreateNewPart, EditExistingPart, ...) einmalig wrappen
            pcall(UndoHooks.WrapObjectMethods, clh, "Hierarchy")
            return clh
        end
    end)
    UndoHooks.bEditorsWrapped = ok
    Log.Write("wrap editors.CreateUndoOperationsHierarchy -> " .. tostring(ok))
end

return UndoHooks
