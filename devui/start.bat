@echo off
rem PC2MP Dev-UI starten (installiert Electron beim ersten Mal)
cd /d "%~dp0"
if not exist node_modules\electron (
  echo Installiere Electron ^(einmalig^)...
  call npm install --no-audit --no-fund || (echo npm fehlt? Node.js installieren: https://nodejs.org & pause & exit /b 1)
)
call npm start
