#!/usr/bin/env python3
"""Mini-Testclient (ersetzt das Spiel) zum manuellen Testen des Servers bzw. der Netzwerk-DLL.

    python server/fake_client.py --name Bot            # verbinden, alles Empfangene ausgeben
    python server/fake_client.py --name Bot --tree     # zusätzlich eine Beispiel-Aktion senden
Eingaben auf stdin werden als Chat gesendet.
"""
import argparse
import asyncio
import json
import sys


async def main(a):
    r, w = await asyncio.open_connection(a.host, a.port, limit=4 * 1024 * 1024)

    def send(m):
        w.write((json.dumps(m) + "\n").encode())

    send({"t": "hello", "v": 1, "name": a.name, "park": "test", "lastSeq": a.last_seq})
    if a.tree:
        send({"t": "action", "cseq": 1, "action": {
            "op": "commit", "calls": [{"m": "CreateNewPart", "a": {"1": "ExampleTree"}}],
            "objects": [{"partID": 1, "pos": [0, 0, 0], "rot": [0, 0, 0], "scale": 1}]}})
    await w.drain()

    async def reader():
        while line := await r.readline():
            print("<-", line.decode().rstrip()[:500], flush=True)
        print("Verbindung geschlossen")

    async def stdin():
        loop = asyncio.get_running_loop()
        while True:
            text = await loop.run_in_executor(None, sys.stdin.readline)
            if not text:
                return
            send({"t": "chat", "text": text.strip()})
            await w.drain()

    await asyncio.gather(reader(), stdin())


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=7777)
    p.add_argument("--name", default="fake")
    p.add_argument("--last-seq", type=int, default=0)
    p.add_argument("--tree", action="store_true")
    asyncio.run(main(p.parse_args()))
