-----------------------------------------------------------------------
--/  PC2MP GameState: Park-Einstellungen und Marketing synchronisieren.
--/
--/  Prinzip: ausgewählte Setter (Whitelist tTargets) abfangen. Ruft der Spieler einen davon auf,
--/  wird { op="call", k=<Schlüssel>, a={Argumente} } gesendet; die anderen Clients rufen denselben
--/  Setter mit denselben Argumenten auf. Nur einfache Werte (Zahl, Text, bool, Tabellen daraus).
--/
--/  Verifiziert im dekompilierten Lua (Stand 2026-11-07), noch NICHT im Spiel getestet:
--/    Park (tWorldAPIs.park, native):  SetParkOpenForGuests(b) (MainHUD.OpenClosePark), SetParkName(s),
--/      SetParkEntranceAdultTicketPrice(n), SetParkEntrancePriceState(n), SetFastPassTicketPrice(n),
--/      SetFastPassTicketPriceState(n), SetPoolPassPrice(n), SetPoolPassPriceState(n)
--/      (Editors.Park.GamefaceParkOptionsEventHandler, ParkEntranceInfoPopUpGameface)
--/    Marketing (Interfaces.IGuestBucketManager, Lua):  SetAdvertisingActive(nBucket, b),
--/      SetCurrentCostPerHour(nBucket, n)   (Editors.Park.MarketingEventHandlerGameface)
--/      Die Kampagnen-Funktionen im MarketingManager sind in PC2 leere Stubs.
--/    Sandbox-/Welt-Einstellungen (Interfaces.ISandboxSettingsManager):  SetSandboxSettings(tSettings)
--/      (StartScreen.Shared.SandboxPauseMenuHUD)
-----------------------------------------------------------------------
local global = _G
local api = global.api
local type = global.type
local pairs = global.pairs
local ipairs = global.ipairs
local pcall = global.pcall
local tostring = global.tostring
local tonumber = global.tonumber
local table = global.table
local math = global.math
local getmetatable = global.getmetatable
local rawget = global.rawget
local rawset = global.rawset
local require = global.require
local Log = require("pc2mp.log")

local GameState = {}
GameState.tListeners = {}
GameState.nWarmupFrames = 300     -- nach dem Laden: Setter-Aufrufe des Spiels selbst ignorieren
GameState.nDebounce = 0.5         -- Schieberegler (Preise): erst nach 0,5 s Ruhe senden
GameState.nFrame = 0
GameState.bApplying = false
GameState.tLast = {}              -- sKey(+Index) -> JSON der letzten Argumente (gegen Doppelte/Echo)
GameState.tPending = {}           -- sKey(+Index) -> { tAction, nTime }
GameState.fnOnEvent = nil         -- optional: fn(sText) für die Dev-UI (Testmodus)

-- k: Schlüssel im Netz.  api: Name in tWorldAPIs (native)  ODER  iface: Lua-Interface im Environment.
-- idx: das erste Argument unterscheidet Einträge (z. B. Gästegruppe), debounce: Schieberegler
GameState.tTargets = {
    { k = "park.SetParkOpenForGuests", api = "park", m = "SetParkOpenForGuests" },
    { k = "park.SetParkName", api = "park", m = "SetParkName", debounce = true },
    { k = "park.SetParkEntranceAdultTicketPrice", api = "park", m = "SetParkEntranceAdultTicketPrice", debounce = true },
    { k = "park.SetParkEntrancePriceState", api = "park", m = "SetParkEntrancePriceState" },
    { k = "park.SetFastPassTicketPrice", api = "park", m = "SetFastPassTicketPrice", debounce = true },
    { k = "park.SetFastPassTicketPriceState", api = "park", m = "SetFastPassTicketPriceState" },
    { k = "park.SetPoolPassPrice", api = "park", m = "SetPoolPassPrice", debounce = true },
    { k = "park.SetPoolPassPriceState", api = "park", m = "SetPoolPassPriceState" },
    { k = "ads.SetAdvertisingActive", iface = "Interfaces.IGuestBucketManager", m = "SetAdvertisingActive", idx = true },
    { k = "ads.SetCurrentCostPerHour", iface = "Interfaces.IGuestBucketManager", m = "SetCurrentCostPerHour", idx = true,
      debounce = true },
    { k = "sandbox.SetSandboxSettings", iface = "Interfaces.ISandboxSettingsManager", m = "SetSandboxSettings" },
}
GameState.tByKey = {}
for _, t in ipairs(GameState.tTargets) do GameState.tByKey[t.k] = t end

local function Note(s)
    Log.Write("GameState: " .. s)
    if GameState.fnOnEvent then pcall(GameState.fnOnEvent, s) end
end

local function Now()
    local ok, t = pcall(api.time.GetTotalTimeUnscaled)
    return ok and type(t) == "number" and t or (GameState.nFrame / 30)
