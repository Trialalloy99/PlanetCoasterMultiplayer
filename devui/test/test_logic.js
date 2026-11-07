// Integrationstest der UI-Logik (ohne Electron): startet den Python-Server lokal und spielt
// New Server -> Liste -> Join (ohne Spieler) -> Download durch. Außerdem GameLink gegen Fake-Dateien.
// Ausführen:  node devui/test/test_logic.js   (braucht "py -3.14" oder "python" im PATH)
const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('assert');
const { ServerLink } = require('../lib/server');
const { GameLink, asArray, normTest } = require('../lib/game');
const P = require('../lib/paths');

const PORT = 17790 + Math.floor(Math.random() * 1000);
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pc2mp-ui-'));
const ok = msg => console.log('ok  ' + msg);

async function main() {
  const py = process.env.PYTHON || 'py';
  const args = py === 'py' ? ['-3.14'] : [];
  const srv = spawn(py, [...args, path.join(__dirname, '..', '..', 'server', 'pc2mp_server.py'),
    '--host', '127.0.0.1', '--port', String(PORT), '--data', path.join(tmp, 'data')], { stdio: 'ignore' });
  try {
    await new Promise(r => setTimeout(r, 1500));
    const ui = new ServerLink('127.0.0.1', PORT, 'Test-UI');
    await ui.connect();
    assert.deepStrictEqual(ui.rooms, []);
    ok('UI verbunden, keine Server');

    const save = path.join(tmp, 'Testpark-0A1B2C3D.park2');
    fs.writeFileSync(save, Buffer.alloc(1300 * 1024, 7));
    const roomsUpdate = new Promise(r => ui.once('rooms', r));
    const stored = await ui.createServer('Testpark Server', save);
    assert.strictEqual(stored.room, 'Testpark Server');
    const rooms = await roomsUpdate;
    assert.strictEqual(rooms[0].name, 'Testpark Server');
    assert.strictEqual(rooms[0].hasSave, true);
    ok('New Server hochgeladen (3 Chunks), Liste aktualisiert');

    await assert.rejects(ui.createServer('Testpark Server', save), /gibt es schon/);
    ok('doppelter Name abgelehnt');

    let waited = false;
    const ready = await ui.joinPrepare('Testpark Server', () => { waited = true; });
    assert.strictEqual(ready.hasSave, true);
    assert.strictEqual(waited, false);
    ok('Join ohne Spieler: sofort bereit');

    const { info, data } = await ui.download('Testpark Server');
    assert.strictEqual(data.length, 1300 * 1024);
    assert.strictEqual(info.seq, 0);
    ok('Spielstand heruntergeladen, Prüfsumme stimmt');
    ui.close();

    // GameLink gegen Fake-Statusdatei
    const dd = path.join(tmp, 'gamedata');
    fs.mkdirSync(dd);
    const g = new GameLink(dd);
    fs.writeFileSync(path.join(dd, 'ui_state.json'), JSON.stringify({ mode: 'menu', saves: { 1: { id: 'A', name: 'x' }, 2: { id: 'B', name: 'y' } } }));
    const st = g.readState();
    assert.deepStrictEqual(st.saves.map(s => s.id), ['A', 'B']);
    assert.ok(st.fresh);
    ok('ui_state.json gelesen (Spiel-Arrays {"1":..} umgewandelt)');
    const id = g.send({ cmd: 'load', save: 'A' });
    const cmd = JSON.parse(fs.readFileSync(path.join(dd, 'ui_cmd.json'), 'utf8'));
    assert.strictEqual(cmd.id, id);
    assert.ok(g.send({ cmd: 'refresh' }) > id);
    ok('Befehle mit steigender id');
    assert.deepStrictEqual(asArray([1, 2]), [1, 2]);
    const tt = normTest({ on: true, active: true, offset: 30, count: 3, log: { 2: 'b', 1: 'a' } });
    assert.deepStrictEqual(tt, { on: true, active: true, offset: 30, count: 3, log: ['a', 'b'] });
    assert.strictEqual(normTest(null), null);
    ok('Testmodus-Status aus ui_state.json');

    assert.strictEqual(P.worldNameFromFile('test2-59D70CED.park2'), 'test2');
    assert.strictEqual(P.safeName('Maxi & Finn!'), 'Maxi _ Finn_');
    ok('Hilfsfunktionen');
    console.log('\nALLE UI-TESTS OK');
  } finally {
    srv.kill();
  }
}

main().catch(e => { console.error('FEHLER:', e); process.exit(1); });
