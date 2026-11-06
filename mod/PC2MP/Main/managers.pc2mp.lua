-----------------------------------------------------------------------
--/  PC2MP Park-Manager: läuft im Park (CPTEnvironment).
--/  Registriert die Event-Erkennung, treibt Replay-Jobs pro Frame an
--/  und aktiviert (vorerst) den lokalen Spiegel-Test.
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
local Events = require("pc2mp.events")
local Replay = require("pc2mp.replay")
local Mirror = require("pc2mp.mirror")

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
    Replay.Init(tWorldAPIs)
    Events.fnIsSuppressing = Replay.IsSuppressing
    Events.fnOnOwnPart = Replay.OnOwnPart
    local ok3, err3 = pcall(Events.Register, tWorldAPIs)
    if not ok3 then Log.Write("Events.Register Fehler: " .. tostring(err3)) end
    Events.AddListener(Mirror.OnAction)
    Log.Write("Spiegel-Test aktiv (Zwilling bei x+" .. tostring(Mirror.nOffsetX) .. ")")
    self.bActive = true
end

function PC2MPManager.Advance(self, _nDeltaTime)
    if not self.bActive then return end
    local ok, err = pcall(Events.Tick)
    if not ok then Log.Write("Events.Tick Fehler: " .. tostring(err)) end
    ok, err = pcall(Replay.Tick)
    if not ok then Log.Write("Replay.Tick Fehler: " .. tostring(err)) end
end

function PC2MPManager.Deactivate(self)
    Log.Write("Manager Deactivate")
    self.bActive = false
    pcall(Events.Unregister)
end

function PC2MPManager.Shutdown(self)
    Log.Write("Manager Shutdown")
end
