// Verbindung der UI zum VPS-Server (role "ui"), Protokoll siehe docs/protocol.md
const net = require('net');
const crypto = require('crypto');
const fs = require('fs');
const { EventEmitter } = require('events');

const CHUNK = 512 * 1024;

class ServerLink extends EventEmitter {
  constructor(host, port, name) {
    super();
    this.host = host;
    this.port = port;
    this.name = name;
    this.sock = null;
    this.buf = '';
    this.rooms = [];
    this.connected = false;
    this.waiters = [];
  }

  connect(timeoutMs = 8000) {
    return new Promise((resolve, reject) => {
      const sock = net.connect({ host: this.host, port: this.port });
      const timer = setTimeout(() => { sock.destroy(); reject(new Error('Server nicht erreichbar')); }, timeoutMs);
      sock.setEncoding('utf8');
      sock.setNoDelay(true);
      sock.on('connect', () => {
        this.sock = sock;
        this.send({ t: 'hello', v: 1, name: this.name, role: 'ui' });
      });
      sock.on('data', d => this._onData(d));
      sock.on('error', e => { clearTimeout(timer); this.connected = false; this.emit('status', false, e.message); reject(e); });
      sock.on('close', () => {
        this.connected = false;
        this.emit('status', false, 'getrennt');
        for (const w of this.waiters.splice(0)) w.reject(new Error('Verbindung zum Server getrennt'));
      });
      // fertig erst mit der Serverliste (kommt direkt nach welcome)
      this.once('rooms', () => { clearTimeout(timer); this.connected = true; this.emit('status', true); resolve(); });
    });
  }

  close() { if (this.sock) this.sock.destroy(); }

  send(msg) {
    if (!this.sock) throw new Error('nicht verbunden');
    return this.sock.write(JSON.stringify(msg) + '\n');
  }

  _onData(d) {
    this.buf += d;
    let i;
    while ((i = this.buf.indexOf('\n')) >= 0) {
      const line = this.buf.slice(0, i);
      this.buf = this.buf.slice(i + 1);
      if (!line.trim()) continue;
      let msg;
      try { msg = JSON.parse(line); } catch { continue; }
      this._onMsg(msg);
    }
  }

  _onMsg(msg) {
    if (msg.t === 'welcome') this.emit('welcome', msg);
    if (msg.t === 'rooms') { this.rooms = msg.rooms || []; this.emit('rooms', this.rooms); }
    this.emit('msg', msg);
    for (const w of [...this.waiters]) {
      if (w.pred(msg)) { this.waiters.splice(this.waiters.indexOf(w), 1); clearTimeout(w.timer); w.resolve(msg); }
    }
  }

  // wartet auf eine Nachricht; Server-Fehler brechen ab
  waitFor(pred, timeoutMs = 60000) {
    return new Promise((resolve, reject) => {
      const w = {
        pred: m => pred(m) || m.t === 'error',
        resolve: m => (m.t === 'error' && !pred(m) ? reject(new Error(m.msg || m.code)) : resolve(m)),
        reject,
      };
      w.timer = setTimeout(() => { this.waiters.splice(this.waiters.indexOf(w), 1); reject(new Error('Zeitüberschreitung')); }, timeoutMs);
      this.waiters.push(w);
    });
  }

  async _drain() {
    if (this.sock.writableNeedDrain) await new Promise(r => this.sock.once('drain', r));
  }

  // Neuen Server anlegen: Spielstand hochladen
  async createServer(room, filePath, onProgress) {
    const data = fs.readFileSync(filePath);
    const sha = crypto.createHash('sha256').update(data).digest('hex');
    const done = this.waitFor(m => m.t === 'saveStored' && m.room === room, 300000);
    this.send({ t: 'saveUpload', room, create: true, name: require('path').basename(filePath), size: data.length, sha256: sha });
    for (let i = 0; i < data.length; i += CHUNK) {
      this.send({ t: 'saveChunk', i: i / CHUNK, data: data.subarray(i, i + CHUNK).toString('base64') });
      await this._drain();
      if (onProgress) onProgress(Math.min(1, (i + CHUNK) / data.length));
    }
    this.send({ t: 'saveEnd' });
    return done;
  }

  // Join vorbereiten: liefert saveReady; onWaiting wird gerufen, wenn jemand erst speichern muss
  async joinPrepare(room, onWaiting) {
    const onMsg = m => { if (m.t === 'waitingForSave' && m.room === room && onWaiting) onWaiting(m); };
    this.on('msg', onMsg);
    try {
      const ready = this.waitFor(m => m.t === 'saveReady' && m.room === room, 120000);
      this.send({ t: 'joinPrepare', room });
      return await ready;
    } finally {
      this.off('msg', onMsg);
    }
  }

  // Spielstand eines Servers herunterladen -> {info, data}
  async download(room, onProgress) {
    const chunks = [];
    let info = null;
    const collect = m => {
      if (m.t === 'saveBegin' && m.room === room) info = m;
      else if (m.t === 'saveChunk' && info) {
        chunks.push(Buffer.from(m.data, 'base64'));
        if (onProgress && info.size) onProgress(Math.min(1, chunks.length * CHUNK / info.size));
      }
    };
    this.on('msg', collect);
    try {
      const end = this.waitFor(m => m.t === 'saveEnd' || (m.t === 'error' && m.code === 'no_save'), 300000);
      this.send({ t: 'saveRequest', room });
      const last = await end;
      if (last.t === 'error') throw new Error(last.msg);
    } finally {
      this.off('msg', collect);
    }
    const data = Buffer.concat(chunks);
    const sha = crypto.createHash('sha256').update(data).digest('hex');
    if (!info || sha !== info.sha256) throw new Error('Prüfsumme des Spielstands stimmt nicht');
    return { info, data };
  }
}

module.exports = { ServerLink };
