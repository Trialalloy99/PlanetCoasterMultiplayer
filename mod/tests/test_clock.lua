-- Offline-Test für pc2mp.clock: Park-Uhr über die Spielgeschwindigkeit angleichen.
-- Ausführen:  tools/cobra-tools/modules/formats/utils/luadec/lua.exe mod/tests/test_clock.lua mod/PC2MP/Main
local MAIN = arg[1] or "mod/PC2MP/Main"
local function check(c, msg) if not c then error("FEHLER: " .. msg, 2) end print("ok  " .. msg) end
package.preload["pc2mp.log"] = function() return { Write = function() end, ToStr = tostring } end
package.preload["pc2mp.clock"] = function() return assert(loadfile(MAIN .. "/pc2mp.clock.lua"))("pc2mp.clock") end

-- Simulierte Spielzeit: day + prop; läuft pro Frame mit (Basis * Skalierer), angehalten bei Pause
local sim = { t = 3.5, base = 1 / 1200 / 30 }   -- 1 Tag = 1200 s bei 30 FPS
local scalers, paused, real = {}, {}, 0
api = {
    time = {
        AcquireTimeScaler = function() local h = { f = 1 }; scalers[#scalers + 1] = h; return h end,
        SetTimeScaler = function(h, f) h.f = f end,
        ReleaseTimeScaler = function(h) h.f = 1 end,
        Pause = function(l) paused[l] = true end,
        Unpause = function(l) paused[l] = nil end,
        GetTotalTimeUnscaled = function() return real end,
    },
    world = { GetActive = function() return 1 end, GetScript = function() return { mainHUD = { nTimeScaleIndex = 1 } } end },
}
local park = {
    GetParkDay = function() return math.floor(sim.t) end,
    GetTimeOfDayActual = function() local p = sim.t - math.floor(sim.t); return math.floor(p * 24), 0, p, 0 end,
    GetDayDurationInSeconds = function() return 1200 end,
}
local function Rate() local f = 1; for _, h in ipairs(scalers) do f = f * h.f end; return f end
local function Step(n)
    for _ = 1, n do
        local bP = next(paused) ~= nil
        if not bP then sim.t = sim.t + sim.base * Rate() end
        real = real + 1 / 30
        require("pc2mp.clock").Tick()
    end
end

local Clock = require("pc2mp.clock")
Clock.Install({ park = park })
check(Clock.Format(Clock.Now()) == "Tag 3 12:00", "Park-Zeit gelesen: " .. Clock.Format(Clock.Now()))

-- 1. Mitspieler 1 h voraus -> schneller
Clock.OnTarget(sim.t + 1 / 24, "c3")
check(Clock.nFactor > 1.5 and not Clock.bPaused, string.format("zurück -> schneller (x%.1f)", Clock.nFactor))
-- 2. Mitspieler 2 h zurück -> anhalten
Clock.OnTarget(sim.t - 2 / 24, "c3")
check(Clock.bPaused, "weit voraus -> warten (Pause)")
-- 3. gleich -> normal
Clock.OnTarget(sim.t + 0.0001, "c3")
check(not Clock.bPaused and Clock.nFactor == 1, "gleich -> normales Tempo")

-- 4. Regelkreis: virtueller Mitspieler läuft normal weiter, wir holen auf
local master = sim.t + 1 / 24
local nMaxF = 1
for i = 1, 200 do
    Step(30)
    master = master + sim.base * 30
    if i % 3 == 0 then Clock.OnTarget(master, "c3") end
    nMaxF = math.max(nMaxF, Clock.nFactor)
end
check(math.abs(master - sim.t) * 1440 < 2 and nMaxF > 1.5, string.format("aufgeholt: Abstand %.1f min (max. Tempo x%.1f)", (master - sim.t) * 1440, nMaxF))
check(Clock.nFactor == 1, "nach dem Aufholen wieder normales Tempo")

-- 5. Mitspieler weg, während wir pausiert sind -> nicht hängen bleiben
Clock.OnTarget(sim.t - 1, "c3")
check(Clock.bPaused, "pausiert")
Step(700)
check(not Clock.bPaused and Clock.nFactor == 1, "keine Uhr-Nachrichten mehr -> Pause aufgehoben")

-- 6. Uhr-Test ohne Mitspieler
local ok = Clock.StartTest(1)
check(ok and Clock.tTest, "Uhr-Test gestartet")
local nGuard = 0
while Clock.tTest and nGuard < 400 do Step(30); nGuard = nGuard + 1 end
check(Clock.tTest == nil and Clock.nFactor == 1, "Uhr-Test: aufgeholt und beendet (" .. nGuard .. " s)")

-- 7. Kassenwart sendet
local sent = {}
Clock.tListeners = { function(a) sent[#sent + 1] = a end }
Clock.bMaster, Clock.bHasPeers = true, true
Step(Clock.nSendEvery)
check(#sent == 1 and sent[1].op == "clock" and math.abs(sent[1].t - sim.t) < 0.001, "Kassenwart sendet seine Park-Zeit")
Clock.Release()
check(Rate() == 1 and next(paused) == nil, "beim Verlassen alles zurückgesetzt")
print("\nALLE CLOCK-TESTS OK")
