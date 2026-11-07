-----------------------------------------------------------------------
--/  PC2MP Spiegel-Test / Testmodus (lokal, ohne Netzwerk, Issue #9):
--/  Für jedes Teil, das der Spieler setzt/ändert/löscht, wird ein "Zwilling"
--/  daneben (x + nOffsetX) per Replay erzeugt/geändert/gelöscht – inklusive Farben,
--/  Lichtmuster und Name (pc2mp.props). Simuliert damit exakt, was ein Remote-Client tun muss.
--/  Ein- und ausschaltbar über die Dev-UI (Testmodus, pc2mp.menu -> api.pc2mp.tTest).
-----------------------------------------------------------------------
local global = _G
local tostring = global.tostring
local Log = require("pc2mp.log")
local Replay = require("pc2mp.replay")
local Events = require("pc2mp.events")
local Props = require("pc2mp.props")

local Mirror = {}
Mirror.bEnabled = true
Mirror.nOffsetX = 5.0
Mirror.tTwinOf = {}      -- Original-PartID -> Zwillings-PartID
Mirror.tPending = {}     -- Original-PartID -> true (Erstellung läuft)
Mirror.tLast = {}        -- Original-PartID -> letzter gespiegelter Zustand (gegen doppelte Meldungen)
Mirror.tQueued = {}      -- Original-PartID -> Zustand, der nach der laufenden Erstellung noch kommt
Mirror.nCount = 0
Mirror.fnOnEvent = nil   -- optional: fn(sText) für die Testmodus-Anzeige in der Dev-UI

local function Note(s)
    Mirror.nCount = Mirror.nCount + 1
    Log.Write("Mirror: " .. s)
    if Mirror.fnOnEvent then global.pcall(Mirror.fnOnEvent, s) end
end

local function Shifted(tAction)
    local t = { resource = tAction.resource, rot = tAction.rot, scale = tAction.scale, props = tAction.props }
    t.pos = { tAction.pos[1] + Mirror.nOffsetX, tAction.pos[2], tAction.pos[3] }
    return t
end

local function Describe(tAction)
    local s = tostring(tAction.resource)
    local p = tAction.props
    if p then
        if p.colours then s = s .. ", " .. #p.colours .. " Farbe(n)" end
        if p.cookie then s = s .. ", Muster " .. tostring(p.cookie) end
        if p.name then s = s .. ", Name '" .. tostring(p.name) .. "'" end
    end
    return s
end

local function EditTwin(nSrc, nTwin, tAction)
    Replay.Enqueue("edit twin " .. tostring(nTwin), function()
        return Replay.DoEdit(nTwin, Shifted(tAction))
    end, function(bOk)
        Note("Zwilling " .. tostring(nTwin) .. " geändert (" .. Describe(tAction) .. ") -> " .. tostring(bOk))
    end)
end

function Mirror.OnAction(tAction)
    if not Mirror.bEnabled then return end
    local nSrc = tAction.partID
    if tAction.op == "upsert" then
        if Props.StateEqual(Mirror.tLast[nSrc], tAction) then return end -- nichts Neues
        Mirror.tLast[nSrc] = tAction
        local nTwin = Mirror.tTwinOf[nSrc]
        if nTwin ~= nil then
            EditTwin(nSrc, nTwin, tAction)
        elseif Mirror.tPending[nSrc] then
            Mirror.tQueued[nSrc] = tAction -- nach der Erstellung nachziehen
        else
            Mirror.tPending[nSrc] = true
            Replay.Enqueue("create twin of " .. tostring(nSrc) .. " " .. tostring(tAction.resource), function()
                return Replay.DoCreate(Shifted(tAction), function(nNewID)
                    Events.IgnoreFor(nNewID)
                end)
            end, function(bOk, nNewID)
                Mirror.tPending[nSrc] = nil
                if bOk and nNewID ~= nil then
                    Mirror.tTwinOf[nSrc] = nNewID
                    Events.IgnoreFor(nNewID)
                    Note("Zwilling " .. tostring(nNewID) .. " für " .. tostring(nSrc) .. " (" .. Describe(tAction) .. ")")
                    local q = Mirror.tQueued[nSrc]
                    Mirror.tQueued[nSrc] = nil
                    if q ~= nil then EditTwin(nSrc, nNewID, q) end
                else
                    Mirror.tLast[nSrc] = nil
                    Note("Zwilling für " .. tostring(nSrc) .. " fehlgeschlagen")
                end
            end)
        end
    elseif tAction.op == "remove" then
        Mirror.tLast[nSrc] = nil
        Mirror.tQueued[nSrc] = nil
        local nTwin = Mirror.tTwinOf[nSrc]
        if nTwin ~= nil then
            Mirror.tTwinOf[nSrc] = nil
            Replay.Enqueue("destroy twin " .. tostring(nTwin), function()
                return Replay.DoDestroy(nTwin)
            end, function(bOk) Note("Zwilling " .. tostring(nTwin) .. " gelöscht -> " .. tostring(bOk)) end)
        end
    end
end

return Mirror
