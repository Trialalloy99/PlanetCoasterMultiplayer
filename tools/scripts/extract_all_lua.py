"""Extract and decompile every .lua from all Planet Coaster 2 OVLs.

Usage: <cobra-tools venv python> extract_all_lua.py <ovldata_dir> <out_dir>
Output: <out_dir>/<ovl relative path>/<name>.lua (decompiled) and .lua.bin
"""
import os
import sys
import logging
import traceback

COBRA = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "cobra-tools"))
sys.path.insert(0, COBRA)
os.chdir(COBRA)

from utils.logs import logging_setup  # noqa: E402
logging_setup("extract_all_lua")
from generated.formats.ovl import OvlFile  # noqa: E402

logging.getLogger().setLevel(logging.ERROR)

SKIP_DIRS = {"ACSE", "ForgeUtils"}


def main():
    src, out = sys.argv[1], sys.argv[2]
    ovls = []
    for root, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        ovls += [os.path.join(root, f) for f in files if f.lower().endswith(".ovl")]
    ovls.sort()
    total = 0
    for i, path in enumerate(ovls, 1):
        rel = os.path.splitext(os.path.relpath(path, src))[0]
        try:
            ovl = OvlFile()
            ovl.cfg["lua_decompile"] = True
            ovl.load(path, {"game": "Planet Coaster 2"})
            names = [f.name for f in ovl.loaders.values() if f.name.lower().endswith(".lua")] \
                if hasattr(ovl, "loaders") else None
            if names is not None and not names:
                continue
            dst = os.path.join(out, rel)
            os.makedirs(dst, exist_ok=True)
            ovl.extract(dst, only_types=[".lua"])
            n = sum(1 for f in os.listdir(dst) if f.endswith(".lua") or f.endswith(".lua.bin"))
            if n == 0:
                os.rmdir(dst)
            total += n
            print(f"[{i}/{len(ovls)}] {rel}: {n}", flush=True)
        except Exception as e:
            print(f"[{i}/{len(ovls)}] {rel}: ERROR {e!r}", flush=True)
            traceback.print_exc(limit=1)
    print(f"DONE total lua files: {total}", flush=True)


if __name__ == "__main__":
    main()
