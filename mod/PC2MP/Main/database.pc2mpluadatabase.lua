-----------------------------------------------------------------------
--/  PC2MP Lua-Datenbank: Einstiegspunkt der Mod (wird von ACSE gefunden).
-----------------------------------------------------------------------
local global = _G
local table = global.table
local type = global.type
local tostring = global.tostring
local pcall = global.pcall
---@diagnostic disable-next-line: undefined-field
local api = global.api

local LuaDB = {}

function LuaDB.AddContentToCall(_tContentToCall)
    if not api.acse or api.acse.versionNumber < 0.7 then
        return
    end
    table.insert(_tContentToCall, require("database.pc2mpluadatabase"))
end

-- Diagnose: was steht uns in dieser Lua-Umgebung zur Verfügung?
local function Diagnose(Log)
    local pkg = global.package
    Log.Write("==== PC2MP Diagnose ====")
    Log.Write("ACSE " .. tostring(api.acse and api.acse.versionNumber))
    Log.Write("package=" .. type(pkg))
    if type(pkg) == "table" then
        Log.Write("package.loadlib=" .. type(pkg.loadlib) .. " cpath=" .. tostring(pkg.cpath))
        Log.Write("package.searchers=" .. type(pkg.searchers))
    end
    Log.Write("io=" .. type(global.io) .. " os=" .. type(global.os) .. " debug=" .. type(global.debug))
    Log.Write("api.json=" .. type(api.json) .. " api.undo=" .. type(api.undo) .. " api.world=" .. type(api.world))
    Log.Write("WriteStringToFile funktioniert=" .. tostring(Log.bFileWorks))
    Log.Write("native DLL=" .. tostring(Log.fnNative ~= nil) .. " fehler=" .. tostring(Log.sNativeError))
end

function LuaDB.Init()
    local Log = require("pc2mp.log")
    local ok, err = pcall(Diagnose, Log)
    if not ok then Log.Write("Diagnose Fehler: " .. tostring(err)) end
end

-- Unseren Manager im Park-Environment registrieren (wie ProTrack).
LuaDB.tManagers = {
    ["Environments.CPTEnvironment"] = {
        ["managers.pc2mp"] = {},
    },
    -- spielweit (Hauptmenü + Park): Dev-UI-Steuerung (#21)
    ["Game.GameEnvironment"] = {
        ["managers.pc2mpgame"] = {},
    },
}

-- ACSE: Hook auf das Spieler-Undo (wird beim ersten require des Moduls angewendet)
function LuaDB.AddLuaHooks(_fnAdd)
    _fnAdd("Editors.Shared.BaseEditMode", function(tModule)
        require("pc2mp.undohook").AcseHook(tModule)
    end)
    -- Fallback für die Dev-UI, falls der Manager in Game.GameEnvironment nicht greift (#21)
    _fnAdd("Managers.ParkLoadSaveManager", function(tModule)
        require("pc2mp.menu").AcseHookPlm(tModule)
    end)
    -- Hauptmenü: diese Module laden erst mit der Menü-Welt, also nach ACSE (#21)
    _fnAdd("StartScreen.Shared.StartScreenStateHelper", function(tModule)
        require("pc2mp.menu").AcseHookAdvance(tModule, "menu-statehelper")
    end)
    _fnAdd("StartScreen.Globe.GlobeMode", function(tModule)
        require("pc2mp.menu").AcseHookAdvance(tModule, "menu-globemode")
    end)
end

function LuaDB.AddLuaManagers(_fnAdd)
    for sEnvironmentName, tParams in global.pairs(LuaDB.tManagers) do
        _fnAdd(sEnvironmentName, tParams)
    end
end

return LuaDB
