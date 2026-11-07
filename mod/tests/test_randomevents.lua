-- Offline-Test für pc2mp.randomevents (Zufallsereignisse auf Spieler aufteilen, Vandalismus übertragen).
-- Ausführen:  tools/cobra-tools/modules/formats/utils/luadec/lua.exe mod/tests/test_randomevents.lua mod/PC2MP/Main
local MAIN = arg[1] or "mod/PC2MP/Main"
local set = {}
local receivers = {}
local vandalised = {}
local ents = { [500] = { 10, 0, 10 }, [600] = { 50, 0, 50 } }
api = {
    pc2mp = {},
    messaging = {
        MsgType_ParkObjectVandalisedMessage = 77,
        RegisterReceiver = function(t, fn) receivers[t] = fn end,
        UnregisterReceiver = function() end,
    },
    transform = { CalculateWorldTransform = function(e)
        local p = ents[e]
        if not p then return nil end
        return { GetPos = function() return { GetX = function() return p[1] end, GetY = function() return p[2] end, GetZ = function() return p[3] end } end }
    end },
}
package.preload["pc2mp.log"] = function() return { Write = function(s) print("  log: " .. s) end, ToStr = function(v) return tostring(v) end } end
package.preload["pc2mp.entref"] = function() return { Places = function() return { 500, 600 } end } end
local RE = assert(loadfile(MAIN .. "/pc2mp.randomevents.lua"))("pc2mp.randomevents")
local sm = {
    GetBreakdownRateMultiplier = function() return 1.5 end,
    GetSecurityNumGuestsPerPickpocketSpawn = function() return 250 end,
    GetSecurityMinGuestsBeforePickpocketSpawn = function() return 150 end,
    GetSecurityMaxPickpocketsInPark = function() return 10 end,
    GetSecurityGroupCanBecomeVandalChance = function() return 0.1 end,
}
local tw = {
    rides = { SetBreakdownRateMultiplier = function(_, x) set.breakdown = x end },
    guests = {
        SetMiscreantSpawnLimits = function(_, a, b, c) set.pp = { a, b, c } end,
        SetGroupCanBecomeVandalChance = function(_, x) set.vandal = x end,
    },
    park = {
        IsVandalised = function(_, e) return vandalised[e] == true end,
        Vandalise = function(_, e) vandalised[e] = true end,
    },
    placement = { EntityIDToPlacementID = function() return nil end },
}
local env = { RequireInterface = function() return sm end }
local function check(c, msg) if not c then error("FEHLER: " .. msg, 2) end print("ok  " .. msg) end

RE.Install(tw, env)
for _ = 1, 120 do RE.Tick() end
check(set.breakdown == 1.5 and set.pp[1] == 250 and set.pp[3] == 10 and math.abs(set.vandal - 0.1) < 1e-9, "allein: normale Raten (Park-Einstellungen)")

RE.SetPlayers(2)
check(set.breakdown == 0.75, "2 Spieler: Ausfallrate halbiert (Basis 1.5 -> 0.75)")
check(set.pp[1] == 500 and set.pp[2] == 150 and set.pp[3] == 5, "2 Spieler: halb so viele Taschendiebe (alle 500 Gäste, max 5)")
check(math.abs(set.vandal - 0.05) < 1e-9, "2 Spieler: Vandalen-Chance halbiert")
RE.SetPlayers(1)
check(set.breakdown == 1.5 and set.pp[1] == 250, "Mitspieler weg: wieder normale Raten")

-- Vandalismus erkannt -> gesendet
local out = {}
RE.tListeners = { function(a) out[#out + 1] = a end }
receivers[77]({ { nEntityID = 500 } })
check(#out == 1 and out[1].op == "vandal" and out[1].ref.pos[1] == 10, "Vandalismus erkannt und mit Position gesendet")

-- beim Mitspieler übernommen, kein Echo
local okA = RE.ApplyRemote({ op = "vandal", ref = { pos = { 50.2, 0, 50 } } }, "c2")
check(okA and vandalised[600], "Vandalismus vom Mitspieler übernommen (Objekt über Position gefunden)")
receivers[77]({ { nEntityID = 600 } })
check(#out == 1, "eigener Nachbau wird nicht zurückgesendet")
check(RE.ApplyRemote({ op = "vandal", ref = { pos = { 999, 0, 999 } } }, "c2") == false, "unbekanntes Objekt: kein Fehler")
print("\nALLE RANDOMEVENTS-TESTS OK")
