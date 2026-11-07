// PC2MP Dev-UI (Electron-Hauptprozess): verbindet Spiel (Dateien) und VPS-Server (TCP).
const { app, BrowserWindow, ipcMain } = require('electron');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const P = require('./lib/paths');
const { GameLink } = require('./lib/game');
const { ServerLink } = require('./lib/server');

let win = null;
let gameDir = null;
let game = null;
let server = null;
let config = null;

function ui(channel, payload) {
  if (win && !win.isDestroyed()) win.webContents.send(channel, payload);
}
function log(msg) {
  console.log(msg);
  ui('log', `${new Date().toLocaleTimeString()}  ${msg}`);
}

// ------------------------------------------------------------------ Spiel (ohne Server, z. B. für den Testmodus)
function ensureGame() {
  if (game) return game;
  gameDir = P.findGameDir(process.env.PC2_GAME_DIR);
  if (!gameDir) throw new Error('Planet Coaster 2 nicht gefunden');
  if (!fs.existsSync(P.modDir(gameDir))) throw new Error('PC2MP-Mod ist nicht installiert');
  game = new GameLink(P.dataDir(gameDir));
  return game;
}

// ------------------------------------------------------------------ Connect
async function connect() {
  game = null;
  ensureGame();
  config = P.readConfig(gameDir) || {};
  const st = await game.status();
  log(`Spiel: ${st.running ? (st.responding ? st.mode : 'läuft, Mod antwortet nicht') : 'nicht gestartet'}`);

  if (!config.host) throw new Error('Kein Server in PC2MP_config.json (host fehlt)');
  if (server) server.close();
  server = new ServerLink(config.host, config.port || 7790, config.name || 'Spieler');
  server.on('rooms', rooms => ui('rooms', rooms));
  server.on('status', (ok, why) => ui('server-status', { ok, why }));
  await server.connect();
  log(`Server verbunden (${config.host}:${config.port || 7790}) als ${config.name || 'Spieler'}`);
  return { game: st, rooms: server.rooms, name: config.name };
}

function requireGame(st, wantMenu) {
  if (!st.running) throw new Error('Spiel läuft nicht');
  if (!st.responding) throw new Error('Mod antwortet nicht. Bist du im Hauptmenü?');
  if (wantMenu && st.mode !== 'menu') throw new Error('Bitte erst ins Hauptmenü gehen');
}

// ------------------------------------------------------------------ Welten
function worlds() {
  return P.listWorldFiles(P.savesDir());
}

async function loadWorld(name) {
  const st = await game.status();
  requireGame(st, false);
  const save = st.saves.find(s => s.name === name);
  if (!save) throw new Error(`Spiel kennt die Welt "${name}" nicht`);
  const r = await game.sendAndWait({ cmd: 'load', save: save.id });
  if (!r.ok) throw new Error(r.msg);
  log(`Lade Welt "${name}"`);
}

// ------------------------------------------------------------------ New Server
async function createServer(room, file) {
  if (!server || !server.connected) throw new Error('Nicht mit dem Server verbunden');
  room = String(room || '').trim();
  if (!room) throw new Error('Name fehlt');
  const full = path.join(P.savesDir(), file);
  log(`Lade "${file}" als Server "${room}" hoch...`);
  await server.createServer(room, full, p => ui('progress', { what: 'upload', p }));
  ui('progress', null);
  log(`Server "${room}" angelegt`);
}

