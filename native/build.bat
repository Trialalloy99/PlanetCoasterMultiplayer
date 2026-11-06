@echo off
rem Baut native\PC2MPNative.dll mit MSVC (x64). Aufruf: native\build.bat
setlocal
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq tokens=*" %%i in (`call "%%VSWHERE%%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%i"
if not defined VSDIR (echo MSVC nicht gefunden & exit /b 1)
call "%VSDIR%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
set ROOT=%~dp0..
if not exist "%ROOT%\build\native" mkdir "%ROOT%\build\native"
cl /nologo /O2 /W4 /MT /LD /D_CRT_SECURE_NO_WARNINGS "%~dp0pc2mp_native.c" /Fo"%ROOT%\build\native\\" /Fe"%ROOT%\build\native\PC2MPNative.dll" /link /NOLOGO || exit /b 1
echo OK: %ROOT%\build\native\PC2MPNative.dll
