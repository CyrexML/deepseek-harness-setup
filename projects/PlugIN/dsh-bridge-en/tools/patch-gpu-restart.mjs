// Model restart and GPU watchdog status in the Power menu (2026-10-14). Idempotent;
// usage: node patch-gpu-restart.mjs <plugin_dir>. Runs AFTER patch-power.mjs: its anchors
// are inside the code that patch adds.
//
// The stand's GPU can get "stuck": generation drops from ~70-130 to ~14-23 tok/s, the card
// reports ~99% busy at ~120 W of 360 with a memory bus that is ~13% busy. Restarting only
// llama-server cures it (measured 22.7 -> 131 tok/s); the Windows launcher's watchdog
// (scripts/harness-start.ps1, Wait-StopSignal) detects it and does that on its own, and
// writes what it sees to run\gpu.status next to the power signal file.
//
// This patch gives the UI both halves:
//   - powerOff accepts mode 'model' (the launcher restarts llama-server and keeps running);
//   - a gpuStatus RPC reads run\gpu.status;
//   - the sidebar ⏻ popover and the Settings → Remote access → Power card get a status
//     line and a "Restart the model" button.
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
// Plugin files are hardlinks into the pnpm store: unlink first (new inode), then write.
const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };
const dir = process.argv[2] || '.';
const MARK = '/* dsh-bridge-en: gpu restart */';

function patch(file, edits) {
  const path = join(dir, file);
  let s = readFileSync(path, 'utf8');
  let applied = 0, skipped = 0;
  for (const [a, b] of edits) {
    if (s.includes(b)) { skipped++; continue; }
    const n = s.split(a).length - 1;
    if (n !== 1) { console.error(`${file}: MATCH COUNT ${n} for ${JSON.stringify(a.slice(0, 80))}`); process.exit(1); }
    s = s.replace(a, b); applied++;
  }
  unlinkWrite(path, s);
  console.log(`${file}: gpu-restart patch applied ${applied}, already present ${skipped}`);
}

const POWER = '/* dsh-bridge-en: power */';

patch('lib/bridge-rpc-constants.js', [[
  `  powerOff: 'powerOff', ${POWER}\n`,
  `  powerOff: 'powerOff', ${POWER}\n  gpuStatus: 'gpuStatus', ${MARK}\n`,
]]);

patch('lib/bridge-rpc.js', [[
  `        if (endpoint === BRIDGE_ENDPOINTS.powerOff) { ${POWER}\n`,
  `        if (endpoint === BRIDGE_ENDPOINTS.gpuStatus) { ${MARK}
          if (typeof service.gpuStatus !== 'function') return fail('bad-request', 'GPU status unavailable');
          return ok(await service.gpuStatus());
        }

        if (endpoint === BRIDGE_ENDPOINTS.powerOff) { ${POWER}\n`,
]]);

patch('lib/index.js', [
  [
    "const m = ['wsl', 'sleep', 'shutdown'].includes(mode) ? mode : 'dsh';",
    "const m = ['wsl', 'sleep', 'shutdown', 'model'].includes(mode) ? mode : 'dsh'; " + MARK,
  ],
  [
    '  async powerOff(mode) {\n',
    `  ${MARK} // the launcher's GPU watchdog writes run\\gpu.status next to the power signal file
  async gpuStatus() {
    const file = process.env.DSH_POWER_REQUEST_FILE;
    if (!file) return { available: false, reason: 'DSH was not started by the launcher' };
    try {
      const st = JSON.parse((await readFile(join(dirname(file), 'gpu.status'), 'utf8')).replace(/^\\uFEFF/, ''));
      return { available: true, ...st };
    } catch (e) {
      return { available: false, reason: e?.code === 'ENOENT' ? 'no data yet' : String(e?.message || e) };
    }
  }

  async powerOff(mode) {\n`,
  ],
]);

const MODEL_DONE = 'Model restart requested. The model is back in about 10–30 s; nothing else stops.';
const MODEL_CONFIRM = 'Only the model server restarts (about 10–30 s). DSH, sessions and the phone tunnel keep running; a reply being generated now is retried automatically. Continue?';

