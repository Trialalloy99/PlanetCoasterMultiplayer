-----------------------------------------------------------------------
--/  PC2MP Spiel-Manager: läuft im spielweiten Environment (Game.GameEnvironment),
--/  also schon im Hauptmenü. Treibt pc2mp.menu (Dev-UI-Steuerung, #21).
-----------------------------------------------------------------------
local global = _G
local pcall = global.pcall
local tostring = global.tostring
local require = global.require
---@diagnostic disable-next-line: deprecated
local module = global.module

local Mutators = require("Environment.ModuleMutators")
local Log = require("pc2mp.log")
local Menu = require("pc2mp.menu")

local PC2MPGameManager = module(..., Mutators.Manager())

function PC2MPGameManager.Init(self, _tProperties, _tEnvironment)
    Log.Write("Game-Manager Init (Hauptmenü-Environment)")
end

function PC2MPGameManager.Activate(self)
    Log.Write("Game-Manager Activate")
end

function PC2MPGameManager.Advance(self, _nDeltaTime)
    local ok, err = pcall(Menu.Tick, "manager")
    if not ok then Log.Write("Menu.Tick Fehler: " .. tostring(err)) end
end

function PC2MPGameManager.Deactivate(self)
    Log.Write("Game-Manager Deactivate")
end

function PC2MPGameManager.Shutdown(self)
    Log.Write("Game-Manager Shutdown")
end
