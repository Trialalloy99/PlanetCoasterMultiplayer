#!/usr/bin/env python3
"""PC2MP Relay-Server (Protokoll: docs/protocol.md).

Nur Python-Standardbibliothek (>= 3.10). Start:
    python server/pc2mp_server.py --host 0.0.0.0 --port 7777 --data server/data --park "multiplayer test"
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import json
import logging
import os
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

PROTOCOL_VERSION = 1
MAX_LINE = 1024 * 1024
SAVE_CHUNK = 512 * 1024

log = logging.getLogger("pc2mp")


def _atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


class ParkStore:
    """Persistenz eines Parks: Aktionsprotokoll + Meta + Spielstand."""

    def __init__(self, root: Path):
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)
        self.actions_path = root / "actions.jsonl"
        self.meta_path = root / "meta.json"
        self.save_path = root / "save.park2"
        self.save_meta_path = root / "save.json"
        self.meta = {"serverSeq": 0, "nextNetId": 1}
        if self.meta_path.exists():
            self.meta.update(json.loads(self.meta_path.read_text("utf-8")))
        self._recover_seq()
        self._actions_file = open(self.actions_path, "a", encoding="utf-8")

    def _recover_seq(self) -> None:
        # Falls der Server zwischen Append und Meta-Write abgestürzt ist
        last = 0
        if self.actions_path.exists():
            with open(self.actions_path, encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line:
                        try:
                            last = max(last, int(json.loads(line).get("seq", 0)))
                        except (ValueError, json.JSONDecodeError):
                            log.warning("defekte Zeile in actions.jsonl ignoriert")
        self.meta["serverSeq"] = max(self.meta["serverSeq"], last)

    @property
    def seq(self) -> int:
        return self.meta["serverSeq"]

    def next_net_id(self) -> str:
        n = self.meta["nextNetId"]
        self.meta["nextNetId"] = n + 1
        return f"n{n}"

    def append_action(self, msg: dict) -> None:
        self.meta["serverSeq"] = msg["seq"]
        self._actions_file.write(json.dumps(msg, separators=(",", ":"), ensure_ascii=False) + "\n")
        self._actions_file.flush()
        os.fsync(self._actions_file.fileno())
        self.write_meta()

    def write_meta(self) -> None:
        _atomic_write(self.meta_path, json.dumps(self.meta, indent=2).encode("utf-8"))

    def actions_since(self, last_seq: int):
        if not self.actions_path.exists():
            return
        with open(self.actions_path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if msg.get("seq", 0) > last_seq:
                    yield msg

    def save_info(self) -> dict | None:
        if self.save_path.exists() and self.save_meta_path.exists():
            return json.loads(self.save_meta_path.read_text("utf-8"))
        return None

    def store_save(self, data: bytes, info: dict) -> None:
        _atomic_write(self.save_path, data)
        _atomic_write(self.save_meta_path, json.dumps(info, indent=2).encode("utf-8"))

    def close(self) -> None:
        self._actions_file.close()


@dataclass
class Client:
    client_id: str
    name: str
    writer: asyncio.StreamWriter
    upload: dict | None = None
    upload_chunks: list = field(default_factory=list)

    async def send(self, msg: dict) -> None:
        data = (json.dumps(msg, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")
        self.writer.write(data)
        await self.writer.drain()


class Server:
    def __init__(self, store: ParkStore, park: str):
        self.store = store
        self.park = park
        self.clients: dict[str, Client] = {}
        self._next_client = 1
        self._lock = asyncio.Lock()  # serialisiert seq-Vergabe + Broadcast

    # ---------------------------------------------------------------
    async def broadcast(self, msg: dict, exclude: str | None = None) -> None:
        for c in list(self.clients.values()):
            if c.client_id == exclude:
                continue
            try:
                await c.send(msg)
            except (ConnectionError, OSError):
                log.info("senden an %s fehlgeschlagen", c.client_id)

    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        peer = writer.get_extra_info("peername")
        client: Client | None = None
        try:
            line = await reader.readline()
            hello = json.loads(line) if line else None
            if not hello or hello.get("t") != "hello":
                await self._raw_send(writer, {"t": "error", "code": "protocol", "msg": "hello erwartet"})
                return
            if hello.get("v") != PROTOCOL_VERSION:
                await self._raw_send(writer, {"t": "error", "code": "version",
                                              "msg": f"Server spricht v{PROTOCOL_VERSION}"})
                return
            client = await self._register(hello, writer)
            log.info("%s verbunden als %s (%s)", peer, client.client_id, client.name)
            while True:
                line = await reader.readline()
                if not line:
                    break
                if len(line) > MAX_LINE:
                    await client.send({"t": "error", "code": "too_large", "msg": "Nachricht zu groß"})
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    await client.send({"t": "error", "code": "json", "msg": "ungültiges JSON"})
                    continue
                if not isinstance(msg, dict):
                    await client.send({"t": "error", "code": "json", "msg": "Objekt erwartet"})
                    continue
                await self.dispatch(client, msg)
        except (ConnectionError, asyncio.IncompleteReadError, OSError) as e:
            log.info("Verbindung %s beendet: %s", peer, e)
        except (ValueError, json.JSONDecodeError) as e:
            log.info("Protokollfehler von %s: %s", peer, e)
        finally:
            if client is not None:
                self.clients.pop(client.client_id, None)
                await self.broadcast({"t": "leave", "clientId": client.client_id})
                log.info("%s getrennt", client.client_id)
            writer.close()
            try:
                await writer.wait_closed()
            except (ConnectionError, OSError):
                pass

    async def _raw_send(self, writer, msg) -> None:
        writer.write((json.dumps(msg) + "\n").encode("utf-8"))
        await writer.drain()

    async def _register(self, hello: dict, writer) -> Client:
        async with self._lock:
            cid = f"c{self._next_client}"
            self._next_client += 1
            client = Client(cid, str(hello.get("name", cid))[:64], writer)
            others = [{"clientId": c.client_id, "name": c.name} for c in self.clients.values()]
            self.clients[cid] = client
            await client.send({
                "t": "welcome", "v": PROTOCOL_VERSION, "clientId": cid,
                "serverSeq": self.store.seq, "park": self.park, "clients": others,
                "hasSave": self.store.save_info() is not None,
            })
            # Catch-up innerhalb des Locks, damit keine neue Aktion dazwischenrutscht
            last = int(hello.get("lastSeq", 0) or 0)
            for msg in self.store.actions_since(last):
                await client.send(msg)
            await client.send({"t": "caughtUp", "serverSeq": self.store.seq})
        await self.broadcast({"t": "join", "clientId": cid, "name": client.name}, exclude=cid)
        return client

    # ---------------------------------------------------------------
    async def dispatch(self, c: Client, msg: dict) -> None:
        t = msg.get("t")
        if t == "action":
            await self.on_action(c, msg)
        elif t == "ping":
            await c.send({"t": "pong", "time": msg.get("time")})
        elif t == "chat":
            await self.broadcast({"t": "chat", "clientId": c.client_id, "name": c.name,
                                  "text": str(msg.get("text", ""))[:500]})
        elif t == "cursor":
            await self.broadcast({"t": "cursor", "clientId": c.client_id, "pos": msg.get("pos")},
                                 exclude=c.client_id)
        elif t == "saveUpload":
            c.upload = msg
            c.upload_chunks = []
        elif t == "saveChunk" and c.upload is not None:
            c.upload_chunks.append(base64.b64decode(msg.get("data", "")))
        elif t == "saveEnd" and c.upload is not None:
            await self.on_save_end(c)
        elif t == "saveRequest":
            await self.on_save_request(c)
        else:
            await c.send({"t": "error", "code": "unknown", "msg": f"unbekannter Typ {t!r}"})

    async def on_action(self, c: Client, msg: dict) -> None:
        action = msg.get("action")
        if not isinstance(action, dict):
            await c.send({"t": "error", "code": "action", "msg": "action fehlt"})
            return
        async with self._lock:
            seq = self.store.seq + 1
            id_map = []
            # Format v1 der Mod: {"op":"upsert","localId":..} ohne netId = neues Objekt
            if action.get("op") == "upsert" and "netId" not in action and "localId" in action:
                action["netId"] = self.store.next_net_id()
                id_map.append({"localId": action["localId"], "netId": action["netId"]})
            for obj in action.get("objects") or []:
                # Neue Objekte (ohne netId) bekommen eine globale ID
                if isinstance(obj, dict) and "netId" not in obj and _creates_objects(action):
                    obj["netId"] = self.store.next_net_id()
                    if "partID" in obj:
                        id_map.append({"localId": obj["partID"], "netId": obj["netId"]})
            out = {"t": "action", "seq": seq, "clientId": c.client_id, "cseq": msg.get("cseq"),
                   "action": action}
            self.store.append_action(out)
            await self.broadcast(out)
            if id_map:
                await c.send({"t": "ids", "seq": seq, "map": id_map})

    async def on_save_end(self, c: Client) -> None:
        info, chunks = c.upload, c.upload_chunks
        c.upload, c.upload_chunks = None, []
        data = b"".join(chunks)
        sha = hashlib.sha256(data).hexdigest()
        if info.get("sha256") and info["sha256"] != sha:
            await c.send({"t": "error", "code": "save_hash", "msg": "sha256 stimmt nicht"})
            return
        seq = int(info.get("seq", self.store.seq))
        self.store.store_save(data, {"seq": seq, "name": info.get("name", "save.park2"),
                                     "size": len(data), "sha256": sha, "from": c.client_id})
        await c.send({"t": "saveStored", "seq": seq})
        log.info("Spielstand von %s gespeichert (seq %d, %d Bytes)", c.client_id, seq, len(data))

    async def on_save_request(self, c: Client) -> None:
        info = self.store.save_info()
        if info is None:
            await c.send({"t": "error", "code": "no_save", "msg": "kein Spielstand vorhanden"})
            return
        data = self.store.save_path.read_bytes()
        await c.send({"t": "saveBegin", **info})
        for i in range(0, len(data), SAVE_CHUNK):
            await c.send({"t": "saveChunk", "i": i // SAVE_CHUNK,
                          "data": base64.b64encode(data[i:i + SAVE_CHUNK]).decode("ascii")})
        await c.send({"t": "saveEnd"})


def _creates_objects(action: dict) -> bool:
    calls = action.get("calls") or []
    return any(isinstance(x, dict) and str(x.get("m", "")).startswith(("CreateNewPart", "Clone"))
               for x in calls)


async def start(server: Server, host: str, port: int) -> asyncio.base_events.Server:
    # Zeilenlimit muss Save-Chunks (base64 von 512 KiB ≈ 700 KB) + JSON abdecken
    return await asyncio.start_server(server.handle, host, port, limit=2 * MAX_LINE)


async def run(host: str, port: int, data_dir: Path, park: str) -> None:
    safe = "".join(ch if ch.isalnum() or ch in " -_" else "_" for ch in park).strip() or "park"
    store = ParkStore(data_dir / safe)
    server = Server(store, park)
    srv = await start(server, host, port)
    addrs = ", ".join(str(s.getsockname()) for s in srv.sockets)
    log.info("PC2MP-Server läuft auf %s, Park %r, seq=%d", addrs, park, store.seq)
    try:
        async with srv:
            await srv.serve_forever()
    finally:
        store.close()


def main() -> None:
    p = argparse.ArgumentParser(description="PC2MP Relay-Server")
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=7777)
    p.add_argument("--data", default=str(Path(__file__).parent / "data"))
    p.add_argument("--park", default="default")
    p.add_argument("-v", "--verbose", action="store_true")
    a = p.parse_args()
    logging.basicConfig(level=logging.DEBUG if a.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    try:
        asyncio.run(run(a.host, a.port, Path(a.data), a.park))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
