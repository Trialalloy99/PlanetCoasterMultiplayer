-----------------------------------------------------------------------
--/  PC2MP SaveUpload (#21): Spielstand nach jedem Speichern auf den Server laden + Quick-Save auf Anfrage.
--/
--/  Ablauf:
--/   1. Speichern beginnt: das Spiel ruft unseren worldserialisation-Client (pc2mp.persist) ->
--/      Sync.GetPersistState -> SaveUpload.OnSaveStarted(seq). Wir merken uns den Stand des Saves-Ordners.
--/   2. Tick prüft alle nPollEvery Frames, welche .park2 sich geändert hat, und wartet, bis sie fertig
--/      geschrieben ist (Größe/Zeit zweimal gleich, api.save nicht beschäftigt).
--/   3. Upload über die bestehende Server-Verbindung: saveUpload{seq,name,size,sha256}, saveChunk (1 pro Frame), saveEnd.
--/  Quick-Save (Server schickt {t="quickSave"}, wenn jemand joinen will): speichert den aktuellen Park über
--/  ParkLoadSaveManager:SaveParkToSaveToken (wie das Spielmenü) -> danach wie oben.
--/  STATUS: offline getestet (Mocks), im Spiel NICHT getestet.
-----------------------------------------------------------------------
local global = _G
local api = global.api
local type = global.type
local pcall = global.pcall
local pairs = global.pairs
local ipairs = global.ipairs
local tostring = global.tostring
local coroutine = global.coroutine
local Log = require("pc2mp.log")

local SU = {}
SU.nPollEvery = 20         -- Frames zwischen zwei Blicken in den Saves-Ordner
SU.nMaxPolls = 90          -- danach aufgeben (~30 s bei 60 FPS)
SU.tJob = nil              -- laufender Upload-Auftrag
SU.coQuick = nil           -- laufende Quick-Save-Coroutine
-- Abhängigkeiten (vom Sync gesetzt, im Test gemockt)
SU.Persist = nil           -- pc2mp.persist (SaveList/SaveInfo/ReadSaveChunk)
SU.fnSend = nil            -- function(msg) -> bool
SU.fnCanUpload = function() return true end

local function Snapshot()
    local t = {}
    local tList = SU.Persist and SU.Persist.SaveList() or nil
    for _, e in ipairs(tList or {}) do
        if type(e) == "table" and e.name then t[e.name] = tostring(e.mtime) .. "/" .. tostring(e.size) end
    end
    return t, tList
end

local function SaveBusy()
    local ok, b = pcall(function() return api.save.IsBusy() end)
    return ok and b == true
end

-- Speichern hat begonnen (oder Quick-Save angestoßen). nSeq = Server-Seq, bis zu der der Stand alles enthält.
function SU.OnSaveStarted(nSeq, bQuick)
    if not SU.fnCanUpload() then return end
    if SU.tJob ~= nil and SU.tJob.sPhase == "wait" then
        SU.tJob.bQuick = SU.tJob.bQuick or bQuick
        return
    end
    if SU.tJob ~= nil then
        Log.Write("SaveUpload: Upload läuft noch, neuer Spielstand wird danach nicht hochgeladen")
        return
    end
    local tBefore = Snapshot()
    SU.tJob = { sPhase = "wait", nSeq = nSeq or 0, bQuick = bQuick, tBefore = tBefore, nPolls = 0, nWait = SU.nPollEvery }
    Log.Write("SaveUpload: Speichern erkannt (seq " .. tostring(nSeq) .. "), warte auf die Datei")
end

local function Fail(sWhy)
    local job = SU.tJob
    SU.tJob = nil
    Log.Write("SaveUpload: abgebrochen: " .. tostring(sWhy))
    if job and job.bQuick and SU.fnSend then SU.fnSend({ t = "quickSaveFailed", msg = tostring(sWhy) }) end
end

local function PollWait(job)
    job.nWait = job.nWait - 1
    if job.nWait > 0 then return end
    job.nWait = SU.nPollEvery
    job.nPolls = job.nPolls + 1
    if job.nPolls > SU.nMaxPolls then return Fail("keine geänderte .park2 gefunden") end
    local tNow, tList = Snapshot()
    -- neueste geänderte Datei (Liste ist nach Zeit sortiert, neueste zuerst)
    local sName, sSig
    for _, e in ipairs(tList or {}) do
        local s = tNow[e.name]
        if job.tBefore[e.name] ~= s then sName, sSig = e.name, s; break end
    end
    if sName == nil then return end
    if job.sCand == sName and job.sCandSig == sSig and not SaveBusy() then
        local info = SU.Persist.SaveInfo(sName)
        if type(info) ~= "table" or not info.sha256 then return Fail("SaveInfo fehlgeschlagen für " .. sName) end
        job.sName, job.tInfo = sName, info
        job.nChunks = global.math.tointeger(info.chunks) or 0
        job.nNext = 0
        job.sPhase = "upload"
        SU.fnSend({ t = "saveUpload", seq = job.nSeq, name = sName, size = info.size, sha256 = info.sha256 })
        Log.Write("SaveUpload: lade " .. sName .. " hoch (" .. tostring(info.size) .. " Bytes, " .. job.nChunks .. " Teile)")
    else
        job.sCand, job.sCandSig = sName, sSig -- beim nächsten Blick prüfen, ob die Datei fertig ist
    end
end

local function PollUpload(job)
    if job.nNext >= job.nChunks then
        SU.fnSend({ t = "saveEnd" })
        Log.Write("SaveUpload: " .. job.sName .. " fertig gesendet (seq " .. tostring(job.nSeq) .. ")")
        SU.tJob = nil
        return
    end
    local sB64 = SU.Persist.ReadSaveChunk(job.sName, job.nNext)
    if type(sB64) ~= "string" then return Fail("Teil " .. job.nNext .. " nicht lesbar") end
    if not SU.fnSend({ t = "saveChunk", i = job.nNext, data = sB64 }) then return Fail("Senden fehlgeschlagen") end
    job.nNext = job.nNext + 1
end

-- Quick-Save auf Anfrage des Servers
function SU.QuickSave(nSeq)
    if SU.coQuick ~= nil then return end
    SU.OnSaveStarted(nSeq, true)
    SU.coQuick = coroutine.create(function()
        local tEnv = api.game.GetEnvironment()
        local plm = tEnv:RequireInterface("Interfaces.IParkLoadSaveManager")
        local tok = plm.cLastActiveParkSaveToken
        if tok == nil then error("Park hat noch keinen Spielstand (erst einmal normal speichern)") end
        local tMeta = plm:GenerateCurrentParkMetaData()
        local bOk, err = plm:SaveParkToSaveToken(tok, nil, tMeta, nil, true)
        if not bOk then error("Speichern fehlgeschlagen: " .. tostring(err)) end
    end)
    Log.Write("SaveUpload: Quick-Save angefordert (seq " .. tostring(nSeq) .. ")")
end

function SU.Tick()
    if SU.coQuick ~= nil then
        local ok, err = coroutine.resume(SU.coQuick)
        if not ok then
            SU.coQuick = nil
            Fail("Quick-Save: " .. tostring(err))
        elseif coroutine.status(SU.coQuick) == "dead" then
            SU.coQuick = nil
        end
    end
    local job = SU.tJob
    if job == nil then return end
    if job.sPhase == "wait" then PollWait(job) else PollUpload(job) end
end

return SU
