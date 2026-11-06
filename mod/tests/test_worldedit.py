"""Test von pc2mp.worldedit in echter Lua 5.3 (lupa), ohne Spiel.
Simuliert den Ablauf aus Editors.Terrain.TerrainEditMode (pro Frame: Hierarchy, Flags, Add*ToChangeList,
PreviewChangeList, CommitPreview) und einen gezeichneten Weg; prüft Erfassung, Bündelung,
Spiegel-Nachbau mit Versatz und dass eigene Replays nicht erneut erfasst werden.
usage: python mod/tests/test_worldedit.py
"""
import json
import os
import sys
import lupa.lua53 as lua53

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'PC2MP', 'Main')).replace('\\', '/')
L = lua53.LuaRuntime(unpack_returned_tuples=True)
fails = []


def check(c, m):
    print(('ok   ' if c else 'FAIL ') + m)
    if not c:
        fails.append(m)


def to_py(v):
    if lua53.lua_type(v) == 'table':
        keys = list(v.keys())
        if keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
            return [to_py(v[k]) for k in sorted(keys)]
        return {str(k): to_py(v[k]) for k in keys}
    return v


L.globals().PYSTRINGIFY = lambda t: (True, json.dumps(to_py(t)))
L.execute(r'''
local ROOT = [[%s]]
table.insert(package.searchers, 2, function(name)
  local path = ROOT .. "/" .. name .. ".lua"
  local f = io.open(path, "r"); if not f then return "\n\tno file " .. path end; f:close()
  return loadfile(path), path
end)
NOW = 0
LOG = {}
package.loaded["pc2mp.log"] = { Write = function(s) LOG[#LOG + 1] = s end, ToStr = tostring }
-- Vector3 wie im Spiel: Objekt mit :X() :Y() :Z()
V = {}; V.__index = V
function V:new(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end
function V:X() return self.x end; function V:Y() return self.y end; function V:Z() return self.z end
package.loaded["Vector3"] = V
-- Replay mit Coroutine-Jobs (wie pc2mp.replay)
Replay = { tQueue = {}, tCurrent = nil }
function Replay.Enqueue(l, fn, done) table.insert(Replay.tQueue, { co = coroutine.create(fn), done = done }) end
function Replay.Run()
  while #Replay.tQueue > 0 do
    local j = table.remove(Replay.tQueue, 1); Replay.tCurrent = j
    local ok, r
    repeat ok, r = coroutine.resume(j.co) until coroutine.status(j.co) == "dead"
    Replay.tCurrent = nil
    if j.done then j.done(ok, r) end
  end
end
package.loaded["pc2mp.replay"] = Replay
-- Undo-Mock
local tok = 0
local function T() tok = tok + 1; return setmetatable({ id = tok }, { __tostring = function() return "tok" end }) end
api = {
  time = { GetTotalTimeUnscaled = function() return NOW end },
  json = { Stringify = function(t) return PYSTRINGIFY(t) end },
  undo = {
    PreviewChangeList = function(cl) return T(), T() end,
    CommitPreview = function(p) COMMITS = (COMMITS or 0) + 1; return T() end,
    CancelPreview = function(p) return T() end,
    IsOperationComplete = function() return true end,
    CanCommitPreview = function() return true end,
    IsBusy = function() return false end,
    Checkpoint = function() end,
    GetCommitFailReasons = function() return {} end,
  },
}
-- Spiel-APIs: Methoden über Metatable (wie native Objekte)
GT_CALLS = {}
local gtm = {}
function gtm:SetTerrainEditOpCollisionFlags(op, ...) GT_CALLS[#GT_CALLS + 1] = { "flags", op, ... } end
function gtm:AddSmoothToChangeList(op, v, s, i, h) GT_CALLS[#GT_CALLS + 1] = { "smooth", op, v, s, i, h } end
gameterrain = setmetatable({}, { __index = gtm })
VOL_CALLS = {}
local vm = {}
function vm:CreateMoveObjectForVolumeOutline(c, h, o, p, g) VOL_CALLS[#VOL_CALLS + 1] = { c = c, o = o, p = p, g = g }; return newproxy and newproxy(true) or io.stdout end
function vm:GetVolumeOutlinesFromMoveObject(mo) return { { sRenderType = "Tarmac", nClipPriority = 3, nGroundedRequest = 1, tPoints = { V:new(1, 0, 1), V:new(4, 0, 1), V:new(4, 0, 5) } } } end
volumes = setmetatable({}, { __index = vm })
local hm = {}
function hm:GetTerrainEditOperation() return "OP" end
function hm:GetFullUndoChangeList() return "CL" end
function hm:BeginVolumeModificationsBlock() end
function hm:EndVolumeModificationsBlock() end
function hm:CreateCompositeObject() return "COMPOSITE" end
editors = setmetatable({}, { __index = { CreateUndoOperationsHierarchy = function() return setmetatable({}, { __index = hm }) end } })
TW = { gameterrain = gameterrain, volumes = volumes, editors = editors }
WE = require("pc2mp.worldedit")
WE.Install(TW)
ACTIONS = {}
WE.AddListener(function(a) ACTIONS[#ACTIONS + 1] = a end)
-- Spieler malt 3 Frames lang (wie TerrainEditMode.AdvanceTerrainEdit + TryCommitTerrainPreviews)
for f = 1, 3 do
  NOW = NOW + 0.016
  local clh = editors:CreateUndoOperationsHierarchy()
  local op = clh:GetTerrainEditOperation()
  gameterrain:SetTerrainEditOpCollisionFlags(op, true, false, false, false, false, false)
  gameterrain:AddSmoothToChangeList(op, V:new(10 + f, 2, 20), 8, 0.5, 0.3)
  local w, p = api.undo.PreviewChangeList(clh:GetFullUndoChangeList())
  api.undo.CommitPreview(p)
end
AFTER_STROKE = #ACTIONS
NOW = NOW + 0.5
WE.Tick()
''' % ROOT)

