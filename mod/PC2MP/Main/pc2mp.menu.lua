-----------------------------------------------------------------------
--/  PC2MP Menu (#21): Steuerung des Spiels von außen (Dev-UI), auch im Hauptmenü.
--/
--/  Läuft im spielweiten Environment (Game.GameEnvironment), also im Hauptmenü UND im Park.
--/  Kopplung an die Dev-UI über Dateien in ovldata/PC2MP/data/ (DLL, siehe pc2mp.persist):
--/    ui_state.json  Spiel -> UI   { v, frame, mode = "menu"|"park", park, saves = [{id,name,world}], cmd = {id,ok,msg} }
--/    ui_cmd.json    UI -> Spiel   { id = <Zahl, steigend>, cmd = "load"|"refresh", save = <id> }
--/  Ein Befehl wird nur ausgeführt, wenn seine id größer ist als die beim Spielstart vorgefundene.
-----------------------------------------------------------------------
local global = _G
local api = global.api
local type = global.type
local pcall = global.pcall
local tostring = global.tostring
local tonumber = global.tonumber
local coroutine = global.coroutine
local string = global.string
local Log = require("pc2mp.log")
local Persist = require("pc2mp.persist")

local Menu = {}
Menu.nFrame = 0
Menu.nLastTickFrame = -1
Menu.nPollEvery = 30           -- Frames zwischen zwei Blicken auf ui_cmd.json
Menu.nRefreshEvery = 1800      -- Frames zwischen automatischen Neu-Auflistungen der Welten
Menu.tSaves = {}               -- Liste für die UI
Menu.tTokens = {}              -- id -> SaveToken
Menu.nLastCmdId = nil          -- nil = beim Start noch nicht gelesen
Menu.tCmdResult = nil
Menu.sLastState = nil
Menu.sSource = nil

local function ToJson(t)
    local okJ, bOk, s = pcall(api.json.Stringify, t)
    if okJ and bOk and type(s) == "string" then return s end
    return nil
end

local function FromJson(s)
    local okJ, bOk, t = pcall(api.json.Parse, s)
    if okJ and bOk and type(t) == "table" then return t end
    return nil
end

local function Plm()
    local ok, tEnv = pcall(api.game.GetEnvironment)
    if not ok or tEnv == nil then return nil end
    local ok2, plm = pcall(tEnv.RequireInterface, tEnv, "Interfaces.IParkLoadSaveManager")
    if ok2 then return plm end
    return nil
end

-- Wie ParkLoadSaveManager._EnumSaves: GetExistingSaves wiederholen, bis fertig (läuft in Coroutine)
local function EnumSaves()
    if not api.player.HasGameOwner() then return false, "kein GameOwner" end
    local owner = api.player.GetGameOwner()
    local tInfo = { sort = api.save.GetExistingSaves_SortMostRecentFirst }
    local ok, bDone, tSaves = api.save.GetExistingSaves(owner, "park2", tInfo)
    local n = 0
    while ok and not bDone and n < 600 do
        coroutine.yield()
        n = n + 1
        ok, bDone, tSaves = api.save.GetExistingSaves(owner, "park2", tInfo)
    end
    if not ok then return false, "GetExistingSaves fehlgeschlagen: " .. tostring(bDone) end
    return true, tSaves or {}
end

local function DescribeSave(tok, i)
    local function Get(fn)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, tok)
        if ok then return v end
        return nil
    end
    local sName = Get(api.save.GetSaveCustomName)
    local sId = Get(api.save.GetSaveIdentifier)
    local tMeta = Get(api.save.GetSaveMetadata)
    local sWorld = type(tMeta) == "table" and type(tMeta.tSave) == "table" and tMeta.tSave.sWorldName or nil
    sId = sId ~= nil and tostring(sId) or ("idx" .. i)
    if sName == nil or sName == "" then sName = tostring(tok) end
    return { id = sId, name = tostring(sName), world = sWorld and tostring(sWorld) or nil,
        corrupt = Get(api.save.IsSaveCorrupt) and true or nil }
end

