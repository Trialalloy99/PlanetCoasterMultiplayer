-----------------------------------------------------------------------
--/  PC2MP logger: schreibt in eine Datei (api.debug.WriteStringToFile)
--/  und zusätzlich per api.debug.Trace.
-----------------------------------------------------------------------
local global = _G
local api = global.api
local type = global.type
local tostring = global.tostring
local pairs = global.pairs
local pcall = global.pcall
local string = global.string
local table = global.table

local Log = {}

-- Relativ zum Arbeitsverzeichnis des Spiels (vermutlich Spielordner).
Log.sFile = "PC2MP_log.txt"
Log.bFileWorks = nil

function Log.ToStr(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == "string" then
        return string.format("%q", v)
    elseif t == "table" then
        if depth > 1 then return "{...}" end
        local parts = {}
        local n = 0
        for k, val in pairs(v) do
            n = n + 1
            if n > 12 then
                table.insert(parts, "...")
                break
            end
            table.insert(parts, tostring(k) .. "=" .. Log.ToStr(val, depth + 1))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    elseif t == "userdata" then
        local ok, s = pcall(tostring, v)
        return "<ud " .. (ok and s or "?") .. ">"
    else
        return tostring(v)
    end
end

function Log.Args(...)
    local n = global.select("#", ...)
    local parts = {}
    for i = 1, n do
        table.insert(parts, Log.ToStr((global.select(i, ...))))
    end
    return table.concat(parts, ", ")
end

-- Native DLL (PC2MPNative.dll) laden: Pfad relativ zum Spielordner, wie bei ACSEDebug.
Log.sDllPath = ".\\Win64\\ovldata\\PC2MP\\PC2MPNative.dll"
Log.fnNative = nil
Log.sNativeError = nil

function Log.InitNative()
    if Log.fnNative ~= nil or Log.sNativeError ~= nil then return end
    local pkg = global.package
    if type(pkg) ~= "table" or type(pkg.loadlib) ~= "function" then
        Log.sNativeError = "package.loadlib nicht verfuegbar"
        return
    end
    local ok, fn, sErr, sWhere = pcall(pkg.loadlib, Log.sDllPath, "pc2mp_log")
    if ok and type(fn) == "function" then
        Log.fnNative = fn
        local okPing, fnPing = pcall(pkg.loadlib, Log.sDllPath, "pc2mp_ping")
        if okPing and type(fnPing) == "function" then
            local okCall, nPong = pcall(fnPing)
            pcall(fn, "[PC2MP] ping -> " .. tostring(okCall) .. " " .. tostring(nPong))
        end
    else
        Log.sNativeError = "loadlib fehlgeschlagen: " .. tostring(fn) .. " " .. tostring(sErr) .. " " .. tostring(sWhere)
    end
end

function Log.Write(sMsg)
    local sLine = "[PC2MP] " .. tostring(sMsg)
    Log.InitNative()
    if Log.fnNative then
        pcall(Log.fnNative, sLine)
    end
    if api.debug and api.debug.Trace then
        pcall(api.debug.Trace, sLine)
    end
    if Log.bFileWorks ~= false and api.debug and api.debug.WriteStringToFile then
        local ok, bSuccess = pcall(api.debug.WriteStringToFile, sLine .. "\n", Log.sFile, true)
        if Log.bFileWorks == nil then
            Log.bFileWorks = (ok and bSuccess) and true or false
        end
    end
end

return Log
