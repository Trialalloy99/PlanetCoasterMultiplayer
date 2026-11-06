-----------------------------------------------------------------------
--/  PC2MP Undo-Hook: Strg+Z / Strg+Y des Spielers laufen über
--/  BaseEditMode._DoRequestedUndoRedo. Im Multiplayer ersetzen wir das durch
--/  den eigenen Undo-Stack (nur eigene Aktionen, pc2mp.sync).
--/  Interne Undo-Aufrufe des Spiels (Parkzonen, Eingänge, ...) bleiben unberührt.
-----------------------------------------------------------------------
local global = _G
local api = global.api
local type = global.type
local pcall = global.pcall
local tostring = global.tostring
local Log = require("pc2mp.log")

local UndoHook = {}
UndoHook.sModule = "Editors.Shared.BaseEditMode"

function UndoHook.Patch(tModule, sVia)
    if type(tModule) ~= "table" or tModule.__PC2MPUndoHook then return false end
    local fnOrig = tModule._DoRequestedUndoRedo
    if type(fnOrig) ~= "function" then
        Log.Write("UndoHook: _DoRequestedUndoRedo nicht gefunden (" .. tostring(sVia) .. ")")
        return false
    end
    tModule._DoRequestedUndoRedo = function(self, ...)
        local S = api.pc2mp and api.pc2mp.Sync
        if S and S.bActive then
            local t = self.tBaseEditMode
            while t.nUndoSteps ~= 0 do
                if t.nUndoSteps > 0 then
                    t.nUndoSteps = t.nUndoSteps - 1
                    pcall(S.Undo)
                else
                    t.nUndoSteps = t.nUndoSteps + 1
                    pcall(S.Redo)
                end
            end
            return
        end
        return fnOrig(self, ...)
    end
    tModule.__PC2MPUndoHook = true
    Log.Write("UndoHook: installiert (" .. tostring(sVia) .. ")")
    return true
end

-- Für LuaDB.AddLuaHooks (ACSE wendet das beim ersten require des Moduls an)
function UndoHook.AcseHook(tModule)
    UndoHook.Patch(tModule, "ACSE-Hook")
end

-- Fallback: Modul ist schon geladen -> direkt patchen
function UndoHook.EnsurePatched()
    local tMod = global.package.loaded[UndoHook.sModule] or global.package.loaded[global.string.lower(UndoHook.sModule)]
    if tMod == nil then
        Log.Write("UndoHook: Modul noch nicht geladen")
        return false
    end
    if tMod.__PC2MPUndoHook then return true end
    return UndoHook.Patch(tMod, "package.loaded")
end

return UndoHook
