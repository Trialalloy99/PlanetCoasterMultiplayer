@echo off
rem Baut build\native\PC2MPNative.dll (x64).
rem   1. MSVC, falls installiert (vswhere)
rem   2. sonst zig cc: %ZIG% oder zig.exe im PATH oder tools\zig*\zig.exe (neben dem Repo / im Repo)
rem Aufruf: native\build.bat          (Test-DLL + Tests: native\test\run_tests.bat)
setlocal
set "ROOT=%~dp0.."
set "SRC=%~dp0pc2mp_native.c %~dp0resolve.c %~dp0net.c"
if not exist "%ROOT%\build\native" mkdir "%ROOT%\build\native"

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "%VSWHERE%" (
  for /f "usebackq tokens=*" %%i in (`call "%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%i"
)
if defined VSDIR (
  call "%VSDIR%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
  cl /nologo /O2 /W4 /MT /LD /D_CRT_SECURE_NO_WARNINGS %SRC% ws2_32.lib /Fo"%ROOT%\build\native\\" /Fe"%ROOT%\build\native\PC2MPNative.dll" /link /NOLOGO || exit /b 1
  echo OK ^(MSVC^): %ROOT%\build\native\PC2MPNative.dll
  exit /b 0
)

call :findzig
if not defined ZIG (echo Weder MSVC noch zig gefunden. zig: https://ziglang.org/download/ entpacken und ZIG=...\zig.exe setzen & exit /b 1)
"%ZIG%" cc -target x86_64-windows-gnu -O2 -Wall -Wextra -shared -o "%ROOT%\build\native\PC2MPNative.dll" %SRC% -lws2_32 || exit /b 1
echo OK ^(zig^): %ROOT%\build\native\PC2MPNative.dll
exit /b 0

:findzig
if defined ZIG if exist "%ZIG%" exit /b 0
set "ZIG="
for /f "usebackq tokens=*" %%z in (`where zig.exe 2^>nul`) do if not defined ZIG set "ZIG=%%z"
if defined ZIG exit /b 0
for /d %%d in ("%ROOT%\tools\zig*" "%ROOT%\..\tools\zig*") do if exist "%%d\zig.exe" set "ZIG=%%d\zig.exe"
exit /b 0
