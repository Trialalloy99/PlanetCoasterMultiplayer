@echo off
rem PC2MP Dev-UI starten (installiert Electron beim ersten Mal)
cd /d "%~dp0"
set "EXE=node_modules\electron\dist\electron.exe"
if not exist node_modules\electron (
  echo Installiere Electron ^(einmalig^)...
  call npm install --no-audit --no-fund || (echo npm fehlt? Node.js installieren: https://nodejs.org & pause & exit /b 1)
)
rem Electrons eigener Entpacker scheitert mit neuen Node-Versionen (z. B. v26) still:
rem dann liegt nur "locales" in dist. Fallback: Archiv aus dem Electron-Cache selbst entpacken.
if not exist "%EXE%" (
  echo electron.exe fehlt, lade/entpacke Electron neu...
  call node node_modules\electron\install.js
)
if not exist "%EXE%" (
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$v = (Get-Content 'node_modules\electron\package.json' -Raw | ConvertFrom-Json).version;" ^
    "$z = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'electron\Cache') -Recurse -Filter ('electron-v' + $v + '-win32-x64.zip') -ErrorAction SilentlyContinue | Select-Object -First 1;" ^
    "if (-not $z) { Write-Host ('Electron-Archiv v' + $v + ' nicht im Cache gefunden'); exit 1 }" ^
    "Expand-Archive -Force $z.FullName 'node_modules\electron\dist';" ^
    "Set-Content -NoNewline -Path 'node_modules\electron\path.txt' -Value 'electron.exe'"
)
if not exist "%EXE%" (
  echo.
  echo FEHLER: Electron konnte nicht installiert werden. Ordner devui\node_modules loeschen und neu starten.
  pause
  exit /b 1
)
start "" "%EXE%" .
