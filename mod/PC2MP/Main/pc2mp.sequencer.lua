-----------------------------------------------------------------------
--/  PC2MP Sequencer: animierte Szenerie (Schleifentyp, Auslöser) und Event-Ablauf-Steuerung
--/  (Display-Sequencer: Programm, Auslöser-Einstellungen, Musik) lesen und auf einem anderen Teil setzen.
--/
--/  Verifiziert im dekompilierten Lua (Stand 2026-11-07), noch NICHT im Spiel getestet:
--/    Animation (AnimatedSceneryInfoPopUpGameface / BaseSceneryInfoPopUpGameface):
--/      lesen:  sequence:GetTriggerTargetPropData(nPartID) -> { nAnimLoop, nType, ... },
--/              sequence:GetPartTriggerControlled / GetPartTriggerDuration / GetPartTriggerStrobe (nPartID)
--/      setzen: sequence:SetLoopAnim(eo, n) + CreateEditOperationForDatastoreChange(clh, id, DatastoreChange_LoopAnim)
--/              sequence:SetTriggerControlledMoveObject(eo, b), SetTriggerBehaviourMoveObject(eo, nType)
--/                + DatastoreChange_Behaviour / DatastoreChange_TriggerControlled
--/              sequence:SetTriggerDurationPart(nPartID, n), SetTriggerStrobePart(nPartID, n)   (direkt)
--/    Ablaufsteuerung (DisplaySequencerInfoPopUpGameface, GamefaceBaseAdvancedTriggerUIMode, SequencerUIContext):
--/      Einstellungen: sequence:GetSequencerTriggerSettings(id) / SetSequencerTriggerSettingsMoveObject(eo, t)
--/                     + CreateEditOperationForSequencerDatastoreChange(clh, id, SequencerDatastoreChange_TriggerSettings)
--/      Musik:         gameaudio:GetSequencerEvent(id) / sequence:SetSequencerCustomMusicMoveObject(eo, s)
--/      Programm:      sequence:GetSequencerTriggerSequence(id) -> natives Sequenz-Objekt (Spuren -> Ereignisse/Gruppen)
--/                     sequence:SetSequencerTriggerSequenceMoveObject(eo, oSequence)
--/  Ereignisse verweisen auf lokale PartIDs -> Props.fnPartToRef / fnRefToPart (netId im Multiplayer, Zwilling im Test).
-----------------------------------------------------------------------
local global = _G
local api = global.api
local type = global.type
local pairs = global.pairs
local ipairs = global.ipairs
local pcall = global.pcall
local tostring = global.tostring
local tonumber = global.tonumber
local table = global.table
local math = global.math
local require = global.require

local Seq = {}
Seq.bLog = true
Seq.nMaxDepth = 4

local function Log(s)
    local ok, L = pcall(require, "pc2mp.log")
    if ok and L then L.Write("Sequencer: " .. s) end
end

-- Methode aufrufen, Fehler -> nil (mehrere Rückgabewerte)
local function Call(obj, sMethod, ...)
    if obj == nil then return nil end
    local f = obj[sMethod]
    if type(f) ~= "function" then return nil end
    local r = table.pack(pcall(f, obj, ...))
    if not r[1] then return nil end
    return table.unpack(r, 2, r.n)
end

local function Rgb(v)
    if type(v) == "table" and type(v[1]) == "number" then return { v[1], v[2], v[3] } end
    if v == nil or type(v) == "number" or type(v) == "string" or type(v) == "boolean" then return nil end
    local ok, x = pcall(function() return v:GetX() end)
    if ok and type(x) == "number" then return { x, v:GetY(), v:GetZ() } end
    ok, x = pcall(function() return v:X() end)
    if ok and type(x) == "number" then return { x, v:Y(), v:Z() } end
    return nil
end

local function Vec(c)
    if type(c) ~= "table" then return nil end
    local r, g, b = c[1] or c["1"], c[2] or c["2"], c[3] or c["3"]
    if type(r) ~= "number" then return nil end
    return require("Vector3"):new(r, g, b)
end

-- Einfache Werte / Tabellen daraus (Einstellungs-Tabellen), Vektoren als {r,g,b}
local function Plain(v, nDepth)
    local t = type(v)
    if t == "number" or t == "string" or t == "boolean" then return v end
    if (nDepth or 0) > 5 then return nil end
    if t ~= "table" then return Rgb(v) end
    local c = Rgb(v)
    if c and v[4] == nil then return c end
    local o = {}
    for k, x in pairs(v) do
        if type(k) == "string" or type(k) == "number" then o[k] = Plain(x, (nDepth or 0) + 1) end
    end
    return o
end
Seq.Plain = Plain

