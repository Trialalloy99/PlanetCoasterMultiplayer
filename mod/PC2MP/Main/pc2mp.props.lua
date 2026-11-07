-----------------------------------------------------------------------
--/  PC2MP Props: Eigenschaften eines Szenerie-Teils über Position/Rotation/Skalierung hinaus.
--/
--/  Verifiziert im dekompilierten Lua (Stand 2026-11-07), noch NICHT im Spiel getestet:
--/    Farben (auch Lichtfarbe):  tWorldAPIs.scenery_flexicolour
--/        :GetFlexiColourForPartID(nPartID) -> { [sTag] = { [?] = { vColour = Vector3 | "ambiguous" } } }
--/        :SetFlexiColourForPartSet(clh, partSet, sTag, Vector3)   (nach StartEditingParts_Scenery, vor Preview)
--/        (Editors.Scenery.SubModeSelect.SetFlexiColour, Editors.Shared.SceneryColourPickerUtils)
--/    Lichtmuster (Spotlight-Cookie):  scenery:GetLightCookieName(nPartID) / scenery:SetLightCookieName(editObject, s)
--/        nur bei scenery:IsCustomisableLight(nEntityID)  (AnimatedSceneryInfoPopUpGameface.ChangeSpotlightPattern)
--/    Atmosphäre:  scenery:GetSceneryAtmosphereType(nPartID, true) / scenery:SetSceneryAtmosphereType(nPartID, n)  (direkt)
--/    Name:        scenery:GetRawNameOverride(nPartID) / scenery:OverridePropName(nPartID, s)                   (direkt)
--/
--/    Animation/Auslöser + Event-Ablauf-Steuerung: pc2mp.sequencer
--/
--/  Format (JSON-tauglich):
--/    props = { colours = { {tag=<sTag>, c={r,g,b}}, ... }, cookie = "...", atmos = n, name = "...",
--/              anim = {loop, type, ctrl, dur, strobe}, seqr = {set = {...}, music = "...", prog = {tracks = ...}} }
--/  Teil-Verweise im Programm (seqr.prog): Props.fnPartToRef / Props.fnRefToPart (Sync: netId, Testmodus: Zwilling).
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

local Props = {}
Props.bLog = true
Props.fnPartToRef = function(n) return n end
Props.fnRefToPart = function(r) return global.math.tointeger(tonumber(r)) end

local function Seq()
    local ok, S = pcall(require, "pc2mp.sequencer")
    return ok and S or nil
end

local function Log(s)
    local ok, L = pcall(require, "pc2mp.log")
    if ok and L then L.Write(s) end
end

local function TryCall(obj, sMethod, ...)
    if obj == nil then return nil end
    local f = obj[sMethod]
    if type(f) ~= "function" then return nil end
    local ok, a, b = pcall(f, obj, ...)
    if ok then return a, b end
    return nil
end

-- Vector3 aus dem Spiel (Userdata oder Tabelle, :GetX() oder :X()) -> {r,g,b}
local function Rgb(v)
    if type(v) == "table" and type(v[1]) == "number" then return { v[1], v[2], v[3] } end
    if v == nil or type(v) == "string" then return nil end
    local ok, x = pcall(function() return v:GetX() end)
    if ok and type(x) == "number" then return { x, v:GetY(), v:GetZ() } end
    ok, x = pcall(function() return v:X() end)
    if ok and type(x) == "number" then return { x, v:Y(), v:Z() } end
    return nil
end
Props.Rgb = Rgb

