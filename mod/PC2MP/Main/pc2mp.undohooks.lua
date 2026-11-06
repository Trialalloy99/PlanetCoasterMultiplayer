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
    for _, sName in global.ipairs(tNames) do
        if not (tSkip and tSkip[sName]) then
            local bOk = WrapFunctionInTable(idx, sName, sLabel .. ":" .. sName)
            if not bOk then
                Log.Write("META " .. sLabel .. ":" .. sName .. " nicht wrapbar")
            end
        end
    end
end

-- api.undo.* wrappen (globale Tabelle, früh möglich).
function UndoHooks.WrapUndoAPI()
    if UndoHooks.bUndoWrapped then return end
    local undo = api.undo
    Log.Write("api.undo type=" .. type(undo))
    if type(undo) ~= "table" then return end
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

-- Editors-World-API wrappen (erst verfügbar, wenn eine Welt/Park geladen ist).
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
