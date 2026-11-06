-----------------------------------------------------------------------
--/  PC2MP Park-Manager: läuft im Park (CPTEnvironment).
--/  Holt die World-APIs und installiert die Editor-Hooks.
-----------------------------------------------------------------------
local global = _G
local api = global.api
local pcall = global.pcall
local tostring = global.tostring
local require = global.require
---@diagnostic disable-next-line: deprecated
local module = global.module

local Mutators = require("Environment.ModuleMutators")
local Log = require("pc2mp.log")
local UndoHooks = require("pc2mp.undohooks")

local PC2MPManager = module(..., Mutators.Manager())

function PC2MPManager.Init(self, _tProperties, _tEnvironment)
    Log.Write("Manager Init")
end

function PC2MPManager.Activate(self)
    Log.Write("Manager Activate")
    UndoHooks.WrapUndoAPI()
    local ok, tWorldAPIs = pcall(api.world.GetWorldAPIs)
    if ok then
        local ok2, err = pcall(UndoHooks.InspectEditorsAPI, tWorldAPIs)
        if not ok2 then Log.Write("InspectEditorsAPI Fehler: " .. tostring(err)) end
    else
        Log.Write("GetWorldAPIs Fehler: " .. tostring(tWorldAPIs))
    end
end

function PC2MPManager.Advance(self, _nDeltaTime)
end

function PC2MPManager.Deactivate(self)
    Log.Write("Manager Deactivate")
end

function PC2MPManager.Shutdown(self)
    Log.Write("Manager Shutdown")
end