// ------------------------------------------------------------------ Join
async function join(room) {
  if (!server || !server.connected) throw new Error('Nicht mit dem Server verbunden');
  let st = await game.status();
  requireGame(st, true);
  const idsBefore = new Set(st.saves.map(s => s.id));

  ui('join-step', 'Frage den Server nach dem neuesten Spielstand...');
  const ready = await server.joinPrepare(room, w => {
    ui('join-step', `Waiting for the latest save to upload... (${w.saver} speichert)`);
    log(`Warte auf Quick-Save von ${w.saver}`);
  });
  if (!ready.hasSave) throw new Error('Dieser Server hat noch keinen Spielstand');
  log(`Spielstand bereit (seq ${ready.saveSeq}, ${ready.fresh ? 'frisch gespeichert' : 'letzter Stand'}, ${ready.pending} Aktionen danach)`);

  ui('join-step', 'Lade Spielstand herunter...');
  const { info, data } = await server.download(room, p => ui('progress', { what: 'download', p }));
  ui('progress', null);

  // alte Kopien dieses Servers entfernen, neue unter frischem Namen ablegen
  const dir = P.savesDir();
  const prefix = `${P.DOWNLOAD_PREFIX}${P.safeName(room)}-`;
  for (const f of fs.readdirSync(dir)) {
    if (f.startsWith(prefix) && f.endsWith('.park2')) {
      try { fs.unlinkSync(path.join(dir, f)); } catch { /* egal */ }
    }
  }
  const file = `${prefix}${crypto.randomBytes(4).toString('hex').toUpperCase()}.park2`;
  fs.writeFileSync(path.join(dir, file), data);
  log(`Gespeichert als ${file} (${(data.length / 1e6).toFixed(1)} MB)`);

  ui('join-step', 'Spiel liest die Welten neu ein...');
  const nRefresh = st.refreshes;
  const r = await game.sendAndWait({ cmd: 'refresh' });
  if (!r.ok) throw new Error(r.msg);
  st = await game.waitFor(s => (s.refreshes || 0) > nRefresh, 30000);
  if (!st) throw new Error('Spiel hat die Welten nicht neu eingelesen');
  const fresh = st.saves.filter(s => !idsBefore.has(s.id));
  log(`Neue Welten im Spiel: ${fresh.map(s => `${s.name} (${s.id})`).join(', ') || 'keine'}`);
  if (fresh.length === 0) throw new Error('Spiel erkennt den neuen Spielstand nicht (Neustart nötig?)');

  ui('join-step', 'Öffne die Welt...');
  const r2 = await game.sendAndWait({ cmd: 'join', save: fresh[0].id, room, lastSeq: info.seq });
  if (!r2.ok) throw new Error(r2.msg);
  log(`Join "${room}": Welt wird geladen, danach ${ready.pending} Aktionen nachladen`);
  ui('join-step', null);
}

// ------------------------------------------------------------------ Testmodus (alleine testen, pc2mp.testmode)
async function setTestMode(on, offset) {
  ensureGame();
  const st = await game.status();
  if (!st.running) throw new Error('Spiel läuft nicht');
  if (!st.responding) throw new Error('Mod antwortet nicht (Hauptmenü oder Park öffnen)');
  const off = Math.min(500, Math.max(1, Number(offset) || 25));
  const r = await game.sendAndWait({ cmd: 'testmode', on: !!on, offset: off });
  if (!r.ok) throw new Error(r.msg);
  log(`Testmodus ${on ? 'an' : 'aus'} (Versatz ${off} m)`);
  return (await game.status()).test;
}

// ------------------------------------------------------------------ IPC
function handle(name, fn) {
  ipcMain.handle(name, async (_e, ...args) => {
    try {
      return { ok: true, value: await fn(...args) };
    } catch (e) {
      log(`Fehler (${name}): ${e.message}`);
      ui('join-step', null);
      ui('progress', null);
      return { ok: false, error: e.message };
    }
  });
}
handle('connect', connect);
handle('game-status', () => {
  try { ensureGame(); } catch { return { running: false }; }
  return game.status();
});
handle('set-testmode', setTestMode);
handle('worlds', worlds);
handle('load-world', loadWorld);
handle('create-server', createServer);
handle('join', join);
handle('refresh-rooms', () => { server.send({ t: 'listRooms' }); return true; });

app.whenReady().then(() => {
  win = new BrowserWindow({
    width: 980,
    height: 700,
    minWidth: 720,
    minHeight: 480,
    backgroundColor: '#14161a',
    title: 'PC2MP Dev',
    autoHideMenuBar: true,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false },
  });
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
});
app.on('window-all-closed', () => app.quit());
