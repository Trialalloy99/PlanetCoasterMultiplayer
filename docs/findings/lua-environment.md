# Finding: Lua-Umgebung & Exe von Planet Coaster 2

Stand 2026-11-06, agent:maxi.

## Exe
- `PlanetCoaster2.exe` ist **geschützt/verschlüsselt** (Sections `.xcode` ~235 MB, `.arch`, `.code` leer).
  Statische Analyse des Maschinencodes (Ghidra/rea) ist daher sehr mühsam → **wir arbeiten auf Lua-Ebene.**

## Lua
- Lua 5.3, **von Frontier modifiziert**: Bytecode-Header Format-Byte = 2 (statt 0), `lua_Number` = float (4 Byte),
  `lua_Integer` = 8 Byte. luadec aus Cobra Tools kann es dekompilieren.
- Laufzeit-Layout (aus ACSEDebug.dll für Planet Zoo, **für PC2 noch per Ingame-Test zu bestätigen**):
  TValue = 0x18 Byte, Typ-Tag bei +0x10; `lua_State`: `top` +0x10, `ci` +0x20; `CallInfo.func` +0x00;
  TString: tt +0x08, shrlen +0x0B, lnglen +0x10, Daten +0x18.
- `package.loadlib`, `package.cpath`, `searchers` existieren als Strings in der Exe.
- In Mod-Code sind Standard-Globals nicht automatisch importiert → `local x = global.x`.

## Logging
- `api.debug.WriteStringToFile` und `api.debug.Trace` erzeugen in der Retail-Version **keine Ausgabe**
  (1. Ingame-Test, keine Datei gefunden).
- Lösung: eigene DLL `PC2MPNative.dll` (`native/`), Log nach `Win64/ovldata/PC2MP/PC2MP_native.log`.

## Vorsicht
- Wrapping der Methoden in Metatables nativer Objekte (UndoOperationsHierarchy) → vermutlich
  **Crash beim Beenden** des Spiels (AV in der Exe). Nicht mehr machen, bis geklärt.
- Nützlich: `api.json.Stringify` existiert → Aktionen als JSON serialisieren.
