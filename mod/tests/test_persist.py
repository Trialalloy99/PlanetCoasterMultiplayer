"""Test von pc2mp.persist in echter Lua 5.3 (lupa), ohne Spiel.
Mockt die DLL (package.loadlib), api.json, api.time und worldserialisation/placement inkl.
Umnummerierung der IDs beim Laden eines Spielstands.
usage: python mod/tests/test_persist.py
"""
import json
import os
import struct
import sys
import lupa.lua53 as lua53

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'PC2MP', 'Main')).replace('\\', '/')
L = lua53.LuaRuntime(unpack_returned_tuples=True)
fails = []


def check(c, m):
    print(('ok   ' if c else 'FAIL ') + m)
    if not c:
        fails.append(m)


files = {}
mode = {'fallback': False, 'slot': b''}


def py_from_lua(v):
    if lua53.lua_type(v) == "table":
        keys = list(v.keys())
        if keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
            return [py_from_lua(v[k]) for k in sorted(keys)]
        return {str(k): py_from_lua(v[k]) for k in keys}
    return v




def stringify(t):
    return True, json.dumps(py_from_lua(t))


def parse(s):
    try:
        return True, L.table_from(json.loads(s), recursive=True)
    except Exception:
        return False, None


def ret_str(s):
    if s is None:
        return None
    if mode['fallback']:
        mode['slot'] = s.encode() if isinstance(s, str) else s
        return len(mode['slot'])
    return s


def dll(name):
    def write_file(n, d):
        if n.startswith('.') or '/' in n or '\\' in n:
            return 0
        files[n] = d
        return 1

    def read_i64(i):
        b = mode['slot'][(i - 1) * 8:(i - 1) * 8 + 8].ljust(8, b'\0')
        return struct.unpack('<q', b)[0]
    tbl = {
        'pc2mp_write_file': write_file,
        'pc2mp_read_file': lambda n: ret_str(files.get(n)),
        'pc2mp_file_error': lambda: None,
        'pc2mp_read_i64': read_i64,
        'pc2mp_saves_dir': lambda: ret_str('C:/Saves/'),
        'pc2mp_save_list': lambda: ret_str('[{"name":"a.park2","size":5,"mtime":1}]'),
        'pc2mp_save_info': lambda n: ret_str('{"name":"a.park2","size":5,"sha256":"ab","chunks":1,"chunkSize":524288}'),
        'pc2mp_save_read_chunk': lambda n, i: ret_str('QUJD'),
        'pc2mp_save_write_chunk': lambda n, i, b: 1,
        'pc2mp_save_finish': lambda n, h: 1,
        'pc2mp_save_abort': lambda n: None,
    }
    return tbl.get(name)


L.globals().PYDLL = dll
L.globals().PYSTRINGIFY = stringify
L.globals().PYPARSE = parse
L.execute(r'''
local ROOT = [[%s]]
table.insert(package.searchers, 2, function(name)
  local path = ROOT .. "/" .. name .. ".lua"
  local f = io.open(path, "r"); if not f then return "\n\tno file " .. path end; f:close()
  return loadfile(path), path
end)
NOW = 0
LOG = {}
package.loaded["pc2mp.log"] = { Write = function(s) LOG[#LOG + 1] = s end }
package.loadlib = function(path, sym) local f = PYDLL(sym); if not f then return nil end; return function(...) return f(...) end end
api = { time = { GetTotalTimeUnscaled = function() return NOW end },
        json = { Stringify = function(t) return PYSTRINGIFY(t) end, Parse = function(s) return PYPARSE(s) end } }
Persist = require("pc2mp.persist")
''' % ROOT)

# Dateinamen
check(L.eval('Persist.FileNameFor("multiplayer test")') == 'state_multiplayer_test.json', 'Parkname -> sicherer Dateiname')
_evil = L.eval('Persist.FileNameFor("../../evil")')
check('..' not in _evil and '/' not in _evil and '\\' not in _evil and _evil.startswith('state_'), '../ wird entschaerft: ' + _evil)

# Save / Load
L.execute('OK = Persist.Save("Park A", { lastSeq = 42, map = { n1 = 20166, n2 = 20168 } })')
check(L.eval('OK') is True and 'state_Park_A.json' in files, 'Save schreibt state_Park_A.json')
if L.eval('OK') is not True:
    print('   Log:', list(L.eval('LOG').values()), 'Dateien:', list(files))
