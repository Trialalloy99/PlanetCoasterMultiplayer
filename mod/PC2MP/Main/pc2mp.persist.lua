-----------------------------------------------------------------------
--/  PC2MP Persist (#14): Sync-Zustand ueber Neustarts retten + Spielstand-Transfer (#3).
--/
--/  tState = { lastSeq = n, map = { [netId] = partID } }
--/
--/  Zwei Wege, sich ergaenzend:
--/  1. JSON-Datei ueber die DLL: ovldata/PC2MP/data/state_<park>.json
--/     Persist.Save / Persist.Load / Persist.MarkDirty + Persist.Tick (gedrosselt, max. 1x pro s)
--/  2. IM Park-Spielstand selbst (empfohlen fuer das Mapping): eigener
--/     worldserialisation-Client "PC2MPSync". partIDs/EntityIDs sind nach dem Laden NICHT stabil
--/     (das Spiel nummeriert um); SaveEntityID/LoadEntityID rechnen das korrekt um. So reist das
--/     Mapping mit dem Spielstand mit, auch zu Spielern, die spaeter einsteigen.
--/     Persist.RegisterSaveClient(tWorldAPIs, fnGetState, fnOnLoaded) -- im Manager.Init aufrufen
--/
--/  Spielstand-Transfer (Dateien im Saves-Ordner, siehe docs/findings/save-load.md):
--/     Persist.SaveList(), Persist.SaveInfo(name), Persist.ReadSaveChunk(name, i),
--/     Persist.WriteSaveChunk(name, i, b64), Persist.FinishSave(name, sha256), Persist.AbortSave(name)
-----------------------------------------------------------------------
local global = _G
local api = global.api
local type = global.type
local pcall = global.pcall
local pairs = global.pairs
local tostring = global.tostring
local string = global.string
local table = global.table
local require = global.require
local Log = require("pc2mp.log")

local Persist = {}
Persist.sDllPath = ".\\Win64\\ovldata\\PC2MP\\PC2MPNative.dll"
Persist.nMinInterval = 1.0          -- s zwischen zwei Datei-Schreibvorgaengen
Persist.sClientName = "PC2MPSync"
Persist.nClientVersion = 1

local tExports = {
    "pc2mp_write_file", "pc2mp_read_file", "pc2mp_file_error",
    "pc2mp_saves_dir", "pc2mp_save_list", "pc2mp_save_info",
    "pc2mp_save_read_chunk", "pc2mp_save_write_chunk", "pc2mp_save_finish", "pc2mp_save_abort",
    "pc2mp_read_i64",
}

local function Fns()
    if Persist.tFns then return Persist.tFns end
    if Persist.sError then return nil end
    local pkg = global.package
    if type(pkg) ~= "table" or type(pkg.loadlib) ~= "function" then
        Persist.sError = "package.loadlib nicht verfuegbar"
        return nil
    end
    local t = {}
    for _, sName in global.ipairs(tExports) do
        local ok, fn = pcall(pkg.loadlib, Persist.sDllPath, sName)
        if not ok or type(fn) ~= "function" then
            Persist.sError = "loadlib " .. sName .. " fehlgeschlagen (alte DLL?)"
            Log.Write("Persist: " .. Persist.sError)
            return nil
        end
        t[sName] = fn
    end
    Persist.tFns = t
    return t
end

-- DLL-Rueckgabe -> Lua-String (Fallback-Modus der DLL liefert die Laenge, Bytes per read_i64)
local function ToStr(v)
    if type(v) ~= "number" then return v end
    local tParts = {}
    for i = 1, (v + 7) // 8 do
        tParts[i] = string.pack("<i8", Persist.tFns.pc2mp_read_i64(i))
    end
    return string.sub(table.concat(tParts), 1, v)
end

local function RawCall(sName, ...)
    local t = Fns()
    if not t then return nil end
    local ok, v = pcall(t[sName], ...)
    if not ok then
        Log.Write("Persist: " .. sName .. " Fehler: " .. tostring(v))
        return nil
    end
    return v
end
-- Funktionen, die einen String (oder nil) liefern
local function CallStr(sName, ...) return ToStr(RawCall(sName, ...)) end
-- Funktionen, die 1/0 liefern
local function CallInt(sName, ...) return RawCall(sName, ...) end

-- Parkname -> erlaubter Dateiname (nur [A-Za-z0-9_.-], DLL lehnt alles andere ab)
function Persist.FileNameFor(sPark)
    local s = string.gsub(tostring(sPark or "default"), "[^%w%-_%.]", "_")
    s = string.gsub(s, "%.%.+", "_")
    if string.sub(s, 1, 1) == "." then s = "_" .. s end
    if #s > 64 then s = string.sub(s, 1, 64) end
    return "state_" .. s .. ".json"
end

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

-- map-Schluessel als Strings (netIds), Werte als Zahlen (partIDs) normalisieren
local function NormaliseState(t)
    local tOut = { lastSeq = global.math.tointeger(t.lastSeq) or 0, map = {} }
    if type(t.map) == "table" then
        for k, v in pairs(t.map) do
            local n = global.tonumber(v)
            if n then tOut.map[tostring(k)] = global.math.tointeger(n) or n end
        end
    end
    return tOut
end

-- ---------------------------------------------------------------- 1. JSON-Datei

function Persist.Save(sPark, tState)
    local s = ToJson({ v = 1, park = tostring(sPark), lastSeq = tState.lastSeq or 0, map = tState.map or {} })
    if not s then Log.Write("Persist: JSON-Fehler beim Speichern"); return false end
    local r = CallInt("pc2mp_write_file", Persist.FileNameFor(sPark), s)
    if r ~= 1 then Log.Write("Persist: Speichern fehlgeschlagen: " .. tostring(CallStr("pc2mp_file_error"))) end
    return r == 1
end

function Persist.Load(sPark)
    local s = CallStr("pc2mp_read_file", Persist.FileNameFor(sPark))
    if type(s) ~= "string" then return nil end
    local t = FromJson(s)
    if not t then Log.Write("Persist: " .. Persist.FileNameFor(sPark) .. " ist kein gueltiges JSON"); return nil end
    return NormaliseState(t)
end

-- Gedrosselt: nach jeder angewendeten Aktion aufrufen, Tick() pro Frame.
function Persist.MarkDirty(sPark, tState)
    Persist.tDirty = { sPark = sPark, tState = tState }
end

local function Now()
    local ok, t = pcall(api.time.GetTotalTimeUnscaled)
    return ok and type(t) == "number" and t or 0
end

function Persist.Tick()
    local d = Persist.tDirty
    if d == nil then return end
    local nNow = Now()
    if Persist.nLastWrite and nNow - Persist.nLastWrite < Persist.nMinInterval then return end
    Persist.tDirty = nil
    Persist.nLastWrite = nNow
    Persist.Save(d.sPark, d.tState)
end

function Persist.Flush()
    local d = Persist.tDirty
    if d then Persist.tDirty = nil; Persist.nLastWrite = Now(); return Persist.Save(d.sPark, d.tState) end
    return true
end

-- ---------------------------------------------------------------- 2. im Park-Spielstand

-- fnGetState() -> tState (beim Speichern des Parks)
-- fnOnLoaded(tState) wird aufgerufen, sobald die geladenen Entities wieder partIDs haben
-- (Persist.ResolveLoaded() pro Frame aufrufen, bis es true liefert).
function Persist.RegisterSaveClient(tWorldAPIs, fnGetState, fnOnLoaded)
    local ws = tWorldAPIs and tWorldAPIs.worldserialisation
    local placement = tWorldAPIs and tWorldAPIs.placement
    if not ws or not placement then Log.Write("Persist: worldserialisation/placement fehlt"); return false end
    Persist.ws, Persist.placement, Persist.fnOnLoaded = ws, placement, fnOnLoaded

    local fnSave = function(_tSave)
        local okS, tState = pcall(fnGetState)
        if not okS or type(tState) ~= "table" then return end
        _tSave.lastSeq = tState.lastSeq or 0
        _tSave.tEntries = {}
        for sNet, nPart in pairs(tState.map or {}) do
            local okE, nEntity = pcall(placement.PlacementIDToEntityID, placement, nPart)
            if okE and nEntity then
                local okW, serial = pcall(ws.SaveEntityID, ws, nEntity)
                if okW and serial ~= nil then
                    table.insert(_tSave.tEntries, { netId = tostring(sNet), entity = serial })
                end
            end
        end
        Log.Write("Persist: " .. #_tSave.tEntries .. " Zuordnungen in den Spielstand geschrieben (lastSeq " .. tostring(_tSave.lastSeq) .. ")")
    end
    local fnLoad = function(_tLoad, _nVersion)
        local tPending = {}
        for _, e in global.ipairs(_tLoad.tEntries or {}) do
            local okL, nEntity = pcall(ws.LoadEntityID, ws, e.entity)
            if okL and nEntity then table.insert(tPending, { netId = e.netId, entity = nEntity }) end
        end
        Persist.tLoaded = { lastSeq = _tLoad.lastSeq or 0, tPending = tPending }
        Log.Write("Persist: " .. #tPending .. " Zuordnungen aus dem Spielstand gelesen (lastSeq " .. tostring(_tLoad.lastSeq) .. ")")
        return true
    end
    local fnCanLoadOldVersion = function(_nOld) return true end
    local ok, err = pcall(ws.RegisterWorldSerialisationClient, ws, Persist.sClientName, Persist.nClientVersion, fnSave, fnLoad, fnCanLoadOldVersion)
    if not ok then Log.Write("Persist: RegisterWorldSerialisationClient Fehler: " .. tostring(err)) end
    return ok
end

function Persist.UnregisterSaveClient()
    if Persist.ws then pcall(Persist.ws.UnregisterWorldSerialisationClient, Persist.ws, Persist.sClientName) end
end

-- Entity -> partID erst nach dem Laden moeglich. true, sobald fertig (oder nichts zu tun).
function Persist.ResolveLoaded()
    local t = Persist.tLoaded
    if t == nil then return true end
    local tMap, nMissing = {}, 0
    for _, e in global.ipairs(t.tPending) do
        local ok, nPart = pcall(Persist.placement.EntityIDToPlacementID, Persist.placement, e.entity)
        if ok and nPart then tMap[e.netId] = nPart else nMissing = nMissing + 1 end
    end
    t.nTries = (t.nTries or 0) + 1
    if nMissing > 0 and t.nTries < 300 then return false end
    Persist.tLoaded = nil
    if nMissing > 0 then Log.Write("Persist: " .. nMissing .. " Zuordnungen ohne partID verworfen") end
    if Persist.fnOnLoaded then pcall(Persist.fnOnLoaded, { lastSeq = t.lastSeq, map = tMap }) end
    return true
end

-- ---------------------------------------------------------------- Spielstand-Transfer (#3)

function Persist.SavesDir() return CallStr("pc2mp_saves_dir") end
function Persist.SaveList() local s = CallStr("pc2mp_save_list"); return s and FromJson(s) end
function Persist.SaveInfo(sName) local s = CallStr("pc2mp_save_info", sName); return s and FromJson(s) end
function Persist.ReadSaveChunk(sName, i) return CallStr("pc2mp_save_read_chunk", sName, i) end
function Persist.WriteSaveChunk(sName, i, sB64) return CallInt("pc2mp_save_write_chunk", sName, i, sB64) == 1 end
function Persist.FinishSave(sName, sSha) return CallInt("pc2mp_save_finish", sName, sSha) == 1, CallStr("pc2mp_file_error") end
function Persist.AbortSave(sName) RawCall("pc2mp_save_abort", sName) end

return Persist
