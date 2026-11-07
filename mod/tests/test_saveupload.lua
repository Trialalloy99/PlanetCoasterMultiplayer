-- Offline-Test für pc2mp.saveupload (Upload nach Speichern + Quick-Save) mit Mocks.
-- Ausführen:  tools/cobra-tools/modules/formats/utils/luadec/lua.exe mod/tests/test_saveupload.lua mod/PC2MP/Main
local MAIN = arg[1] or "mod/PC2MP/Main"
local busy = false
local saved = 0
local files = { { name = "a-11111111.park2", mtime = 100, size = 10 }, { name = "b-22222222.park2", mtime = 50, size = 20 } }
local plm = {
    cLastActiveParkSaveToken = "TOK",
    GenerateCurrentParkMetaData = function() return {} end,
    SaveParkToSaveToken = function(self, tok, _, _, _, bWait)
        coroutine.yield() -- wie das Spiel: wartet auf das Ende
        saved = saved + 1
        table.insert(files, 1, { name = "b-22222222.park2", mtime = 200, size = 25 })
        table.remove(files, 3)
        return true, tok
    end,
}
api = {
    save = { IsBusy = function() return busy end },
    game = { GetEnvironment = function() return { RequireInterface = function() return plm end } end },
}
package.preload["pc2mp.log"] = function() return { Write = function(s) print("  log: " .. s) end } end
local SU = assert(loadfile(MAIN .. "/pc2mp.saveupload.lua"))("pc2mp.saveupload")
local sent = {}
SU.fnSend = function(m) sent[#sent + 1] = m; return true end
SU.Persist = {
    SaveList = function() local t = {}; for i, f in ipairs(files) do t[i] = f end; return t end,
    SaveInfo = function(n) return { name = n, size = 25, sha256 = "abc", chunks = 2 } end,
    ReadSaveChunk = function(n, i) return "DATA" .. i end,
}
SU.nPollEvery = 1
local function check(c, msg) if not c then error("FEHLER: " .. msg, 2) end print("ok  " .. msg) end
local function tick(n) for _ = 1, n or 1 do SU.Tick() end end

-- 1. normales Speichern
SU.OnSaveStarted(42)
tick(3)
check(#sent == 0, "ohne geänderte Datei kein Upload")
files[1] = { name = "a-11111111.park2", mtime = 300, size = 11 }
busy = true
tick(3)
check(#sent == 0, "solange api.save beschäftigt ist, kein Upload")
busy = false
tick(2)
check(sent[1] and sent[1].t == "saveUpload" and sent[1].seq == 42 and sent[1].name == "a-11111111.park2", "geänderte Datei wird mit seq hochgeladen")
tick(5)
check(sent[2].t == "saveChunk" and sent[2].data == "DATA0" and sent[3].i == 1 and sent[4].t == "saveEnd", "Teile + Ende gesendet")
check(SU.tJob == nil, "Auftrag erledigt")

-- 2. Quick-Save
sent = {}
SU.QuickSave(77)
tick(10)
check(saved == 1, "Quick-Save speichert über ParkLoadSaveManager")
check(sent[1] and sent[1].t == "saveUpload" and sent[1].name == "b-22222222.park2" and sent[1].seq == 77, "Quick-Save-Datei wird hochgeladen")
check(sent[#sent].t == "saveEnd", "Quick-Save-Upload fertig")

-- 3. Quick-Save ohne Spielstand -> Server bekommt quickSaveFailed
sent = {}
plm.cLastActiveParkSaveToken = nil
SU.QuickSave(80)
tick(2)
check(sent[1] and sent[1].t == "quickSaveFailed", "Fehler wird dem Server gemeldet")
print("\nALLE SAVEUPLOAD-TESTS OK")
