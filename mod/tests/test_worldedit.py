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
TQ = {}; TQ.__index = TQ
function TQ.FromOrPos(q, v) return setmetatable({ pos = v }, TQ) end
function TQ:GetPos() return self.pos end
function TQ:WithPos(v) return TQ.FromOrPos(nil, v) end
package.loaded["TransformQ"] = TQ
package.loaded["Quaternion"] = { Identity = "QID" }
local MO = {}; MO.__index = MO
function MO:GetTransform() return self.t end
function MO:SetTransform(t) self.t = t; SET_T = (SET_T or 0) + 1 end
function MO:GetPosition() return self.t:GetPos() end
local vm = {}
function vm:CreateMoveObjectForVolumeOutline(c, h, o, p, g) VOL_CALLS[#VOL_CALLS + 1] = { c = c, o = o, p = p, g = g }; return setmetatable({}, MO) end
function vm:CreateMoveObjectForVolumeSpline(h, t, bc, bcl, bra, bst) local mo = setmetatable({ t = t }, MO); SPLINES = SPLINES or {}; SPLINES[#SPLINES + 1] = { mo = mo, start = t, bStub = bst }; return mo end
function vm:SetSplinePathData(mo, ...) mo.path = { ... } end
function vm:SetSplineBuildingOptions(mo, ...) mo.opts = { ... } end
function vm:SetSplineControlPoint(mo, v) mo.cps = mo.cps or {}; mo.cps[#mo.cps + 1] = v end
function vm:CanSetSplineControlPoint(mo) return true end
function vm:GetSplineResultData(mo) return true, mo.t0 or mo.t:GetPos(), mo.t:GetPos() end
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
check(v.get('op') == 'volume' and len(v.get('outlines', [])) == 1 and v['outlines'][0]['prio'] == 3, 'Umriss mit Priorität erfasst')
L.execute('VOL_CALLS = {}; WE.Apply(ACTIONS[2], 25); Replay.Run()')
check(L.eval('#VOL_CALLS') == 1 and L.eval('VOL_CALLS[1].p') == 3 and L.eval('VOL_CALLS[1].o[1]:X()') == 26,
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

# --- Fälle aus dem Ingame-Test 2026-11-07 ---
# 1) nur Kollisions-Flags (Szenerie-Platzierung) -> KEINE Terrain-Aktion
L.execute(r"""
N0 = #ACTIONS
local clh = editors:CreateUndoOperationsHierarchy()
gameterrain:SetTerrainEditOpCollisionFlags(clh:GetTerrainEditOperation(), true, false, false, true, false, false)
local w, p = api.undo.PreviewChangeList(clh:GetFullUndoChangeList())
api.undo.CommitPreview(p)
NOW = NOW + 1; WE.Tick()
""")
check(L.eval('#ACTIONS') == L.eval('N0'), 'nur Flags (Szenerie) -> keine leere Terrain-Aktion')

# 2) Aktion wie vom Netz: api.json-Format mit String-Schlüsseln
net = {"op": "terrain", "flags": {"1": True, "2": False, "3": False, "4": False, "5": False, "6": False},
       "calls": {"1": {"m": "AddSmoothToChangeList", "a": {"1": "op", "2": {"v3": {"1": 5, "2": 1, "3": 7}}, "3": 30, "4": 1, "5": 1}},
                 "2": {"m": "AddSmoothToChangeList", "a": {"1": "op", "2": {"v3": {"1": 6, "2": 1, "3": 7}}, "3": 30, "4": 1, "5": 1}}}}
L.globals().NET = L.table_from(net, recursive=True)
L.execute('GT_CALLS = {}; R_OK = nil; WE.Apply(NET, 0, function(ok, r) R_OK = r end); Replay.Run()')
sm = [c for c in to_py(L.eval('GT_CALLS')) if c[0] == 'smooth']
check(len(sm) == 2 and L.eval('R_OK') is True, 'Netz-Aktion mit String-Schlüsseln wird angewendet (2 Stempel)')
check(L.eval('GT_CALLS[2][3]:X()') == 5, 'Position aus Netz-Aktion korrekt')

# 3) Spline-Weg: Stub (wird abgebrochen), echter Spline mit Kontrollpunkt, Commit
L.execute(r"""
N1 = #ACTIONS
local h0 = editors:CreateUndoOperationsHierarchy()
local stub = volumes:CreateMoveObjectForVolumeSpline(h0, TQ.FromOrPos(nil, V:new(0,0,0)), true, false, false, true)
local w0, p0 = api.undo.PreviewChangeList(h0:GetFullUndoChangeList())
api.undo.CancelPreview(p0)
local h = editors:CreateUndoOperationsHierarchy()
local mo = volumes:CreateMoveObjectForVolumeSpline(h, TQ.FromOrPos(nil, V:new(10,0,10)), true, false, false, false)
volumes:SetSplinePathData(mo, "Tarmac", "Render", "Edge", 2.0, 0.2, 3, 1, true)
local w, p = api.undo.PreviewChangeList(h:GetFullUndoChangeList())
for i = 1, 5 do volumes:SetSplineBuildingOptions(mo, false, true, false, 1); mo:SetTransform(TQ.FromOrPos(nil, V:new(10 + i, 0, 10))) end
volumes:SetSplineControlPoint(mo, V:new(15, 0, 10))
for i = 1, 5 do mo:SetTransform(TQ.FromOrPos(nil, V:new(15, 0, 10 + i))) end
api.undo.CommitPreview(p)
""")
check(L.eval('#ACTIONS') == L.eval('N1') + 1, 'Spline-Weg -> genau eine Aktion (Stub ignoriert)')
sp = to_py(L.eval('ACTIONS[#ACTIONS]'))
spl = (sp.get('splines') or [{}])[0]
check(sp.get('op') == 'volume' and spl.get('start') == {'tq': {'v3': [10, 0, 10]}} and spl.get('end') == {'v3': [15, 0, 15]},
      'Spline: Start (Transform) und Ende erfasst: %s / %s' % (spl.get('start'), spl.get('end')))
check(spl.get('cps') == [{'v3': [15, 0, 10]}] and (spl.get('pathData') or [None])[0] == 'Tarmac' and spl.get('buildOpts') == [False, True, False, 1],
      'Spline: Kontrollpunkt, Weg-Stil, Bau-Optionen erfasst')
L.execute('SPLINES = {}; SET_T = 0; R_SP = nil; WE.Apply(ACTIONS[#ACTIONS], 25, function(ok, r) R_SP = r end); Replay.Run()')
check(L.eval('R_SP') is True and L.eval('#SPLINES') == 1, 'Spline-Nachbau: Commit ok, ein neuer Spline')
check(L.eval('SPLINES[1].start:GetPos():X()') == 35 and L.eval('SPLINES[1].mo.path[1]') == 'Tarmac', 'Nachbau-Start mit Versatz, Stil übernommen')
check(L.eval('SPLINES[1].mo.cps[1]:X()') == 40 and L.eval('SPLINES[1].mo:GetPosition():X()') == 40 and L.eval('SPLINES[1].mo:GetPosition():Z()') == 15,
      'Nachbau: Kontrollpunkt + Ende mit Versatz')
check(L.eval('#ACTIONS') == L.eval('N1') + 1, 'Spline-Nachbau nicht erneut erfasst')

# Pool-Werkzeug: Randweg-Ring mit LOKALEN Punkten, Composite an die Mausposition verschoben (#23)
L.execute(r"""
package.loaded["Quaternion"].FromPackedAxisAngle = function(v) return { packed = v } end
local COMP = {}; COMP.__index = COMP
function COMP:GetTransform() return self.t end
function COMP:SetTransform(t) self.t = t; self.calls[#self.calls + 1] = "SetTransform" end
function COMP:SetCompositeOriginToOBBCentre() self.calls[#self.calls + 1] = "Origin" end
function COMP:AlignCompositeRotation() self.calls[#self.calls + 1] = "Align" end
COMPS = {}
local fnOldClh = editors.CreateUndoOperationsHierarchy
rawset(editors, "CreateUndoOperationsHierarchy", function(self)
  local h = fnOldClh(self)
  h.CreateCompositeObject = function() local c = setmetatable({ calls = {} }, COMP); COMPS[#COMPS + 1] = c; return c end
  return h
end)
N2 = #ACTIONS
local clh = editors:CreateUndoOperationsHierarchy()
clh:BeginVolumeModificationsBlock()
local comp = clh:CreateCompositeObject({})
volumes:CreateMoveObjectForVolumeOutline(comp, clh, { sOutlineType = "Path", sRenderType = "DefaultPoolPath",
  { vPos = V:new(-6,0,-6), sEdgeType = "DefaultPoolPathEdge" }, { vPos = V:new(6,0,-6), sEdgeType = "DefaultPoolPathEdge" },
  { vPos = V:new(6,0,6), sEdgeType = "DefaultPoolPathEdge" } }, 4, 0)
clh:EndVolumeModificationsBlock()
local tr = TQ.FromOrPos(nil, V:new(-397, 1, -71))
tr.GetOr = function() return { ToPackedAxisAngle = function() return V:new(0, 1.5, 0) end } end
comp.t = tr
local w, p = api.undo.PreviewChangeList(clh:GetFullUndoChangeList())
api.undo.CommitPreview(p)
""")
pr = to_py(L.eval('ACTIONS[#ACTIONS]'))
o0 = (pr.get('outlines') or [{}])[0]
xf = o0.get('xf')
check(L.eval('#ACTIONS') == L.eval('N2') + 1 and xf == {'pos': [-397, 1, -71], 'rot': [0, 1.5, 0]},
      'Pool-Randweg: Endlage des Composites erfasst: %s' % (xf,))
check('comp' not in o0, 'Composite-Userdata wird nicht gesendet')
L.execute('COMPS = {}; R_PR = nil; WE.Apply(ACTIONS[#ACTIONS], 0, function(ok, r) R_PR = r end); Replay.Run()')
calls = to_py(L.eval('COMPS[1].calls'))
check(calls == ['Origin', 'Align', 'SetTransform'], 'Nachbau wie VolumeMoveMode: Ursprung, Ausrichten, Endlage (%s)' % (calls,))
check(L.eval('COMPS[1].t:GetPos():X()') == -397 and L.eval('COMPS[1].t:GetPos():Z()') == -71, 'Nachbau an der richtigen Stelle')
L.execute(r"""
local clh = editors:CreateUndoOperationsHierarchy()
clh:BeginVolumeModificationsBlock()
volumes:CreateMoveObjectForVolumeOutline(clh:CreateCompositeObject({}), clh, { V:new(1,0,1), V:new(4,0,1) }, 3, 1)
clh:EndVolumeModificationsBlock()
local w, p = api.undo.PreviewChangeList(clh:GetFullUndoChangeList())
api.undo.CommitPreview(p)
""")
dr = to_py(L.eval('ACTIONS[#ACTIONS]'))
check((dr.get('outlines') or [{}])[0].get('xf') is None, 'gezeichneter Weg (nicht verschoben): keine Endlage angehängt')

print('\nALLE WORLDEDIT-TESTS OK' if not fails else f'\n{len(fails)} FEHLER')
sys.exit(1 if fails else 0)
