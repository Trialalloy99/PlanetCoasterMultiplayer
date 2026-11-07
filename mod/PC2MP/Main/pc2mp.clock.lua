-----------------------------------------------------------------------
--/  PC2MP Clock: Park-Uhr (Tag + Uhrzeit) zwischen den Spielern angleichen.
--/
--/  Reverse Engineering (PlanetCoaster2.exe, 2026-11-07): Die Park-Methoden werden einzeln registriert
--/  (lea r8, fn / lea rdx, "Name" / call 0x1915780). GetParkDay = RVA 0x60f800 liest int64 [Park+0x320],
--/  GetTimeOfDayActual = RVA 0x60f8d0 liest einen doppelt gepufferten Eintrag (Index [Park+0x328], je 12 Byte
--/  ab +0x32c: float Tagesanteil, float Dämmerung, byte Stunde, byte Minute). Das sind von der Simulation jeden
--/  Tick neu geschriebene Ausgaben; eine Setz-API gibt es nicht. Speicher direkt zu beschreiben wäre unsicher.
--/  Deshalb: Uhr über die Spielgeschwindigkeit nachregeln (sicher, nur öffentliche APIs):
--/    Zeit lesen: park:GetParkDay() + select(3, park:GetTimeOfDayActual())  (Tag + Tagesanteil 0..1)
--/    Regeln:     eigener api.time-Skalierer (AcquireTimeScaler/SetTimeScaler), bei großem Vorsprung api.time.Pause
--/  Der Kassenwart (pc2mp.economy) sendet { op="clock", t=<Tage> }, die anderen regeln auf diesen Wert.
-----------------------------------------------------------------------
local global = _G
local api = global.api
local type = global.type
local pcall = global.pcall
local tostring = global.tostring
local tonumber = global.tonumber
local ipairs = global.ipairs
local math = global.math
local string = global.string
local Log = require("pc2mp.log")

local Clock = {}
Clock.tListeners = {}
Clock.fnOnEvent = nil
Clock.nSendEvery = 180          -- Frames (~3 s)
Clock.nKp = 120                 -- Tempo-Faktor pro Tag Abstand (0,01 Tag ~ 14 min Parkzeit -> 2,2x)
Clock.nMaxFactor = 5
Clock.nMinFactor = 0.2
Clock.nDeadband = 0.0007        -- ~1 min Parkzeit: gilt als gleich
Clock.nPauseAhead = 0.02        -- so weit voraus (~30 min) -> anhalten statt verlangsamen
Clock.sPauseLevel = "PC2MPClock"
Clock.nFrame = 0
Clock.bMaster = false
Clock.bHasPeers = false
Clock.nFactor = 1
Clock.bPaused = false

local function Note(s)
    Log.Write("Clock: " .. s)
    if Clock.fnOnEvent then pcall(Clock.fnOnEvent, s) end
end

local function Park() return Clock.tWorldAPIs and Clock.tWorldAPIs.park end

-- Park-Zeit in Tagen (Tag + Anteil) oder nil
function Clock.Now()
    local p = Park()
    if p == nil then return nil end
    local okD, nDay = pcall(p.GetParkDay, p)
    local okT, h, m, nProp = pcall(p.GetTimeOfDayActual, p)
    if not okD or not okT or type(nDay) ~= "number" or type(nProp) ~= "number" then return nil end
    return nDay + nProp
end

