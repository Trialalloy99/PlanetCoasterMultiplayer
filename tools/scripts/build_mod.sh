#!/usr/bin/env bash
# Baut mod/PC2MP/Main -> Main.ovl und installiert die Mod nach ovldata/PC2MP.
# Usage: tools/scripts/build_mod.sh [GAME_DIR]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GAME="${1:-C:/Program Files (x86)/Steam/steamapps/common/Planet Coaster 2}"
MOD="$ROOT/mod/PC2MP"
BUILD="$ROOT/build/PC2MP"
PY="$ROOT/tools/cobra-tools/.venv/Scripts/python.exe"

rm -rf "$BUILD" && mkdir -p "$BUILD"
# Syntax-Check aller Lua-Dateien mit dem luac aus Cobra Tools
LUAC="$ROOT/tools/cobra-tools/modules/formats/utils/luadec/luac.exe"
for f in "$MOD"/Main/*.lua; do "$LUAC" -p "$f"; done

(cd "$ROOT/tools/cobra-tools" && "$PY" ovl_tool_cmd.py new -g "Planet Coaster 2" -i "$MOD/Main" -o "$BUILD/Main.ovl" -f)
cp "$MOD/Manifest.xml" "$BUILD/"

DEST="$GAME/Win64/ovldata/PC2MP"
mkdir -p "$DEST"
cp "$BUILD"/Main.ovl "$BUILD"/Manifest.xml "$DEST/"
ls "$BUILD"/*.ovs >/dev/null 2>&1 && cp "$BUILD"/*.ovs "$DEST/" || true
echo "Installiert nach: $DEST"
ls -la "$DEST"
