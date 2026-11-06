#!/usr/bin/env bash
# Baut mod/PC2MP/Main -> Main.ovl + PC2MPNative.dll nach build/PC2MP,
# installiert nach ovldata/PC2MP (wenn das Spiel läuft und die DLL sperrt: nur Warnung)
# und packt optional ein Release-Zip.
# Usage: tools/scripts/build_mod.sh [--no-install] [--zip] [GAME_DIR]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL=1; ZIP=0
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --no-install) INSTALL=0 ;;
        --zip) ZIP=1 ;;
    esac
    shift
done
GAME="${1:-C:/Program Files (x86)/Steam/steamapps/common/Planet Coaster 2}"
MOD="$ROOT/mod/PC2MP"
BUILD="$ROOT/build/PC2MP"
PY="$ROOT/tools/cobra-tools/.venv/Scripts/python.exe"

rm -rf "$BUILD" && mkdir -p "$BUILD"
# Syntax-Check aller Lua-Dateien mit dem luac aus Cobra Tools
LUAC="$ROOT/tools/cobra-tools/modules/formats/utils/luadec/luac.exe"
for f in "$MOD"/Main/*.lua; do "$LUAC" -p "$f"; done

(cd "$ROOT/tools/cobra-tools" && "$PY" ovl_tool_cmd.py new -g "Planet Coaster 2" -i "$MOD/Main" -o "$BUILD/Main.ovl" -f) >/dev/null
cp "$MOD/Manifest.xml" "$BUILD/"

# Native DLL bauen (MSVC oder zig) und beilegen
cmd //c "$(cygpath -w "$ROOT/native/build.bat")" | grep -E "^OK|rror" || true
cp "$ROOT/build/native/PC2MPNative.dll" "$BUILD/"
echo "Gebaut: $BUILD"

if [[ $INSTALL == 1 ]]; then
    DEST="$GAME/Win64/ovldata/PC2MP"
    mkdir -p "$DEST"
    for f in Main.ovl Manifest.xml PC2MPNative.dll; do
        cp "$BUILD/$f" "$DEST/" 2>/dev/null || echo "WARNUNG: $f nicht kopiert (Spiel läuft?)"
    done
    echo "Installiert nach: $DEST"
fi

if [[ $ZIP == 1 ]]; then
    REL="$ROOT/build/release"
    rm -rf "$REL" && mkdir -p "$REL/PC2MP-Mod"
    cp -r "$BUILD" "$REL/PC2MP-Mod/PC2MP"
    cp "$ROOT/release/install.ps1" "$ROOT/release/INSTALL.md" "$ROOT/release/install.bat" "$REL/PC2MP-Mod/"
    (cd "$REL" && powershell -NoProfile -Command "Compress-Archive -Path 'PC2MP-Mod' -DestinationPath 'PC2MP-Mod.zip' -Force")
    echo "Release-Zip: $REL/PC2MP-Mod.zip"
fi
