-----------------------------------------------------------------------
--/  PC2MP Sync: verbindet lokale Bau-Aktionen mit dem Server und spielt
--/  Aktionen der Mitspieler nach.
--/
--/  Objekt-Handle H (eins pro synchronisiertem Objekt):
--/    { partID = lokale PartID (nil, wenn gelöscht), netId = globale ID vom Server,
--/      state = letzter bekannter Zustand {resource,pos,rot,scale} }
--/
--/  Lokal:   Events (upsert/remove) -> Undo-Stack + Net.Send({t="action", action={op,netId|localId,...}})
--/  Remote:  Net.Pump -> action von anderem origin -> Replay Create/Edit/Destroy
--/  Strg+Z:  eigener Undo-Stack (nur eigene Aktionen), Ergebnis wird wie eine normale Aktion gesendet.
-----------------------------------------------------------------------
local global = _G
local api = global.api
local type = global.type
local pairs = global.pairs
local ipairs = global.ipairs
local pcall = global.pcall
local tostring = global.tostring
local table = global.table
local Log = require("pc2mp.log")
local Net = require("pc2mp.net")
local Events = require("pc2mp.events")
local Replay = require("pc2mp.replay")

local Sync = {}
Sync.bActive = false
Sync.tConfig = nil
Sync.sMyId = nil
Sync.nCseq = 0
Sync.tByPart = {}      -- partID -> H
Sync.tByNet = {}       -- netId -> H
Sync.tPendingLocal = {} -- localId (partID beim Senden) -> H, wartet auf "ids"
Sync.tUndo = {}
Sync.tRedo = {}
Sync.nMaxUndo = 100

-- Eindeutige Kennung dieser Spielsitzung (Echo-Erkennung, auch nach Reconnect/Catch-up)
api.pc2mp = api.pc2mp or {}
api.pc2mp.sInstance = api.pc2mp.sInstance or (tostring({}):gsub("table: ", "") .. "-" .. tostring(global.math.random(1, 1e9)))
api.pc2mp.nLastSeq = api.pc2mp.nLastSeq or 0
Sync.sInstance = api.pc2mp.sInstance

local function CopyState(t)
    if t == nil then return nil end
    return { resource = t.resource, pos = t.pos, rot = t.rot, scale = t.scale }
end

---------------------------------------------------------------------
-- Senden
---------------------------------------------------------------------
local function SendAction(tAction)
    Sync.nCseq = Sync.nCseq + 1
    tAction.origin = Sync.sInstance
    local ok = Net.Send({ t = "action", cseq = Sync.nCseq, action = tAction })
    if not ok then Log.Write("Sync: Senden fehlgeschlagen (" .. tostring(Net.LastError()) .. ")") end
end

-- Aktuellen Zustand von H an alle senden
function Sync.SendState(H)
    if H.netId then
        if H.partID == nil then
            SendAction({ op = "remove", netId = H.netId })
        else
            local s = H.state
            SendAction({ op = "upsert", netId = H.netId, resource = s.resource, pos = s.pos, rot = s.rot, scale = s.scale })
        end
    elseif not H.bCreateSent then
        if H.partID == nil then return end -- erstellt und sofort gelöscht, nie gesendet
        H.bCreateSent = true
        H.nLocalId = H.partID
        Sync.tPendingLocal[H.nLocalId] = H
        local s = H.state
        SendAction({ op = "upsert", localId = H.nLocalId, resource = s.resource, pos = s.pos, rot = s.rot, scale = s.scale })
    else
        H.bDirtyAfterIds = true -- Änderung, bevor die netId da ist -> nach "ids" nachsenden
    end
end

---------------------------------------------------------------------
-- Lokale Aktionen (von Events)
---------------------------------------------------------------------
local function PushUndo(H, before, after)
    table.insert(Sync.tUndo, { H = H, before = CopyState(before), after = CopyState(after) })
    if #Sync.tUndo > Sync.nMaxUndo then table.remove(Sync.tUndo, 1) end
    Sync.tRedo = {}
end

function Sync.OnLocalAction(tAction)
    if not Sync.bActive then return end
    local nPart = tAction.partID
    local H = Sync.tByPart[nPart]
    if tAction.op == "upsert" then
        if H == nil then
            H = { partID = nPart }
            Sync.tByPart[nPart] = H
        end
        local before = H.state
        H.state = { resource = tAction.resource, pos = tAction.pos, rot = tAction.rot, scale = tAction.scale }
        PushUndo(H, before, H.state)
        Sync.SendState(H)
    elseif tAction.op == "remove" then
        if H == nil then return end -- Teil, das wir nie kannten
        local before = H.state
        Sync.tByPart[nPart] = nil
        H.partID = nil
        PushUndo(H, before, nil)
        Sync.SendState(H)
    end
end