patch('client/index.js', [
  // shared helpers, before the sidebar power button
  [
    'function setupPowerButton(rpcCall) {\n',
    `${MARK}
// Status of the launcher's GPU watchdog (run\\gpu.status through the gpuStatus RPC).
async function fetchGpuStatus(rpcCall) {
  try { const res = await rpcCall(BRIDGE_ENDPOINTS.gpuStatus, {}); return res?.ok ? res.value : null; } catch { return null; }
}
function gpuStatusLine(st) {
  if (!st) return { text: 'Generation speed: no data.', tone: 'muted' };
  if (st.available === false) return { text: 'Generation speed: ' + (st.reason || 'no data') + '.', tone: 'muted' };
  const age = st.checked ? Math.round((Date.now() - Date.parse(st.checked)) / 1000) : null;
  if (age !== null && age > 90) return { text: 'Generation speed: no fresh data — the GPU watchdog runs only when the stand is started from the shortcut.', tone: 'muted' };
  const ago = (iso) => { const s = Math.max(0, Math.round((Date.now() - Date.parse(iso)) / 1000)); return s < 90 ? s + ' s ago' : Math.round(s / 60) + ' min ago'; };
  const g = st.lastGeneration;
  const meas = g ? ' (memory bus ' + g.mem + '%, ' + Math.round(g.watts) + ' W, ' + ago(g.at) + ')' : '';
  const r = st.lastRestart;
  const last = r ? ' Last model restart: ' + new Date(r.at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) + ' (' + r.reason + (r.ok ? '' : ', FAILED') + ').' : '';
  switch (st.state) {
    case 'restarting': return { text: 'The model is restarting…', tone: 'info' };
    case 'reboot-needed': return { text: 'Generation stays slow even after model restarts — reboot the PC.' + meas + last, tone: 'err' };
    case 'restart-pending': return { text: 'GPU stuck, generation is slow' + meas + '. The model restarts automatically at the next pause between requests.' + last, tone: 'err' };
    case 'stuck': return { text: 'GPU stuck, generation is slow' + meas + '.' + last, tone: 'err' };
    case 'ok': return { text: 'Generation speed: normal' + meas + '.' + last, tone: 'ok' };
    default: return { text: 'Generation speed: not measured yet — it is measured while the model generates.' + last, tone: 'muted' };
  }
}
const GPU_TONE_COLOR = { err: 'var(--dsw-alias-state-error-primary,#dc2626)', ok: 'var(--dsw-alias-state-success-primary,#16a34a)', info: 'var(--dsw-alias-state-info-primary,#2563eb)', muted: 'var(--dsw-alias-label-secondary,#6b7280)' };
function GpuStatusNote({ rpcCall }) {
  const [st, setSt] = React.useState(undefined);
  React.useEffect(() => {
    let alive = true;
    const load = () => fetchGpuStatus(rpcCall).then((v) => { if (alive) setSt(v); });
    load(); const t = setInterval(load, 5000);
    return () => { alive = false; clearInterval(t); };
  }, [rpcCall]);
  const l = st === undefined ? { text: 'Generation speed: checking…', tone: 'muted' } : gpuStatusLine(st);
  return React.createElement('div', { style: { fontSize: 12, fontWeight: 500, color: GPU_TONE_COLOR[l.tone], marginBottom: 10 } }, l.text);
}

function setupPowerButton(rpcCall) {\n`,
  ],
  // sidebar popover: status line + button
  [
    '        row.append(b1, b2, b4, b5, b3); pop.appendChild(row);\n',
    `        const bm = el('button', null, '↻ Restart the model (slow generation)'); bm.onclick = () => render({ phase: 'confirm', mode: 'model' }); ${MARK}
        const gs = el('div', 'msg', 'Generation speed: checking…'); gs.style.marginBottom = '10px'; gs.style.color = GPU_TONE_COLOR.muted; pop.appendChild(gs);
        fetchGpuStatus(rpcCall).then((st) => { const l = gpuStatusLine(st); gs.textContent = l.text; gs.style.color = GPU_TONE_COLOR[l.tone]; });
        row.append(bm, b1, b2, b4, b5, b3); pop.appendChild(row);\n`,
  ],
  [
    "          wsl: 'This also shuts down WSL: every Ubuntu process ends — Claude Code sessions, Docker, open terminals. Continue?',\n",
    `          model: '${MODEL_CONFIRM}', ${MARK}\n          wsl: 'This also shuts down WSL: every Ubuntu process ends — Claude Code sessions, Docker, open terminals. Continue?',\n`,
  ],
  [
    "({ wsl: 'Yes, stop DSH and WSL', sleep: 'Yes, stop and sleep', shutdown: 'Yes, shut down the PC' })[state.mode]",
    "({ model: 'Yes, restart the model', wsl: 'Yes, stop DSH and WSL', sleep: 'Yes, stop and sleep', shutdown: 'Yes, shut down the PC' })[state.mode]",
  ],
  [
    "            wsl: 'Shutdown signal sent. The model, the web interface and Ubuntu (WSL) will stop within a few seconds; this page will lose its connection.',\n",
    `            model: '${MODEL_DONE}', ${MARK}\n            wsl: 'Shutdown signal sent. The model, the web interface and Ubuntu (WSL) will stop within a few seconds; this page will lose its connection.',\n`,
  ],
  // Settings → Remote access → Power card
  [
    "      btn('⏻ Stop DSH (keep Ubuntu)', () => setPhase('confirm-dsh'), false),\n",
    `      btn('↻ Restart the model (slow generation)', () => setPhase('confirm-model'), false), ${MARK}\n      btn('⏻ Stop DSH (keep Ubuntu)', () => setPhase('confirm-dsh'), false),\n`,
  ],
  [
    "          'confirm-wsl': 'This also shuts down WSL",
    `          'confirm-model': '${MODEL_CONFIRM}', ${MARK}\n          'confirm-wsl': 'This also shuts down WSL`,
  ],
  [
    "        btn(({ 'confirm-wsl': 'Yes, stop DSH and WSL'",
    "        btn(({ 'confirm-model': 'Yes, restart the model', 'confirm-wsl': 'Yes, stop DSH and WSL'",
  ],
  [
    "      setText({\n        wsl: 'Shutdown signal sent.",
    `      setText({\n        model: '${MODEL_DONE}', ${MARK}\n        wsl: 'Shutdown signal sent.`,
  ],
  [
    "        'Stops the local stand started by the Harness AI launcher: the model server and this web interface. Starting it again is only possible from the PC (the launcher shortcut).'),\n    ),\n",
    "        'Stops the local stand started by the Harness AI launcher: the model server and this web interface. Starting it again is only possible from the PC (the launcher shortcut).'),\n    ),\n    React.createElement(GpuStatusNote, { rpcCall }), " + MARK + "\n",
  ],
]);
