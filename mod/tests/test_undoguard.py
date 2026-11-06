"""Test von pc2mp.undoguard in echter Lua 5.3 (lupa), ohne Spiel.

Mockt api.undo so, wie sich das Spiel verhält: IsOperationComplete(nil) "stürzt ab"
(Lua-Fehler statt Access Violation), Operationen brauchen ein paar Frames.
Prüft: nil-Schutz, Tracking von Spiel-Operationen, IsBusy-Sperre nur für den Replay-Job.
usage: python mod/tests/test_undoguard.py
"""
import os
import sys
import lupa.lua53 as lua53

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'PC2MP', 'Main'))
L = lua53.LuaRuntime(unpack_returned_tuples=True)

# Wie im Spiel: Modulname = Dateiname mit Punkten (pc2mp.undoguard -> pc2mp.undoguard.lua)
L.execute(r'''
local ROOT = [[%s]]
table.insert(package.searchers, 2, function(name)
  local path = ROOT .. "/" .. name .. ".lua"
  local f = io.open(path, "r")
  if not f then return "\n\tno file " .. path end
  f:close()
  return loadfile(path), path
end)
''' % ROOT.replace('\\', '/'))

L.execute(r'''
-- ---- Mock-Umgebung -------------------------------------------------
NOW = 0.0
CRASHED = nil
local ops = {}          -- token -> fertig ab Zeitpunkt
local function newop(dt) local t = setmetatable({}, {__name = "token"}); ops[t] = NOW + dt; return t end
api = {
  time = { GetTotalTimeUnscaled = function() return NOW end },
  debug = {},
  undo = {
    IsOperationComplete = function(t)
      if t == nil then CRASHED = "IsOperationComplete(nil)"; error("NATIVE CRASH") end
      return NOW >= ops[t]
    end,
    CanCommitPreview = function(t) if t == nil then CRASHED = "CanCommitPreview(nil)"; error("NATIVE CRASH") end return true end,
    CanCommitPreviewApprox = function(t) return true end,
    GetCommitFailReasons = function(t) return {} end,
    PreviewChangeList = function(cl) if cl == "bad" then return nil, nil end return newop(0.05), newop(0) end,
    CommitPreview = function(t) if t == nil then CRASHED = "CommitPreview(nil)"; error("NATIVE CRASH") end return newop(0.05) end,
    CancelPreview = function(t) if t == nil then CRASHED = "CancelPreview(nil)"; error("NATIVE CRASH") end return newop(0.03) end,
    Undo = function() return newop(0.1) end,
    Redo = function() return newop(0.1) end,
    IsBusy = function() return false end,
    IsPreviewingChangeList = function() return false end,
  },
}
package.loaded["pc2mp.log"] = { Write = function(s) LOG[#LOG + 1] = s end, ToStr = tostring, Args = function(...) return "" end }
LOG = {}
''')

L.execute(r'''
Replay = { tCurrent = nil }
package.loaded["pc2mp.replay"] = Replay
Guard = require("pc2mp.undoguard")
assert(Guard.Install() == true)
assert(Guard.Install() == true)   -- zweites Install = no-op
''')

fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)
        print('FAIL', msg)
    else:
        print('ok  ', msg)


# 1) nil-Schutz (Spiel und Replay)
L.execute('''r1 = api.undo.IsOperationComplete(nil); r2 = api.undo.CanCommitPreview(nil);
             r3 = api.undo.CommitPreview(nil); r4 = api.undo.CancelPreview(nil)''')
check(L.eval('CRASHED') is None, 'nil-Token erreicht die native Funktion nie')
check(L.eval('r1') is True and L.eval('r2') is False and L.eval('r3') is None, 'nil -> complete=true, canCommit=false, commit=nil')

# 2) Spiel-Operation läuft -> Replay-Job sieht IsBusy=true, Spiel selbst nicht
L.execute('''
GAME_TOKEN = api.undo.CommitPreview({})      -- Spiel committet (Einfügen mehrerer Objekte)
local co = coroutine.create(function()
  while api.undo.IsBusy() do coroutine.yield("wait") end
  return "go"
end)
Replay.tCurrent = { co = co }
JOB = co
''')
check(L.eval('api.undo.IsBusy()') is False, 'Spiel selbst: IsBusy unverändert false')
st = L.eval('select(2, coroutine.resume(JOB))')
check(st == 'wait', 'Replay-Job wartet, solange die Spiel-Operation läuft')
L.execute('NOW = 0.06')   # Operation des Spiels ist intern fertig, aber das Spiel hat es noch nicht abgefragt
st = L.eval('select(2, coroutine.resume(JOB))')
check(st == 'wait', 'Replay wartet weiter, bis das Spiel selbst "fertig" gesehen hat')
L.execute('assert(api.undo.IsOperationComplete(GAME_TOKEN) == true)')   # Spiel pollt -> fertig
L.execute('NOW = 0.10')
st = L.eval('select(2, coroutine.resume(JOB))')
check(st == 'wait', 'Replay wartet noch die Nachlaufzeit (0,25 s)')
L.execute('NOW = 0.40')
st = L.eval('select(2, coroutine.resume(JOB))')
check(st == 'go', 'Replay startet nach Nachlaufzeit')

# 3) Spiel pollt nie -> Timeout gibt frei
L.execute('''
api.undo.Undo()
local co = coroutine.create(function()
  while api.undo.IsBusy() do coroutine.yield("wait") end
  return "go"
end)
Replay.tCurrent = { co = co }; JOB = co
''')
check(L.eval('select(2, coroutine.resume(JOB))') == 'wait', 'Undo des Spiels sperrt den Replay')
L.execute('NOW = 0.40 + 2.3')
check(L.eval('select(2, coroutine.resume(JOB))') == 'go', 'nach Timeout (2 s) + Nachlauf frei, kein Hänger')

# 4) Eigene Operationen werden nicht als "Spiel" gezählt
L.execute('''
local co = coroutine.create(function()
  local w, p = api.undo.PreviewChangeList("cl")
  coroutine.yield("previewed")
  while api.undo.IsBusy() do coroutine.yield("wait") end
  return "free"
end)
Replay.tCurrent = { co = co }; JOB = co
''')
L.execute('NOW = 10')
check(L.eval('select(2, coroutine.resume(JOB))') == 'previewed', 'Replay-Preview')
check(L.eval('select(2, coroutine.resume(JOB))') == 'free', 'eigene Preview sperrt den Replay nicht selbst')

# 5) Replay-Ablauf wie pc2mp.replay.PreviewAndCommit bei Preview ohne Token -> sauberer Abbruch
L.execute('''
local function WaitOp(t) while not api.undo.IsOperationComplete(t) do coroutine.yield() end end
local co = coroutine.create(function()
  while api.undo.IsBusy() do coroutine.yield() end
  local w, p = api.undo.PreviewChangeList("bad")
  WaitOp(w)
  local bCan = api.undo.CanCommitPreview(p)
  if bCan then WaitOp(api.undo.CommitPreview(p)) else WaitOp(api.undo.CancelPreview(p)) end
  return bCan
end)
Replay.tCurrent = { co = co }; JOB = co
OKR, RES = coroutine.resume(JOB)
''')
check(L.eval('OKR') is True and L.eval('RES') is False and L.eval('CRASHED') is None,
      'Preview ohne Token -> Job endet mit false statt Absturz')

print('\nLog:', list(L.eval('LOG').values())[:8])
print('\nALLE TESTS OK' if not fails else f'\n{len(fails)} FEHLER')
sys.exit(1 if fails else 0)
