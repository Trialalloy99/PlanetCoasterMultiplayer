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
    async def connect(cls, port, name, last_seq=0):
        r, w = await asyncio.open_connection("127.0.0.1", port, limit=4 * 1024 * 1024)
        c = cls(r, w)
        await c.send({"t": "hello", "v": 1, "name": name, "park": "test", "lastSeq": last_seq})
        return c

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
        self.store = srvmod.ParkStore(Path(self.tmp.name) / "park")
        self.server = srvmod.Server(self.store, "test")
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
        self.store.close()

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
        self.assertEqual(mb["action"]["objects"][0]["netId"], "n1")
        ma = await a.recv_until("action")  # Echo als Bestätigung
        self.assertEqual(ma["cseq"], 1)
        ids = await a.recv_until("ids")
        self.assertEqual(ids["map"], [{"localId": 55, "netId": "n1"}])
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
        self.assertEqual(m["action"]["netId"], "n1")
        self.assertEqual((await a.recv_until("ids"))["map"], [{"localId": 77, "netId": "n1"}])
        # Folge-Upsert mit netId bekommt keine neue ID
        await a.send({"t": "action", "cseq": 2, "action": {"op": "upsert", "netId": "n1", "pos": [5, 5, 5]}})
        m2 = await a.recv_until("action")
        self.assertEqual(m2["action"]["netId"], "n1")
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


if __name__ == "__main__":
    unittest.main()