end

local function ToJson(t)
    local okJ, bOk, s = pcall(api.json.Stringify, t)
    if okJ and bOk and type(s) == "string" then return s end
    return nil
end

-- Nur einfache Werte übernehmen (keine Funktionen/Userdata), Tiefe begrenzt
local function Plain(v, nDepth)
    local t = type(v)
    if t == "number" or t == "string" or t == "boolean" then return v end
    if t ~= "table" or (nDepth or 0) > 6 then return nil end
    local o = {}
    for k, x in pairs(v) do
        local tk = type(k)
        if tk == "string" or tk == "number" then o[k] = Plain(x, (nDepth or 0) + 1) end
    end
    return o
end
GameState.Plain = Plain

-- api.json: Arrays kommen als {"1":..} zurück -> Argumentliste wiederherstellen
local function ArgList(a)
    if type(a) ~= "table" then return {}, 0 end
    local o, n = {}, 0
    for k, v in pairs(a) do
        local i = tonumber(k)
        if i and i >= 1 and i == math.floor(i) then
            o[i] = v
            if i > n then n = i end
        end
    end
    return o, n
end

local function SlotKey(tgt, tArgs)
    if tgt.idx then return tgt.k .. "#" .. tostring(tArgs[1]) end
    return tgt.k
end

---------------------------------------------------------------------
-- Erfassen
---------------------------------------------------------------------
local function Dispatch(tAction)
    for _, fn in ipairs(GameState.tListeners) do
        local ok, err = pcall(fn, tAction)
        if not ok then Log.Write("GameState: Listener Fehler: " .. tostring(err)) end
    end
end

function GameState.IsLive()
    return GameState.bInstalled and GameState.nFrame >= GameState.nWarmupFrames
end

function GameState.OnCall(sKey, tArgs, nArgs)
    local tgt = GameState.tByKey[sKey]
    if tgt == nil or GameState.bApplying then return end
    local tA = {}
    for i = 1, nArgs do tA[i] = Plain(tArgs[i]) end
    local sSlot = SlotKey(tgt, tA)
    local sJson = ToJson(tA) or Log.ToStr(tA)
    if not GameState.IsLive() then
        GameState.tLast[sSlot] = sJson -- Ausgangszustand merken, nicht senden (Park lädt noch)
        return
    end
    if GameState.tLast[sSlot] == sJson then return end
    GameState.tLast[sSlot] = sJson
    local tAction = { op = "call", k = sKey, a = tA, n = nArgs }
    if tgt.debounce then
        GameState.tPending[sSlot] = { tAction = tAction, nTime = Now() }
    else
        GameState.tPending[sSlot] = nil
        Note("erfasst " .. sKey .. " " .. sJson)
        Dispatch(tAction)
    end
end

function GameState.Tick()
    GameState.nFrame = GameState.nFrame + 1
    if global.next(GameState.tPending) == nil then return end
    local nNow = Now()
    for sSlot, p in pairs(GameState.tPending) do
        if nNow - p.nTime >= GameState.nDebounce then
            GameState.tPending[sSlot] = nil
            Note("erfasst " .. p.tAction.k .. " " .. tostring(ToJson(p.tAction.a)))
            Dispatch(p.tAction)
        end
    end
end

---------------------------------------------------------------------
-- Haken setzen
---------------------------------------------------------------------
-- Gemeinsame Einsprungstelle (über api, damit ältere Wrapper nach Park-Wechsel das aktuelle Modul rufen)
local function Hub()
    api.pc2mp = api.pc2mp or {}
    api.pc2mp.fnGameStateCall = function(sKey, tArgs, nArgs)
        local ok, err = pcall(GameState.OnCall, sKey, tArgs, nArgs)
        if not ok then Log.Write("GameState: Erfassung " .. tostring(sKey) .. " Fehler: " .. tostring(err)) end
    end
end

local function MakeWrapper(sKey, fnOrig)
    return function(self, ...)
        local tRet = table.pack(fnOrig(self, ...))
        local fn = api.pc2mp and api.pc2mp.fnGameStateCall
        if fn then fn(sKey, { ... }, global.select("#", ...)) end
        return table.unpack(tRet, 1, tRet.n)
    end
end

-- Native API-Objekte: Methoden liegen direkt in der Tabelle oder in der (geteilten) Metatabelle
local function ApiMethodTable(obj, sMethod)
    if type(obj) == "table" and (rawget(obj, sMethod) ~= nil or rawget(obj, "__pc2mp_gs_" .. sMethod) ~= nil) then
        return obj
    end
    local mt = getmetatable(obj)
    if type(mt) == "table" and type(mt.__index) == "table" then return mt.__index end
    return nil
end

