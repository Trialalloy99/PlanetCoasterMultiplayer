"""Orchestriert test_server_client.exe gegen den echten Server inkl. Server-Neustart.
usage: python native/test/test_with_server.py <test_server_client.exe> <PC2MPNative_test.dll>
"""
import os
import subprocess
import sys
import tempfile
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
SERVER = os.path.join(ROOT, 'server', 'pc2mp_server.py')
PORT = '37778'
data = tempfile.mkdtemp(prefix='pc2mp_bridgetest_')


def start_server():
    p = subprocess.Popen([sys.executable, SERVER, '--host', '127.0.0.1', '--port', PORT,
                          '--data', data, '--park', 'bridgetest'],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.0)
    return p


def stop_server(p):
    # ganzen Prozessbaum beenden (sys.executable kann ein Launcher mit Kindprozess sein)
    subprocess.run(['taskkill', '/PID', str(p.pid), '/T', '/F'],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        p.wait(5)
    except subprocess.TimeoutExpired:
        pass


srv = start_server()
cli =subprocess.Popen([os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2]), PORT],
                       stdout=subprocess.PIPE, text=True)
rc = None
try:
    for line in cli.stdout:
        print(line, end='', flush=True)
        if line.strip() == 'RESTART':
            stop_server(srv)
            time.sleep(0.5)
            srv = start_server()
    rc = cli.wait(30)
finally:
    stop_server(srv)
sys.exit(rc if rc is not None else 1)
