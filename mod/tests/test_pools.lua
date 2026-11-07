-- Offline-Test für pc2mp.pools: Pools per Abfrage erkennen, Umriss übertragen, Zwilling, Abriss.
-- Ausführen:  tools/cobra-tools/modules/formats/utils/luadec/lua.exe mod/tests/test_pools.lua mod/PC2MP/Main
local MAIN = arg[1] or "mod/PC2MP/Main"
local function check(c, msg) if not c then error("FEHLER: " .. msg, 2) end print("ok  " .. msg) end
local function preload(n) package.preload[n] = function() return assert(loadfile(MAIN .. "/" .. n .. ".lua"))(n) end end
package.preload["pc2mp.log"] = function() return { Write = function() end, ToStr = tostring } end
package.preload["Vector3"] = function()
    local V = {}; V.__index = V
    function V:new(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end
    function V:GetX() return self.x end function V:GetY() return self.y end function V:GetZ() return self.z end
    return V
end
local applied, jobs = {}, {}
package.preload["pc2mp.worldedit"] = function()
    local W = assert(loadfile(MAIN .. "/pc2mp.worldedit.lua"))("pc2mp.worldedit")
    W.Apply = function(a, off, done) applied[#applied + 1] = { a = a, off = off }; if done then done(true, true) end end
    return W
end
package.preload["pc2mp.replay"] = function()
    return { IsBusy = function() return false end, Enqueue = function(l, fn) jobs[#jobs + 1] = l end }
end
preload("pc2mp.pools")
local n = 0
api = { json = { Stringify = function(t) n = n + 1; return true, "sig" .. tostring(SIG) end },
        transform = { CalculateWorldTransform = function(e) return { GetPos = function() return require("Vector3"):new(10, 0, 10) end } end } }
local Vector3 = require("Vector3")
local pools = { 501 }
local outline = { sOutlineType = "Pool", sRenderType = "Tiles", nClipPriority = 2, nGroundedRequest = 1,
                  { vPos = Vector3:new(0, 0, 0) }, { vPos = Vector3:new(20, 0, 0) }, { vPos = Vector3:new(20, 0, 20) } }
local tw = {
    pools = { GetAllPools = function() return pools end },
    volumes = { GetVolumeIDFromEntityID = function(_, e) if e == 502 then return 502 end return nil end,
                Raycast = function(_, s, d) return 5, 77 end,
                GetVolumeOutline = function(_, id)
                    if id == 502 then   -- Zwilling: gleicher Umriss bei +25
                        return { sOutlineType = "Pool", { vPos = Vector3:new(25, 0, 0) }, { vPos = Vector3:new(45, 0, 0) }, { vPos = Vector3:new(45, 0, 20) } }
                    end
                    return outline
                end },
}
local Pools = require("pc2mp.pools")
Pools.Install(tw)
local out = {}
Pools.tListeners = { function(a) out[#out + 1] = a end }
SIG = 1
for _ = 1, Pools.nPollEvery do Pools.Tick() end
check(#out == 0, "vorhandene Pools beim Laden nicht senden")
SIG = 2   -- Umriss geändert (z. B. Pinsel)
for _ = 1, Pools.nPollEvery do Pools.Tick() end
check(#out == 1 and out[1].op == "pool" and out[1].outline.sOutlineType == "Pool" and out[1].prio == 2, "Änderung erkannt, Umriss gesendet (Volumen per Raycast)")
-- Testmodus: Zwilling bei +25
Pools.nOffsetX = 25
Pools.Apply(out[1], "Testmodus")
check(#applied == 1 and applied[1].off == 25 and applied[1].a.outlines[1].outline.sRenderType == "Tiles", "Zwilling über WorldEdit (Versatz 25)")
check(Pools.tCopies[out[1].key].centre[1] > 30, "Kopie-Position gemerkt")
-- Kopie taucht als neuer Pool auf -> nicht erneut senden
pools = { 501, 502 }
local oldPos = api.transform.CalculateWorldTransform
SIG = 3
for _ = 1, Pools.nPollEvery do Pools.Tick() end
check(#out == 2, "Original erneut geändert -> gesendet (Kopie wird über die Position erkannt)")
pools = { 502 }
for _ = 1, Pools.nPollEvery do Pools.Tick() end
check(out[#out].op == "pooldel", "Abriss gemeldet")
Pools.Apply(out[#out], "Testmodus")
check(jobs[#jobs]:find("pool remove"), "Kopie wird entfernt")
print("\nALLE POOLS-TESTS OK")
