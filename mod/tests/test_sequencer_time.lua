-- Offline-Test: Event-Ablauf-Steuerung (Programm/Einstellungen/Musik), animierte Szenerie (Schleifentyp, Auslöser),
-- Zeit/Wetter über das HUD (pc2mp.gamestate) und Defekte von Fahrgeschäften (pc2mp.breakdowns). Gemockte Spiel-APIs.
-- Ausführen:  tools/cobra-tools/modules/formats/utils/luadec/lua.exe mod/tests/test_sequencer_time.lua mod/PC2MP/Main
local MAIN = arg[1] or "mod/PC2MP/Main"
local function preload(name)
    package.preload[name] = function() return assert(loadfile(MAIN .. "/" .. name .. ".lua"))(name) end
end
local function check(c, msg) if not c then error("FEHLER: " .. msg, 2) end print("ok  " .. msg) end

local log = {}
local REG = {}
local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end
api = {
    pc2mp = nil,
    json = {
        Stringify = function(t)
            local function conv(v)
                if type(v) ~= "table" then return v end
                local o = {}
                for k, x in pairs(v) do o[type(k) == "number" and tostring(k) or k] = conv(x) end
                return o
            end
            local function enc(v)
                if type(v) ~= "table" then return type(v) .. ":" .. tostring(v) end
                local ks = {}
                for k in pairs(v) do ks[#ks + 1] = k end
                table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
                local o = {}
                for _, k in ipairs(ks) do o[#o + 1] = tostring(k) .. "=" .. enc(v[k]) end
                return "{" .. table.concat(o, ",") .. "}"
            end
            local c = conv(t)
            local k = "#json" .. enc(c)
            REG[k] = c
            return true, k
        end,
        Parse = function(s) return REG[s] ~= nil, deepcopy(REG[s]) end,
    },
    time = { GetTotalTimeUnscaled = function() return NOW or 0 end },
}
package.preload["pc2mp.log"] = function()
    return { Write = function(s) log[#log + 1] = s end, ToStr = function(v) return tostring(v) end }
end
package.preload["Vector3"] = function()
    local V = {}
    V.__index = V
    function V:new(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end
    function V:GetX() return self.x end
    function V:GetY() return self.y end
    function V:GetZ() return self.z end
    return V
end
for _, m in ipairs({ "pc2mp.props", "pc2mp.sequencer", "pc2mp.gamestate", "pc2mp.breakdowns", "pc2mp.economy",
                     "pc2mp.entref" }) do preload(m) end
local Vector3 = require("Vector3")
local Props = require("pc2mp.props")
local Seq = require("pc2mp.sequencer")

-- ---------------------------------------------------------------- Mock: natives Sequenz-Objekt
local nNextItem = 100
local SeqMT = {}
SeqMT.__index = SeqMT
local function NewSeq() return setmetatable({ items = {}, ui = Vector3:new(0.5, 0.5, 0.5) }, SeqMT) end
function SeqMT:CountItems() return #self.items end
function SeqMT:GetSequenceItems() local ids = {}; for i, it in ipairs(self.items) do ids[i] = it.id end; return { tItemIDs = ids } end
function SeqMT:GetItemIsGroup(i) return self.items[i + 1].group == true end
function SeqMT:GetSequenceItemFromIndex(i) local it = self.items[i + 1]; return it.t, it.sub end
function SeqMT:GetEventItemFromIndex(i) return self.items[i + 1].part end
local function ById(s, id) for _, it in ipairs(s.items) do if it.id == id then return it end end end
function SeqMT:GetEventDelayWithItemID(id) return ById(self, id).t end
function SeqMT:GetEventTypeWithItemID(id) return ById(self, id).ty end
function SeqMT:GetEventDurationWithItemID(id) return ById(self, id).d end
function SeqMT:GetEventStrobeWithItemID(id) return ById(self, id).s end
function SeqMT:GetEventFadeDurationWithItemID(id) return ById(self, id).fd end
function SeqMT:GetEventFadeToColourWithItemID(id) return ById(self, id).fc end
function SeqMT:GetEventUIColourWithItemID(id) return ById(self, id).ui end
function SeqMT:SetEventDelayWithItemID(id, v) ById(self, id).t = v end
function SeqMT:SetEventTypeWithItemID(id, v) ById(self, id).ty = v end
function SeqMT:SetEventDurationWithItemID(id, v) ById(self, id).d = v end
function SeqMT:SetEventStrobeWithItemID(id, v) ById(self, id).s = v end
function SeqMT:SetEventFadeDurationWithItemID(id, v) ById(self, id).fd = v end
function SeqMT:SetEventColourWithItemID(id, v) ById(self, id).fc = v end
function SeqMT:GetUIColour() return self.ui end
function SeqMT:RemoveItemWithItemID(id) for i, it in ipairs(self.items) do if it.id == id then table.remove(self.items, i) return end end end
function SeqMT:SortItems() table.sort(self.items, function(a, b) return (a.t or 0) < (b.t or 0) end) end
function SeqMT:AddBlankSequenceItem(t, nColour, bGroup)
    nNextItem = nNextItem + 1
    local sub = NewSeq()
    table.insert(self.items, { id = nNextItem, t = t, group = bGroup, sub = sub })
    return sub, nNextItem
end
function SeqMT:SetSequenceItemWithItemID(id, sub) ById(self, id).sub = sub end
function SeqMT:AddEventItem(t, part, mode, vUI, d)
    nNextItem = nNextItem + 1
    table.insert(self.items, { id = nNextItem, t = t, part = part, ui = vUI, d = d, ty = 0 })
end
function SeqMT:CreateDeepCopy()
    local function cp(s)
        local n = NewSeq()
        for _, it in ipairs(s.items) do
            local c = {}
            for k, v in pairs(it) do c[k] = v end
            if it.sub then c.sub = cp(it.sub) end
            table.insert(n.items, c)
        end
        return n
    end
    return cp(self)
end

-- Welt: Sequencer 10 (Original) mit Programm, Lichter 11/12; Zwillinge: 20 (Sequencer), 21/22
local sequences = {}
local settings = {}
local music = {}
local propData = {}
local anim = {}
local function MakeProgram()
    local root = NewSeq()
    local track1 = select(1, root:AddBlankSequenceItem(0, 0, false))
    track1:AddEventItem(1.5, 11, 0, Vector3:new(1, 0, 0), 4)
    local it = track1.items[#track1.items]; it.ty = 2; it.s = 0.25; it.fd = 1; it.fc = Vector3:new(0, 0, 1)
    local grp = select(1, track1:AddBlankSequenceItem(5, 0, true))
    grp:AddEventItem(0.5, 12, 0, Vector3:new(0, 1, 0))
    local track2 = select(1, root:AddBlankSequenceItem(0, 0, false))
    track2:AddEventItem(3, 12, 0, Vector3:new(0, 1, 0))
    track2:AddEventItem(4, 99, 0, Vector3:new(0, 1, 0))   -- Objekt ohne Zuordnung
    return root
end
sequences[10] = MakeProgram()
sequences[20] = NewSeq()
settings[10] = { nTriggerMode = 2, nLoopMode = 1, bRestrictActivationTimes = true, tShowTimes = { { nHour = 20 }, { nHour = 22 } } }
settings[20] = { nTriggerMode = 0 }
music[10] = "Music_Fanfare"
local edits = {}
local tw = {
    sequence = {
        DatastoreChange_LoopAnim = 1, DatastoreChange_Behaviour = 2, DatastoreChange_TriggerControlled = 3,
        SequencerDatastoreChange_TriggerSettings = 4,
        GetSequencerTriggerSettings = function(_, id) return settings[id] end,
        GetSequencerTriggerSequence = function(_, id) return sequences[id] end,
        SetSequencerTriggerSequenceMoveObject = function(_, eo, o) eo.pending.seq = o end,
        SetSequencerTriggerSettingsMoveObject = function(_, eo, t) eo.pending.set = t end,
        SetSequencerCustomMusicMoveObject = function(_, eo, s) eo.pending.music = s end,
        CreateEditOperationForSequencerDatastoreChange = function(_, clh, id, k) edits[#edits + 1] = k end,
        CreateEditOperationForDatastoreChange = function(_, clh, id, k) edits[#edits + 1] = k end,
        GetTriggerUIMode = function() return 0 end,
        GetTriggerTargetPropData = function(_, id) return propData[id] end,
        GetPartTriggerControlled = function(_, id) return anim[id] and anim[id].ctrl end,
        GetPartTriggerDuration = function(_, id) return anim[id] and anim[id].dur end,
        GetPartTriggerStrobe = function(_, id) return anim[id] and anim[id].strobe end,
        SetLoopAnim = function(_, eo, n) eo.pending.loop = n end,
        SetTriggerControlledMoveObject = function(_, eo, b) eo.pending.ctrl = b end,
        SetTriggerBehaviourMoveObject = function(_, eo, n) eo.pending.type = n end,
        SetTriggerDurationPart = function(_, id, n) anim[id].dur = n end,
        SetTriggerStrobePart = function(_, id, n) anim[id].strobe = n end,
    },
    gameaudio = { GetSequencerEvent = function(_, id) return music[id] end },
    scenery = {},
}

-- ---------------------------------------------------------------- 1. Programm lesen
local twinOf = { [11] = 21, [12] = 22, [10] = 20 }
local d = Seq.DescribeSequencer(tw, 10, function(n) if n == 99 then return nil end return n end)
check(d and d.music == "Music_Fanfare" and d.set.nTriggerMode == 2, "Einstellungen + Musik gelesen")
check(#d.prog.tracks == 2 and #d.prog.tracks[1].items == 2 and #d.prog.tracks[2].items == 1, "2 Spuren, Gruppe, Objekt ohne Zuordnung ausgelassen")
local e1 = d.prog.tracks[1].items[1]
check(e1.p == 11 and e1.t == 1.5 and e1.ty == 2 and e1.d == 4 and e1.s == 0.25 and e1.fc[3] == 1, "Ereignis mit allen Werten")
check(d.prog.tracks[1].items[2].g and d.prog.tracks[1].items[2].g[1].p == 12, "Gruppe mit Unter-Ereignis")
check(Seq.nUnmapped == 1, "unbekanntes Ziel gezählt")

-- über JSON (wie das Netz) und auf den Zwilling-Sequencer 20 anwenden
local _, s = api.json.Stringify({ seqr = d })
local _, back = api.json.Parse(s)
local eo = { pending = {} }
local n = Seq.ApplySequencerInEdit(tw, {}, eo, 20, Seq.Norm(back.seqr), function(r) return twinOf[tonumber(r)] end)
check(n == 3, "Einstellungen, Musik und Programm gesetzt")
check(eo.pending.music == "Music_Fanfare" and eo.pending.set.nTriggerMode == 2 and #eo.pending.set.tShowTimes == 2,
    "Einstellungen (inkl. Showzeiten-Liste) nach JSON korrekt")
local root = eo.pending.seq
check(root and root:CountItems() == 2, "neues Programm hat 2 Spuren")
local _, tr1 = root:GetSequenceItemFromIndex(0)
local ev = tr1.items[1]
check(ev.part == 21 and ev.t == 1.5 and ev.ty == 2 and ev.d == 4 and ev.s == 0.25 and ev.fd == 1, "Ereignis zeigt auf den Zwilling, Werte übernommen")
check(tr1.items[2].group and tr1.items[2].sub.items[1].part == 22, "Gruppe nachgebaut, Ziel = Zwilling")
local _, tr2 = root:GetSequenceItemFromIndex(1)
check(#tr2.items == 1 and tr2.items[1].part == 22, "Spur 2 nachgebaut")
check(sequences[20]:CountItems() == 0, "Original-Sequenz des Ziels nicht verändert (Kopie)")
-- Rundweg: nochmal lesen ergibt dasselbe (mit Zwilling-IDs zurückgerechnet)
sequences[20] = root
local d2 = Seq.DescribeSequencer(tw, 20, function(n2) for k, v in pairs(twinOf) do if v == n2 then return k end end end)
check(Props.DeepEq(d2.prog, d.prog), "Programm Rundweg identisch")

-- ---------------------------------------------------------------- 2. Animation (Schleifentyp, Auslöser)
propData[30] = { nAnimLoop = 3, nType = 1 }
anim[30] = { ctrl = false, dur = 12, strobe = 4 }
propData[31] = { nAnimLoop = 0, nType = 0 }
anim[31] = { ctrl = false, dur = 5, strobe = 1 }
local a = Seq.DescribeAnim(tw, 30)
check(a.loop == 3 and a.type == 1 and a.ctrl == false and a.dur == 12 and a.strobe == 4, "Animation gelesen")
local eo2 = { pending = {} }
edits = {}
Seq.ApplyAnimInEdit(tw, {}, eo2, 31, a)
check(eo2.pending.loop == 3 and eo2.pending.type == 1 and eo2.pending.ctrl == false, "Schleifentyp + Auslöser in der Edit-Hierarchie")
check(#edits == 2, "Datastore-Änderungen für Schleife + Verhalten angemeldet")
Seq.ApplyAnimDirect(tw, 31, a)
check(anim[31].dur == 12 and anim[31].strobe == 4, "Intervall + Dauer direkt gesetzt")
check(Props.NeedsEdit({ anim = a }) and Props.NeedsEdit({ seqr = d }), "Animation/Ablaufsteuerung brauchen eine Edit-Hierarchie")
check(not Props.Equal({ anim = a }, { anim = { loop = 2, type = 1, ctrl = false, dur = 12, strobe = 4 } }), "anderer Schleifentyp wird erkannt")
check(Props.Equal({ anim = a }, Props.Normalize({ anim = { loop = 3, type = 1, ctrl = false, dur = 12, strobe = 4 } })), "gleiche Animation = gleich")

-- ---------------------------------------------------------------- 3. Zeit/Wetter über das HUD
local GameState = require("pc2mp.gamestate")
local Hud = {}
Hud.__index = Hud
function Hud:ChangeSimulationSpeedSettings(b, n) if b ~= nil then self.paused = b end if n ~= nil then self.speed = n end end
function Hud:SetWeatherOverride(n) self.weather = n end
function Hud:ChangeFixedSunTime(n) self.sun = n end
local hud = setmetatable({ paused = false, speed = 1 }, Hud)
api.world = { GetActive = function() return 1 end, GetScript = function() return HUDREADY and { mainHUD = hud } or {} end }
local weatherApi = { cur = 0, SetWeatherOverride = function(self, n) self.cur = n end }
GameState.Install({ weather = weatherApi }, nil)
check(#GameState.tMissing > 0, "HUD noch nicht da -> Ziele fehlen")
HUDREADY = true
for _ = 1, GameState.nWarmupFrames do GameState.Tick() end
local nTime = 0
for _, t in ipairs(GameState.tTargets) do if t.hud and not (function() for _, m in ipairs(GameState.tMissing) do if m == t then return true end end end)() then nTime = nTime + 1 end end
check(nTime == 1, "HUD-Ziel (Geschwindigkeit) später per Nachversuch erfasst")
local sent = {}
GameState.tListeners = { function(x) sent[#sent + 1] = x end }
hud:ChangeSimulationSpeedSettings(nil, 3)
check(#sent == 1 and sent[1].k == "time.Speed" and sent[1].a[1] == nil and sent[1].a[2] == 3, "Geschwindigkeit gesendet (nil, 3)")
hud:ChangeSimulationSpeedSettings(true, nil)
check(#sent == 2 and sent[2].a[1] == true, "Pause gesendet")
weatherApi:SetWeatherOverride(4)
check(#sent == 3 and sent[3].k == "weather.Override" and weatherApi.cur == 4, "Wetter erzwingen gesendet")
-- Mitspieler: über JSON zurück
local hud2 = setmetatable({ paused = false, speed = 1 }, Hud)
local _, sJ = api.json.Stringify(sent[1])
local _, tJ = api.json.Parse(sJ)
GameState.oHud = hud2
GameState.ApplyRemote(tJ, "c2")
check(hud2.speed == 3 and hud2.paused == false, "Remote: Geschwindigkeit 3, Pause unverändert (nil-Argument bleibt nil)")
GameState.oHud = nil

-- ---------------------------------------------------------------- 4. Defekte
local BD = require("pc2mp.breakdowns")
local broken = {}
local stationPos = { [501] = { 10, 0, 10 }, [502] = { 50, 0, 10 }, [601] = { 35, 0, 10 } }  -- 601 = Zwilling von 501 (+25)
api.transform = { CalculateWorldTransform = function(e)
    local p = stationPos[e]
    return { GetPos = function() return { GetX = function() return p[1] end, GetY = function() return p[2] end, GetZ = function() return p[3] end } end }
end }
local twBD = {
    rides = { GetAllRides = function() return { 1, 2, 3 } end,
              GetStationsForRide = function(_, r) return ({ { 501 }, { 502 }, { 601 } })[r] end },
    ridestation = { IsBrokenDown = function(_, s) return broken[s] == true end,
                    TriggerBreakdown = function(_, s) broken[s] = true end },
}
BD.Install(twBD)
local out = {}
BD.tListeners = { function(x) out[#out + 1] = x end }
broken[502] = true                                  -- war schon beim Laden kaputt
for _ = 1, BD.nPollEvery do BD.Tick() end
check(#out == 0, "Defekte beim Laden werden nicht gemeldet")
broken[501] = true
for _ = 1, BD.nPollEvery do BD.Tick() end
check(#out == 1 and out[1].op == "breakdown" and out[1].pos[1] == 10, "neuer Defekt gemeldet (mit Position)")
BD.nOffsetX = 25
check(BD.ApplyRemote(out[1], "Testmodus") and broken[601], "Testmodus: Zwilling-Station kaputt gemacht")
for _ = 1, BD.nPollEvery do BD.Tick() end
check(#out == 1, "selbst ausgelöster Defekt wird nicht erneut gemeldet")
BD.nOffsetX = 0
check(not BD.ApplyRemote({ op = "breakdown", pos = { 900, 0, 0 } }, "c2"), "keine Station an der Position -> nichts")
local okT, sT = BD.TriggerTest()
check(okT == false and sT:find("schon defekt"), "Test-Knopf: alle schon defekt")
broken = {}
okT = BD.TriggerTest()
check(okT and broken[501], "Test-Knopf löst einen Defekt aus")

-- ---------------------------------------------------------------- 5. Läden + Mitarbeiter (Entity-Zuordnung) + Kontostand
local ER = require("pc2mp.entref")
local facPos = { [701] = { 100, 0, 0 }, [702] = { 125, 0, 0 } }  -- 702 = Zwilling von 701 (+25)
local staffPos = {}
local open, inv, names = {}, { [701] = 801, [702] = 802 }, { [901] = "Anna Schmidt" }
local prices = {}
local cash = 5000
local fired = {}
api.transform.CalculateWorldTransform = function(e)
    local p = facPos[e] or stationPos[e] or staffPos[e]
    if p == nil then return nil end
    return { GetPos = function() return { GetX = function() return p[1] end, GetY = function() return p[2] end, GetZ = function() return p[3] end } end }
end
api.transform.SetPosition = function(e, v) staffPos[e] = { v:GetX(), v:GetY(), v:GetZ() } end
local FacMT = { __index = {
    GetAllFacilityEntityIDs = function() return { 701, 702 } end,
    SetOpen = function(_, e, b) open[e] = b end,
    GetShopInventoryEntityID = function(_, e) return inv[e] end,
    SetShopItemPrice = function(_, i, n, p) prices[i .. ":" .. n] = p end,
} }
local nextStaff = 950
local tok = {}
local twE = {
    facilities = setmetatable({}, FacMT),
    staff = { GetAllStaffEntities = function() local o = {}; for e in pairs(names) do o[#o + 1] = e end; return o end,
              GetStaffUIName = function(_, e) return names[e] end,
              SetStaffUIName = function(_, e, s) names[e] = s end,
              FireStaffMember = function(_, e) fired[e] = true; names[e] = nil end,
              GenerateRandomStaff = function(_, prefab, x, t) nextStaff = nextStaff + 1; names[nextStaff] = "Zufall " .. nextStaff; return nextStaff end,
              SetStaffMemberSuspended = function() end, SetStaffMemberParkZone = function() end,
              GetAllStaffBuildingEntityIDs = function() return {} end },
    park = { GetParkZoneIDFromPoint = function() return 1 end, ExpenditureCategory_Uncategorised = 99 },
    money = { GetCash = function() return cash end, ModifyCash = function(_, n, c) cash = cash + n; LASTCAT = c end },
    rides = { GetAllRides = function() return {} end },
}
api.entity = { CreateRequestCompletionToken = function() return tok end, HaveRequestsCompleted = function() return true end }
ER.tWorldAPIs = twE
GameState.Install(twE, nil)
for _ = 1, GameState.nWarmupFrames do GameState.Tick() end
local sentE = {}
GameState.tListeners = { function(x) sentE[#sentE + 1] = x end }
twE.facilities:SetOpen(701, false)
check(#sentE == 1 and sentE[1].k == "fac.SetOpen" and sentE[1].a[1].pos[1] == 100 and sentE[1].a[2] == false, "Laden schließen: Laden über Position gesendet")
twE.facilities:SetShopItemPrice(801, 2, 350)
NOW = 100; GameState.Tick(); NOW = 101; GameState.Tick()
check(#sentE == 2 and sentE[2].k == "shop.SetShopItemPrice" and sentE[2].a[1].pos[1] == 100 and sentE[2].a[3] == 350, "Preis: Sortiment über die Laden-Position")
ER.nOffsetX = 25
local _, sE = api.json.Stringify(sentE[1]); local _, tE = api.json.Parse(sE)
check(GameState.ApplyRemote(tE, "c2") and open[702] == false and open[701] == false, "Remote/Test: Zwilling-Laden geschlossen")
local _, sP = api.json.Stringify(sentE[2]); local _, tP = api.json.Parse(sP)
GameState.ApplyRemote(tP, "c2")
check(prices["802:2"] == 350, "Remote/Test: Preis im Sortiment des Zwilling-Ladens")
ER.nOffsetX = 0
check(#sentE == 2, "kein Echo")
twE.staff:SetStaffUIName(901, "Anna S.")
check(#sentE == 3 and sentE[3].a[1].name == "Anna Schmidt" and sentE[3].a[2] == "Anna S.", "Umbenennen: alter Name als Kennung")
names[905] = "Anna Schmidt"
local _, sR = api.json.Stringify(sentE[3]); local _, tR = api.json.Parse(sR)
names[901] = nil
GameState.ApplyRemote(tR, "c2")
check(names[905] == "Anna S.", "Remote: Mitarbeiter umbenannt")
names[901] = "Anna S."; names[905] = nil
twE.staff:FireStaffMember(901)
check(#sentE == 4 and sentE[4].k == "staff.FireStaffMember" and sentE[4].a[1].name == "Anna S.", "Entlassen gesendet (Name vor dem Entlassen)")

local Eco = require("pc2mp.economy")
Eco.Install(twE)
local ecoOut = {}
Eco.tListeners = { function(x) ecoOut[#ecoOut + 1] = x end }
local eNew = twE.staff:GenerateRandomStaff("Staff_Mechanic", 0, tok)
staffPos[eNew] = { 50, 0, 50 }
twE.staff:SetStaffMemberSuspended(eNew, false, nil)
check(#ecoOut == 1 and ecoOut[1].act == "hire" and ecoOut[1].prefab == "Staff_Mechanic" and ecoOut[1].name == names[eNew], "Einstellen erkannt (Prefab, Position, Name)")
twE.staff:SetStaffMemberSuspended(eNew, false, nil)
check(#ecoOut == 2 and ecoOut[2].act == "move", "erneutes Absetzen = Versetzen")
-- Ablauf wie im Spiel: sofort aufheben, auf Gehirn warten, dann absetzen
local suspendLog, brainReady = {}, {}
twE.staff.SetStaffMemberSuspended = function(_, e, b) suspendLog[#suspendLog + 1] = { e, b } end
twE.staff.HasStaffBrain = function(_, e) return brainReady[e] == true end
Eco.Install(twE)
Eco.tListeners = { function(x) ecoOut[#ecoOut + 1] = x end }
Eco.nOffsetX, Eco.bTwinMode = 25, true
local co = coroutine.create(function() return Eco.ApplyStaff(ecoOut[1], "Testmodus") end)
local okC, bHire = coroutine.resume(co)
local eTwin = nextStaff
check(okC and coroutine.status(co) == "suspended" and suspendLog[1][1] == eTwin and suspendLog[1][2] == true,
    "Zwilling sofort aufgehoben, wartet auf das Gehirn")
check(staffPos[eTwin] == nil, "ohne Gehirn noch nicht abgesetzt")
brainReady[eTwin] = true
for _ = 1, 5 do if coroutine.status(co) == "suspended" then okC, bHire = coroutine.resume(co) end end
check(okC and bHire and staffPos[eTwin][1] == 75 and suspendLog[#suspendLog][2] == false, "mit Gehirn bei +25 abgesetzt")
check(names[eTwin] ~= names[eNew] and Eco.tTwinStaff[names[eNew]] == eTwin, "Testmodus: Zwilling nicht umbenannt, Zuordnung über Tabelle")
check(#ecoOut == 2, "eigenes Einstellen beim Nachspielen nicht erneut gesendet")
Eco.nOffsetX, Eco.bTwinMode = 0, false
Eco.UpdateMaster("c3", { c7 = true })
check(Eco.bCashMaster, "kleinste Client-ID ist Kassenwart")
for _ = 1, Eco.nCashEvery do Eco.Tick() end
check(ecoOut[#ecoOut].op == "cash" and ecoOut[#ecoOut].n == 5000, "Kassenwart sendet den Kontostand")
Eco.UpdateMaster("c7", { c3 = true })
check(not Eco.bCashMaster, "andere Client-ID: kein Kassenwart")
Eco.ApplyCash({ op = "cash", n = 7250 }, "c3")
check(cash == 7250 and LASTCAT == 99, "Kontostand angeglichen (Kategorie 'Sonstiges')")
local nBefore = #ecoOut
Eco.UpdateMaster("c3", {})
for _ = 1, Eco.nCashEvery do Eco.Tick() end
check(#ecoOut == nBefore, "allein im Room: kein Senden")

print("\nALLE SEQUENCER/ZEIT/DEFEKT-TESTS OK")