-- api.json: {"1":..} -> Arrays; rekursiv
local function Norm(v)
    if type(v) ~= "table" then return v end
    local o = {}
    for k, x in pairs(v) do
        local nk = (type(k) == "string" and tonumber(k)) or k
        o[nk] = Norm(x)
    end
    return o
end
Seq.Norm = Norm

local function List(t)
    t = Norm(t)
    if type(t) ~= "table" then return {} end
    local o, nMax = {}, 0
    for k in pairs(t) do if type(k) == "number" and k > nMax then nMax = k end end
    for i = 1, nMax do if t[i] ~= nil then o[#o + 1] = t[i] end end
    return o
end
Seq.List = List

---------------------------------------------------------------------
-- Animation / Auslöser einer animierten Szenerie
---------------------------------------------------------------------
function Seq.DescribeAnim(tw, nPartID)
    local sq = tw and tw.sequence
    if sq == nil then return nil end
    if type(sq.IsTriggerTargetPropData) == "function" and not Call(sq, "IsTriggerTargetPropData", nPartID) then return nil end
    local pd = Call(sq, "GetTriggerTargetPropData", nPartID)
    if type(pd) ~= "table" then return nil end
    local a = { loop = pd.nAnimLoop, type = pd.nType }
    a.ctrl = Call(sq, "GetPartTriggerControlled", nPartID) and true or false
    local d = Call(sq, "GetPartTriggerDuration", nPartID)
    if type(d) == "number" then a.dur = d end
    local s = Call(sq, "GetPartTriggerStrobe", nPartID)
    if type(s) == "number" then a.strobe = s end
    if a.loop == nil and a.type == nil and a.dur == nil and a.strobe == nil then return nil end
    return a
end

-- in der Edit-Hierarchie (Schleifentyp, Auslöser-Art)
function Seq.ApplyAnimInEdit(tw, clh, eo, nPartID, a)
    local sq = tw and tw.sequence
    if sq == nil or eo == nil or type(a) ~= "table" then return 0 end
    local n = 0
    if type(a.loop) == "number" and pcall(sq.SetLoopAnim, sq, eo, a.loop) then
        pcall(sq.CreateEditOperationForDatastoreChange, sq, clh, nPartID, sq.DatastoreChange_LoopAnim)
        n = n + 1
    end
    if a.ctrl ~= nil then
        pcall(sq.SetTriggerControlledMoveObject, sq, eo, a.ctrl == true)
        if a.ctrl == true then
            pcall(sq.CreateEditOperationForDatastoreChange, sq, clh, nPartID, sq.DatastoreChange_TriggerControlled)
        elseif type(a.type) == "number" then
            pcall(sq.SetTriggerBehaviourMoveObject, sq, eo, a.type)
            pcall(sq.CreateEditOperationForDatastoreChange, sq, clh, nPartID, sq.DatastoreChange_Behaviour)
        end
        n = n + 1
    end
    return n
end

-- direkt (ohne Undo): Intervall und Dauer
function Seq.ApplyAnimDirect(tw, nPartID, a)
    local sq = tw and tw.sequence
    if sq == nil or type(a) ~= "table" then return 0 end
    local n = 0
    if type(a.dur) == "number" and Call(sq, "GetPartTriggerDuration", nPartID) ~= a.dur then
        Seq.bApplying = true
        if pcall(sq.SetTriggerDurationPart, sq, nPartID, a.dur) then n = n + 1 end
        Seq.bApplying = false
    end
    if type(a.strobe) == "number" and Call(sq, "GetPartTriggerStrobe", nPartID) ~= a.strobe then
        Seq.bApplying = true
        if pcall(sq.SetTriggerStrobePart, sq, nPartID, a.strobe) then n = n + 1 end
        Seq.bApplying = false
    end
    return n
end

---------------------------------------------------------------------
-- Programm der Ablaufsteuerung (natives Sequenz-Objekt) <-> Tabelle
---------------------------------------------------------------------
local function ItemIDs(oSeq)
    local t = Call(oSeq, "GetSequenceItems", true)
    if type(t) ~= "table" then return {} end
    return List(t.tItemIDs or {})
end

-- Spur/Gruppe: Liste von Einträgen { g = {Unter-Einträge}, t = Start } oder Ereignis { p = Ref, t, ty, d, s, fd, fc, ui }
local function SerItems(oSeq, fnRef, nDepth)
    local out = {}
    local tIDs = ItemIDs(oSeq)
    for i, nID in ipairs(tIDs) do
        local nIdx = i - 1
        if Call(oSeq, "GetItemIsGroup", nIdx) then
            local nStart, oGroup = Call(oSeq, "GetSequenceItemFromIndex", nIdx)
            local e = { g = {}, t = nStart, ui = Rgb(Call(oGroup, "GetUIColour")) }
            if oGroup ~= nil and nDepth < Seq.nMaxDepth then e.g = SerItems(oGroup, fnRef, nDepth + 1) end
            out[#out + 1] = e
        else
            local nPart = Call(oSeq, "GetEventItemFromIndex", nIdx)
            local ref = nPart ~= nil and fnRef(nPart) or nil
            if ref ~= nil then
                out[#out + 1] = {
                    p = ref,
                    t = Call(oSeq, "GetEventDelayWithItemID", nID) or 0,
                    ty = Call(oSeq, "GetEventTypeWithItemID", nID),
                    d = Call(oSeq, "GetEventDurationWithItemID", nID),
                    s = Call(oSeq, "GetEventStrobeWithItemID", nID),
                    fd = Call(oSeq, "GetEventFadeDurationWithItemID", nID),
                    fc = Rgb(Call(oSeq, "GetEventFadeToColourWithItemID", nID)),
                    ui = Rgb(Call(oSeq, "GetEventUIColourWithItemID", nID)),
                }
            elseif nPart ~= nil then
                Seq.nUnmapped = (Seq.nUnmapped or 0) + 1
            end
        end
    end
    return out
end

function Seq.SerializeSequence(oRoot, fnRef)
    if oRoot == nil then return nil end
    Seq.nUnmapped = 0
    local tTracks = {}
    local n = Call(oRoot, "CountItems") or 0
    for i = 0, n - 1 do
        local nDelay, oTrack = Call(oRoot, "GetSequenceItemFromIndex", i)
        if oTrack ~= nil then
            tTracks[#tTracks + 1] = { t = nDelay or 0, ui = Rgb(Call(oTrack, "GetUIColour")), items = SerItems(oTrack, fnRef, 1) }
        end
    end
    if Seq.nUnmapped > 0 and Seq.bLog then
        Log(Seq.nUnmapped .. " Ereignis(se) ohne Netz-Zuordnung ausgelassen (Objekt noch nicht synchronisiert)")
    end
    return { tracks = tTracks }
end

local function ColourInt(c)
    c = type(c) == "table" and c or { 1, 1, 1 }
    local function B(x) return math.max(0, math.min(255, math.floor((tonumber(x) or 1) * 255 + 0.5))) end
    return B(c[1] or c["1"]) * 65536 + B(c[2] or c["2"]) * 256 + B(c[3] or c["3"])
end

local function NewIDs(oSeq, tBefore)
    local tSet = {}
    for _, id in ipairs(tBefore) do tSet[id] = true end
    local tNew = {}
    for _, id in ipairs(ItemIDs(oSeq)) do if not tSet[id] then tNew[#tNew + 1] = id end end
    return tNew
end

local function FillItems(sq, oSeq, tItems, fnPart, nDepth, tStat)
    for _, e in ipairs(List(tItems)) do
        if type(e) == "table" and e.g ~= nil then
            if nDepth < Seq.nMaxDepth then
                local oGroup, nGroupID = Call(oSeq, "AddBlankSequenceItem", tonumber(e.t) or 0, ColourInt(e.ui), true)
                if oGroup ~= nil and nGroupID ~= nil then
                    FillItems(sq, oGroup, e.g, fnPart, nDepth + 1, tStat)
                    pcall(oSeq.SetSequenceItemWithItemID, oSeq, nGroupID, oGroup)
                    tStat.groups = tStat.groups + 1
                end
            end
        elseif type(e) == "table" and e.p ~= nil then
            local nPart = fnPart(e.p)
            if nPart == nil then
                tStat.missing = tStat.missing + 1
            else
                local tBefore = ItemIDs(oSeq)
                local nUIMode = Call(sq, "GetTriggerUIMode", nPart)
                local vUI = Vec(e.ui) or require("Vector3"):new(1, 1, 1)
                local bOk
                if type(e.d) == "number" then
                    bOk = pcall(oSeq.AddEventItem, oSeq, tonumber(e.t) or 0, nPart, nUIMode, vUI, e.d)
                else
                    bOk = pcall(oSeq.AddEventItem, oSeq, tonumber(e.t) or 0, nPart, nUIMode, vUI)
                end
                local nID = bOk and NewIDs(oSeq, tBefore)[1] or nil
                if nID ~= nil then
                    if e.ty ~= nil then pcall(oSeq.SetEventTypeWithItemID, oSeq, nID, e.ty) end
                    if type(e.d) == "number" then pcall(oSeq.SetEventDurationWithItemID, oSeq, nID, e.d) end
                    if e.s ~= nil then pcall(oSeq.SetEventStrobeWithItemID, oSeq, nID, e.s) end
                    if type(e.fd) == "number" then pcall(oSeq.SetEventFadeDurationWithItemID, oSeq, nID, e.fd) end
                    if e.fc ~= nil then pcall(oSeq.SetEventColourWithItemID, oSeq, nID, Vec(e.fc)) end
                    pcall(oSeq.SetEventDelayWithItemID, oSeq, nID, tonumber(e.t) or 0)
                    tStat.events = tStat.events + 1
                else
                    tStat.failed = tStat.failed + 1
                end
            end
        end
    end
    pcall(oSeq.SortItems, oSeq)
end

-- Baut aus tData ein neues Sequenz-Objekt auf Basis der vorhandenen Sequenz des Ziel-Sequencers
function Seq.BuildSequence(tw, nSequencerPart, tData, fnPart)
    local sq = tw and tw.sequence
    local oCur = Call(sq, "GetSequencerTriggerSequence", nSequencerPart)
    local oRoot = oCur and Call(oCur, "CreateDeepCopy")
    if oRoot == nil then return nil, "keine Sequenz am Ziel" end
    for _, id in ipairs(ItemIDs(oRoot)) do pcall(oRoot.RemoveItemWithItemID, oRoot, id) end
    local tStat = { tracks = 0, events = 0, groups = 0, missing = 0, failed = 0 }
    for _, tr in ipairs(List(tData and tData.tracks)) do
        local oTrack, nTrackID = Call(oRoot, "AddBlankSequenceItem", tonumber(tr.t) or 0, ColourInt(tr.ui), false)
        if oTrack ~= nil and nTrackID ~= nil then
            FillItems(sq, oTrack, tr.items, fnPart, 1, tStat)
            pcall(oRoot.SetSequenceItemWithItemID, oRoot, nTrackID, oTrack)
            tStat.tracks = tStat.tracks + 1
        else
            tStat.failed = tStat.failed + 1
        end
    end
    return oRoot, tStat
end

---------------------------------------------------------------------
-- Ablaufsteuerung als Ganzes (für pc2mp.props)
---------------------------------------------------------------------
function Seq.IsSequencer(tw, nPartID)
    local sq = tw and tw.sequence
    if sq == nil then return false end
    -- erst die Prüffunktion des Spiels (SelectedModularSceneryUIContext), dann die Einstellungen
    if type(sq.IsSequencerPropData) == "function" and not Call(sq, "IsSequencerPropData", nPartID) then return false end
    local t = Call(sq, "GetSequencerTriggerSettings", nPartID)
    return type(t) == "table"
end

function Seq.DescribeSequencer(tw, nPartID, fnRef)
    if not Seq.IsSequencer(tw, nPartID) then return nil end
    local sq = tw.sequence
    local o = { set = Plain(Call(sq, "GetSequencerTriggerSettings", nPartID)) }
    local sMusic = Call(tw.gameaudio, "GetSequencerEvent", nPartID)
    if type(sMusic) == "string" then o.music = sMusic end
    local okS, tProg = pcall(Seq.SerializeSequence, Call(sq, "GetSequencerTriggerSequence", nPartID), fnRef)
    if okS then o.prog = tProg else Log("Programm lesen fehlgeschlagen: " .. tostring(tProg)) end
    return o
end

function Seq.ApplySequencerInEdit(tw, clh, eo, nPartID, o, fnPart)
    local sq = tw and tw.sequence
    if sq == nil or eo == nil or type(o) ~= "table" then return 0 end
    local n = 0
    if type(o.set) == "table" then
        local t = Norm(o.set)
        if type(t.tShowTimes) == "table" then t.tShowTimes = List(t.tShowTimes) end
        if pcall(sq.SetSequencerTriggerSettingsMoveObject, sq, eo, t) then
            pcall(sq.CreateEditOperationForSequencerDatastoreChange, sq, clh, nPartID, sq.SequencerDatastoreChange_TriggerSettings)
            n = n + 1
        end
    end
    if type(o.music) == "string" and pcall(sq.SetSequencerCustomMusicMoveObject, sq, eo, o.music) then n = n + 1 end
    if type(o.prog) == "table" then
        local okB, oRoot, tStat = pcall(Seq.BuildSequence, tw, nPartID, o.prog, fnPart)
        if okB and oRoot ~= nil then
            if pcall(sq.SetSequencerTriggerSequenceMoveObject, sq, eo, oRoot) then n = n + 1 end
            Log("Programm gesetzt: " .. tStat.tracks .. " Spuren, " .. tStat.events .. " Ereignisse, " .. tStat.groups
                .. " Gruppen" .. (tStat.missing > 0 and (", " .. tStat.missing .. " Ziel(e) fehlen") or "")
                .. (tStat.failed > 0 and (", " .. tStat.failed .. " fehlgeschlagen") or ""))
        else
            Log("Programm bauen fehlgeschlagen: " .. tostring(okB and tStat or oRoot))
        end
    end
    return n
end

return Seq
