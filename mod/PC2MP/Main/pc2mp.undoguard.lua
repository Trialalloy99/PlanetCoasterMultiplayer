-----------------------------------------------------------------------
--/  PC2MP UndoGuard: schützt vor dem nativen Absturz in api.undo.IsOperationComplete.
--/
--/  Analyse (Crash 2026-11-06, Minidump): IsOperationComplete @ exe+0x352be0 holt das
--/  Operation-Objekt per Weak-Pointer aus dem Token und liest danach ungeprüft [obj+8].
--/  Ist der Token nil oder die Operation schon zerstört -> Null-Zeiger -> Access Violation
--/  (exe+0x354fe7, kein Lua-Fehler, das Spiel stürzt ab). Ausgelöst, wenn unser Replay eine
--/  Preview startet, während das Spiel selbst noch eine Undo-Operation laufen hat
--/  (z. B. Einfügen mehrerer kopierter Objekte: 13 Teile in einem Frame, der Einfüge-Modus
--/  previewt sofort weiter). Das Undo-System ist auf eine Operation zur Zeit ausgelegt
--/  (das Spiel prüft selbst: Assert(not api.undo.IsPreviewingChangeList(), ...)).
--/
--/  Was der Guard macht (ohne Änderungen an pc2mp.replay.lua):
--/  1. nil-Tokens erreichen die nativen Funktionen nie (IsOperationComplete/CanCommitPreview/
--/     CommitPreview/CancelPreview/GetCommitFailReasons/CanCommitPreviewApprox).
--/  2. Er merkt sich laufende Undo-Operationen des SPIELS (Preview/Commit/Cancel/Undo/Redo),
--/     bis das Spiel selbst IsOperationComplete == true gesehen hat (max. 2 s).
--/  3. Ruft unser Replay-Job api.undo.IsBusy() auf (das macht er vor jeder Preview), meldet
--/     der Guard "busy", solange eine Spiel-Operation läuft oder gerade (0,25 s) fertig wurde.
--/     Für das Spiel selbst bleibt IsBusy unverändert.
-----------------------------------------------------------------------
local global = _G
local api = global.api
local type = global.type
local pcall = global.pcall
local tostring = global.tostring
local pairs = global.pairs
local coroutine = global.coroutine
local require = global.require
local Log = require("pc2mp.log")

local UndoGuard = {}
UndoGuard.nPendingTimeout = 2.0   -- s: Spiel-Operation gilt spätestens dann als fertig
UndoGuard.nSettleTime = 0.25      -- s: nach Ende einer Spiel-Operation noch warten
UndoGuard.nNilBlocked = 0

-- Zustand global (pro Environment laufen Module neu, api.undo ist aber geteilt)
local function State()
    local s = api.pc2mp_undoguard
    if s == nil then
        s = { tPending = {}, nLastForeignEnd = -1000, tOrig = {} }
        api.pc2mp_undoguard = s
    end
    return s
end

local function Now()
    local ok, t = pcall(api.time.GetTotalTimeUnscaled)
    return ok and type(t) == "number" and t or 0
end

-- Läuft der Aufruf in unserem Replay-Job?
local function IsOwnCall()
    local okR, Replay = pcall(require, "pc2mp.replay")
    if not okR or type(Replay) ~= "table" then return false end
    local tJob = Replay.tCurrent
    if tJob == nil or tJob.co == nil then return false end
    return coroutine.running() == tJob.co
end

local function Prune(s, nNow)
    for tok, t0 in pairs(s.tPending) do
        if nNow - t0 > UndoGuard.nPendingTimeout then
            s.tPending[tok] = nil
            local nExpired = t0 + UndoGuard.nPendingTimeout
            if nExpired > s.nLastForeignEnd then s.nLastForeignEnd = nExpired end
        end
    end
end

-- true, solange eine Undo-Operation des Spiels läuft oder gerade beendet wurde.
function UndoGuard.IsForeignActive()
    local s = State()
    local nNow = Now()
    Prune(s, nNow)
    if global.next(s.tPending) ~= nil then return true end
    return (nNow - s.nLastForeignEnd) < UndoGuard.nSettleTime
