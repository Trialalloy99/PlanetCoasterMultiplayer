-- Offline-Test: Objekt-Eigenschaften (Farben/Lichtmuster), Spiegel-Zwilling mit Farben, Park-Einstellungen/
-- Marketing (pc2mp.gamestate), Testmodus und Farb-Vektoren im Wege-Spiegel. Gemockte Spiel-APIs.
-- Ausführen:  tools/cobra-tools/modules/formats/utils/luadec/lua.exe mod/tests/test_props_settings.lua mod/PC2MP/Main
local MAIN = arg[1] or "mod/PC2MP/Main"
local function preload(name)
    package.preload[name] = function() return assert(loadfile(MAIN .. "/" .. name .. ".lua"))(name) end
end
local function check(c, msg) if not c then error("FEHLER: " .. msg, 2) end print("ok  " .. msg) end

-- ---------------------------------------------------------------- Mocks
local log = {}
local files = {}
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
        -- wie das Spiel: Arrays werden zu Objekten mit String-Schlüsseln
        Stringify = function(t)
            local function conv(v)
                if type(v) ~= "table" then return v end
                local o = {}
                for k, x in pairs(v) do o[type(k) == "number" and tostring(k) or k] = conv(x) end
                return o
            end
            -- deterministischer Text (wie echtes JSON): gleiche Werte -> gleicher String
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
    undo = { IsBusy = function() return false end },
}
package.preload["pc2mp.log"] = function()
    return { Write = function(s) log[#log + 1] = s end, ToStr = function(v) return tostring(v) end }
end
package.preload["pc2mp.persist"] = function()
    return { WriteData = function(n, s) files[n] = s; return true end, ReadData = function(n) return files[n] end }
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
package.preload["Quaternion"] = function() return { Identity = "QI", FromPackedAxisAngle = function(v) return v end } end
package.preload["TransformQ"] = function() return { FromOrPos = function(q, p) return { q = q, p = p } end } end
package.preload["pc2mp.capture"] = function() return {} end
for _, m in ipairs({ "pc2mp.props", "pc2mp.replay", "pc2mp.events", "pc2mp.mirror", "pc2mp.gamestate",
                     "pc2mp.testmode", "pc2mp.worldedit", "pc2mp.sequencer", "pc2mp.breakdowns", "pc2mp.economy", "pc2mp.entref", "pc2mp.rides" }) do preload(m) end
local Vector3 = require("Vector3")
local Props = require("pc2mp.props")

-- Spielwelt: partID -> { resource, pos, colours = {tag -> {r,g,b}}, cookie, light }
local world = {}
local nextPart = 500
local setColourCalls = {}
local function NewPartSet()
    local s = { ids = {} }
    function s:Add(id) self.ids[#self.ids + 1] = id end
    return s
end
local tw = {
    placement = {
        PlacementPartExists = function(_, id) return world[id] ~= nil end,
        GetPartResourceName = function(_, id) return world[id] and world[id].resource end,
        PlacementIDToEntityID = function(_, id) return world[id] and id or nil end,
        EntityIDToPlacementID = function(_, e) return world[e] and e or nil end,
    },
    scenery = {
        GetPartScaleData = function() return { nScale = 1 } end,
        CreateBuildingPartSet = function() return NewPartSet() end,
        IsCustomisableLight = function(_, e) return world[e] and world[e].light end,
        GetLightCookieName = function(_, id) return world[id] and world[id].cookie end,
        SetLightCookieName = function(_, eo, s) (world[eo.id] or eo.clh.pending[eo.id]).pendingCookie = s end,
        GetSceneryAtmosphereType = function() return nil end,
        GetRawNameOverride = function() return nil end,
    },
    scenery_flexicolour = {
        GetFlexiColourForPartID = function(_, id)
            local t = {}
            for tag, c in pairs(world[id] and world[id].colours or {}) do
                t[tag] = { [1] = { vColour = Vector3:new(c[1], c[2], c[3]) } }
            end
            return t
        end,
        SetFlexiColourForPartSet = function(_, clh, set, tag, v)
            setColourCalls[#setColourCalls + 1] = { tag = tag, id = set.ids[1] }
            for _, id in ipairs(set.ids) do
                local w = world[id] or clh.pending[id]
                w.pendingColours = w.pendingColours or {}
                w.pendingColours[tag] = { v:GetX(), v:GetY(), v:GetZ() }
            end
        end,
    },
}
-- Hierarchy: Create/Edit sammeln, Commit schreibt in die Welt
tw.editors = { CreateUndoOperationsHierarchy = function()
    local clh = { pending = {}, edits = {} }
    function clh:CreateNewPart(res, tok)
        nextPart = nextPart + 1
        self.pending[nextPart] = { resource = res }
        return { id = nextPart, new = true }
    end
    function clh:EditExistingPart(id) return { id = id } end
    local function EO(co)
        local eo = { id = co.id, clh = clh }
        function eo:SetTransform(t) local w = world[self.id] or clh.pending[self.id]; w.pendingPos = t.p end
        function eo:SetScale() end
        function eo:GetPlacementPartID() return self.id end
        clh.edits[#clh.edits + 1] = co.id
        return eo
    end
    function clh:StartEditingParts_Scenery(t) return { EO(t[1]) } end
    function clh:StartEditingPart_Scenery(co) return EO(co) end
    function clh:SetCashPos() end
    function clh:GetFullUndoChangeList() return self end
    return clh
end }
api.transform = { CalculateWorldTransform = function(e)
    local p = world[e].pos
    local function V(x, y, z) return { GetX = function() return x end, GetY = function() return y end, GetZ = function() return z end } end
    return { GetPos = function() return V(p[1], p[2], p[3]) end,
             GetOr = function() return { ToPackedAxisAngle = function() return V(0, 0, 0) end } end }
end }
api.entity = { CreateRequestCompletionToken = function() return {} end, HaveRequestsCompleted = function() return true end }
local preview = nil
api.undo.PreviewChangeList = function(clh) preview = clh; return "w", "p" end
api.undo.IsOperationComplete = function() return true end
api.undo.CanCommitPreview = function() return true end
api.undo.CommitPreview = function()
    for id, w in pairs(preview.pending) do world[id] = w end
    for _, id in ipairs(preview.edits) do
        local w = world[id]
        if w then
            if w.pendingPos then w.pos = { w.pendingPos.x, w.pendingPos.y, w.pendingPos.z }; w.pendingPos = nil end
            if w.pendingColours then
                w.colours = w.colours or {}
                for k, c in pairs(w.pendingColours) do w.colours[k] = c end
                w.pendingColours = nil
            end
            if w.pendingCookie then w.cookie = w.pendingCookie; w.pendingCookie = nil end
        end
    end
    return "c"
end
api.undo.Checkpoint = function() end

-- ---------------------------------------------------------------- 1. Props beschreiben / vergleichen
world[1] = { resource = "Light_Spot", pos = { 0, 0, 0 }, light = true, cookie = "Stars",
             colours = { LightColour = { 1, 0, 0 }, Primary = { 0.2, 0.3, 0.4 } } }
local p = Props.Describe(tw, 1, 1)
check(p and #p.colours == 2 and p.cookie == "Stars", "Licht: Farben + Muster ausgelesen")
check(p.colours[1].tag == "LightColour" and p.colours[1].c[1] == 1, "Farben sortiert nach Tag, Werte korrekt")
local okJ, sJ = api.json.Stringify({ props = p })
local _, back = api.json.Parse(sJ)
check(back.props.colours["1"] ~= nil, "JSON-Mock liefert Arrays als String-Schlüssel (wie das Spiel)")
check(Props.Equal(Props.Normalize(back.props), p), "Normalize nach JSON == Original")
local p2 = Props.Normalize(back.props); p2.colours[1].c[1] = 0.5
check(not Props.Equal(p2, p), "andere Farbe wird erkannt")
check(Props.StateEqual({ resource = "A", pos = { 1, 2, 3 }, props = p }, { resource = "A", pos = { 1, 2, 3.0000001 }, props = Props.Normalize(back.props) }),
    "StateEqual ignoriert Rundungsrauschen")

-- ---------------------------------------------------------------- 2. Replay setzt Farben beim Erstellen/Ändern
local Replay = require("pc2mp.replay")
Replay.Init(tw)
local function runJob(fn)
    local co = coroutine.create(fn)
    local ok, a, b
    repeat ok, a, b = coroutine.resume(co); assert(ok, a) until coroutine.status(co) == "dead"
    return a, b
end
Replay.tCurrent = { co = true }
local nNew = runJob(function() return Replay.DoCreate({ resource = "Light_Spot", pos = { 5, 0, 0 }, props = Props.Normalize(back.props) }) end)
check(nNew ~= nil and world[nNew] ~= nil, "Zwilling erstellt")
check(world[nNew].colours and world[nNew].colours.LightColour[1] == 1 and world[nNew].colours.Primary[3] == 0.4,
    "Farben beim Erstellen gesetzt (gleiche Hierarchie)")
check(world[nNew].cookie == "Stars", "Lichtmuster beim Erstellen gesetzt")
runJob(function() return Replay.DoEdit(nNew, { props = { colours = { { tag = "LightColour", c = { 0, 0, 1 } } } } }) end)
check(world[nNew].colours.LightColour[3] == 1 and world[nNew].colours.LightColour[1] == 0, "Farbänderung per Edit übernommen")
check(world[nNew].pos[1] == 5, "Edit nur mit Props verschiebt nichts")
Replay.tCurrent = nil

-- ---------------------------------------------------------------- 3. Spiegel: Farbänderung am Original -> Zwilling
local Events = require("pc2mp.events")
local Mirror = require("pc2mp.mirror")
Events.tWorldAPIs = tw
local frame = 0
Events.fnNow = function() return frame end
Replay.Init(tw)
Mirror.nOffsetX = 25
local queue = {}
Replay.Enqueue = function(label, job, done)   -- synchron ausführen
    Replay.tCurrent = { co = true }
    local r1, r2 = runJob(job)
    Replay.tCurrent = nil
    if done then done(true, r1, r2) end
end
Events.tListeners = { Mirror.OnAction }
world[2] = { resource = "Lamp", pos = { 10, 0, 0 }, light = false, colours = { Primary = { 1, 1, 1 } } }
Events.tKnownOriginals[2] = true
Events.HandlePart(2, 1, true)
local nTwin = Mirror.tTwinOf[2]
check(nTwin ~= nil and world[nTwin].pos[1] == 35, "Zwilling bei x+25")
check(world[nTwin].colours.Primary[1] == 1, "Zwilling hat die Farbe des Originals")
local nEdits = #setColourCalls
Events.HandlePart(2, 1, true)
check(#setColourCalls == nEdits, "gleiche Meldung nochmal -> kein zweiter Nachbau (Dedupe)")
-- Spieler ändert die Farbe -> MaterialChanged -> erst nach Commit melden
world[2].colours.Primary = { 0, 1, 0 }
Events.MarkDirty(2, false)
frame = frame + 10
Events.Tick()
check(world[nTwin].colours.Primary[2] == 1 and world[nTwin].colours.Primary[1] == 1, "ohne Spieler-Commit: Zwilling noch alt")
Events.nLastUserCommitFrame = frame
frame = frame + 5
Events.Tick()
check(world[nTwin].colours.Primary[1] == 0 and world[nTwin].colours.Primary[2] == 1, "nach Commit: Zwilling bekommt die neue Farbe")
check(Mirror.nCount >= 2, "Testmodus-Ereignisse gezählt")

-- ---------------------------------------------------------------- 4. GameState: Park-API (Metatabelle) + Manager (Proxy)
local GameState = require("pc2mp.gamestate")
local parkState = { open = false, name = "Park" }
local ParkMT = { __index = {
    SetParkOpenForGuests = function(self, b) parkState.open = b end,
    SetParkName = function(self, s) parkState.name = s end,
    SetParkEntranceAdultTicketPrice = function(self, n) parkState.price = n end,
} }
local park = setmetatable({}, ParkMT)
local gbm = { buckets = { [1] = { active = false, cost = 0 } } }
local GbmClass = { __index = {
    SetAdvertisingActive = function(self, i, b) self.buckets[i].active = b end,
    SetCurrentCostPerHour = function(self, i, n) self.buckets[i].cost = n end,
} }
setmetatable(gbm, GbmClass)
local proxy = setmetatable({}, { __index = { SetAdvertisingActive = function(_, ...) return gbm:SetAdvertisingActive(...) end,
                                             SetCurrentCostPerHour = function(_, ...) return gbm:SetCurrentCostPerHour(...) end },
                                 __newindex = function() error("immutable") end, tObject = gbm })
local sandbox = { t = {} }
setmetatable(sandbox, { __index = { SetSandboxSettings = function(self, t) self.t = t end } })
local env = { RequestInterface = function(_, s)
    if s == "Interfaces.IGuestBucketManager" then return proxy end
    if s == "Interfaces.ISandboxSettingsManager" then return sandbox end
end }
local sent = {}
local nInst = GameState.Install({ park = park }, env)
check(nInst == 6, "6 Setter erfasst (3 Park-Setter im Mock + 2 Marketing + Sandbox), war " .. tostring(nInst))
GameState.tListeners = { function(a) sent[#sent + 1] = a end }
park:SetParkOpenForGuests(true)   -- während des Ladens (Warmup)
check(#sent == 0 and parkState.open == true, "Aufrufe beim Laden werden nicht gesendet")
for _ = 1, GameState.nWarmupFrames do GameState.Tick() end
park:SetParkOpenForGuests(true)
check(#sent == 0, "gleicher Wert wie beim Laden -> nichts senden")
park:SetParkOpenForGuests(false)
check(#sent == 1 and sent[1].k == "park.SetParkOpenForGuests" and sent[1].a[1] == false, "Park schließen gesendet")
proxy:SetAdvertisingActive(1, true)
check(#sent == 2 and sent[2].k == "ads.SetAdvertisingActive" and sent[2].a[1] == 1 and gbm.buckets[1].active,
    "Werbekampagne (über Interface-Proxy) erfasst")
NOW = 10
proxy:SetCurrentCostPerHour(1, 100); proxy:SetCurrentCostPerHour(1, 150); proxy:SetCurrentCostPerHour(1, 200)
GameState.Tick()
check(#sent == 2, "Schieberegler: noch nicht gesendet (Entprellen)")
NOW = 11
GameState.Tick()
check(#sent == 3 and sent[3].a[2] == 200, "Schieberegler: nur der Endwert gesendet")
sandbox:SetSandboxSettings({ bEnabledRain = false, nDifficulty = 2, fnBad = function() end })
check(#sent == 4 and sent[4].a[1].bEnabledRain == false and sent[4].a[1].fnBad == nil, "Sandbox-Einstellungen ohne Funktionen gesendet")

-- vom Netz (String-Schlüssel wie api.json): anwenden, ohne erneut zu senden
local _, sAct = api.json.Stringify({ op = "call", k = "ads.SetAdvertisingActive", a = { 1, false }, n = 2 })
local _, tAct = api.json.Parse(sAct)
check(GameState.ApplyRemote(tAct, "c2") and gbm.buckets[1].active == false, "Remote: Werbung beendet")
check(#sent == 4, "Remote-Anwendung erzeugt kein Echo")
local _, sAct2 = api.json.Stringify({ op = "call", k = "park.SetParkName", a = { "Maxis Park" }, n = 1 })
local _, tAct2 = api.json.Parse(sAct2)
GameState.ApplyRemote(tAct2, "c2")
check(parkState.name == "Maxis Park" and #sent == 4, "Remote: Parkname gesetzt, kein Echo")
check(not GameState.ApplyRemote({ op = "call", k = "os.execute", a = { "x" } }, "evil"), "unbekannte Schlüssel werden abgelehnt")
-- Testmodus-Loopback
GameState.tListeners = { GameState.LoopbackListener }
park:SetParkEntranceAdultTicketPrice(42)
NOW = 20; GameState.Tick(); GameState.Tick()
check(parkState.price == 42, "Loopback: Preis bleibt korrekt gesetzt")
local bApplied = false
for _, l in ipairs(log) do if l:find("angewendet park.SetParkEntranceAdultTicketPrice von Testmodus", 1, true) then bApplied = true end end
check(bApplied, "Loopback: über JSON wieder angewendet")

-- Park-API, deren Methoden über eine __index-FUNKTION kommen (wie im Spiel beobachtet)
local closed = nil
local parkFn = setmetatable({}, { __index = function(_, k)
    if k == "SetParkOpenForGuests" then return function(_, b) closed = not b end end
end })
local GS2 = GameState
GS2.tWorldAPIs = { park = parkFn }
local tgtOpen = GS2.tByKey["park.SetParkOpenForGuests"]
GS2.Install({ park = parkFn }, env)
for _ = 1, GS2.nWarmupFrames do GS2.Tick() end
local sent2 = {}
GS2.tListeners = { function(a) sent2[#sent2 + 1] = a end }
parkFn:SetParkOpenForGuests(false)
check(closed == true and #sent2 == 1 and sent2[1].k == tgtOpen.k, "Park-API mit __index-Funktion wird abgefangen")
GS2.tListeners = { GS2.LoopbackListener }
parkFn:SetParkOpenForGuests(true)
check(closed == false and #GS2.tLoopQueue == 1, "Loopback wartet auf den nächsten Frame (kein verschachtelter Aufruf)")
GS2.Tick()
check(#GS2.tLoopQueue == 0, "Loopback im nächsten Frame ausgeführt")
GS2.tListeners = { function(a) sent2[#sent2 + 1] = a end }
GS2.ApplyRemote({ op = "call", k = "park.SetParkOpenForGuests", a = { true }, n = 1 }, "c2")
check(closed == false and #sent2 == 1, "Remote-Anwendung darauf ohne Echo")

-- ---------------------------------------------------------------- 5. Testmodus (Dev-UI-Befehl)
local TestMode = require("pc2mp.testmode")
local WorldEdit = require("pc2mp.worldedit")
Events.tListeners = {}
TestMode.Set(true, 30)
check(files["testmode.json"] ~= nil and TestMode.IsOn() and TestMode.Offset() == 30, "Testmodus gespeichert")
TestMode.ApplyInPark(true)
check(Mirror.nOffsetX == 30 and WorldEdit.nMirrorOffsetX == 30 and WorldEdit.bMirror, "Objekte und Wege mit gleichem Versatz")
check(#Events.tListeners == 1 and Events.tListeners[1] == Mirror.OnAction, "Spiegel-Listener angehängt")
TestMode.ApplyInPark(true)
check(#Events.tListeners == 1, "zweimal an -> Listener nicht doppelt")
check(TestMode.State().active and #TestMode.State().log > 0, "Status für die Dev-UI")
TestMode.ApplyInPark(false)
check(#Events.tListeners == 0 and not WorldEdit.bMirror, "Testmodus aus -> Spiegel weg")
-- Multiplayer: Sync-Listener dürfen nicht angefasst werden
local fnSync = function() end
WorldEdit.tListeners = { fnSync }
GameState.tListeners = { fnSync }
TestMode.ApplyInPark(false)
check(WorldEdit.tListeners[1] == fnSync and GameState.tListeners[1] == fnSync, "aus (Multiplayer) lässt Sync-Listener in Ruhe")

-- ---------------------------------------------------------------- 6. Wege-Spiegel: Farben nicht verschieben
local tOutline = WorldEdit.Normalize({ ["1"] = { vPos = { v3 = { 1, 2, 3 } }, vEdgeColour = { v3 = { 0.5, 0.5, 0.5 } } },
                                       vOutlineColour = { v3 = { 0.1, 0.2, 0.3 } }, sRenderType = "Tarmac" })
local d = WorldEdit.Deser(tOutline, 25)
check(d[1].vPos:GetX() == 26, "Position um 25 verschoben")
check(d[1].vEdgeColour:GetX() == 0.5 and d.vOutlineColour:GetX() == 0.1, "Farb-Vektoren NICHT verschoben")
check(d.sRenderType == "Tarmac", "Belag-Typ bleibt erhalten")

print("\nALLE PROPS/SETTINGS-TESTS OK")
