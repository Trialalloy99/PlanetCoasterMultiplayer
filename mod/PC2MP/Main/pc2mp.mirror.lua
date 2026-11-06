-----------------------------------------------------------------------
--/  PC2MP Spiegel-Test (lokaler Replay-Test ohne Netzwerk, Issue #9):
--/  Für jedes Teil, das der Spieler setzt/ändert/löscht, wird ein "Zwilling"
--/  5 m daneben (x + 5) per Replay erzeugt/geändert/gelöscht.
--/  Simuliert damit exakt, was ein Remote-Client tun muss.
-----------------------------------------------------------------------
local global = _G
local tostring = global.tostring
local Log = require("pc2mp.log")
local Replay = require("pc2mp.replay")
local Events = require("pc2mp.events")

local Mirror = {}
Mirror.bEnabled = true
Mirror.nOffsetX = 5.0
Mirror.tTwinOf = {}      -- Original-PartID -> Zwillings-PartID
Mirror.tPending = {}     -- Original-PartID -> true (Erstellung läuft)

local function Shifted(tAction)
    local t = { resource = tAction.resource, rot = tAction.rot, scale = tAction.scale }
    t.pos = { tAction.pos[1] + Mirror.nOffsetX, tAction.pos[2], tAction.pos[3] }
    return t
end

function Mirror.OnAction(tAction)
    if not Mirror.bEnabled then return end
    local nSrc = tAction.partID
    if tAction.op == "upsert" then
        local nTwin = Mirror.tTwinOf[nSrc]
        if nTwin ~= nil then
            Replay.Enqueue("edit twin " .. tostring(nTwin), function()
                return Replay.DoEdit(nTwin, Shifted(tAction))
            end)
        elseif not Mirror.tPending[nSrc] then
            Mirror.tPending[nSrc] = true
            Replay.Enqueue("create twin of " .. tostring(nSrc) .. " " .. tostring(tAction.resource), function()
                return Replay.DoCreate(Shifted(tAction), function(nNewID)
                    Events.tIgnore[nNewID] = true
                end)
            end, function(bOk, nNewID)
                Mirror.tPending[nSrc] = nil
                if bOk and nNewID ~= nil then
                    Mirror.tTwinOf[nSrc] = nNewID
                    Events.tIgnore[nNewID] = true
                    Log.Write("Mirror: Zwilling " .. tostring(nNewID) .. " für " .. tostring(nSrc))
                else
                    Log.Write("Mirror: Zwilling für " .. tostring(nSrc) .. " fehlgeschlagen")
                end
            end)
        end
    elseif tAction.op == "remove" then
        local nTwin = Mirror.tTwinOf[nSrc]
        if nTwin ~= nil then
            Mirror.tTwinOf[nSrc] = nil
            Replay.Enqueue("destroy twin " .. tostring(nTwin), function()
                return Replay.DoDestroy(nTwin)
            end)
        end
    end
end

return Mirror