---------------------------------------------------------------------
-- Zustand per Replay herstellen (für Remote-Aktionen und Undo/Redo)
---------------------------------------------------------------------
-- Bringt H in Zustand tState (nil = gelöscht). fnDone() nach Abschluss.
function Sync.Apply(H, tState, sLabel, fnDone)
    Replay.Enqueue(sLabel, function()
        if tState == nil then
            if H.partID ~= nil then
                local nPart = H.partID
                Events.IgnoreFor(nPart, 120)
                Replay.DoDestroy(nPart)
                Sync.tByPart[nPart] = nil
                H.partID = nil
            end
        elseif H.partID ~= nil then
            Events.IgnoreFor(H.partID, 120)
            Replay.DoEdit(H.partID, tState)
        else
            local nNew = Replay.DoCreate(tState, function(n) Events.IgnoreFor(n, 120) end)
            if nNew ~= nil then
                Events.IgnoreFor(nNew, 120)
                H.partID = nNew
                Sync.tByPart[nNew] = H
            else
                Log.Write("Sync: Erstellen fehlgeschlagen für " .. tostring(H.netId) .. " " .. tostring(tState.resource))
            end
        end
        H.state = CopyState(tState)
        return true
    end, fnDone)
end

---------------------------------------------------------------------
-- Eingehende Nachrichten
---------------------------------------------------------------------
-- api.json.Stringify schreibt Lua-Arrays als {"1":x,"2":y,"3":z} -> beide Formen akzeptieren
local function Vec3(t)
    if type(t) ~= "table" then return nil end
    local x, y, z = t[1] or t["1"] or t.x, t[2] or t["2"] or t.y, t[3] or t["3"] or t.z
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
    return { x, y, z }
end
Sync.Vec3 = Vec3

local function OnRemoteAction(msg)
    local a = msg.action
    if type(a) ~= "table" then return end
    if type(msg.seq) == "number" and msg.seq > api.pc2mp.nLastSeq then
        api.pc2mp.nLastSeq = msg.seq
        Sync.UpdateHello()
    end
    if a.origin == Sync.sInstance then return end -- eigenes Echo
    local sNet = a.netId
    if sNet == nil then return end
    local H = Sync.tByNet[sNet]
    if a.op == "upsert" then
        if H == nil then
            H = { netId = sNet }
            Sync.tByNet[sNet] = H
        end
        local tState = { resource = a.resource or (H.state and H.state.resource), pos = Vec3(a.pos),
                         rot = Vec3(a.rot) or { 0, 0, 0 }, scale = a.scale }
        if tState.resource == nil or tState.pos == nil then
            Log.Write("Sync: unvollständige Aktion " .. Log.ToStr(a))
            return
        end
        Sync.Apply(H, tState, "remote " .. sNet .. " von " .. tostring(msg.clientId))
    elseif a.op == "remove" then
        if H ~= nil then Sync.Apply(H, nil, "remote remove " .. sNet) end
    end
end

local function OnIds(msg)
    for _, m in ipairs(msg.map or {}) do
        local H = Sync.tPendingLocal[m.localId]
        if H ~= nil then
            Sync.tPendingLocal[m.localId] = nil
            H.netId = m.netId
            Sync.tByNet[m.netId] = H
            if H.partID == nil or H.bDirtyAfterIds then
                H.bDirtyAfterIds = nil
                Sync.SendState(H)
            end
        end
    end
end

function Sync.OnMessage(msg, sRaw)
    if type(msg) ~= "table" then return end
    local t = msg.t
    if t == "action" then
        OnRemoteAction(msg)
    elseif t == "ids" then
        OnIds(msg)
    elseif t == "welcome" then
        Sync.sMyId = msg.clientId
        Log.Write("Sync: verbunden als " .. tostring(msg.clientId) .. ", Server-Seq " .. tostring(msg.serverSeq)
            .. ", Spieler online: " .. Log.ToStr(msg.clients))
    elseif t == "caughtUp" then
        Log.Write("Sync: Catch-up fertig bis Seq " .. tostring(msg.serverSeq))
    elseif t == "join" or t == "leave" then
        Log.Write("Sync: " .. t .. " " .. tostring(msg.name or msg.clientId))
    elseif t == "error" then
        Log.Write("Sync: Server-Fehler " .. tostring(msg.code) .. ": " .. tostring(msg.msg))
    end
end

---------------------------------------------------------------------
-- Eigenes Strg+Z / Strg+Y (nur eigene Aktionen)
---------------------------------------------------------------------
function Sync.Undo()
    local e = table.remove(Sync.tUndo)
    if e == nil then Log.Write("Sync: nichts rückgängig zu machen") return end
    table.insert(Sync.tRedo, e)
    Log.Write("Sync: Undo " .. tostring(e.H.netId or e.H.nLocalId))
    Sync.Apply(e.H, e.before, "undo", function() Sync.SendState(e.H) end)
end

function Sync.Redo()
    local e = table.remove(Sync.tRedo)
    if e == nil then return end
    table.insert(Sync.tUndo, e)
    Log.Write("Sync: Redo " .. tostring(e.H.netId or e.H.nLocalId))
    Sync.Apply(e.H, e.after, "redo", function() Sync.SendState(e.H) end)
end

