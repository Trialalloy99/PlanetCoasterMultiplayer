#!/usr/bin/env python3
"""Spielstand (.park2) über den PC2MP-Server austauschen, damit alle mit derselben Startwelt beginnen.

    python server/save_tool.py upload   --host <ip> [--port 7790] <datei.park2>
    python server/save_tool.py download --host <ip> [--port 7790] [--out <ordner>]
    python server/save_tool.py savesdir          # zeigt den lokalen Saves-Ordner von PC2

Ohne --out wird in den Saves-Ordner von Planet Coaster 2 gespeichert
(%USERPROFILE%\\Saved Games\\Frontier Developments\\Planet Coaster 2\\<steamid>\\Saves).
"""
import argparse
import asyncio
import base64
import hashlib
import json
import os
import sys
from pathlib import Path

CHUNK = 512 * 1024


def saves_dir() -> Path | None:
    root = Path(os.environ.get("USERPROFILE", "~")).expanduser() / "Saved Games" / "Frontier Developments" / "Planet Coaster 2"
    if not root.exists():
        return None
    cands = [p / "Saves" for p in root.iterdir() if p.is_dir() and (p / "Saves").is_dir()]
    if not cands:
        return None
    return max(cands, key=lambda p: max((f.stat().st_mtime for f in p.glob("*.park2")), default=0))


async def connect(host, port):
    r, w = await asyncio.wait_for(asyncio.open_connection(host, port, limit=8 * 1024 * 1024), 15)

    def send(m):
        w.write((json.dumps(m) + "\n").encode())

    async def recv():
        return json.loads(await asyncio.wait_for(r.readline(), 60))

    send({"t": "hello", "v": 1, "name": "save_tool", "park": "-", "lastSeq": 2 ** 62})
    while (m := await recv())["t"] != "caughtUp":
        pass
    return r, w, send, recv


async def upload(a):
    data = Path(a.file).read_bytes()
    sha = hashlib.sha256(data).hexdigest()
    r, w, send, recv = await connect(a.host, a.port)
    send({"t": "saveUpload", "seq": 0, "name": Path(a.file).name, "size": len(data), "sha256": sha})
    for i in range(0, len(data), CHUNK):
        send({"t": "saveChunk", "i": i // CHUNK, "data": base64.b64encode(data[i:i + CHUNK]).decode()})
        await w.drain()
    send({"t": "saveEnd"})
    await w.drain()
    while (m := await recv())["t"] not in ("saveStored", "error"):
        pass
    print("OK hochgeladen:" if m["t"] == "saveStored" else "FEHLER:", Path(a.file).name, len(data), "Bytes", m)
    w.close()


async def download(a):
    out = Path(a.out) if a.out else saves_dir()
    if out is None:
        sys.exit("Saves-Ordner nicht gefunden, bitte --out angeben")
    r, w, send, recv = await connect(a.host, a.port)
    send({"t": "saveRequest"})
    await w.drain()
    m = await recv()
    if m["t"] != "saveBegin":
        sys.exit(f"FEHLER: {m}")
    buf = bytearray()
    while (c := await recv())["t"] == "saveChunk":
        buf += base64.b64decode(c["data"])
    if hashlib.sha256(buf).hexdigest() != m["sha256"]:
        sys.exit("FEHLER: Prüfsumme stimmt nicht")
    out.mkdir(parents=True, exist_ok=True)
    target = out / m["name"]
    target.write_bytes(buf)
    print("OK gespeichert:", target, len(buf), "Bytes")
    w.close()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("cmd", choices=["upload", "download", "savesdir"])
    p.add_argument("file", nargs="?")
    p.add_argument("--host")
    p.add_argument("--port", type=int, default=7790)
    p.add_argument("--out")
    a = p.parse_args()
    if a.cmd == "savesdir":
        print(saves_dir())
        return
    if not a.host:
        sys.exit("--host fehlt")
    if a.cmd == "upload":
        if not a.file:
            sys.exit("Datei fehlt")
        asyncio.run(upload(a))
    else:
        asyncio.run(download(a))


if __name__ == "__main__":
    main()
