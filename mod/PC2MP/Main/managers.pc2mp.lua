-----------------------------------------------------------------------
--/  PC2MP Park-Manager: läuft im Park (CPTEnvironment).
--/  Holt die World-APIs und installiert die Capture-Hooks.
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
local Capture = require("pc2mp.capture")

local PC2MPManager = module(..., Mutators.Manager())

function PC2MPManager.Init(self, _tProperties, _tEnvironment)
    Log.Write("Manager Init")
end

function PC2MPManager.Activate(self)
    Log.Write("Manager Activate")
    local ok, tWorldAPIs = pcall(api.world.GetWorldAPIs)
    if not ok then
        Log.Write("GetWorldAPIs Fehler: " .. tostring(tWorldAPIs))
        return
    end
    local ok2, err = pcall(Capture.Install, tWorldAPIs)
    if not ok2 then Log.Write("Capture.Install Fehler: " .. tostring(err)) end
end

function PC2MPManager.Advance(self, _nDeltaTime)
end

function PC2MPManager.Deactivate(self)
    Log.Write("Manager Deactivate")
end

function PC2MPManager.Shutdown(self)
    Log.Write("Manager Shutdown")
end
