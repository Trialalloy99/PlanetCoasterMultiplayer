-----------------------------------------------------------------------
--/  PC2MP Park-Manager: läuft im Park (CPTEnvironment).
--/  Mit PC2MP_config.json (neben der DLL): Multiplayer über den Server.
--/  Ohne Config oder mit Testmodus (Dev-UI): lokaler Spiegel-Test (Zwilling bei x+Versatz), pc2mp.testmode.
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
local UndoGuard = require("pc2mp.undoguard")
local WorldEdit = require("pc2mp.worldedit")
local Sync = require("pc2mp.sync")
local UndoHook = require("pc2mp.undohook")
local Menu = require("pc2mp.menu")
local GameState = require("pc2mp.gamestate")
local TestMode = require("pc2mp.testmode")
local Breakdowns = require("pc2mp.breakdowns")

local PC2MPManager = module(..., Mutators.Manager())

function PC2MPManager.Init(self, _tProperties, _tEnvironment)
    Log.Write("Manager Init")
    self.tEnvironment = _tEnvironment
    -- Vor dem Laden des Spielstands registrieren, damit unsere Zuordnungen mitgeladen werden (#14)
    local ok, tWorldAPIs = pcall(api.world.GetWorldAPIs)
    if ok and tWorldAPIs then
        local okP, errP = pcall(Sync.RegisterPersist, tWorldAPIs)
        if not okP then Log.Write("RegisterPersist Fehler: " .. tostring(errP)) end
    end
end

function PC2MPManager.Activate(self)
    Log.Write("Manager Activate")
    api.pc2mp = api.pc2mp or {}
    api.pc2mp.bInPark = true
    local ok, tWorldAPIs = pcall(api.world.GetWorldAPIs)
    if not ok then
        Log.Write("GetWorldAPIs Fehler: " .. tostring(tWorldAPIs))
        return
    end
    -- Vor allem anderen: schützt api.undo vor nil/gleichzeitigen Operationen (nativer Crash, siehe pc2mp.undoguard)
    local okG, errG = pcall(UndoGuard.Install)
    if not okG then Log.Write("UndoGuard Fehler: " .. tostring(errG)) end
    Replay.Init(tWorldAPIs)
    -- Terrain + Wege erfassen (#15); Spiegel-Nachbau nur ohne Server (siehe unten)
    local okW, errW = pcall(WorldEdit.Install, tWorldAPIs)
    if not okW then Log.Write("WorldEdit.Install Fehler: " .. tostring(errW)) end
    Events.fnIsReplayCoroutine = Replay.IsReplayCoroutine
    Events.fnClaimOwnPart = Replay.ClaimOwnPart
    Events.fnHasOpenCreate = Replay.HasOpenCreate
    Events.fnOnOwnPart = Replay.OnOwnPart
    Events.fnNow = function() return Replay.nFrame end
    Events.tListeners = {}
    local okG, errG = pcall(Events.InstallCommitGate)
    if not okG then Log.Write("Commit-Gate Fehler: " .. tostring(errG)) end
    local ok3, err3 = pcall(Events.Register, tWorldAPIs)
    if not ok3 then Log.Write("Events.Register Fehler: " .. tostring(err3)) end

    -- Park-Einstellungen + Marketing (pc2mp.gamestate); Environment aus Init, sonst über die aktive Welt
    local tEnv = self.tEnvironment
    if tEnv == nil then
        local okE, ws = pcall(function() return api.world.GetScript(api.world.GetActive()) end)
        tEnv = okE and ws and ws.tEnvironment or nil
    end
    GameState.tListeners = {}
    Breakdowns.tListeners = {}
    pcall(Breakdowns.Install, tWorldAPIs)
    local okGS, errGS = pcall(GameState.Install, tWorldAPIs, tEnv)
    if not okGS then Log.Write("GameState.Install Fehler: " .. tostring(errGS)) end

    Sync.fnTestModeOn = TestMode.IsOn
    local okS, bSync = pcall(Sync.Start)
    if not okS then Log.Write("Sync.Start Fehler: " .. tostring(bSync)) end
    self.bMultiplayer = okS and bSync
    if self.bMultiplayer then
        pcall(UndoHook.EnsurePatched)
    end
    -- Testmodus: ohne Config immer (altes Verhalten), sonst per Dev-UI-Schalter; nie im Multiplayer
    self.bNoConfig = Sync.tConfig == nil
    local manager = self
    api.pc2mp.fnTestModeChanged = function() manager:UpdateTestMode() end
    self:UpdateTestMode()
    if not self.bMultiplayer and not TestMode.IsOn() and not self.bNoConfig then
        Log.Write("Offline (nicht über die Dev-UI gejoint, Testmodus aus)")
    end
    self.bActive = true
end

function PC2MPManager.UpdateTestMode(self)
    local bWanted = (not self.bMultiplayer) and (self.bNoConfig or TestMode.IsOn())
    local ok, err = pcall(TestMode.ApplyInPark, bWanted)
    if not ok then Log.Write("Testmodus Fehler: " .. tostring(err)) end
end

function PC2MPManager.Advance(self, _nDeltaTime)
    if not self.bActive then return end
    -- Dev-UI-Steuerung auch im Park (#21)
    local okM, errM = pcall(Menu.Tick, "park")
    if not okM then Log.Write("Menu.Tick Fehler: " .. tostring(errM)) end
    local ok, err = pcall(Events.Tick)
    if not ok then Log.Write("Events.Tick Fehler: " .. tostring(err)) end
    ok, err = pcall(Replay.Tick)
    if not ok then Log.Write("Replay.Tick Fehler: " .. tostring(err)) end
    ok, err = pcall(WorldEdit.Tick)
    if not ok then Log.Write("WorldEdit.Tick Fehler: " .. tostring(err)) end
    ok, err = pcall(Breakdowns.Tick)
    if not ok then Log.Write("Breakdowns.Tick Fehler: " .. tostring(err)) end
    ok, err = pcall(GameState.Tick)
    if not ok then Log.Write("GameState.Tick Fehler: " .. tostring(err)) end
    ok, err = pcall(Sync.Tick)
    if not ok then Log.Write("Sync.Tick Fehler: " .. tostring(err)) end
end

function PC2MPManager.Deactivate(self)
    Log.Write("Manager Deactivate")
    self.bActive = false
    if api.pc2mp then
        api.pc2mp.bInPark = false
        api.pc2mp.fnTestModeChanged = nil
    end
    pcall(TestMode.OnParkLeft)
    pcall(Sync.Stop)
    pcall(Events.Unregister)
end

function PC2MPManager.Shutdown(self)
    Log.Write("Manager Shutdown")
end