L.execute('T = Persist.Load("Park A")')
check(L.eval('T.lastSeq') == 42 and L.eval('T.map.n1') == 20166 and L.eval('T.map.n2') == 20168, 'Load liest lastSeq + map zurueck')
check(L.eval('Persist.Load("unbekannt")') is None, 'fehlende Datei -> nil')

# Fallback-Modus der DLL (Strings als Laenge + read_i64)
mode['fallback'] = True
L.execute('T2 = Persist.Load("Park A")')
check(L.eval('T2 and T2.lastSeq') == 42 and L.eval('T2.map.n2') == 20168, 'Load funktioniert auch im Chunk-Fallback')
check(L.eval('Persist.SavesDir()') == 'C:/Saves/', 'SavesDir im Fallback')
mode['fallback'] = False

# Drosselung
files.clear()
L.execute('NOW = 100; Persist.MarkDirty("P", {lastSeq=1, map={}}); Persist.Tick()')
check(json.loads(files['state_P.json'])['lastSeq'] == 1, 'erster Tick schreibt sofort')
L.execute('NOW = 100.3; Persist.MarkDirty("P", {lastSeq=2, map={}}); Persist.Tick()')
check(json.loads(files['state_P.json'])['lastSeq'] == 1, 'innerhalb 1 s nicht erneut geschrieben')
L.execute('NOW = 101.2; Persist.Tick()')
check(json.loads(files['state_P.json'])['lastSeq'] == 2, 'nach 1 s der neueste Zustand')
L.execute('NOW = 101.3; Persist.MarkDirty("P", {lastSeq=3, map={}}); Persist.Flush()')
check(json.loads(files['state_P.json'])['lastSeq'] == 3, 'Flush schreibt sofort')

# Spielstand-Client: speichern, Spiel nummeriert beim Laden um, Mapping zeigt auf neue partIDs
L.execute(r'''
-- vor dem Speichern: partID -> entityID
local part2ent = { [20166] = 9001, [20168] = 9002 }
SAVED = nil
WS = {
  RegisterWorldSerialisationClient = function(self, name, ver, fnSave, fnLoad, fnOld)
    CLIENT = { name = name, save = fnSave, load = fnLoad } end,
  UnregisterWorldSerialisationClient = function() end,
  SaveEntityID = function(self, e) return "S" .. e end,           -- Spiel serialisiert eigene IDs
  LoadEntityID = function(self, s) return ({ S9001 = 7001, S9002 = 7002 })[s] end,  -- neue Entity-IDs
}
PL = {
  PlacementIDToEntityID = function(self, p) return part2ent[p] end,
  EntityIDToPlacementID = function(self, e) if not READY then return nil end return ({ [7001] = 31001, [7002] = 31002 })[e] end,
}
Persist.RegisterSaveClient({ worldserialisation = WS, placement = PL },
  function() return { lastSeq = 77, map = { n1 = 20166, n2 = 20168, nX = 99999 } } end,
  function(t) LOADED = t end)
local tSave = {}
CLIENT.save(tSave)
SAVED = tSave
CLIENT.load(tSave, 1)
R1 = Persist.ResolveLoaded()
READY = true
R2 = Persist.ResolveLoaded()
''')
check(L.eval('CLIENT.name') == 'PC2MPSync', 'Client "PC2MPSync" registriert')
check(L.eval('#SAVED.tEntries') == 2, 'nur Objekte mit Entity gespeichert (geloeschtes nX ausgelassen)')
check(L.eval('R1') is False and L.eval('R2') is True, 'wartet, bis die Entities wieder partIDs haben')
check(L.eval('LOADED.lastSeq') == 77 and L.eval('LOADED.map.n1') == 31001 and L.eval('LOADED.map.n2') == 31002,
      'nach Laden zeigen netIds auf die NEUEN partIDs (31001/31002)')

# Transfer-Wrapper
check(L.eval('Persist.SaveList()[1].name') == 'a.park2', 'SaveList parst JSON')
check(L.eval('Persist.SaveInfo("a.park2").chunks') == 1, 'SaveInfo parst JSON')
check(L.eval('Persist.WriteSaveChunk("a.park2", 0, "QUJD")') is True, 'WriteSaveChunk -> true')

print('\nALLE PERSIST-TESTS OK' if not fails else f'\n{len(fails)} FEHLER')
sys.exit(1 if fails else 0)
