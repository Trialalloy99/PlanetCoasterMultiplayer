// Renderer der Dev-UI: nur Anzeige + Klicks, alle Logik im Hauptprozess (main.js).
const $ = sel => document.querySelector(sel);
const api = window.pc2mp;

const state = { connected: false, game: null, rooms: [], worlds: [], name: null };

function el(tag, props = {}, ...children) {
  const e = document.createElement(tag);
  Object.assign(e, props);
  for (const c of children) e.append(c);
  return e;
}

function setPill(id, cls, text) {
  const p = $(id);
  p.className = 'pill ' + (cls || '');
  p.querySelector('em').textContent = text;
}

function fmtAge(t) {
  if (!t) return 'nie';
  const s = Date.now() / 1000 - t;
  if (s < 90) return 'gerade eben';
  if (s < 3600) return `vor ${Math.round(s / 60)} min`;
  if (s < 86400) return `vor ${Math.round(s / 3600)} h`;
  return `vor ${Math.round(s / 86400)} Tagen`;
}

function busy(text, progress) {
  if (!text) { $('#busy').classList.add('hidden'); return; }
  $('#busy').classList.remove('hidden');
  $('#busy-text').textContent = text;
  const bar = $('#busy-bar');
  bar.classList.toggle('hidden', progress == null);
  if (progress != null) bar.firstElementChild.style.width = `${Math.round(progress * 100)}%`;
}

async function call(fn, busyText) {
  if (busyText) busy(busyText);
  const r = await fn();
  if (busyText) busy(null);
  if (!r.ok) alert(r.error);
  return r;
}

// ------------------------------------------------------------------ Anzeige
function renderGame(st) {
  state.game = st;
  if (!st || !st.running) setPill('#pill-game', 'bad', 'aus');
  else if (!st.responding) setPill('#pill-game', 'warn', 'Mod antwortet nicht');
  else setPill('#pill-game', 'ok', st.mode === 'menu' ? 'Hauptmenü' : `im Park${st.park ? ' ' + st.park : ''}`);
}

function renderWorlds() {
  const ul = $('#world-list');
  ul.replaceChildren();
  if (!state.worlds.length) { ul.append(el('li', { className: 'empty', textContent: 'Keine Spielstände gefunden.' })); return; }
  const known = new Set((state.game && state.game.saves || []).map(s => s.name));
  for (const w of state.worlds) {
    const load = el('button', { textContent: 'Laden', disabled: !known.has(w.name) });
    load.title = known.has(w.name) ? 'Im Spiel öffnen' : 'Spiel muss laufen (Hauptmenü)';
    load.onclick = () => call(() => api.loadWorld(w.name), `Lade "${w.name}"…`);
    const up = el('button', { textContent: 'Als Server', disabled: !state.connected });
    up.onclick = () => openNewServer(w.file, w.name);
    ul.append(el('li', {},
      el('div', { className: 'main' },
        el('div', { className: 'title', textContent: w.name }),
        el('div', { className: 'sub', textContent: `${(w.size / 1e6).toFixed(1)} MB · gespeichert ${fmtAge(w.mtime / 1000)}` })),
      load, up));
  }
}

function renderRooms() {
  const ul = $('#server-list');
  ul.replaceChildren();
  if (!state.connected) { ul.append(el('li', { className: 'empty', textContent: 'Erst auf Connect drücken.' })); return; }
  if (!state.rooms.length) { ul.append(el('li', { className: 'empty', textContent: 'Noch keine Server. Leg mit „New Server“ einen an.' })); return; }
  for (const r of state.rooms) {
    const online = r.online || [];
    const sub = el('div', { className: 'sub' });
    if (online.length) sub.append(el('span', { className: 'online', textContent: `● ${online.join(', ')}` }), ' · ');
    sub.append(r.hasSave
      ? `Spielstand ${fmtAge(r.saveTime)} · ${r.pending} Änderungen danach`
      : 'noch kein Spielstand');
    const join = el('button', { className: 'primary', textContent: 'Join', disabled: !r.hasSave });
    join.onclick = () => doJoin(r.name);
    ul.append(el('li', {},
      el('div', { className: 'main' }, el('div', { className: 'title', textContent: r.name }), sub),
      online.length ? el('span', { className: 'badge live', textContent: `${online.length} online` }) : el('span', { className: 'badge', textContent: 'leer' }),
      join));
  }
}

// ------------------------------------------------------------------ Aktionen
async function connect() {
  const r = await call(() => api.connect(), 'Verbinde…');
  if (!r.ok) { setPill('#pill-server', 'bad', 'Fehler'); return; }
  state.connected = true;
  state.name = r.value.name;
  state.rooms = r.value.rooms || [];
  renderGame(r.value.game);
  setPill('#pill-server', 'ok', `verbunden${state.name ? ' als ' + state.name : ''}`);
  $('#btn-new').disabled = false;
  $('#btn-connect').textContent = 'Neu verbinden';
  await refreshWorlds();
  renderRooms();
}

async function refreshWorlds() {
  const r = await api.worlds();
  state.worlds = r.ok ? r.value : [];
  renderWorlds();
}

function openNewServer(file, name) {
  const sel = $('#new-world');
  sel.replaceChildren(...state.worlds.map(w => el('option', { value: w.file, textContent: w.name, selected: w.file === file })));
  $('#new-name').value = name || '';
  $('#dlg-new').showModal();
}

$('#dlg-new').addEventListener('close', async () => {
  if ($('#dlg-new').returnValue !== 'ok') return;
  const room = $('#new-name').value.trim();
  const file = $('#new-world').value;
  const r = await call(() => api.createServer(room, file), `Lade Welt als „${room}“ hoch…`);
  if (r.ok) document.querySelector('[data-tab="servers"]').click();
});

async function doJoin(room) {
  busy(`Join „${room}“…`);
  const r = await api.join(room);
  busy(null);
  if (!r.ok) alert(r.error);
}

// ------------------------------------------------------------------ Events
for (const t of document.querySelectorAll('.tab')) {
  t.onclick = () => {
    document.querySelectorAll('.tab').forEach(x => x.classList.toggle('active', x === t));
    document.querySelectorAll('.panel').forEach(p => p.classList.toggle('active', p.id === 'tab-' + t.dataset.tab));
  };
}
$('#btn-connect').onclick = connect;
$('#btn-new').onclick = () => openNewServer();

api.on('rooms', rooms => { state.rooms = rooms; renderRooms(); });
api.on('server-status', s => {
  if (!s.ok && state.connected) {
    state.connected = false;
    setPill('#pill-server', 'bad', 'getrennt');
    $('#btn-new').disabled = true;
    renderRooms();
  }
});
api.on('join-step', text => { if (text) busy(text); });
api.on('progress', p => { if (p) busy($('#busy-text').textContent, p.p); });
api.on('log', line => {
  const pre = $('#log');
  pre.textContent += line + '\n';
  pre.scrollTop = pre.scrollHeight;
});

// Spielstatus regelmäßig abfragen
setInterval(async () => {
  if (!state.connected) return;
  const r = await api.gameStatus();
  if (r.ok) {
    const before = JSON.stringify(state.game && state.game.saves);
    renderGame(r.value);
    if (JSON.stringify(r.value.saves) !== before) renderWorlds();
  }
}, 2000);