-- Erste eindeutige Farbe aus einem "Uses"-Eintrag von GetFlexiColourForPartID
local function FirstColour(tUses)
    if type(tUses) ~= "table" then return nil end
    if tUses.vColour ~= nil then return Rgb(tUses.vColour) end
    local tKeys = {}
    for k in pairs(tUses) do tKeys[#tKeys + 1] = k end
    table.sort(tKeys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(tKeys) do
        local u = tUses[k]
        local c = type(u) == "table" and Rgb(u.vColour) or nil
        if c then return c end
    end
    return nil
end

function Props.Describe(tw, nPartID, nEntityID)
    if tw == nil or nPartID == nil then return nil end
    local p, n = {}, 0
    local fc = tw.scenery_flexicolour
    local tFlexi = TryCall(fc, "GetFlexiColourForPartID", nPartID)
    if type(tFlexi) == "table" then
        local tTags = {}
        for sTag in pairs(tFlexi) do tTags[#tTags + 1] = sTag end
        table.sort(tTags, function(a, b) return tostring(a) < tostring(b) end)
        local tCols = {}
        for _, sTag in ipairs(tTags) do
            local c = FirstColour(tFlexi[sTag])
            if c then tCols[#tCols + 1] = { tag = sTag, c = c } end
        end
        if #tCols > 0 then p.colours = tCols; n = n + 1 end
    end
    local sc = tw.scenery
    if sc ~= nil then
        if nEntityID ~= nil and TryCall(sc, "IsCustomisableLight", nEntityID) then
            local s = TryCall(sc, "GetLightCookieName", nPartID)
            if type(s) == "string" and s ~= "" then p.cookie = s; n = n + 1 end
        end
        local a = TryCall(sc, "GetSceneryAtmosphereType", nPartID, true)
        if type(a) == "number" then p.atmos = a; n = n + 1 end
        local sName = TryCall(sc, "GetRawNameOverride", nPartID)
        if type(sName) == "string" and sName ~= "" then p.name = sName; n = n + 1 end
    end
    local S = Seq()
    if S then
        local okA, a = pcall(S.DescribeAnim, tw, nPartID)
        if okA and a then p.anim = a; n = n + 1 end
        local okQ, q = pcall(S.DescribeSequencer, tw, nPartID, Props.fnPartToRef)
        if okQ and q then p.seqr = q; n = n + 1 end
    end
    if n == 0 then return nil end
    return p
end

-- api.json macht aus Lua-Arrays Objekte mit String-Schlüsseln -> zurück in Arrays
local function List(t)
    if type(t) ~= "table" then return {} end
    local o, nMax = {}, 0
    for k in pairs(t) do
        local i = tonumber(k)
        if i and i > nMax then nMax = math.floor(i) end
    end
    for i = 1, nMax do
        local v = t[i]
        if v == nil then v = t[tostring(i)] end
        if v ~= nil then o[#o + 1] = v end
    end
    return o
end

local function ColourOf(e)
    local c = type(e) == "table" and e.c or nil
    if type(c) ~= "table" then return nil end
    local r, g, b = c[1] or c["1"], c[2] or c["2"], c[3] or c["3"]
    if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then return nil end
    return r, g, b
end

-- Normalisiert Props aus dem Netz (String-Schlüssel) in die Form von Describe
function Props.Normalize(p)
    if type(p) ~= "table" then return nil end
    local S = Seq()
    local o = { cookie = p.cookie, atmos = p.atmos, name = p.name,
                anim = S and S.Norm(p.anim) or p.anim, seqr = S and S.Norm(p.seqr) or p.seqr }
    if p.colours ~= nil then
        o.colours = {}
        for _, e in ipairs(List(p.colours)) do
            local r, g, b = ColourOf(e)
            if r ~= nil and e.tag ~= nil then o.colours[#o.colours + 1] = { tag = e.tag, c = { r, g, b } } end
        end
    end
    return o
end

local function Near(a, b) return math.abs(a - b) < 0.002 end

-- tiefer Vergleich (Zahlen mit Toleranz, Schlüssel "1" == 1)
local function DeepEq(a, b, nDepth)
    if type(a) == "number" and type(b) == "number" then return Near(a, b) end
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    if (nDepth or 0) > 12 then return true end
    local function Get(t, k)
        local v = t[k]
        if v == nil and type(k) == "string" then v = t[tonumber(k) or k] end
        if v == nil and type(k) == "number" then v = t[tostring(k)] end
        return v
    end
    for k, v in pairs(a) do if not DeepEq(v, Get(b, k), (nDepth or 0) + 1) then return false end end
    for k, v in pairs(b) do if Get(a, k) == nil and v ~= nil then return false end end
    return true
end
Props.DeepEq = DeepEq

function Props.Equal(a, b)
    if a == nil or b == nil then return a == b end
    if a.cookie ~= b.cookie or a.atmos ~= b.atmos or a.name ~= b.name then return false end
    if not DeepEq(a.anim, b.anim) or not DeepEq(a.seqr, b.seqr) then return false end
    local ca, cb = a.colours or {}, b.colours or {}
    if #ca ~= #cb then return false end
    for i = 1, #ca do
        local x, y = ca[i], cb[i]
        if tostring(x.tag) ~= tostring(y.tag) then return false end
        for j = 1, 3 do if not Near(x.c[j], y.c[j]) then return false end end
    end
    return true
end

local function VecEq(a, b, eps)
    if a == nil or b == nil then return a == b end
    for j = 1, 3 do
        if type(a[j]) ~= "number" or type(b[j]) ~= "number" or math.abs(a[j] - b[j]) > eps then return false end
    end
    return true
end

-- Gleicher Objekt-Zustand? {resource,pos,rot,scale,props} (gegen doppelte Meldungen, z. B.
-- PlacementPartCommitted + MaterialChanged für dieselbe Änderung)
function Props.StateEqual(a, b)
    if a == nil or b == nil then return a == b end
    if a.resource ~= b.resource then return false end
    if not VecEq(a.pos, b.pos, 0.001) or not VecEq(a.rot or { 0, 0, 0 }, b.rot or { 0, 0, 0 }, 0.0005) then return false end
    if (a.scale or 1) ~= (b.scale or 1) and math.abs((a.scale or 1) - (b.scale or 1)) > 0.0001 then return false end
    return Props.Equal(Props.Normalize(a.props), Props.Normalize(b.props))
end

-- Hat das Teil (tActual = Describe) alle gewünschten Farben/Lichtmuster aus tWanted?
function Props.Matches(tWanted, tActual)
    tWanted = Props.Normalize(tWanted)
    if tWanted == nil then return true end
    tActual = Props.Normalize(tActual) or {}
    if tWanted.cookie ~= nil and tWanted.cookie ~= tActual.cookie then return false end
    local tHave = {}
    for _, e in ipairs(tActual.colours or {}) do tHave[tostring(e.tag)] = e.c end
    for _, e in ipairs(tWanted.colours or {}) do
        local c = tHave[tostring(e.tag)]
        if c == nil then return false end
        for j = 1, 3 do if not Near(c[j], e.c[j]) then return false end end
    end
    if tWanted.anim ~= nil then
        local w, h = tWanted.anim, tActual.anim or {}
        if w.loop ~= h.loop or (w.ctrl ~= nil and w.ctrl ~= h.ctrl) or (w.ctrl == false and w.type ~= h.type) then return false end
    end
    if tWanted.seqr ~= nil and not DeepEq(tWanted.seqr, tActual.seqr) then return false end
    return true
end

-- Innerhalb einer Edit-Hierarchie (nach StartEditingPart(s)_Scenery, vor PreviewChangeList) aufrufen.
-- Gibt die Anzahl gesetzter Eigenschaften zurück.
function Props.ApplyInEdit(tw, clh, eo, nPartID, p)
    p = Props.Normalize(p)
    if p == nil or tw == nil then return 0 end
    local n = 0
    if p.colours and #p.colours > 0 and tw.scenery_flexicolour and nPartID ~= nil then
        local Vector3 = require("Vector3")
        local okS, set = pcall(function()
            local s = tw.scenery:CreateBuildingPartSet()
            s:Add(nPartID)
            return s
        end)
        if okS and set ~= nil then
            for _, e in ipairs(p.colours) do
                local ok, err = pcall(tw.scenery_flexicolour.SetFlexiColourForPartSet, tw.scenery_flexicolour, clh, set,
                    e.tag, Vector3:new(e.c[1], e.c[2], e.c[3]))
                if ok then n = n + 1 elseif Props.bLog then Log("Props: Farbe " .. tostring(e.tag) .. " Fehler: " .. tostring(err)) end
            end
        end
    end
    if p.cookie and eo ~= nil and tw.scenery then
        local ok, err = pcall(tw.scenery.SetLightCookieName, tw.scenery, eo, p.cookie)
        if ok then n = n + 1 elseif Props.bLog then Log("Props: Lichtmuster Fehler: " .. tostring(err)) end
    end
    local S = Seq()
    if S and eo ~= nil then
        if p.anim then
            local ok, r = pcall(S.ApplyAnimInEdit, tw, clh, eo, nPartID, p.anim)
            if ok then n = n + r elseif Props.bLog then Log("Props: Animation Fehler: " .. tostring(r)) end
        end
        if p.seqr then
            local ok, r = pcall(S.ApplySequencerInEdit, tw, clh, eo, nPartID, p.seqr, Props.fnRefToPart)
            if ok then n = n + r elseif Props.bLog then Log("Props: Ablaufsteuerung Fehler: " .. tostring(r)) end
        end
    end
    return n
end

-- Nach dem Commit: Eigenschaften, die das Spiel direkt (ohne Undo) setzt
function Props.ApplyDirect(tw, nPartID, p)
    p = Props.Normalize(p)
    if p == nil or tw == nil or tw.scenery == nil or nPartID == nil then return 0 end
    local n = 0
    if type(p.atmos) == "number" then
        local cur = TryCall(tw.scenery, "GetSceneryAtmosphereType", nPartID, true)
        if cur ~= p.atmos and pcall(tw.scenery.SetSceneryAtmosphereType, tw.scenery, nPartID, p.atmos) then n = n + 1 end
    end
    if type(p.name) == "string" and p.name ~= "" then
        local cur = TryCall(tw.scenery, "GetRawNameOverride", nPartID)
        if cur ~= p.name and pcall(tw.scenery.OverridePropName, tw.scenery, nPartID, p.name) then n = n + 1 end
    end
    local S = Seq()
    if S and p.anim then
        local ok, r = pcall(S.ApplyAnimDirect, tw, nPartID, p.anim)
        if ok then n = n + r end
    end
    return n
end

-- Braucht dieses Props-Objekt eine Edit-Hierarchie (Farben/Lichtmuster)?
function Props.NeedsEdit(p)
    p = Props.Normalize(p)
    return p ~= nil and ((p.colours and #p.colours > 0) or p.cookie ~= nil or p.seqr ~= nil
        or (p.anim ~= nil and (p.anim.loop ~= nil or p.anim.ctrl ~= nil)))
end

return Props
