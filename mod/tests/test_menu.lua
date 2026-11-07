-- Offline-Test für pc2mp.menu (Dev-UI-Steuerung) mit gemockten Spiel-APIs.
-- Ausführen:  tools/cobra-tools/modules/formats/utils/luadec/lua.exe mod/tests/test_menu.lua mod/PC2MP/Main
local MAIN = arg[1] or "mod/PC2MP/Main"
local files = {}
REG = {}
local function J(t) local k = "#" .. tostring(t); REG[k] = t; return k end
local function S(n) return REG[files[n]] end
local loaded = nil
local calls = 0
local plm = { LoadParkFromSaveToken = function(self, tok) loaded = tok; return true end }
api = {
    pc2mp = nil,
    json = {
        -- JSON-Mock: Tabelle in Registry ablegen, String-Schlüssel zurückgeben
        Stringify = function(t) local k = "#" .. tostring(t); REG[k] = t; return true, k end,
        Parse = function(s) return REG[s] ~= nil, REG[s] end,
    },
    player = { HasGameOwner = function() return true end, GetGameOwner = function() return "owner" end },
    save = {
        GetExistingSaves_SortMostRecentFirst = 1,
        GetExistingSaves = function() calls = calls + 1
            if calls < 3 then return true, false, nil end
            return true, true, { "TOK_A", "TOK_B" } end,
        GetSaveCustomName = function(t) return ({ TOK_A = "test2", TOK_B = "alt" })[t] end,
        GetSaveIdentifier = function(t) return ({ TOK_A = "A1", TOK_B = "B2" })[t] end,
        GetSaveMetadata = function() return { tSave = { sWorldName = "W" } } end,
    },
    game = { GetEnvironment = function() return { RequireInterface = function() return plm end } end },
}
package.preload["pc2mp.log"] = function() return { Write = function(s) print("  log: " .. s) end } end
package.preload["pc2mp.persist"] = function()
    return { WriteData = function(n, s) files[n] = s; return true end, ReadData = function(n) return files[n] end }
end
local Menu = assert(loadfile(MAIN .. "/pc2mp.menu.lua"))("pc2mp.menu")
local function check(c, msg) if not c then error("FEHLER: " .. msg, 2) end print("ok  " .. msg) end
local function tick(n, src) for _ = 1, n or 1 do Menu.Tick(src or "manager") end end

files["ui_cmd.json"] = J({ id = 5, cmd = "load", save = "A1" })   -- alter Befehl vom letzten Spielstart
tick(40)
check(#Menu.tSaves == 2 and Menu.tSaves[1].name == "test2" and Menu.tSaves[1].id == "A1", "Welten aufgelistet")
check(loaded == nil, "alter Befehl beim Start wird nicht ausgeführt")
check(S("ui_state.json") and S("ui_state.json").mode == "menu", "Status geschrieben (Hauptmenü)")

files["ui_cmd.json"] = J({ id = 6, cmd = "load", save = "A1" })
tick(30)
check(loaded == "TOK_A", "Laden-Befehl lädt die Welt")
check(S("ui_state.json").cmd.id == 6 and S("ui_state.json").cmd.ok == true, "Ergebnis im Status")
tick(30)
check(loaded == "TOK_A" and Menu.nLastCmdId == 6, "Befehl wird nur einmal ausgeführt")

files["ui_cmd.json"] = J({ id = 7, cmd = "load", save = "XX" })
tick(30)
check(S("ui_state.json").cmd.ok == false, "unbekannte Welt -> Fehler im Status")

local n = Menu.nFrame
tick(5, "plm-hook")
check(Menu.nFrame == n, "Fallback-Hook tickt nicht doppelt, wenn der Manager läuft")
api.pc2mp = { bInPark = true }
tick(30)
check(S("ui_state.json").mode == "park", "Modus park erkannt")
print("\nALLE MENU-TESTS OK")