function Clock.Format(t)
    if type(t) ~= "number" then return "?" end
    local nDay = math.floor(t)
    local nMin = math.floor((t - nDay) * 1440 + 0.5)
    return string.format("Tag %d %02d:%02d", nDay, nMin // 60 % 24, nMin % 60)
end

function Clock.Install(tWorldAPIs)
    Clock.tWorldAPIs = tWorldAPIs
    Clock.nFrame = 0
    Clock.tTarget = nil
    Clock.tTest = nil
    Clock.SetFactor(1)
    Clock.SetPaused(false)
    Log.Write("Clock installiert, Park-Zeit " .. Clock.Format(Clock.Now()))
end

function Clock.SetFactor(f)
    f = math.max(Clock.nMinFactor, math.min(Clock.nMaxFactor, f))
    if math.abs(f - Clock.nFactor) < 0.05 and Clock.hScaler then return end
    if Clock.hScaler == nil then
        local ok, h = pcall(api.time.AcquireTimeScaler)
        if not ok or h == nil then return end
        Clock.hScaler = h
    end
    if pcall(api.time.SetTimeScaler, Clock.hScaler, f) then Clock.nFactor = f end
end

function Clock.SetPaused(b)
    if b == Clock.bPaused then return end
    local fn = b and api.time.Pause or api.time.Unpause
    if pcall(fn, Clock.sPauseLevel) then Clock.bPaused = b end
end

function Clock.Release()
    Clock.SetPaused(false)
    if Clock.hScaler ~= nil then
        pcall(api.time.SetTimeScaler, Clock.hScaler, 1)
        pcall(api.time.ReleaseTimeScaler, Clock.hScaler)
        Clock.hScaler = nil
    end
    Clock.nFactor = 1
end

-- Ziel-Zeit des Mitspielers übernehmen (vom Netz bzw. Uhr-Test)
function Clock.OnTarget(tTarget, sFrom)
    Clock.nLastTargetFrame = Clock.nFrame
    local tNow = Clock.Now()
    if tNow == nil or type(tTarget) ~= "number" then return end
    local nDiff = tTarget - tNow
    Clock.Control(nDiff, sFrom)
end

function Clock.Control(nDiff, sFrom)
    local sState
    if math.abs(nDiff) <= Clock.nDeadband then
        Clock.SetPaused(false)
        Clock.SetFactor(1)
        sState = "gleich"
    elseif nDiff < -Clock.nPauseAhead then
        Clock.SetPaused(true)
        sState = "voraus -> warte"
    else
        Clock.SetPaused(false)
        Clock.SetFactor(1 + nDiff * Clock.nKp)
        sState = (nDiff > 0 and "zurück" or "voraus") .. string.format(" -> Tempo x%.1f", Clock.nFactor)
    end
    local sKey = sState:sub(1, 6)
    if sKey ~= Clock.sLastState or Clock.nFrame - (Clock.nLastNote or -10000) > 1800 then
        Clock.sLastState = sKey
        Clock.nLastNote = Clock.nFrame
        Note(string.format("Uhr %s: Abstand %+.0f min (%s)", sState, nDiff * 1440, tostring(sFrom)))
    end
end

-- Uhr-Test ohne Mitspieler: ein virtueller Mitspieler ist nHours voraus (negativ = zurück) und läuft normal weiter
function Clock.StartTest(nHours)
    local tNow = Clock.Now()
    if tNow == nil then return false, "Park-Zeit nicht lesbar" end
    local ok, nDur = pcall(Park().GetDayDurationInSeconds, Park())
    Clock.tTest = { t0 = tNow + (tonumber(nHours) or 1) / 24, real0 = Clock.RealTime(),
                    nDayDur = (ok and type(nDur) == "number" and nDur > 0) and nDur or 1200 }
    Note(string.format("Uhr-Test: Mitspieler steht auf %s (du: %s)", Clock.Format(Clock.tTest.t0), Clock.Format(tNow)))
    return true, "Uhr-Test gestartet"
end

function Clock.RealTime()
    local ok, t = pcall(api.time.GetTotalTimeUnscaled)
    return ok and type(t) == "number" and t or Clock.nFrame / 30
end

local function HudSpeed()
    local okW, ws = pcall(function() return api.world.GetScript(api.world.GetActive()) end)
    local hud = okW and ws and ws.mainHUD
    if hud == nil then return 1, false end
    local tScales = { 1, 2, 5 }
    return tScales[hud.nTimeScaleIndex or 1] or 1, hud.bPaused == true
end

function Clock.Tick()
    Clock.nFrame = Clock.nFrame + 1
    if Clock.tWorldAPIs == nil then return end
    -- Sicherheit: keine Uhr-Nachrichten mehr (Mitspieler weg) -> normales Tempo, nicht pausiert bleiben
    if not Clock.tTest and Clock.nLastTargetFrame and Clock.nFrame - Clock.nLastTargetFrame > 600
        and (Clock.bPaused or Clock.nFactor ~= 1) then
        Clock.SetPaused(false)
        Clock.SetFactor(1)
        Clock.nLastTargetFrame = nil
        Note("keine Uhr vom Mitspieler mehr -> normales Tempo")
    end
    if Clock.nFrame % Clock.nSendEvery ~= 0 then return end
    local tNow = Clock.Now()
    if tNow == nil then return end
    -- Uhr-Test: virtueller Mitspieler läuft mit normalem Tempo (laut HUD) weiter
    local tt = Clock.tTest
    if tt then
        local nSpeed, bPaused = HudSpeed()
        local nReal = Clock.RealTime()
        if not bPaused then tt.t0 = tt.t0 + (nReal - tt.real0) * nSpeed / tt.nDayDur end
        tt.real0 = nReal
        local nDiff = tt.t0 - tNow
        Clock.Control(nDiff, "Uhr-Test")
        if math.abs(nDiff) <= Clock.nDeadband then
            Note("Uhr-Test fertig: beide Uhren gleich (" .. Clock.Format(tNow) .. ")")
            Clock.tTest = nil
            Clock.SetFactor(1)
            Clock.SetPaused(false)
        end
        return
    end
    if Clock.bMaster and Clock.bHasPeers then
        for _, fn in ipairs(Clock.tListeners) do pcall(fn, { op = "clock", t = tNow }) end
    end
end

return Clock
