"""Legt einen Temp-Saves-Ordner mit test.park2 (1,3 MB Zufallsdaten) an und startet test_files.exe.
usage: python native/test/test_with_files.py <test_files.exe> <PC2MPNative_test.dll>
"""
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

d = tempfile.mkdtemp(prefix='pc2mp_saves_')
data = os.urandom(1_300_000)
with open(os.path.join(d, 'test.park2'), 'wb') as f:
    f.write(data)
sha = hashlib.sha256(data).hexdigest()
env = dict(os.environ, PC2MP_TEST_SAVES_DIR=d)
try:
    rc = subprocess.run([os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2]), d, sha], env=env).returncode
    if rc == 0:
        with open(os.path.join(d, 'empfangen.park2'), 'rb') as f:
            assert f.read() == data, 'empfangen.park2 weicht ab'
        print('Python-Gegenprobe: empfangen.park2 == Original')
finally:
    shutil.rmtree(d, ignore_errors=True)
sys.exit(rc)
