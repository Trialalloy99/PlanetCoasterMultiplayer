-- Offline-Test für pc2mp.rides: Fahrgeschäft als Blaupause exportieren, als Zwilling/Kopie einsetzen,
-- Lage korrigieren, bei Änderungen ersetzen, Abriss, Netz-Teile. Gemockte Spiel-APIs.
-- Ausführen:  tools/cobra-tools/modules/formats/utils/luadec/lua.exe mod/tests/test_rides.lua mod/PC2MP/Main
local MAIN = arg[1] or "mod/PC2MP/Main"
local function preload(name)
    package.preload[name] = function() return assert(loadfile(MAIN .. "/" .. name .. ".lua"))(name) end
end
local function check(c, msg) if not c then error("FEHLER: " .. msg, 2) end print("ok  " .. msg) end

local log = {}
package.preload["pc2mp.log"] = function()
    return { Write = function(s) log[#log + 1] = s; if os.getenv("DBG") then print("LOG " .. s) end end, ToStr = function(v)
        if type(v) == "table" then local o = {}; for k, x in pairs(v) do o[#o + 1] = tostring(k) .. "=" .. tostring(x) end; return "{" .. table.concat(o, ",") .. "}" end
        return tostring(v) end }
end
package.preload["Vector3"] = function()
    local V = {}
    V.__index = V
    function V:new(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end
    function V:GetX() return self.x end
    function V:GetY() return self.y end
    function V:GetZ() return self.z end
    function V:ToPackedAxisAngle() return self end
    return V
end
package.preload["Quaternion"] = function() return { FromPackedAxisAngle = function(v) return v end } end
package.preload["TransformQ"] = function()
    return { FromOrPos = function(q, p) return { q = q, p = p, GetPos = function(s) return s.p end, GetOr = function(s) return s.q end } end }
end
-- Dateien (Blaupausen) im Speicher
local files = {}
-- Saves-Ordner: Dateiname -> Inhalt; Spielstand-System kennt Tokens {file}
local savesDir = {}
local incoming = {}
package.preload["pc2mp.persist"] = function()
    return {
        Native = function(sFn)
            if sFn == "pc2mp_data_dir" then return function() return "D:/data/" end end
            if sFn == "pc2mp_find_blueprint" then return function(prefix)
                for n in pairs(savesDir) do if n:sub(1, #prefix) == prefix then return n end end
            end end
        end,
        SaveInfo = function(n) local c = savesDir[n]; return c and { chunks = 1, size = #c, sha256 = "sha:" .. c } or nil end,
        ReadSaveChunk = function(n, i) return savesDir[n] end,
        WriteSaveChunk = function(n, i, d) incoming[n] = (incoming[n] or "") .. d; return true end,
        FinishSave = function(n, sha) if sha ~= "sha:" .. incoming[n] then return false, "sha" end
            savesDir[n] = incoming[n]; incoming[n] = nil; saveTime = (saveTime or 0) + 1; saveAge[n] = saveTime; return true end,
        AbortSave = function(n) incoming[n] = nil end,
    }
end
-- Replay: Jobs synchron als Coroutine bis zum Ende ausführen
local jobs = {}
package.preload["pc2mp.replay"] = function()
    return { Enqueue = function(label, fn, done) jobs[#jobs + 1] = { label = label, fn = fn, done = done } end }
end
local function RunJobs()
    while #jobs > 0 do
        local j = table.remove(jobs, 1)
        local co = coroutine.create(j.fn)
        local ok, r1, r2
        repeat ok, r1, r2 = coroutine.resume(co); assert(ok, tostring(r1)) until coroutine.status(co) == "dead"
        if j.done then j.done(ok, r1, r2) end
    end
end
preload("pc2mp.rides")
local Vector3 = require("Vector3")

-- ---------------------------------------------------------------- Spielwelt
-- rides[id] = { flat, pos, rot, content }   (content = was die Blaupause enthält, z. B. Zug/Farbe/Strecke)
local rides = { [10] = { flat = false, pos = { 0, 0, 0 }, rot = { 0, 0.5, 0 }, content = "Strecke v1, Zug rot" } }
local nextRide = 100
local preview
local messages = {}
local obbShift = { 3, 0, -2 }   -- Blaupausen landen um den Mittelpunkt -> Abweichung zur Ride-Position
api = {
    pc2mp = { sInstance = "inst1" },
    messaging = {
        MsgType_RideEditedMessage = 1, MsgType_FlatRideCreatedMessage = 2,
        RegisterReceiver = function(t, fn) messages[t] = fn end, UnregisterReceiver = function() end,
    },
    transform = { CalculateWorldTransform = function(id)
        local r = rides[id]
        if r == nil then return nil end
        return { GetPos = function() return Vector3:new(r.pos[1], r.pos[2], r.pos[3]) end,
                 GetOr = function() return Vector3:new(r.rot[1], r.rot[2], r.rot[3]) end }
    end },
    undo = {
        IsBusy = function() return false end,
        PreviewChangeList = function(clh) preview = clh; return "w", "p" end,
        IsOperationComplete = function() return true end,
        CanCommitPreview = function() return true end,
        CommitPreview = function() preview.commit(); return "c" end,
        Checkpoint = function() end,
    },
    player = { GetGameOwner = function() return "owner" end },
    save = {
        GetExistingSaves_SortMostRecentFirst = 1,
        RequestSave = function(owner, t)
            local r = rides[t.selection.ids[1]]
            local fname = t.customname .. "-0000ABCD.blpr2"
            savesDir[fname] = "BP:" .. tostring(r.flat) .. ":" .. r.content
            t.oncomplete({ save = { file = fname } })
        end,
        RequestLoad = function(tok, t)
            ORDER[#ORDER + 1] = "load"
            local sC = savesDir[tok.file]
            if not sC then t.oncomplete({ exception = "fehlt" }) return end
            local flat, content = sC:match("^BP:(%a+):(.*)$")
            loadedBp = { flat = flat == "true", content = content }
            t.oncomplete({})
        end,
        RequestDelete = function(tok) savesDir[tok.file] = nil; deleted = deleted + 1 end,
        -- wie das Spiel (SortMostRecentFirst): neueste zuerst
        GetExistingSaves = function() local o = {}; for n in pairs(savesDir) do o[#o + 1] = { file = n } end
            table.sort(o, function(a, b) return (saveAge[a.file] or 0) > (saveAge[b.file] or 0) end); return true, true, o end,
        GetSaveCustomName = function(tok) return CustomOf(tok.file) end,
        GetSaveIdentifier = function(tok) return tok.file end,
    },
    track = {
        GetTrackHolder = function(id) return { id = id } end,
        RemoveHolder = function(clh, h) clh.ops[#clh.ops + 1] = function() rides[h.id] = nil end end,
        MoveTrack = function(clh, mo, h) mo.moveRide = h.id end,
    },
}
loadedBp = nil
saveAge = {}
deleted = 0
ORDER = {}
function CustomOf(fname) return fname:match("^(.*)%-%x+%.blpr2$") end
local tw = {
    rides = { GetAllRides = function() local o = {}; for id in pairs(rides) do o[#o + 1] = id end; return o end,
              IsFlatRide = function(_, id) return rides[id] and rides[id].flat or false end },
    flatrides = {},
    editors = { TerrainActionType_PathJoinPartFlatten = 1, CreateUndoOperationsHierarchy = function()
        ORDER[#ORDER + 1] = "clh"
        local clh = { ops = {} }
        function clh:CreateCompositeObject()
            local mo = { CompositeAlignmentType_ItemAligned = 1 }
            function mo:DecayCompositeAlignmentType() end
            function mo:SetCompositeOriginToOBBCentre() end
            function mo:IsEmpty() return false end
            function mo:SetTransform(T) self.T = T end
            function mo:GetTransform()
                if self.T then return self.T end
                local r = rides[self.moveRide]
                return { GetPos = function() return Vector3:new(r.pos[1], r.pos[2], r.pos[3]) end, GetOr = function() return Vector3:new(r.rot[1], r.rot[2], r.rot[3]) end }
            end
            clh.mo = mo
            return mo
        end
        function clh:IsLoadedBlueprintReadyForEditing() return loadedBp ~= nil end
        function clh:AddBlueprintToCompositeObject(mo) mo.bp = loadedBp end
        function clh:GetFullUndoChangeList() return self end
        function clh.commit()
            for _, f in ipairs(clh.ops) do f() end
            local mo = clh.mo
            if mo and mo.bp and mo.T then
                nextRide = nextRide + 1
                local p = mo.T.p
                rides[nextRide] = { flat = mo.bp.flat, pos = { p.x + obbShift[1], p.y + obbShift[2], p.z + obbShift[3] },
                                    rot = { mo.T.q.x, mo.T.q.y, mo.T.q.z }, content = mo.bp.content }
                if messages[1] then messages[1]({ { rideID = nextRide } }) end  -- Spiel meldet die neue Kopie
            elseif mo and mo.moveRide and mo.T then
                local p = mo.T.p
                rides[mo.moveRide].pos = { p.x, p.y, p.z }
            end
        end
        return clh
    end },
    worldserialisation = {
        CreateSaveSelection = function() local s = { ids = {} }; function s:AddEntityID(id) self.ids[#self.ids + 1] = id end; return s end,
    },
}
local Rides = require("pc2mp.rides")
Rides.Install(tw)
check(messages[1] ~= nil, "RideEditedMessage registriert")
check(Rides.tRidOf[10] ~= nil and Rides.tRidOf[10]:sub(1, 2) == "s:", "Bahn aus dem Spielstand: rid aus der Position (" .. tostring(Rides.tRidOf[10]) .. ")")
-- Park-Laden: Ride-Messages für vorhandene Bahnen dürfen keinen Export auslösen
messages[1]({ { rideID = 10 } })
check(Rides.tDirty[10] == nil, "Lade-Message in der Ruhezeit ignoriert (keine Duplikate beim Join)")
Rides.nStartQuiet = 0
Rides.tRidOf[10] = nil -- für die folgenden (alten) Tests: wie bisher eigene rid

-- ---------------------------------------------------------------- 1. Testmodus: Zwilling bei +40
Rides.bTestMode, Rides.nOffsetX = true, 40
local notes = {}
Rides.fnOnEvent = function(s) notes[#notes + 1] = s end
Rides.tListeners = { function(a)
    if a.op == "ride" then Rides.ApplyLocal(a, "Testmodus") elseif a.op == "ridedel" then Rides.ApplyRemote(a, "Testmodus") end
end }
local function Frames(n) for _ = 1, n do Rides.Tick(); RunJobs() end end
messages[1]({ { rideID = 10 } })     -- Spieler hat Bahn 10 gebaut/geändert
Frames(Rides.nDebounce + 2)
local nTwin = Rides.tCopyOf["test:10"]
check(nTwin ~= nil and rides[nTwin] and rides[nTwin].content == "Strecke v1, Zug rot", "Zwilling mit gleichem Inhalt (Strecke, Zug, Farbe)")
check(math.abs(rides[nTwin].pos[1] - 40) < 0.01 and math.abs(rides[nTwin].pos[3]) < 0.01, "Lage korrigiert: genau +40 m")
check(rides[nTwin].rot[2] == 0.5, "gleiche Drehung")
Frames(Rides.nDebounce + 2)
local nRides = 0; for _ in pairs(rides) do nRides = nRides + 1 end
check(nRides == 2, "keine Endlosschleife (Zwilling wird nicht erneut gespiegelt)")

-- Live: Spieler baut weiter -> Zwilling wird ersetzt
rides[10].content = "Strecke v2 (Looping), Zug blau, Modus 2 Runden"
messages[1]({ { rideID = 10 } })
Frames(5)
check(rides[nTwin].content == "Strecke v1, Zug rot", "Entprellen: noch nicht sofort")
Frames(Rides.nDebounce)
local nTwin2 = Rides.tCopyOf["test:10"]
check(rides[nTwin] == nil and nTwin2 ~= nTwin and rides[nTwin2].content:find("Looping"), "alter Zwilling abgerissen, neuer mit Looping/Zug blau")
nRides = 0; for _ in pairs(rides) do nRides = nRides + 1 end
check(nRides == 2, "weiterhin genau 2 Bahnen")
local nSaves = 0; for _ in pairs(savesDir) do nSaves = nSaves + 1 end
check(nSaves == 0 and deleted >= 2, "Hilfs-Blaupausen wieder gelöscht (nichts in der Blaupausen-Liste)")

-- Flatride neu gebaut (über die Abfrage erkannt, ohne Nachricht)
rides[20] = { flat = true, pos = { 100, 0, 0 }, rot = { 0, 0, 0 }, content = "Karussell, Sequenz B" }
tw.flatrides.GetFlatRideEditToken = function(_, id) return rides[id] and { id = id } or nil end
tw.flatrides.RemoveFlatRide = function(_, clh, tok) clh.ops[#clh.ops + 1] = function() rides[tok.id] = nil end end
tw.flatrides.MoveFlatRide = function(_, clh, mo, tok) mo.moveRide = tok.id end
Frames(Rides.nPollEvery + Rides.nDebounce + 2)
local nTwinF = Rides.tCopyOf["test:20"]
check(nTwinF and rides[nTwinF].flat and rides[nTwinF].content == "Karussell, Sequenz B" and math.abs(rides[nTwinF].pos[1] - 140) < 0.01,
    "neues Fahrgeschäft erkannt und gespiegelt")

-- Abriss
rides[10] = nil
Frames(Rides.nPollEvery + 2)
check(rides[nTwin2] == nil and Rides.tCopyOf["test:10"] == nil, "Original abgerissen -> Zwilling abgerissen")

-- ---------------------------------------------------------------- 2. Netz: Saves-Datei senden, beim Mitspieler einsetzen
Rides.bTestMode, Rides.nOffsetX = false, 0
rides[30] = { flat = true, pos = { 5, 0, 5 }, rot = { 0, 0, 0 }, content = "Remote-Karussell" }
local sent = {}
Rides.tListeners = { function(a) if a.op == "ride" then Rides.SendOverNet(a, function(x) sent[#sent + 1] = x end) end end }
Frames(Rides.nPollEvery + Rides.nDebounce + 2)
check(#sent == 2 and sent[1].op == "ridebp" and sent[1].data:find("Remote%-Karussell") and sent[2].op == "ride" and sent[2].sha,
    "Blaupause aus dem Saves-Ordner gesendet (mit SHA)")
local rid30 = sent[2].rid
rides[30] = nil
savesDir = {}
for _, a in ipairs(sent) do Rides.ApplyRemote(a, "c2") end
RunJobs()
local nCopy = Rides.tCopyOf[rid30]
check(nCopy and rides[nCopy] and rides[nCopy].content == "Remote-Karussell" and math.abs(rides[nCopy].pos[1] - 5) < 0.01,
    "Mitspieler: Datei abgelegt, Token gefunden, Kopie exakt an der Originalposition")
local nLeft = 0; for _ in pairs(savesDir) do nLeft = nLeft + 1 end
check(nLeft == 0, "empfangene Blaupause danach gelöscht")
Rides.ApplyRemote({ op = "ride", rid = "inst9:77", pos = { 0, 0, 0 }, parts = 2 }, "c2")
check(#jobs == 0, "unvollständige Blaupause wird nicht eingesetzt")
Rides.ApplyRemote({ op = "ridedel", rid = rid30 }, "c2")
RunJobs()
check(rides[nCopy] == nil, "Abriss vom Mitspieler entfernt die Kopie")

-- Reihenfolge wie BlueprintPlacementMode.CreateNew: Hierarchie VOR dem Laden (sonst Absturz im Spiel)
local iLoad
for i = #ORDER, 1, -1 do if ORDER[i] == "load" then iLoad = i; break end end
check(iLoad and ORDER[iLoad - 1] == "clh", "Einsetzen: Undo-Hierarchie wird vor dem Laden der Blaupause angelegt")

-- ---------------------------------------------------------------- 3. Bahn gibt es beim Mitspieler schon (Spielstand) -> ersetzen
-- Maxi und Finn laden denselben Spielstand; Finn ändert "seine" Bahn (andere lokale ID, eigene rid)
rides[50] = { flat = false, pos = { 100, 0, 100 }, rot = { 0, 0, 0 }, content = "Achterbahn alt" }
savesDir = {}
local sBp = "BP:false:Achterbahn neu (Looping)"
Rides.ApplyRemote({ op = "ridebp", rid = "finn:7", part = 1, parts = 1, data = sBp }, "c2")
local nBefore = 0; for _ in pairs(rides) do nBefore = nBefore + 1 end
Rides.ApplyRemote({ op = "ride", rid = "finn:7", pos = { 100.3, 0, 100 }, prev = { 100, 0, 100 }, rot = { 0, 0, 0 }, parts = 1, sha = "sha:" .. sBp }, "c2")
RunJobs()
local nAfter = 0; for _ in pairs(rides) do nAfter = nAfter + 1 end
local nRep = Rides.tCopyOf["finn:7"]
check(rides[50] == nil and nRep and rides[nRep] and rides[nRep].content == "Achterbahn neu (Looping)",
    "vorhandene Bahn (über alte Position gefunden) wird ersetzt")
check(nAfter == nBefore, "keine doppelte Bahn")

-- ---------------------------------------------------------------- 4. Live-Join 17:28: Laden scheitert -> vorhandene Bahn bleibt
rides[60] = { flat = false, pos = { 200, 0, 200 }, rot = { 0, 0, 0 }, content = "Bahn aus dem Spielstand" }
savesDir = {}
local realLoad = api.save.RequestLoad
api.save.RequestLoad = function(tok, t) ORDER[#ORDER + 1] = "load"; t.oncomplete({ exception = "tThisSaveInfo nil" }) end
local sBp2 = "BP:false:kaputt"
Rides.ApplyRemote({ op = "ridebp", rid = "old:60", part = 1, parts = 1, data = sBp2 }, "c2")
Rides.ApplyRemote({ op = "ride", rid = "old:60", pos = { 200, 0, 200 }, prev = { 200, 0, 200 }, rot = { 0, 0, 0 }, parts = 1, sha = "sha:" .. sBp2 }, "c2")
RunJobs()
check(rides[60] ~= nil and rides[60].content == "Bahn aus dem Spielstand", "Blaupause lädt nicht -> vorhandene Bahn wird NICHT abgerissen")
api.save.RequestLoad = realLoad

-- mehrere Versionen derselben Bahn beim Nachholen: nur die neueste wird eingesetzt
savesDir = {}
local nLoadsBefore = 0; for _, o in ipairs(ORDER) do if o == "load" then nLoadsBefore = nLoadsBefore + 1 end end
for i = 1, 3 do
    local sB = "BP:false:Version " .. i
    Rides.ApplyRemote({ op = "ridebp", rid = "old:60", part = 1, parts = 1, data = sB }, "c2")
    Rides.ApplyRemote({ op = "ride", rid = "old:60", pos = { 200, 0, 200 }, rot = { 0, 0, 0 }, parts = 1, sha = "sha:" .. sB }, "c2")
end
RunJobs()
local nLoads = 0; for _, o in ipairs(ORDER) do if o == "load" then nLoads = nLoads + 1 end end
local nC = Rides.tCopyOf["old:60"]
check(nLoads - nLoadsBefore == 1 and nC and rides[nC] and rides[nC].content == "Version 3", "nur die neueste Version wird eingesetzt (1x laden statt 3x)")

print("\nALLE RIDES-TESTS OK")
