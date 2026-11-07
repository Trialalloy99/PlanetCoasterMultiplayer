// Kopplung an die Mod im Spiel über Dateien (siehe mod/PC2MP/Main/pc2mp.menu.lua):
//   ui_state.json  Spiel -> UI   { mode, park, saves, cmd: {id, ok, msg}, refreshes, frame }
//   ui_cmd.json    UI -> Spiel   { id, cmd, ... }
const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');

const STALE_MS = 6000; // so lange darf ui_state.json alt sein, bevor wir "Spiel antwortet nicht" sagen

// api.json des Spiels schreibt Arrays als {"1":..,"2":..}
function asArray(v) {
  if (Array.isArray(v)) return v;
  if (v && typeof v === 'object') {
    return Object.keys(v).filter(k => /^\d+$/.test(k)).sort((a, b) => a - b).map(k => v[k]);
  }
  return [];
}

// Testmodus-Status aus pc2mp.testmode (api.json: log kommt als {"1":..} )
function normTest(t) {
  if (!t || typeof t !== 'object') return null;
  return {
    on: !!t.on,
    active: !!t.active,
    offset: Number(t.offset) || 25,
    count: Number(t.count) || 0,
    log: asArray(t.log).map(String),
  };
}

class GameLink {
  constructor(dataDir) {
    this.dataDir = dataDir;
    this.lastCmdId = 0;
  }

  statePath() { return path.join(this.dataDir, 'ui_state.json'); }
  cmdPath() { return path.join(this.dataDir, 'ui_cmd.json'); }

  isRunning() {
    return new Promise(resolve => {
      execFile('tasklist', ['/FI', 'IMAGENAME eq PlanetCoaster2.exe', '/NH'], { windowsHide: true }, (err, out) => {
        resolve(!err && /PlanetCoaster2\.exe/i.test(out || ''));
      });
    });
  }

  readState() {
    try {
      const st = fs.statSync(this.statePath());
      const raw = JSON.parse(fs.readFileSync(this.statePath(), 'utf8'));
      raw.saves = asArray(raw.saves);
      raw.ageMs = Date.now() - st.mtimeMs;
      raw.fresh = raw.ageMs < STALE_MS;
      return raw;
    } catch {
      return null;
    }
  }

  // Status für die UI: { running, responding, mode, park, saves }
  async status() {
    const running = await this.isRunning();
    const st = running ? this.readState() : null;
    return {
      running,
      responding: !!(st && st.fresh),
      mode: st && st.fresh ? st.mode : null,
      park: st && st.fresh ? st.park : null,
      saves: st && st.fresh ? st.saves : [],
      refreshes: st ? st.refreshes || 0 : 0,
      test: st && st.fresh ? normTest(st.test) : null,
    };
  }

  send(cmd) {
    const id = Math.max(Date.now(), this.lastCmdId + 1);
    this.lastCmdId = id;
    fs.mkdirSync(this.dataDir, { recursive: true });
    const tmp = this.cmdPath() + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify({ id, ...cmd }));
    fs.renameSync(tmp, this.cmdPath());
    return id;
  }

  // wartet, bis das Spiel den Befehl bestätigt hat -> {ok, msg}
  async sendAndWait(cmd, timeoutMs = 15000) {
    const id = this.send(cmd);
    const st = await this.waitFor(s => s.cmd && Number(s.cmd.id) === id, timeoutMs);
    if (!st) throw new Error('Spiel hat nicht geantwortet (läuft die Mod?)');
    return st.cmd;
  }

  async waitFor(pred, timeoutMs = 15000) {
    const end = Date.now() + timeoutMs;
    while (Date.now() < end) {
      const st = this.readState();
      if (st && pred(st)) return st;
      await new Promise(r => setTimeout(r, 300));
    }
    return null;
  }
}

module.exports = { GameLink, asArray, normTest };
