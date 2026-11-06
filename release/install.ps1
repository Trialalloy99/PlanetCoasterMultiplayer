# PC2MP-Mod installieren: kopiert den Ordner PC2MP nach <Planet Coaster 2>\Win64\ovldata\PC2MP
# Aufruf: Rechtsklick -> "Mit PowerShell ausführen", oder install.bat doppelklicken.
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Find-Game {
    $candidates = @()
    $steamRoots = @("${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam")
    try {
        $reg = Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction Stop
        if ($reg.SteamPath) { $steamRoots += ($reg.SteamPath -replace "/", "\") }
    } catch {}
    foreach ($root in $steamRoots | Select-Object -Unique) {
        $vdf = Join-Path $root "steamapps\libraryfolders.vdf"
        $libs = @($root)
        if (Test-Path $vdf) {
            Select-String -Path $vdf -Pattern '"path"\s+"(.+)"' | ForEach-Object {
                $libs += ($_.Matches[0].Groups[1].Value -replace "\\\\", "\")
            }
        }
        foreach ($lib in $libs) { $candidates += (Join-Path $lib "steamapps\common\Planet Coaster 2") }
    }
    foreach ($c in $candidates | Select-Object -Unique) {
        if (Test-Path (Join-Path $c "PlanetCoaster2.exe")) { return $c }
    }
    return $null
}

$game = Find-Game
if (-not $game) {
    $game = Read-Host "Planet Coaster 2 nicht gefunden. Bitte Spielordner eingeben (dort liegt PlanetCoaster2.exe)"
}
$ovl = Join-Path $game "Win64\ovldata"
if (-not (Test-Path $ovl)) { Write-Host "FEHLER: $ovl existiert nicht." -ForegroundColor Red; pause; exit 1 }

if (-not (Test-Path (Join-Path $ovl "ACSE\Manifest.xml"))) {
    Write-Host "ACHTUNG: ACSE ist nicht installiert! Ohne ACSE wird die Mod nicht geladen." -ForegroundColor Yellow
    Write-Host "  -> https://www.nexusmods.com/planetcoaster2/mods/1 herunterladen und den Ordner ACSE nach" -ForegroundColor Yellow
    Write-Host "     $ovl kopieren." -ForegroundColor Yellow
}

if (Get-Process -Name "PlanetCoaster2" -ErrorAction SilentlyContinue) {
    Write-Host "Bitte Planet Coaster 2 zuerst schließen." -ForegroundColor Red; pause; exit 1
}

$dest = Join-Path $ovl "PC2MP"
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $here "PC2MP\*") $dest -Force
Write-Host "PC2MP installiert nach: $dest" -ForegroundColor Green
Write-Host "Log-Datei (für Fehlersuche): $dest\PC2MP_native.log"
pause
