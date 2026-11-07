// Pfade: Spielordner, Mod-Ordner, Datenordner (Kopplung an die Mod), Saves-Ordner, Config.
const fs = require('fs');
const path = require('path');
const os = require('os');

const GAME_REL = path.join('steamapps', 'common', 'Planet Coaster 2');

function steamRoots() {
  const roots = [
    'C:\\Program Files (x86)\\Steam',
    'C:\\Program Files\\Steam',
  ];
  // weitere Steam-Bibliotheken aus libraryfolders.vdf
  for (const r of [...roots]) {
    const vdf = path.join(r, 'steamapps', 'libraryfolders.vdf');
    try {
      const txt = fs.readFileSync(vdf, 'utf8');
      for (const m of txt.matchAll(/"path"\s+"([^"]+)"/g)) roots.push(m[1].replace(/\\\\/g, '\\'));
    } catch { /* gibt es nicht */ }
  }
  return [...new Set(roots)];
}

function findGameDir(override) {
  if (override && fs.existsSync(path.join(override, 'Win64'))) return override;
  for (const r of steamRoots()) {
    const d = path.join(r, GAME_REL);
    if (fs.existsSync(path.join(d, 'Win64'))) return d;
  }
  return null;
}

function modDir(gameDir) { return gameDir && path.join(gameDir, 'Win64', 'ovldata', 'PC2MP'); }
function dataDir(gameDir) { return gameDir && path.join(modDir(gameDir), 'data'); }

function readConfig(gameDir) {
  try {
    return JSON.parse(fs.readFileSync(path.join(modDir(gameDir), 'PC2MP_config.json'), 'utf8'));
  } catch {
    return null;
  }
}

// Wie server/save_tool.py: Saves-Ordner des zuletzt benutzten Profils
function savesDir() {
  const root = path.join(process.env.USERPROFILE || os.homedir(), 'Saved Games', 'Frontier Developments', 'Planet Coaster 2');
  let best = null, bestTime = -1;
  try {
    for (const e of fs.readdirSync(root, { withFileTypes: true })) {
      if (!e.isDirectory()) continue;
      const s = path.join(root, e.name, 'Saves');
      if (!fs.existsSync(s)) continue;
      let t = 0;
      for (const f of fs.readdirSync(s)) if (f.endsWith('.park2')) t = Math.max(t, fs.statSync(path.join(s, f)).mtimeMs);
      if (t > bestTime) { best = s; bestTime = t; }
    }
  } catch { /* kein Ordner */ }
  return best;
}

const DOWNLOAD_PREFIX = 'PC2MP_';

// "test2-59D70CED.park2" -> "test2"
function worldNameFromFile(file) {
  return path.basename(file, '.park2').replace(/-[0-9A-Fa-f]{8}$/, '');
}

function listWorldFiles(dir) {
  if (!dir) return [];
  const out = [];
  for (const f of fs.readdirSync(dir)) {
    if (!f.endsWith('.park2') || f.startsWith(DOWNLOAD_PREFIX)) continue;
    const st = fs.statSync(path.join(dir, f));
    out.push({ file: f, name: worldNameFromFile(f), size: st.size, mtime: st.mtimeMs });
  }
  out.sort((a, b) => b.mtime - a.mtime);
  return out;
}

function safeName(s) {
  // nur Zeichen, die PC2MPNative.dll in Dateinamen erlaubt (files_valid_name: [A-Za-z0-9_.-])
  return String(s).trim().replace(/[^A-Za-z0-9_-]/g, '_').slice(0, 40) || 'server';
}

module.exports = { findGameDir, modDir, dataDir, readConfig, savesDir, listWorldFiles, worldNameFromFile, safeName, DOWNLOAD_PREFIX };
