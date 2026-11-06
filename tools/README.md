# Tools

## Spiel-Lua entpacken + dekompilieren (lokal, NICHT committen)

```bash
# 1. Cobra Tools klonen
git clone --depth 1 https://github.com/OpenNaja/cobra-tools.git tools/cobra-tools
# 2. Python-3.11-venv (Cobra Tools verlangt exakt 3.11), z. B. mit uv:
cd tools/cobra-tools
uv venv -p 3.11 .venv
uv pip install -p .venv/Scripts/python.exe "imageio>=2.26.0" "numpy>=1.26.4,<2.0.0" "pillow>=10.0.1" "bitarray~=2.9.2" vdf
cd ../..
# 3. Alles extrahieren (~20-30 min, ~21k dekompilierte .lua)
tools/cobra-tools/.venv/Scripts/python.exe tools/scripts/extract_all_lua.py \
  "C:/Program Files (x86)/Steam/steamapps/common/Planet Coaster 2/Win64/ovldata" gamelua
```

Der meiste Spiel-Code liegt in `gamelua/Content0/Main/` (Dateinamen = Modulnamen, z. B. `editors.scenery.submodeplacement.lua`).
Dekompilieren schlägt bei einigen Dateien fehl (meist Prefab/VFX-Daten), dann gibt es nur `.lua.bin`.