end

local function TrackForeign(waitToken)
    if waitToken == nil or IsOwnCall() then return end
    State().tPending[waitToken] = Now()
end

local function NilBlocked(sName)
    UndoGuard.nNilBlocked = UndoGuard.nNilBlocked + 1
    if UndoGuard.nNilBlocked <= 20 then
        Log.Write("UndoGuard: " .. sName .. "(nil) abgefangen (" .. (IsOwnCall() and "Replay" or "Spiel") .. ")")
    end
end

function UndoGuard.Install()
    local s = State()
    local undo = api.undo
    if type(undo) ~= "table" then return false end
    if global.rawget(undo, "__pc2mpGuard") then return true end   -- diese api.undo-Tabelle ist schon geschützt
    s.tOrig = {}
    local o = s.tOrig
    for _, sName in global.ipairs({ "IsOperationComplete", "CanCommitPreview", "CanCommitPreviewApprox",
        "CommitPreview", "CancelPreview", "GetCommitFailReasons", "PreviewChangeList", "Undo", "Redo",
        "Operation_Undo", "IsBusy" }) do
        o[sName] = undo[sName]
    end

    if o.IsOperationComplete then
        undo.IsOperationComplete = function(tok, ...)
            if tok == nil then NilBlocked("IsOperationComplete"); return true end
            local b = o.IsOperationComplete(tok, ...)
            if b and s.tPending[tok] ~= nil then
                s.tPending[tok] = nil
                s.nLastForeignEnd = Now()
            end
            return b
        end
    end
    if o.CanCommitPreview then
        undo.CanCommitPreview = function(tok, ...)
            if tok == nil then NilBlocked("CanCommitPreview"); return false end
            return o.CanCommitPreview(tok, ...)
        end
    end
    if o.CanCommitPreviewApprox then
        undo.CanCommitPreviewApprox = function(tok, ...)
            if tok == nil then NilBlocked("CanCommitPreviewApprox"); return false end
            return o.CanCommitPreviewApprox(tok, ...)
        end
    end
    if o.GetCommitFailReasons then
        undo.GetCommitFailReasons = function(tok, ...)
            if tok == nil then NilBlocked("GetCommitFailReasons"); return {} end
            return o.GetCommitFailReasons(tok, ...)
        end
    end
    for _, sName in global.ipairs({ "CommitPreview", "CancelPreview" }) do
        local fn = o[sName]
        if fn then
            undo[sName] = function(tok, ...)
                if tok == nil then NilBlocked(sName); return nil end
                local w = fn(tok, ...)
                TrackForeign(w)
                return w
            end
        end
    end
    if o.PreviewChangeList then
        undo.PreviewChangeList = function(...)
            local bOwn = IsOwnCall()
            if bOwn then
                local okP, bPrev = pcall(api.undo.IsPreviewingChangeList)
                if okP and bPrev then
                    Log.Write("UndoGuard: Replay startet Preview, waehrend das Spiel previewt")
                end
            end
            local w, p = o.PreviewChangeList(...)
            if w == nil then Log.Write("UndoGuard: PreviewChangeList lieferte keinen Token (" .. (bOwn and "Replay" or "Spiel") .. ")") end
            TrackForeign(w)
            return w, p
        end
    end
    for _, sName in global.ipairs({ "Undo", "Redo", "Operation_Undo" }) do
        local fn = o[sName]
        if fn then
            undo[sName] = function(...)
                local tRet = global.table.pack(fn(...))
                local t1 = type(tRet[1])
                if t1 == "userdata" or t1 == "table" then TrackForeign(tRet[1]) end
                return global.table.unpack(tRet, 1, tRet.n)
            end
        end
    end
    if o.IsBusy then
        undo.IsBusy = function(...)
            local b = o.IsBusy(...)
            if b then return b end
            if IsOwnCall() and UndoGuard.IsForeignActive() then return true end
            return b
        end
    end
    global.rawset(undo, "__pc2mpGuard", true)
    Log.Write("UndoGuard installiert")
    return true
end

return UndoGuard