local function WrapApi(obj, tgt)
    local tm = ApiMethodTable(obj, tgt.m)
    if type(tm) ~= "table" then return false end
    local sMark = "__pc2mp_gs_" .. tgt.m
    if rawget(tm, sMark) then return true end
    local fnOrig = tm[tgt.m]
    if type(fnOrig) ~= "function" then return false end
    tm[tgt.m] = MakeWrapper(tgt.k, fnOrig)
    rawset(tm, sMark, fnOrig)
    return true
end

-- Lua-Manager: Interface-Proxy (Debug-Build) -> echtes Objekt; Methode auf der Instanz überschreiben
local function RealObject(o)
    local mt = getmetatable(o)
    if type(mt) == "table" and type(mt.tObject) == "table" then return mt.tObject end
    return o
end

local function WrapManager(obj, tgt)
    obj = RealObject(obj)
    if type(obj) ~= "table" then return false end
    local sMark = "__pc2mp_gs_" .. tgt.m
    if rawget(obj, sMark) then return true end
    local fnOrig = obj[tgt.m]
    if type(fnOrig) ~= "function" then return false end
    rawset(obj, tgt.m, MakeWrapper(tgt.k, fnOrig))
    rawset(obj, sMark, fnOrig)
    return true
end

local function FindTarget(tgt)
    if tgt.api then
        local tw = GameState.tWorldAPIs
        return tw and tw[tgt.api]
    end
    local env = GameState.tEnvironment
    if env == nil then return nil end
    local ok, o = pcall(env.RequestInterface or env.RequireInterface, env, tgt.iface)
    if ok then return o end
    return nil
end

function GameState.Install(tWorldAPIs, tEnvironment)
    GameState.tWorldAPIs = tWorldAPIs
    GameState.tEnvironment = tEnvironment
    GameState.nFrame = 0
    GameState.tLast, GameState.tPending = {}, {}
    Hub()
    local nOk, tMissing = 0, {}
    for _, tgt in ipairs(GameState.tTargets) do
        local obj = FindTarget(tgt)
        local ok, b = false, false
        if obj ~= nil then
            ok, b = pcall(tgt.api and WrapApi or WrapManager, obj, tgt)
        end
        if ok and b then nOk = nOk + 1 else tMissing[#tMissing + 1] = tgt.k end
    end
    GameState.bInstalled = true
    Log.Write("GameState installiert: " .. nOk .. "/" .. #GameState.tTargets .. " Setter erfasst"
        .. (#tMissing > 0 and (" (fehlen: " .. table.concat(tMissing, ", ") .. ")") or ""))
    return nOk
end

---------------------------------------------------------------------
-- Nachspielen (vom Netz bzw. Testmodus-Loopback)
---------------------------------------------------------------------
function GameState.ApplyRemote(a, sFrom)
    local tgt = type(a) == "table" and GameState.tByKey[a.k] or nil
    if tgt == nil then
        Log.Write("GameState: unbekannte Einstellung " .. Log.ToStr(a and a.k))
        return false
    end
    local obj = FindTarget(tgt)
    if tgt.iface then obj = RealObject(obj) end
    if obj == nil then
        Log.Write("GameState: Ziel für " .. tgt.k .. " fehlt")
        return false
    end
    -- Original (ohne Wrapper) aufrufen; Wrapper würden sonst sofort wieder senden
    local fn = nil
    if tgt.api then
        local tm = ApiMethodTable(obj, tgt.m)
        fn = (tm and rawget(tm, "__pc2mp_gs_" .. tgt.m)) or obj[tgt.m]
    else
        fn = rawget(obj, "__pc2mp_gs_" .. tgt.m) or obj[tgt.m]
    end
    if type(fn) ~= "function" then return false end
    local tArgs, nMax = ArgList(a.a)
    local n = math.max(tonumber(a.n) or 0, nMax)
    local sSlot = SlotKey(tgt, tArgs)
    GameState.tLast[sSlot] = ToJson(tArgs) or GameState.tLast[sSlot]
    GameState.tPending[sSlot] = nil
    GameState.bApplying = true
    local ok, err = pcall(fn, obj, table.unpack(tArgs, 1, n))
    GameState.bApplying = false
    Note((ok and "angewendet " or "FEHLER ") .. tgt.k .. " von " .. tostring(sFrom)
        .. (ok and "" or (": " .. tostring(err))))
    return ok
end

-- Testmodus ohne Server: Aktion durch JSON schicken (wie übers Netz) und selbst wieder anwenden.
-- Der Wert ist schon gesetzt -> prüft Erfassung, Serialisierung und Anwenden ohne sichtbare Änderung.
function GameState.LoopbackListener(tAction)
    local sJson = ToJson(tAction)
    local okP, bOk, t = pcall(api.json.Parse, sJson or "")
    if not (okP and bOk and type(t) == "table") then
        Note("Loopback: JSON-Fehler für " .. tostring(tAction.k))
        return
    end
    GameState.ApplyRemote(t, "Testmodus")
end

return GameState
