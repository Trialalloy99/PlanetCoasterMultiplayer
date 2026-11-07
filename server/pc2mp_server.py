#!/usr/bin/env python3
"""PC2MP-Server mit mehreren Welten ("Rooms", in der UI "Servers"). Protokoll: docs/protocol.md.

Nur Python-Standardbibliothek (>= 3.10). Start:
    python server/pc2mp_server.py --host 0.0.0.0 --port 7790 --data server/data

Jeder Unterordner von --data mit meta.json ist ein Room (Spielstand + Aktionsprotokoll seit dem Spielstand).
Spiel-Clients melden sich mit hello.park = Room-Name an (gibt es ihn nicht, wird er angelegt),
UI-Clients mit hello.role = "ui" (sehen alle Rooms, legen neue an, laden Spielstände).
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import json
import logging
import os
import secrets
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

PROTOCOL_VERSION = 1
MAX_LINE = 1024 * 1024
SAVE_CHUNK = 512 * 1024
MAX_SAVE = 200 * 1024 * 1024
KEEP_BACKUPS = 5
QUICKSAVE_TIMEOUT = 90.0

log = logging.getLogger("pc2mp")


def _atomic_write(path: Path, data: bytes, sync: bool = False) -> None:
    # sync=False: kein fsync (auf dem geteilten VPS kann fsync minutenlang hängen); os.replace bleibt atomar
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            if sync:
                os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def safe_dir_name(name: str) -> str:
    s = "".join(ch if ch.isalnum() or ch in " -_" else "_" for ch in name).strip()
    return s[:64] or "park"


class ParkStore:
    """Persistenz eines Rooms: Aktionsprotokoll + Meta + Spielstand (+ Backups)."""

    def __init__(self, root: Path, display_name: str | None = None):
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)
        self.actions_path = root / "actions.jsonl"
        self.meta_path = root / "meta.json"
        self.save_path = root / "save.park2"
        self.save_meta_path = root / "save.json"
        self.backup_dir = root / "backups"
        self.meta = {"serverSeq": 0, "nextNetId": 1}
        self.meta_dirty = False
        if self.meta_path.exists():
            self.meta.update(json.loads(self.meta_path.read_text("utf-8")))
        else:
            # neue Rooms: eigenes netId-Präfix, damit IDs aus anderen Welten nie kollidieren
            self.meta["netPrefix"] = "r" + secrets.token_hex(3)
            self.meta["created"] = time.time()
        self.meta.setdefault("name", display_name or root.name)
        self._recover_seq()
        self.write_meta()
        self._actions_file = open(self.actions_path, "a", encoding="utf-8")

    @property
    def name(self) -> str:
        return self.meta["name"]

    def _recover_seq(self) -> None:
        # Falls der Server zwischen Append und Meta-Write abgestürzt ist
        last = 0
        max_net = 0
        prefix = self.meta.get("netPrefix", "") + "n"
        if self.actions_path.exists():
            with open(self.actions_path, encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line:
                        try:
                            m = json.loads(line)
                            last = max(last, int(m.get("seq", 0)))
                            nid = str((m.get("action") or {}).get("netId") or "")
                            if nid.startswith(prefix) and nid[len(prefix):].isdigit():
                                max_net = max(max_net, int(nid[len(prefix):]))
                        except (ValueError, json.JSONDecodeError, AttributeError):
                            log.warning("defekte Zeile in actions.jsonl ignoriert")
        self.meta["serverSeq"] = max(self.meta["serverSeq"], last)
        self.meta["nextNetId"] = max(self.meta["nextNetId"], max_net + 1)

    @property
    def seq(self) -> int:
        return self.meta["serverSeq"]

    def next_net_id(self) -> str:
        n = self.meta["nextNetId"]
        self.meta["nextNetId"] = n + 1
        return f"{self.meta.get('netPrefix', '')}n{n}"

    def append_action(self, msg: dict) -> None:
        # Kein fsync hier: auf dem (geteilten) VPS hängt fsync bei hoher I/O-Last minutenlang und blockierte
        # den ganzen Server. flush() reicht gegen Server-Absturz; meta.json schreibt der Flusher (Thread).
        self.meta["serverSeq"] = msg["seq"]
        self._actions_file.write(json.dumps(msg, separators=(",", ":"), ensure_ascii=False) + "\n")
        self._actions_file.flush()
        self.meta_dirty = True

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

    def count_since(self, last_seq: int) -> int:
        return sum(1 for _ in self.actions_since(last_seq))

    def save_info(self) -> dict | None:
        if self.save_path.exists() and self.save_meta_path.exists():
            return json.loads(self.save_meta_path.read_text("utf-8"))
        return None

    def store_save(self, data: bytes, info: dict) -> None:
        old = self.save_info()
        if old is not None and self.save_path.exists():
            self.backup_dir.mkdir(exist_ok=True)
            stamp = time.strftime("%Y%m%d-%H%M%S")
            os.replace(self.save_path, self.backup_dir / f"save_{stamp}_seq{old.get('seq', 0)}.park2")
            backups = sorted(self.backup_dir.glob("save_*.park2"), key=lambda p: p.stat().st_mtime)
            for p in backups[:-KEEP_BACKUPS]:
                p.unlink(missing_ok=True)
        info = {**info, "time": time.time()}
        _atomic_write(self.save_path, data)
        _atomic_write(self.save_meta_path, json.dumps(info, indent=2).encode("utf-8"))
        # Nur bis zum VORLETZTEN Spielstand kürzen: wer noch mit dem alten Stand kommt, bekommt alles nach
        if old is not None:
            self.prune_actions(min(int(old.get("seq", 0) or 0), int(info.get("seq", 0) or 0)))

    def prune_actions(self, upto_seq: int) -> None:
        """Aktionen <= upto_seq stecken im Spielstand und werden nicht mehr gebraucht."""
        keep = list(self.actions_since(upto_seq))
        self._actions_file.close()
        _atomic_write(self.actions_path, "".join(
            json.dumps(m, separators=(",", ":"), ensure_ascii=False) + "\n" for m in keep).encode("utf-8"))
        self._actions_file = open(self.actions_path, "a", encoding="utf-8")

    def close(self) -> None:
        self._actions_file.close()


@dataclass
class Client:
    client_id: str
    name: str
    writer: asyncio.StreamWriter
    role: str = "game"              # "game" | "ui"
    room: "Room | None" = None
    upload: dict | None = None
    upload_chunks: list = field(default_factory=list)
    upload_size: int = 0

    async def send(self, msg: dict) -> None:
        data = (json.dumps(msg, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")
        self.writer.write(data)
        await self.writer.drain()


class Room:
    def __init__(self, store: ParkStore):
        self.store = store
        self.clients: dict[str, Client] = {}
        self.lock = asyncio.Lock()           # serialisiert seq-Vergabe + Broadcast
        self.quicksave: dict | None = None   # laufender Quick-Save {saver, seq, waiters, task}
        self.held: list[tuple[Client, dict]] = []   # während Quick-Save zurückgehaltene Aktionen

    @property
    def name(self) -> str:
        return self.store.name

    def summary(self) -> dict:
        info = self.store.save_info() or {}
        return {
            "name": self.name,
            "online": [c.name for c in self.clients.values()],
            "serverSeq": self.store.seq,
            "hasSave": bool(info),
            "saveSeq": info.get("seq"),
            "saveTime": info.get("time"),
            "saveSize": info.get("size"),
            "pending": self.store.count_since(int(info.get("seq", 0) or 0)) if info else self.store.seq,
            "saving": self.quicksave is not None,
        }


class Server:
    def __init__(self, data_dir: Path, default_room: str = "default"):
        self.data_dir = data_dir
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.default_room = default_room
        self.rooms: dict[str, Room] = {}
        self.ui_clients: dict[str, Client] = {}
        self._next_client = 1
        self._reg_lock = asyncio.Lock()
        for d in sorted(p for p in data_dir.iterdir() if p.is_dir() and (p / "meta.json").exists()):
            store = ParkStore(d)
            self.rooms[store.name] = Room(store)
        log.info("%d Rooms geladen: %s", len(self.rooms), ", ".join(self.rooms) or "-")

    async def _meta_flusher(self) -> None:
        while True:
            await asyncio.sleep(2.0)
            for r in list(self.rooms.values()):
                if r.store.meta_dirty:
                    r.store.meta_dirty = False
                    meta = json.dumps(r.store.meta, indent=2).encode("utf-8")
                    try:
                        await asyncio.to_thread(_atomic_write, r.store.meta_path, meta)
                    except OSError as e:
                        log.warning("meta.json für %r nicht geschrieben: %s", r.name, e)
                        r.store.meta_dirty = True

    def ensure_flusher(self) -> None:
        if getattr(self, "_flusher", None) is None:
            self._flusher = asyncio.create_task(self._meta_flusher())

    # --------------------------------------------------------------- Rooms
    def get_room(self, name: str, create: bool) -> Room | None:
        name = str(name or "").strip()[:64]
        if not name:
            return None
        if name in self.rooms:
            return self.rooms[name]
        if not create:
            return None
        base = safe_dir_name(name)
        d = self.data_dir / base
        i = 2
        while d.exists():
            d = self.data_dir / f"{base}_{i}"
            i += 1
        room = Room(ParkStore(d, name))
        self.rooms[name] = room
        log.info("Room angelegt: %r (%s)", name, d.name)
        return room

    def rooms_msg(self) -> dict:
        lst = [r.summary() for r in self.rooms.values()]
        lst.sort(key=lambda r: (-len(r["online"]), -(r["saveTime"] or 0)))
        return {"t": "rooms", "rooms": lst}

    async def push_rooms(self) -> None:
        msg = self.rooms_msg()
        for c in list(self.ui_clients.values()):
            try:
                await c.send(msg)
            except (ConnectionError, OSError):
                pass

    async def broadcast(self, room: Room, msg: dict, exclude: str | None = None) -> None:
        for c in list(room.clients.values()):
            if c.client_id == exclude:
                continue
            try:
                await c.send(msg)
            except (ConnectionError, OSError):
                log.info("senden an %s fehlgeschlagen", c.client_id)

    # --------------------------------------------------------------- Verbindung
    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        peer = writer.get_extra_info("peername")
        client: Client | None = None
        self.ensure_flusher()
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
            log.info("%s verbunden als %s (%s, %s, Room %r)", peer, client.client_id, client.name, client.role,
                     client.room.name if client.room else None)
            while True:
                line = await reader.readline()
                if not line:
                    break
                if len(line) > 2 * MAX_LINE:
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
                await self._unregister(client)
            writer.close()
            try:
                await writer.wait_closed()
            except (ConnectionError, OSError):
                pass

    async def _raw_send(self, writer, msg) -> None:
        writer.write((json.dumps(msg) + "\n").encode("utf-8"))
        await writer.drain()

    async def _register(self, hello: dict, writer) -> Client:
        async with self._reg_lock:
            cid = f"c{self._next_client}"
            self._next_client += 1
        name = str(hello.get("name", cid))[:64]
        if hello.get("role") == "ui":
            client = Client(cid, name, writer, role="ui")
            self.ui_clients[cid] = client
            await client.send({"t": "welcome", "v": PROTOCOL_VERSION, "clientId": cid, "role": "ui"})
            await client.send(self.rooms_msg())
            return client
        room = self.get_room(hello.get("park") or self.default_room, create=True)
        client = Client(cid, name, writer, room=room)
        async with room.lock:
            others = [{"clientId": c.client_id, "name": c.name} for c in room.clients.values()]
            room.clients[cid] = client
            await client.send({
                "t": "welcome", "v": PROTOCOL_VERSION, "clientId": cid,
                "serverSeq": room.store.seq, "park": room.name, "clients": others,
                "hasSave": room.store.save_info() is not None,
            })
            # Catch-up innerhalb des Locks, damit keine neue Aktion dazwischenrutscht
            last = int(hello.get("lastSeq", 0) or 0)
            for msg in room.store.actions_since(last):
                await client.send(msg)
            await client.send({"t": "caughtUp", "serverSeq": room.store.seq})
        await self.broadcast(room, {"t": "join", "clientId": cid, "name": client.name}, exclude=cid)
        await self.push_rooms()
        return client

    async def _unregister(self, client: Client) -> None:
        if client.role == "ui":
            self.ui_clients.pop(client.client_id, None)
        elif client.room is not None:
            room = client.room
            room.clients.pop(client.client_id, None)
            await self.broadcast(room, {"t": "leave", "clientId": client.client_id})
            qs = room.quicksave
            if qs is not None and qs["saver"] is client:
                await self._finish_quicksave(room, ok=False, reason="Spieler hat verlassen")
            await self.push_rooms()
        log.info("%s getrennt", client.client_id)

    # --------------------------------------------------------------- Nachrichten
    async def dispatch(self, c: Client, msg: dict) -> None:
        t = msg.get("t")
        if t == "ping":
            await c.send({"t": "pong", "time": msg.get("time")})
        elif t == "listRooms":
            await c.send(self.rooms_msg())
        elif t == "saveUpload":
            await self.on_save_upload(c, msg)
        elif t == "saveChunk" and c.upload is not None:
            chunk = base64.b64decode(msg.get("data", ""))
            c.upload_size += len(chunk)
            if c.upload_size > MAX_SAVE:
                c.upload, c.upload_chunks = None, []
                await c.send({"t": "error", "code": "save_size", "msg": "Spielstand zu groß"})
                return
            c.upload_chunks.append(chunk)
        elif t == "saveEnd" and c.upload is not None:
            await self.on_save_end(c)
        elif t in ("saveChunk", "saveEnd"):
            pass  # Rest eines abgelehnten Uploads

        elif t == "saveRequest":
            await self.on_save_request(c, msg)
        elif t == "joinPrepare":
            await self.on_join_prepare(c, msg)
        elif c.room is None:
            await c.send({"t": "error", "code": "no_room", "msg": f"{t!r} nur im Room"})
        elif t == "action":
            await self.on_action(c, msg)
        elif t == "chat":
            await self.broadcast(c.room, {"t": "chat", "clientId": c.client_id, "name": c.name,
                                          "text": str(msg.get("text", ""))[:500]})
        elif t == "cursor":
            await self.broadcast(c.room, {"t": "cursor", "clientId": c.client_id, "pos": msg.get("pos")},
                                 exclude=c.client_id)
        elif t == "quickSaveFailed":
            if c.room.quicksave is not None and c.room.quicksave["saver"] is c:
                await self._finish_quicksave(c.room, ok=False, reason=str(msg.get("msg", "fehlgeschlagen")))
        else:
            await c.send({"t": "error", "code": "unknown", "msg": f"unbekannter Typ {t!r}"})

    async def on_action(self, c: Client, msg: dict) -> None:
        action = msg.get("action")
        if not isinstance(action, dict):
            await c.send({"t": "error", "code": "action", "msg": "action fehlt"})
            return
        room = c.room
        if room.quicksave is not None:
            # Während eines Quick-Saves: zurückhalten, sonst steckt die Aktion evtl. im Spielstand UND im Protokoll
            room.held.append((c, msg))
            return
        await self._apply_action(room, c, msg)

    async def _apply_action(self, room: Room, c: Client, msg: dict) -> None:
        action = msg["action"]
        async with room.lock:
            store = room.store
            seq = store.seq + 1
            id_map = []
            # Format v1 der Mod: {"op":"upsert","localId":..} ohne netId = neues Objekt
            if action.get("op") == "upsert" and "netId" not in action and "localId" in action:
                action["netId"] = store.next_net_id()
                id_map.append({"localId": action["localId"], "netId": action["netId"]})
            for obj in action.get("objects") or []:
                if isinstance(obj, dict) and "netId" not in obj and _creates_objects(action):
                    obj["netId"] = store.next_net_id()
                    if "partID" in obj:
                        id_map.append({"localId": obj["partID"], "netId": obj["netId"]})
            out = {"t": "action", "seq": seq, "clientId": c.client_id, "cseq": msg.get("cseq"),
                   "action": action}
            store.append_action(out)
            await self.broadcast(room, out)
            if id_map:
                try:
                    await c.send({"t": "ids", "seq": seq, "map": id_map})
                except (ConnectionError, OSError):
                    pass

    # --------------------------------------------------------------- Spielstände
    async def on_save_upload(self, c: Client, msg: dict) -> None:
        create = bool(msg.get("create"))
        if c.role == "ui":
            room = self.get_room(msg.get("room"), create=False)
            if create and room is not None:
                await c.send({"t": "error", "code": "room_exists", "msg": f"Server {msg.get('room')!r} gibt es schon"})
                return
            if not create and room is None:
                await c.send({"t": "error", "code": "no_room", "msg": "Server nicht gefunden"})
                return
            if create and not str(msg.get("room") or "").strip():
                await c.send({"t": "error", "code": "no_room", "msg": "Name fehlt"})
                return
        elif c.room is None:
            await c.send({"t": "error", "code": "no_room", "msg": "kein Room"})
            return
        c.upload = msg
        c.upload_chunks = []
        c.upload_size = 0

    async def on_save_end(self, c: Client) -> None:
        info, chunks = c.upload, c.upload_chunks
        c.upload, c.upload_chunks, c.upload_size = None, [], 0
        data = b"".join(chunks)
        sha = hashlib.sha256(data).hexdigest()
        if info.get("sha256") and info["sha256"] != sha:
            await c.send({"t": "error", "code": "save_hash", "msg": "sha256 stimmt nicht"})
            return
        if c.role == "ui":
            room = self.get_room(info.get("room"), create=bool(info.get("create")))
            if room is None:
                await c.send({"t": "error", "code": "no_room", "msg": "Server nicht gefunden"})
                return
        else:
            room = c.room
        qs = room.quicksave
        if qs is not None and qs["saver"] is c:
            seq = qs["seq"]                       # Stand zum Zeitpunkt der Anfrage (danach wurde zurückgehalten)
        elif c.role == "ui":
            seq = room.store.seq                  # neuer Server / manueller Upload: Stand = jetzt
        else:
            seq = min(int(info.get("seq", room.store.seq) or 0), room.store.seq)
        async with room.lock:
            await asyncio.to_thread(room.store.store_save, data, {"seq": seq, "name": info.get("name", "save.park2"),
                                                                  "size": len(data), "sha256": sha, "from": c.name})
        await c.send({"t": "saveStored", "seq": seq, "room": room.name})
        log.info("Room %r: Spielstand von %s gespeichert (seq %d, %d Bytes)", room.name, c.name, seq, len(data))
        if qs is not None and qs["saver"] is c:
            await self._finish_quicksave(room, ok=True)
        else:
            await self.push_rooms()

    async def on_save_request(self, c: Client, msg: dict) -> None:
        room = c.room if c.role != "ui" else self.get_room(msg.get("room"), create=False)
        if room is None:
            await c.send({"t": "error", "code": "no_room", "msg": "Server nicht gefunden"})
            return
        info = room.store.save_info()
        if info is None:
            await c.send({"t": "error", "code": "no_save", "msg": "kein Spielstand vorhanden"})
            return
        data = await asyncio.to_thread(room.store.save_path.read_bytes)
        await c.send({"t": "saveBegin", "room": room.name, **info})
        for i in range(0, len(data), SAVE_CHUNK):
            await c.send({"t": "saveChunk", "i": i // SAVE_CHUNK,
                          "data": base64.b64encode(data[i:i + SAVE_CHUNK]).decode("ascii")})
        await c.send({"t": "saveEnd"})

    # --------------------------------------------------------------- Join / Quick-Save
    async def on_join_prepare(self, c: Client, msg: dict) -> None:
        """UI will joinen: ist jemand online, frischen Spielstand bei ihm anfordern, sonst sofort bereit."""
        room = self.get_room(msg.get("room"), create=False)
        if room is None:
            await c.send({"t": "error", "code": "no_room", "msg": "Server nicht gefunden"})
            return
        if room.quicksave is not None:
            room.quicksave["waiters"].append(c)
            await c.send({"t": "waitingForSave", "room": room.name, "saver": room.quicksave["saver"].name})
            return
        savers = [x for x in room.clients.values() if x.role == "game"]
        if not savers:
            await self._send_ready(c, room)
            return
        saver = savers[0]
        room.quicksave = {"saver": saver, "seq": room.store.seq, "waiters": [c], "started": time.time()}
        room.quicksave["task"] = asyncio.create_task(self._quicksave_timeout(room, room.quicksave))
        await c.send({"t": "waitingForSave", "room": room.name, "saver": saver.name})
        try:
            await saver.send({"t": "quickSave", "seq": room.store.seq, "reason": "join", "by": c.name})
        except (ConnectionError, OSError):
            await self._finish_quicksave(room, ok=False, reason="Saver nicht erreichbar")
            return
        log.info("Room %r: Quick-Save bei %s angefordert (für %s)", room.name, saver.name, c.name)
        await self.push_rooms()

    async def _quicksave_timeout(self, room: Room, qs: dict) -> None:
        await asyncio.sleep(QUICKSAVE_TIMEOUT)
        if room.quicksave is qs:
            await self._finish_quicksave(room, ok=False, reason="Zeitüberschreitung")

    async def _finish_quicksave(self, room: Room, ok: bool, reason: str = "") -> None:
        qs = room.quicksave
        if qs is None:
            return
        room.quicksave = None
        task = qs.get("task")
        if task is not None and task is not asyncio.current_task():
            task.cancel()
        if not ok:
            log.info("Room %r: Quick-Save fehlgeschlagen (%s), nehme letzten Spielstand", room.name, reason)
        # zurückgehaltene Aktionen jetzt einspielen (bekommen seq > Spielstand-seq)
        held, room.held = room.held, []
        for client, msg in held:
            await self._apply_action(room, client, msg)
        for w in qs["waiters"]:
            try:
                await self._send_ready(w, room, fresh=ok, reason=reason)
            except (ConnectionError, OSError):
                pass
        await self.push_rooms()

    async def _send_ready(self, c: Client, room: Room, fresh: bool = False, reason: str = "") -> None:
        info = room.store.save_info()
        await c.send({"t": "saveReady", "room": room.name, "hasSave": info is not None,
                      "saveSeq": info.get("seq") if info else None, "fresh": fresh,
                      "pending": room.summary()["pending"], "msg": reason})


def _creates_objects(action: dict) -> bool:
    calls = action.get("calls") or []
    return any(isinstance(x, dict) and str(x.get("m", "")).startswith(("CreateNewPart", "Clone"))
               for x in calls)


async def start(server: Server, host: str, port: int) -> asyncio.base_events.Server:
    # Zeilenlimit muss Save-Chunks (base64 von 512 KiB ≈ 700 KB) + JSON abdecken
    return await asyncio.start_server(server.handle, host, port, limit=4 * MAX_LINE)


async def run(host: str, port: int, data_dir: Path, default_room: str) -> None:
    server = Server(data_dir, default_room)
    srv = await start(server, host, port)
    addrs = ", ".join(str(s.getsockname()) for s in srv.sockets)
    log.info("PC2MP-Server läuft auf %s", addrs)
    try:
        async with srv:
            await srv.serve_forever()
    finally:
        for r in server.rooms.values():
            r.store.write_meta()
            r.store.close()


def main() -> None:
    p = argparse.ArgumentParser(description="PC2MP-Server")
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=7790)
    p.add_argument("--data", default=str(Path(__file__).parent / "data"))
    p.add_argument("--park", default="default", help="Room für Clients ohne hello.park")
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