function Menu.RefreshJob()
    local ok, tOrErr = EnumSaves()
    if not ok then
        Log.Write("Menu: Welten auflisten fehlgeschlagen: " .. tostring(tOrErr))
        return
    end
    local tList, tTokens = {}, {}
    for i, tok in global.ipairs(tOrErr) do
        local d = DescribeSave(tok, i)
        tList[#tList + 1] = d
        tTokens[d.id] = tok
    end
    Menu.tSaves, Menu.tTokens = tList, tTokens
    Log.Write("Menu: " .. #tList .. " Welten gefunden" .. (#tList > 0 and (" (neueste: " .. tList[1].name .. ")") or ""))
    Menu.bDirty = true
end

function Menu.StartRefresh()
    if Menu.coJob then return end
    Menu.coJob = coroutine.create(Menu.RefreshJob)
end

function Menu.CurrentPark()
    local plm = Plm()
    local tok = plm and plm.cLastActiveParkSaveToken
    if tok == nil then return nil end
    local ok, s = pcall(api.save.GetSaveCustomName, tok)
    if ok and s and s ~= "" then return tostring(s) end
    return nil
end

function Menu.Load(sId)
    local tok = Menu.tTokens[tostring(sId)]
    if tok == nil then return false, "Welt nicht gefunden: " .. tostring(sId) end
    local plm = Plm()
    if plm == nil then return false, "ParkLoadSaveManager fehlt" end
    local ok, bOk, sErr = pcall(plm.LoadParkFromSaveToken, plm, tok)
    if not ok then return false, "Fehler: " .. tostring(bOk) end
    if not bOk then return false, "abgelehnt: " .. tostring(sErr) end
    return true, "lade"
end

function Menu.HandleCmd(t)
    local nId = tonumber(t.id)
    if nId == nil then return end
    if Menu.nLastCmdId == nil then
        -- erster Blick nach Spielstart: alter Befehl, nicht ausführen
        Menu.nLastCmdId = nId
        return
    end
    if nId <= Menu.nLastCmdId then return end
    Menu.nLastCmdId = nId
    local ok, sMsg = false, "unbekannter Befehl"
    if t.cmd == "refresh" then
        Menu.StartRefresh(); ok, sMsg = true, "aktualisiere"
    elseif t.cmd == "load" then
        ok, sMsg = Menu.Load(t.save)
    end
    Log.Write("Menu: Befehl " .. nId .. " " .. tostring(t.cmd) .. " " .. tostring(t.save) .. " -> " .. tostring(ok) .. " " .. tostring(sMsg))
    Menu.tCmdResult = { id = nId, ok = ok, msg = sMsg }
    Menu.bDirty = true
end

function Menu.PollCmd()
    local s = Persist.ReadData("ui_cmd.json")
    if type(s) ~= "string" then
        if Menu.nLastCmdId == nil then Menu.nLastCmdId = 0 end
        return
    end
    local t = FromJson(s)
    if t then Menu.HandleCmd(t) elseif Menu.nLastCmdId == nil then Menu.nLastCmdId = 0 end
end

function Menu.WriteState()
    local t = {
        v = 1,
        frame = Menu.nFrame,
        mode = (api.pc2mp and api.pc2mp.bInPark) and "park" or "menu",
        park = Menu.CurrentPark(),
        source = Menu.sSource,
        saves = Menu.tSaves,
        cmd = Menu.tCmdResult,
    }
    -- frame ändert sich ständig: als Lebenszeichen nur alle nPollEvery Frames schreiben (= hier)
    local s = ToJson(t)
    if s then Persist.WriteData("ui_state.json", s) end
end

-- Einmal pro Frame aufrufen (Manager.Advance oder Fallback-Hook); doppelte Aufrufe im selben Frame werden ignoriert
function Menu.Tick(sSource, nFrameHint)
    -- Mehrere Einstiege (Hooks im Menü, Park-Manager) rufen Tick auf; nur einer ("Besitzer") zählt.
    -- Ruft der Besitzer länger nicht mehr (z. B. Menü-Welt entladen), übernimmt ein anderer.
    if sSource ~= Menu.sSource then
        Menu.nOtherCalls = (Menu.nOtherCalls or 0) + 1
        if Menu.sSource ~= nil and Menu.nOtherCalls <= 10 then return end
        Log.Write("Menu: aktiv über " .. tostring(sSource) .. (Menu.sSource and (" (vorher " .. Menu.sSource .. ")") or ""))
        local bFirst = Menu.sSource == nil
        Menu.sSource = sSource
        if bFirst then Menu.StartRefresh() end
    end
    Menu.nOtherCalls = 0
    Menu.nFrame = Menu.nFrame + 1
    if Menu.coJob then
        local ok, err = coroutine.resume(Menu.coJob)
        if not ok then Log.Write("Menu: Job-Fehler: " .. tostring(err)) end
        if coroutine.status(Menu.coJob) == "dead" then Menu.coJob = nil end
    end
    if Menu.nFrame % Menu.nRefreshEvery == 0 then Menu.StartRefresh() end
    if Menu.nFrame % Menu.nPollEvery == 0 or Menu.bDirty then
        Menu.bDirty = false
        Menu.PollCmd()
        Menu.WriteState()
    end
end

-- Einstiege über ACSE-Hooks (AddLuaHooks): wrappt tModule[sFn] und tickt Menu darüber.
-- Game.GameEnvironment / ParkLoadSaveManager werden vor ACSE geladen (Hooks greifen dort nicht),
-- die Startbildschirm-Module erst mit der Menü-Welt -> dort klappt es.
function Menu.AcseHookAdvance(tModule, sSource, sFn)
    sFn = sFn or "Advance"
    local fnOrig = tModule and tModule[sFn]
    if type(fnOrig) ~= "function" then
        Log.Write("Menu: " .. tostring(sSource) .. "." .. sFn .. " nicht gefunden")
        return
    end
    tModule[sFn] = function(self, ...)
        local ok, err = pcall(Menu.Tick, sSource)
        if not ok then Log.Write("Menu.Tick Fehler: " .. tostring(err)) end
        return fnOrig(self, ...)
    end
    Log.Write("Menu: Hook auf " .. tostring(sSource) .. "." .. sFn .. " gesetzt")
end

function Menu.AcseHookPlm(tModule) Menu.AcseHookAdvance(tModule, "plm-hook") end

return Menu
