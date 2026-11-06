-----------------------------------------------------------------------
--/  PC2MP Netzwerk: Lua-Seite der PC2MPNative.dll (#10).
--/  Alles nicht-blockierend: Send() reiht ein, Poll() holt die naechste
--/  empfangene Nachricht (oder nil). Protokoll: eine JSON-Nachricht pro Zeile.
--/  Die TCP-Verbindung lebt in der DLL und ueberlebt Environment-Wechsel.
-----------------------------------------------------------------------
local global = _G
local api = global.api
local type = global.type
local pcall = global.pcall
local tostring = global.tostring
local string = global.string
local table = global.table

local Net = {}

Net.sDllPath = ".\\Win64\\ovldata\\PC2MP\\PC2MPNative.dll"
Net.tFns = nil
Net.sError = nil
Net.bStrings = false     -- true: DLL gibt Strings direkt zurueck (luaS_newlstr gefunden)

Net.Status_Idle = 0
Net.Status_Connecting = 1
Net.Status_Connected = 2
Net.Status_RetryWait = 3
local tStatusNames = { [0] = "idle", "connecting", "connected", "retry" }

local tExports = {
    "pc2mp_init", "pc2mp_info", "pc2mp_read_i64",
    "pc2mp_net_connect", "pc2mp_net_disconnect", "pc2mp_net_send",
    "pc2mp_net_poll", "pc2mp_net_status", "pc2mp_net_error",
}

-- Laedt alle Exporte; true bei Erfolg.
function Net.Init()
    if Net.tFns then return true end
    if Net.sError then return false end
    local pkg = global.package
    if type(pkg) ~= "table" or type(pkg.loadlib) ~= "function" then
        Net.sError = "package.loadlib nicht verfuegbar"
        return false
    end
    local tFns = {}
    for _, sName in global.ipairs(tExports) do
        local ok, fn, sErr = pcall(pkg.loadlib, Net.sDllPath, sName)
        if not ok or type(fn) ~= "function" then
            Net.sError = "loadlib " .. sName .. ": " .. tostring(fn) .. " " .. tostring(sErr)
            return false
        end
        tFns[sName] = fn
    end
    Net.tFns = tFns
    local ok, nStrings = pcall(tFns.pc2mp_init)
    Net.bStrings = ok and nStrings == 1
    return true
end

-- Wandelt eine DLL-Rueckgabe in einen String (Fallback: Laenge + 8-Byte-Chunks).
local function ToLuaString(v)
    if type(v) ~= "number" then return v end
    local nLen = v
    local tParts = {}
    for i = 1, (nLen + 7) // 8 do
        tParts[i] = string.pack("<i8", Net.tFns.pc2mp_read_i64(i))
    end
    return string.sub(table.concat(tParts), 1, nLen)
end

function Net.Info()
    if not Net.Init() then return "PC2MPNative nicht geladen: " .. tostring(Net.sError) end
    local ok, v = pcall(Net.tFns.pc2mp_info)
    if not ok then return "pc2mp_info Fehler: " .. tostring(v) end
    return ToLuaString(v) .. (Net.bStrings and "" or " [Chunk-Fallback]")
end

function Net.Connect(sHost, nPort)
    if not Net.Init() then return false end
    local ok, n = pcall(Net.tFns.pc2mp_net_connect, sHost, global.math.tointeger(nPort) or nPort)
    return ok and n == 1
end

function Net.Disconnect()
    if Net.tFns then pcall(Net.tFns.pc2mp_net_disconnect) end
end

-- Sendet einen String oder eine Tabelle (wird per api.json.Stringify serialisiert).
function Net.Send(msg)
    if not Net.Init() then return false end
    local sMsg = msg
    if type(msg) == "table" then
        local okJ, bOk, sJson = pcall(api.json.Stringify, msg)
        if not (okJ and bOk and type(sJson) == "string") then return false end
        sMsg = sJson
    end
    if type(sMsg) ~= "string" then return false end
    local ok, n = pcall(Net.tFns.pc2mp_net_send, sMsg)
    return ok and n == 1
end

-- Naechste Nachricht als String oder nil.
function Net.Poll()
    if not Net.tFns then return nil end
    local ok, v = pcall(Net.tFns.pc2mp_net_poll)
    if not ok or v == nil then return nil end
    return ToLuaString(v)
end

-- Naechste Nachricht als Tabelle (api.json.Parse) oder nil; sRaw als 2. Rueckgabe.
function Net.PollTable()
    local s = Net.Poll()
    if s == nil then return nil end
    local ok, bOk, t = pcall(api.json.Parse, s)
    if ok and bOk and type(t) == "table" then return t, s end
    return false, s
end

-- Holt bis zu nMax Nachrichten und ruft fnHandler(tMsg, sRaw) (fuer Manager:Advance).
function Net.Pump(fnHandler, nMax)
    for _ = 1, nMax or 32 do
        local t, sRaw = Net.PollTable()
        if t == nil then return end
        fnHandler(t or nil, sRaw)
    end
end

-- sStatus ("idle"/"connecting"/"connected"/"retry"), nWartendEin, nWartendAus
function Net.Status()
    if not Net.tFns then return "unloaded", 0, 0 end
    local ok, n, nIn, nOut = pcall(Net.tFns.pc2mp_net_status)
    if not ok then return "error", 0, 0 end
    return tStatusNames[n] or tostring(n), nIn, nOut
end

function Net.IsConnected()
    return (Net.Status()) == "connected"
end

function Net.LastError()
    if not Net.tFns then return Net.sError end
    local ok, v = pcall(Net.tFns.pc2mp_net_error)
    if not ok or v == nil then return nil end
    return ToLuaString(v)
end

return Net
