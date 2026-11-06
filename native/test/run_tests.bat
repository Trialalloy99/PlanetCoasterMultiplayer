@echo off
rem Tests der nativen Bruecke ohne Spiel (braucht zig wie in native\build.bat, plus Python).
rem   1. test_resolve: Signatursuche gegen die echte PlanetCoaster2.exe (wird nur gemappt, nicht gestartet)
rem   2. test_bridge : Fake-lua_State + TCP-Echo-Server (Strings, Fallback, Zeilenumbrueche, kaputtes Layout)
rem   3. test_server_client: gegen server\pc2mp_server.py, Server-Neustart -> Auto-Reconnect + Hello + Catch-up
setlocal
set "ROOT=%~dp0..\.."
set "OUT=%ROOT%\build\native"
set "GAME=%~1"
if "%GAME%"=="" set "GAME=C:\Program Files (x86)\Steam\steamapps\common\Planet Coaster 2\PlanetCoaster2.exe"
call "%~dp0..\build.bat" || exit /b 1
for /f "usebackq tokens=*" %%z in (`where zig.exe 2^>nul`) do if not defined ZIG set "ZIG=%%z"
if not defined ZIG for /d %%d in ("%ROOT%\tools\zig*" "%ROOT%\..\tools\zig*") do if exist "%%d\zig.exe" set "ZIG=%%d\zig.exe"
set "N=%~dp0.."
"%ZIG%" cc -target x86_64-windows-gnu -O2 -o "%OUT%\test_resolve.exe" "%~dp0test_resolve.c" "%N%\resolve.c" || exit /b 1
"%ZIG%" cc -target x86_64-windows-gnu -O2 -DPC2MP_TEST -shared -o "%OUT%\PC2MPNative_test.dll" "%N%\pc2mp_native.c" "%N%\resolve.c" "%N%\net.c" "%N%\files.c" -lws2_32 -lbcrypt -lshell32 -lole32 || exit /b 1
"%ZIG%" cc -target x86_64-windows-gnu -O1 -o "%OUT%\test_bridge.exe" "%~dp0test_bridge.c" || exit /b 1

echo === test_resolve
"%OUT%\test_resolve.exe" "%GAME%" || (echo FEHLER: Signaturen nicht gefunden - Spiel-Update? & set FAILED=1)
echo === test_bridge
start "" /b python "%~dp0echo_server.py" 37777 --once
ping -n 2 127.0.0.1 >nul
"%OUT%\test_bridge.exe" "%OUT%\PC2MPNative_test.dll" 37777 || set FAILED=1
echo === test_server_client (echter server\pc2mp_server.py inkl. Neustart/Reconnect)
"%ZIG%" cc -target x86_64-windows-gnu -O1 -o "%OUT%\test_server_client.exe" "%~dp0test_server_client.c" || exit /b 1
python "%~dp0test_with_server.py" "%OUT%\test_server_client.exe" "%OUT%\PC2MPNative_test.dll" || set FAILED=1
echo === test_files (Datendateien + Spielstand-Transfer, nur Temp-Ordner)
"%ZIG%" cc -target x86_64-windows-gnu -O1 -o "%OUT%\test_files.exe" "%~dp0test_files.c" || exit /b 1
python "%~dp0test_with_files.py" "%OUT%\test_files.exe" "%OUT%\PC2MPNative_test.dll" || set FAILED=1
if defined FAILED exit /b 1
echo ALLE NATIVEN TESTS OK
