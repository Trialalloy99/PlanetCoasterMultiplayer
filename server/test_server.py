"""Tests für den PC2MP-Server.  Ausführen:  python -m unittest server/test_server.py -v"""
import asyncio
import base64
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import pc2mp_server as srvmod  # noqa: E402


OPEN_CLIENTS = []


class TestClient:
    def __init__(self, reader, writer):
        self.r, self.w = reader, writer
        OPEN_CLIENTS.append(self)

    @classmethod
    async def connect(cls, port, name, last_seq=0, park="test", role=None):
        r, w = await asyncio.open_connection("127.0.0.1", port, limit=4 * 1024 * 1024)
        c = cls(r, w)
        hello = {"t": "hello", "v": 1, "name": name, "park": park, "lastSeq": last_seq}
        if role:
            hello["role"] = role
        await c.send(hello)
        return c

    async def upload(self, data, **extra):
        sha = hashlib.sha256(data).hexdigest()
        await self.send({"t": "saveUpload", "seq": extra.pop("seq", 0), "name": "p.park2", "size": len(data),
                         "sha256": sha, **extra})
        for i in range(0, len(data), 300000):
            await self.send({"t": "saveChunk", "data": base64.b64encode(data[i:i + 300000]).decode()})
        await self.send({"t": "saveEnd"})
        return sha

    async def download(self, **extra):
        await self.send({"t": "saveRequest", **extra})
        begin = await self.recv_until("saveBegin")
        buf = b""
        while True:
            m = await self.recv()
            if m["t"] == "saveEnd":
                return begin, buf
            buf += base64.b64decode(m["data"])

    async def send(self, msg):
        self.w.write((json.dumps(msg) + "\n").encode())
        await self.w.drain()

    async def recv(self, timeout=2.0):
        line = await asyncio.wait_for(self.r.readline(), timeout)
        return json.loads(line)

    async def recv_until(self, t, timeout=2.0):
        while True:
            m = await self.recv(timeout)
            if m["t"] == t:
                return m

    async def close(self):
        if self in OPEN_CLIENTS:
            OPEN_CLIENTS.remove(self)
        self.w.close()
        try:
            await asyncio.wait_for(self.w.wait_closed(), 2)
        except (ConnectionError, OSError, asyncio.TimeoutError):
            pass


class ServerTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        await self._start()

    async def _start(self):
        self.server = srvmod.Server(Path(self.tmp.name))
        self.srv = await srvmod.start(self.server, "127.0.0.1", 0)
        self.port = self.srv.sockets[0].getsockname()[1]

    async def _stop(self):
        for c in list(OPEN_CLIENTS):
            await c.close()
        self.srv.close()
        try:
            await asyncio.wait_for(self.srv.wait_closed(), 3)
        except asyncio.TimeoutError:
            pass
        for r in self.server.rooms.values():
            r.store.close()

    def nid(self, n):
        return self.server.rooms["test"].store.meta.get("netPrefix", "") + f"n{n}"

    async def asyncTearDown(self):
        await self._stop()
        self.tmp.cleanup()

    async def test_welcome_and_join(self):
        a = await TestClient.connect(self.port, "A")
        w = await a.recv()
        self.assertEqual(w["t"], "welcome")
        self.assertEqual(w["clientId"], "c1")
        self.assertEqual((await a.recv())["t"], "caughtUp")
        b = await TestClient.connect(self.port, "B")
        wb = await b.recv()
        self.assertEqual(wb["clients"], [{"clientId": "c1", "name": "A"}])
        j = await a.recv()
        self.assertEqual(j, {"t": "join", "clientId": "c2", "name": "B"})
        await a.close(); await b.close()

    async def test_version_mismatch(self):
        c = TestClient(*await asyncio.open_connection("127.0.0.1", self.port))
        await c.send({"t": "hello", "v": 99})
        m = await c.recv()
        self.assertEqual(m["code"], "version")
        await c.close()

    async def test_action_relay_seq_and_netids(self):
        a = await TestClient.connect(self.port, "A"); await a.recv_until("caughtUp")
        b = await TestClient.connect(self.port, "B"); await b.recv_until("caughtUp")
        await a.recv_until("join")
        action = {"op": "commit", "calls": [{"m": "CreateNewPart", "a": {"1": "Tree"}}],
                  "objects": [{"partID": 55, "pos": [1, 2, 3], "rot": [0, 0, 0], "scale": 1}]}
        await a.send({"t": "action", "cseq": 1, "action": action})
        mb = await b.recv_until("action")
        self.assertEqual(mb["seq"], 1)
        self.assertEqual(mb["clientId"], "c1")
        self.assertEqual(mb["action"]["objects"][0]["netId"], self.nid(1))
        ma = await a.recv_until("action")  # Echo als Bestätigung
        self.assertEqual(ma["cseq"], 1)
        ids = await a.recv_until("ids")
        self.assertEqual(ids["map"], [{"localId": 55, "netId": self.nid(1)}])
        # Edit-Aktion bekommt keine neue netId
        await b.send({"t": "action", "cseq": 1, "action": {"op": "commit",
                      "calls": [{"m": "EditExistingPart"}], "objects": [{"partID": 9}]}})
        m2 = await a.recv_until("action")
        self.assertEqual(m2["seq"], 2)
        self.assertNotIn("netId", m2["action"]["objects"][0])
        await a.close(); await b.close()

    async def test_upsert_format_assigns_netid(self):
        a = await TestClient.connect(self.port, "A"); await a.recv_until("caughtUp")
        await a.send({"t": "action", "cseq": 1, "action": {
            "op": "upsert", "localId": 77, "resource": "Tree", "pos": [1, 2, 3], "rot": [0, 0, 0], "scale": 1}})
        m = await a.recv_until("action")
        self.assertEqual(m["action"]["netId"], self.nid(1))
        self.assertEqual((await a.recv_until("ids"))["map"], [{"localId": 77, "netId": self.nid(1)}])
        # Folge-Upsert mit netId bekommt keine neue ID
        await a.send({"t": "action", "cseq": 2, "action": {"op": "upsert", "netId": self.nid(1), "pos": [5, 5, 5]}})
        m2 = await a.recv_until("action")
        self.assertEqual(m2["action"]["netId"], self.nid(1))
        await a.close()

    async def test_catch_up_and_persistence(self):
        a = await TestClient.connect(self.port, "A"); await a.recv_until("caughtUp")
        for i in range(3):
            await a.send({"t": "action", "cseq": i, "action": {"op": "undo"}})
            await a.recv_until("action")
        await a.close()
        # Server neu starten -> Daten müssen bleiben
        await self._stop(); await self._start()
        c = await TestClient.connect(self.port, "C", last_seq=1)
        w = await c.recv()
        self.assertEqual(w["serverSeq"], 3)
        got = [await c.recv(), await c.recv()]
        self.assertEqual([m["seq"] for m in got], [2, 3])
        self.assertEqual((await c.recv())["t"], "caughtUp")
        await c.close()

    async def test_save_upload_download(self):
        a = await TestClient.connect(self.port, "A"); await a.recv_until("caughtUp")
        data = bytes(range(256)) * 5000  # ~1.2 MB -> mehrere Chunks
        sha = hashlib.sha256(data).hexdigest()
        await a.send({"t": "saveUpload", "seq": 0, "name": "p.park2", "size": len(data), "sha256": sha})
        for i in range(0, len(data), 300000):
            await a.send({"t": "saveChunk", "data": base64.b64encode(data[i:i + 300000]).decode()})
        await a.send({"t": "saveEnd"})
        self.assertEqual((await a.recv_until("saveStored"))["seq"], 0)
        b = await TestClient.connect(self.port, "B")
        self.assertTrue((await b.recv())["hasSave"])
        await b.recv_until("caughtUp")
        await b.send({"t": "saveRequest"})
        begin = await b.recv_until("saveBegin")
        self.assertEqual(begin["sha256"], sha)
        buf = b""
        while True:
            m = await b.recv()
            if m["t"] == "saveEnd":
                break
            buf += base64.b64decode(m["data"])
        self.assertEqual(buf, data)
        await a.close(); await b.close()

    async def test_bad_json_and_ping(self):
        a = await TestClient.connect(self.port, "A"); await a.recv_until("caughtUp")
        a.w.write(b"nicht json\n"); await a.w.drain()
        self.assertEqual((await a.recv())["code"], "json")
        await a.send({"t": "ping", "time": 5})
        self.assertEqual(await a.recv(), {"t": "pong", "time": 5})
        await a.close()

    # ------------------------------------------------------------ Rooms / Dev-UI
    async def test_rooms_are_separate(self):
        a = await TestClient.connect(self.port, "A", park="W1"); await a.recv_until("caughtUp")
        b = await TestClient.connect(self.port, "B", park="W2"); await b.recv_until("caughtUp")
        await a.send({"t": "action", "cseq": 1, "action": {"op": "upsert", "localId": 5, "resource": "T"}})
        m = await a.recv_until("action")
        self.assertEqual(m["seq"], 1)
        await b.send({"t": "ping", "time": 1})
        self.assertEqual((await b.recv())["t"], "pong", "anderer Room bekommt keine Aktion")
        ids = await a.recv_until("ids")
        self.assertTrue(ids["map"][0]["netId"].startswith("r"), "neue Rooms haben netId-Praefix")
        await a.close(); await b.close()

    async def test_ui_create_server_list_and_download(self):
        ui = await TestClient.connect(self.port, "UI", role="ui")
        self.assertEqual((await ui.recv())["role"], "ui")
        self.assertEqual((await ui.recv())["rooms"], [])
        data = bytes(range(256)) * 3000
        sha = await ui.upload(data, room="Mein Park", create=True)
        stored = await ui.recv_until("saveStored")
        self.assertEqual(stored["room"], "Mein Park")
        rooms = (await ui.recv_until("rooms"))["rooms"]
        self.assertEqual(rooms[0]["name"], "Mein Park")
        self.assertTrue(rooms[0]["hasSave"])
        await ui.upload(b"x", room="Mein Park", create=True)
        self.assertEqual((await ui.recv_until("error"))["code"], "room_exists")
        g = await TestClient.connect(self.port, "Maxi", park="Mein Park"); await g.recv_until("caughtUp")
        rooms = (await ui.recv_until("rooms"))["rooms"]
        self.assertEqual(rooms[0]["online"], ["Maxi"])
        begin, buf = await ui.download(room="Mein Park")
        self.assertEqual((begin["sha256"], buf), (sha, data))
        await ui.close(); await g.close()

    async def test_join_without_players_is_ready_immediately(self):
        ui = await TestClient.connect(self.port, "UI", role="ui"); await ui.recv_until("rooms")
        await ui.upload(b"abc", room="Leer", create=True); await ui.recv_until("saveStored")
        await ui.send({"t": "joinPrepare", "room": "Leer"})
        r = await ui.recv_until("saveReady")
        self.assertTrue(r["hasSave"]); self.assertFalse(r["fresh"]); self.assertEqual(r["saveSeq"], 0)
        await ui.close()

    async def test_join_with_player_triggers_quicksave_and_holds_actions(self):
        ui = await TestClient.connect(self.port, "UI", role="ui"); await ui.recv_until("rooms")
        await ui.upload(b"alt", room="Park", create=True); await ui.recv_until("saveStored")
        g = await TestClient.connect(self.port, "Maxi", park="Park"); await g.recv_until("caughtUp")
        await g.send({"t": "action", "cseq": 1, "action": {"op": "upsert", "localId": 1, "resource": "T"}})
        await g.recv_until("action")
        await ui.send({"t": "joinPrepare", "room": "Park"})
        w = await ui.recv_until("waitingForSave")
        self.assertEqual(w["saver"], "Maxi")
        qs = await g.recv_until("quickSave")
        self.assertEqual(qs["seq"], 1)
        await g.send({"t": "action", "cseq": 2, "action": {"op": "upsert", "localId": 2, "resource": "T"}})
        await g.send({"t": "ping", "time": 9})
        self.assertEqual((await g.recv_until("pong"))["time"], 9)
        await g.upload(b"neu", seq=1)
        self.assertEqual((await g.recv_until("saveStored"))["seq"], 1)
        held = await g.recv_until("action")
        self.assertEqual(held["seq"], 2, "zurueckgehaltene Aktion kommt nach dem Spielstand")
        r = await ui.recv_until("saveReady")
        self.assertTrue(r["fresh"]); self.assertEqual(r["saveSeq"], 1); self.assertEqual(r["pending"], 1)
        begin, buf = await ui.download(room="Park")
        self.assertEqual(buf, b"neu")
        await ui.close(); await g.close()

    async def test_quicksave_saver_leaves(self):
        ui = await TestClient.connect(self.port, "UI", role="ui"); await ui.recv_until("rooms")
        await ui.upload(b"alt", room="P", create=True); await ui.recv_until("saveStored")
        g = await TestClient.connect(self.port, "Maxi", park="P"); await g.recv_until("caughtUp")
        await ui.send({"t": "joinPrepare", "room": "P"}); await ui.recv_until("waitingForSave")
        await g.recv_until("quickSave"); await g.close()
        r = await ui.recv_until("saveReady")
        self.assertFalse(r["fresh"]); self.assertTrue(r["hasSave"])
        await ui.close()

    async def test_rooms_survive_restart(self):
        a = await TestClient.connect(self.port, "A", park="Bleibt"); await a.recv_until("caughtUp")
        await a.send({"t": "action", "cseq": 1, "action": {"op": "undo"}}); await a.recv_until("action")
        await a.close()
        await self._stop(); await self._start()
        ui = await TestClient.connect(self.port, "UI", role="ui"); await ui.recv()
        rooms = (await ui.recv_until("rooms"))["rooms"]
        self.assertEqual([(r["name"], r["serverSeq"]) for r in rooms], [("Bleibt", 1)])
        await ui.close()


if __name__ == "__main__":
    unittest.main()
