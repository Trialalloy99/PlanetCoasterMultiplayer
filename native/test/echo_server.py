"""Minimaler Zeilen-Echo-Server fuer test_bridge (eine JSON-Nachricht pro Zeile).
usage: echo_server.py [port] [--once]   (--once: nach der ersten Verbindung beenden)
"""
import socket
import sys
import threading

port = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 37777
once = '--once' in sys.argv


def handle(c):
    buf = b''
    with c:
        while True:
            try:
                d = c.recv(65536)
            except OSError:
                return
            if not d:
                return
            buf += d
            while b'\n' in buf:
                line, buf = buf.split(b'\n', 1)
                c.sendall(line + b'\n')


s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', port))
s.listen()
print('echo server on', port, flush=True)
while True:
    conn, _ = s.accept()
    if once:
        handle(conn)
        break
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