check(L.eval('AFTER_STROKE') == 0, 'während des Strichs noch nichts gesendet (Bündelung)')
check(L.eval('#ACTIONS') == 1, '3 Stempel -> 1 Aktion nach 0,4 s Pause')
a = to_py(L.eval('ACTIONS[1]'))
check(a.get('op') == 'terrain' and len(a.get('calls', [])) == 3, 'Aktion: op=terrain, 3 Aufrufe')
check(a['calls'][0]['m'] == 'AddSmoothToChangeList' and a['calls'][0]['a'][1] == {'v3': [11, 2, 20]}, 'Position als v3 serialisiert')
check(a.get('flags') == [True, False, False, False, False, False], 'Kollisions-Flags ohne op-Handle')

# Spiegel-Nachbau
L.execute('GT_CALLS = {}; WE.Apply(ACTIONS[1], 25); Replay.Run()')
calls = to_py(L.eval('GT_CALLS'))
smooth = [c for c in calls if c[0] == 'smooth']
check(len(smooth) == 3 and smooth[0][1] == 'OP', 'Nachbau: 3x AddSmooth auf neuer Operation')
check(L.eval('GT_CALLS[2][3]:X()') == 36 and L.eval('GT_CALLS[2][3]:Z()') == 20, 'Versatz x+25 angewendet (11 -> 36)')
check(L.eval('#ACTIONS') == 1, 'eigener Nachbau wird nicht erneut erfasst (keine Endlosschleife)')

# Weg zeichnen -> Umrisse beim Commit
L.execute(r'''
local clh = editors:CreateUndoOperationsHierarchy()
clh:BeginVolumeModificationsBlock()
volumes:CreateMoveObjectForVolumeOutline(clh:CreateCompositeObject({}), clh, { V:new(1,0,1), V:new(4,0,1), V:new(4,0,5) }, 3, 1)
clh:EndVolumeModificationsBlock()
local w, p = api.undo.PreviewChangeList(clh:GetFullUndoChangeList())
api.undo.CommitPreview(p)
''')
check(L.eval('#ACTIONS') == 2, 'Weg -> sofort eine Aktion')
v = to_py(L.eval('ACTIONS[2]'))
check(v.get('op') == 'volume' and len(v.get('outlines', [])) == 1 and v['outlines'][0]['sRenderType'] == 'Tarmac', 'Umriss mit sRenderType erfasst')
L.execute('VOL_CALLS = {}; WE.Apply(ACTIONS[2], 25); Replay.Run()')
check(L.eval('#VOL_CALLS') == 1 and L.eval('VOL_CALLS[1].p') == 3 and L.eval('VOL_CALLS[1].o.tPoints[1]:X()') == 26,
      'Weg-Nachbau: Umriss mit Versatz, Priorität übernommen')
check(L.eval('#ACTIONS') == 2, 'Weg-Nachbau nicht erneut erfasst')

# abgebrochene Preview wird nicht gesendet
L.execute(r'''
local clh = editors:CreateUndoOperationsHierarchy()
gameterrain:AddSmoothToChangeList(clh:GetTerrainEditOperation(), V:new(0,0,0), 1, 1, 1)
local w, p = api.undo.PreviewChangeList(clh:GetFullUndoChangeList())
api.undo.CancelPreview(p)
NOW = NOW + 1; WE.Tick()
''')
check(L.eval('#ACTIONS') == 2, 'abgebrochene Preview -> nichts gesendet')

print('\nALLE WORLDEDIT-TESTS OK' if not fails else f'\n{len(fails)} FEHLER')
sys.exit(1 if fails else 0)