---------------------------------------------------------------------
-- Start / Tick
---------------------------------------------------------------------
function Sync.UpdateHello()
    local c = Sync.tConfig or {}
    Net.SetHello({ t = "hello", v = 1, name = c.name or "Spieler", park = c.park or "default",
                   lastSeq = api.pc2mp.nLastSeq })
end

-- true, wenn der Multiplayer läuft (Config vorhanden und enabled ~= false)
function Sync.Start()
    local tCfg, sErr = Net.ReadConfig()
    if tCfg == nil then
        Log.Write("Sync: keine Konfiguration (" .. tostring(sErr) .. ") -> Multiplayer aus")
        return false
    end
    if tCfg.enabled == false or tCfg.host == nil then
        Log.Write("Sync: Multiplayer in PC2MP_config.json deaktiviert")
        return false
    end
    Sync.tConfig = tCfg
    Log.Write("Sync: " .. Net.Info())
    -- Neuer Park/Environment: Zuordnungen kommen (falls vorhanden) aus dem Spielstand (pc2mp.persist),
    -- sonst gilt: alles ab Seq 0 vom Server holen (frischer Start-Spielstand).
    api.pc2mp.nLastSeq = 0
    Sync.tByPart, Sync.tByNet, Sync.tPendingLocal, Sync.tUndo, Sync.tRedo = {}, {}, {}, {}, {}
    Sync.nPort = global.math.tointeger(tCfg.port or 7790) or 7790
    -- Verbinden erst, wenn die Zuordnungen aus dem Spielstand übernommen sind (sonst doppelter Catch-up)
    Sync.bWaitConnect = true
    Sync.nWaitFrames = 0
    Events.AddListener(Sync.OnLocalAction)
    Sync.bActive = true
    api.pc2mp.Sync = Sync -- für den Undo-Hook (läuft in einem anderen Modul-Kontext)
    Log.Write("Sync: Multiplayer aktiv, Server " .. tostring(tCfg.host) .. ":" .. tostring(Sync.nPort)
        .. ", Instanz " .. Sync.sInstance)
    return true
end

---------------------------------------------------------------------
-- Persistenz (Zuordnung netId -> Teil reist im Park-Spielstand mit, pc2mp.persist / #14)
---------------------------------------------------------------------
function Sync.GetPersistState()
    local tMap = {}
    for sNet, H in pairs(Sync.tByNet) do
        if H.partID ~= nil then tMap[sNet] = H.partID end
    end
    return { lastSeq = api.pc2mp.nLastSeq, map = tMap }
end

function Sync.OnPersistLoaded(t)
    local n = 0
    for sNet, nPart in pairs(t.map or {}) do
        local H = { netId = sNet, partID = nPart }
        local okD, d = pcall(Events.DescribePart, nPart)
        if okD and d and d.exists then
            H.state = { resource = d.resource, pos = d.pos, rot = d.rot, scale = d.scale }
        end
        Sync.tByNet[sNet] = H
        Sync.tByPart[nPart] = H
        Events.tKnownOriginals[nPart] = true
        n = n + 1
    end
    api.pc2mp.nLastSeq = t.lastSeq or 0
    Log.Write("Sync: " .. n .. " Zuordnungen aus dem Spielstand übernommen, weiter ab Seq " .. tostring(api.pc2mp.nLastSeq))
end

function Sync.RegisterPersist(tWorldAPIs)
    local okP, Persist = pcall(require, "pc2mp.persist")
    if not okP then
        Log.Write("Sync: pc2mp.persist fehlt: " .. tostring(Persist))
        return
    end
    Sync.Persist = Persist
    Persist.RegisterSaveClient(tWorldAPIs, Sync.GetPersistState, Sync.OnPersistLoaded)
end

Sync.nLastStatusLog = ""
function Sync.Tick()
    if not Sync.bActive then return end
    if Sync.bWaitConnect then
        Sync.nWaitFrames = Sync.nWaitFrames + 1
        local bResolved = true
        if Sync.Persist then
            local ok, b = pcall(Sync.Persist.ResolveLoaded)
            bResolved = (not ok) or b
        end
        if bResolved and Sync.nWaitFrames >= 30 then
            Sync.bWaitConnect = false
            Sync.UpdateHello()
            -- Die DLL hält die Verbindung über Park-Wechsel hinweg; neu verbinden, damit hello (lastSeq) neu geht
            Net.Disconnect()
            Net.Connect(Sync.tConfig.host, Sync.nPort)
            Log.Write("Sync: verbinde (lastSeq " .. tostring(api.pc2mp.nLastSeq) .. ")")
        end
        return
    end
    Net.Pump(Sync.OnMessage, 32)
    local sStatus, _, _, nConn = Net.Status()
    local sKey = sStatus .. "/" .. tostring(nConn)
    if sKey ~= Sync.nLastStatusLog then
        Sync.nLastStatusLog = sKey
        Log.Write("Sync: Netzwerk " .. sStatus .. " (Verbindungen: " .. tostring(nConn) .. ")"
            .. (sStatus ~= "connected" and (" " .. tostring(Net.LastError())) or ""))
    end
end

function Sync.Stop()
    Sync.bActive = false
    api.pc2mp.Sync = nil
end

return Sync
