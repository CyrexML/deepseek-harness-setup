// Lighter power menu (2026-10-14). Idempotent; usage: node patch-power-menu.mjs <plugin_dir>.
// Runs AFTER patch-power.mjs and patch-gpu-restart.mjs: it replaces the sidebar ⏻ popover that
// patch-power adds (setupPowerButton) and uses the GPU status helpers patch-gpu-restart adds.
//
// What changes, at the user's request:
//   - "Stop DSH and put the PC to sleep" is gone from both the popover and the Settings → Remote
//     access → Power card (never used; the launcher still accepts mode 'sleep');
//   - the popover is one light list - restart the model, stop DSH, then after a separator the two
//     destructive stops - with no description paragraph and no Cancel button (a click outside or
//     Esc closes it); the confirmation is one line with Cancel / action;
//   - the GPU status is a dot and two words in the header, with the full line as a tooltip; only a
//     problem gets a visible note;
//   - the card loses its long description.
// The popover uses its own class (.dsh-pwr): patch-settings-mobile forces `!important` colours and
// borders on .dsh-power-pop buttons, which would fight a lighter design.
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };
const dir = process.argv[2] || '.';
const MARK = '/* dsh-bridge-en: power menu v2 */';
const path = join(dir, 'client/index.js');
let s = readFileSync(path, 'utf8');
if (s.includes(MARK)) { console.log('client/index.js: power menu v2 already present'); process.exit(0); }

const START = 'function setupPowerButton(rpcCall) {\n';
const END = '\nfunction setupMobileExperience(rpcCall, ctx) {\n';
const a = s.indexOf(START), b = s.indexOf(END);
if (s.split(START).length !== 2 || a < 0 || b < a) { console.error('client/index.js: setupPowerButton range not found'); process.exit(1); }
if (!s.slice(a, b).includes('dsh-power-pop')) { // the popover class patch-power uses
  console.error('client/index.js: setupPowerButton is not the one patch-power added'); process.exit(1);
}
for (const fn of ['function fetchGpuStatus(', 'function gpuStatusLine(']) {
  if (!s.includes(fn)) { console.error(`client/index.js: ${fn} missing - run patch-gpu-restart.mjs first`); process.exit(1); }
}

const NEW = `${MARK}
// Sidebar ⏻ menu: model restart, stop DSH, then the destructive stops. See tools/patch-power-menu.mjs.
function setupPowerButton(rpcCall) {
  if (typeof document === 'undefined') return;
  const isLocalhost = !window.location.hostname || ['127.0.0.1', 'localhost', '::1'].includes(window.location.hostname) || window.location.hostname.endsWith('.local');
  const style = document.createElement('style');
  style.dataset.plugin = '@wenbin_wb/dsh-bridge';
  style.dataset.pluginCss = '@wenbin_wb/dsh-bridge/power-button';
  style.textContent = \`
    .dsh-power-btn{display:inline-flex;align-items:center;justify-content:center;width:32px;height:32px;margin-left:4px;order:99;border:none;border-radius:8px;background:transparent;color:var(--dsw-alias-label-secondary,#6b7280);cursor:pointer;flex-shrink:0}
    .dsh-power-btn:hover{background:var(--dsw-alias-bg-layer-2,rgba(0,0,0,.06));color:var(--dsw-alias-label-primary,#111827)}
    .dsh-power-btn svg{width:18px;height:18px}
    .dsh-pwr{position:fixed;z-index:2147483000;box-sizing:border-box;width:236px;padding:6px;border-radius:14px;background:#161b2c;color:#e6e8ef;border:1px solid rgba(255,255,255,.08);box-shadow:0 18px 50px rgba(0,0,0,.32);font:13px/1.4 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;animation:dsh-pwr-in .12s ease-out}
    @keyframes dsh-pwr-in{from{opacity:0;transform:translateY(-4px)}to{opacity:1;transform:none}}
    .dsh-pwr .hd{display:flex;align-items:center;justify-content:space-between;gap:8px;padding:5px 8px 7px}
    .dsh-pwr .hd b{font-weight:600}
    .dsh-pwr .st{display:inline-flex;align-items:center;gap:6px;font-size:11.5px;color:#9aa3b8;white-space:nowrap;cursor:default}
    .dsh-pwr .st i{width:7px;height:7px;border-radius:50%;background:#6b7280}
    .dsh-pwr .st.ok i{background:#22c55e}.dsh-pwr .st.err i{background:#f87171}.dsh-pwr .st.info i{background:#60a5fa}
    .dsh-pwr .note{margin:0 4px 6px;padding:7px 9px;border-radius:8px;background:rgba(248,113,113,.12);color:#fca5a5;font-size:12px}
    .dsh-pwr .it{display:flex;align-items:center;gap:10px;width:100%;height:34px;padding:0 10px;border:0;border-radius:8px;background:transparent;color:inherit;font:inherit;text-align:left;cursor:pointer}
    .dsh-pwr .it:hover,.dsh-pwr .it:focus-visible{background:rgba(255,255,255,.07);outline:none}
    .dsh-pwr .it svg{width:16px;height:16px;flex-shrink:0;color:#9aa3b8}
    .dsh-pwr .it.danger,.dsh-pwr .it.danger svg{color:#fca5a5}
    .dsh-pwr .sep{height:1px;margin:5px 8px;background:rgba(255,255,255,.08)}
    .dsh-pwr .q{padding:6px 8px 10px}
    .dsh-pwr .act{display:flex;gap:6px;justify-content:flex-end;padding:0 2px 2px}
    .dsh-pwr .act button{height:30px;padding:0 12px;border-radius:8px;border:0;font:inherit;font-weight:500;cursor:pointer;background:rgba(255,255,255,.08);color:#e6e8ef}
    .dsh-pwr .act button.go{background:#4d6bfe;color:#fff}.dsh-pwr .act button.go.danger{background:#dc2626}
    .dsh-pwr .act button:disabled{opacity:.6;cursor:default}
    .dsh-pwr input{box-sizing:border-box;width:100%;margin:0 0 8px;height:32px;padding:0 10px;border-radius:8px;border:1px solid rgba(255,255,255,.14);background:#0f1117;color:#e6e8ef;font:inherit;outline:none}
    .dsh-pwr .msg{padding:6px 8px 8px;color:#93b4ff}.dsh-pwr .msg.err{color:#fca5a5}
    .dsh-pwr-backdrop{position:fixed;inset:0;z-index:2147482999;background:transparent}
    @media (max-width:767px){.dsh-pwr{left:12px!important;right:12px!important;width:auto}.dsh-pwr-backdrop{background:rgba(0,0,0,.25)}.dsh-pwr .it{height:40px}}
  \`;
  document.head.appendChild(style);
  const svg = (d) => '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' + d + '</svg>';
  const ICON = svg('<path d="M18.36 6.64a9 9 0 1 1-12.73 0"/><line x1="12" y1="2" x2="12" y2="12"/>');
  const ICON_RESTART = svg('<path d="M21 12a9 9 0 1 1-2.64-6.36"/><polyline points="21 3 21 9 15 9"/>');
  const ITEMS = [
    { mode: 'model', icon: ICON_RESTART, label: 'Restart model' },
    { mode: 'dsh', icon: ICON, label: 'Stop DSH' },
    null,
    { mode: 'wsl', icon: ICON, label: 'Stop DSH and WSL', danger: true },
    { mode: 'shutdown', icon: ICON, label: 'Shut down PC', danger: true },
  ];
  const ASK = {
    model: 'Restart the model? About 10 s; sessions keep running.',
    dsh: 'Stop DSH? The phone loses access until the stand is started on the PC.',
    wsl: 'Stop DSH and WSL? Every Ubuntu process ends.',
    shutdown: 'Shut down the PC? It can only be turned on again at the PC.',
  };
  const GO = { model: 'Restart', dsh: 'Stop', wsl: 'Stop', shutdown: 'Shut down' };
  const DONE = { model: 'Restarting the model — back in about 10 s.', dsh: 'Stopping DSH…', wsl: 'Stopping DSH and WSL…', shutdown: 'Shutting down the PC…' };
  const SHORT = { ok: 'Speed normal', stuck: 'GPU stuck', 'restart-pending': 'GPU stuck', restarting: 'Restarting…', 'reboot-needed': 'Reboot PC' };
  const NOTE = { stuck: 'Generation is slow — restart the model.', 'restart-pending': 'Generation is slow — the model restarts at the next pause.', 'reboot-needed': 'Restarts did not help — reboot the PC.' };
  let pop = null, backdrop = null, closeTimer = null;
  const onKey = (e) => { if (e.key === 'Escape') close(); };
  const close = () => { clearTimeout(closeTimer); pop?.remove(); backdrop?.remove(); pop = backdrop = null; document.removeEventListener('keydown', onKey); };
  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined) e.textContent = text; return e; };
  const callPowerOff = async (mode, password) => {
    let token = getAdminToken();
    if (!token && isLocalhost) token = await fetchLoopbackTokenOnce();
    if (!token && password !== undefined) {
      const u = await unlockAdmin(rpcCall, password);
      if (!u.ok) return { ok: false, error: { message: u.error || 'Wrong admin password' } };
      token = getAdminToken();
    }
    return rpcCall(BRIDGE_ENDPOINTS.powerOff, { mode, ...(token ? { adminToken: token } : {}), ...(isLocalhost ? { isLocalhost: true } : {}) });
  };
  const needsAdmin = (res) => res?.ok === false && /admin privileges required|password to unlock/i.test(res?.error?.message || '');
  const open = (anchor) => {
    close();
    backdrop = el('div', 'dsh-pwr-backdrop'); backdrop.onclick = close; document.body.appendChild(backdrop);
    pop = el('div', 'dsh-pwr'); pop.setAttribute('role', 'menu');
    const r = anchor.getBoundingClientRect();
    pop.style.top = Math.min(r.bottom + 8, window.innerHeight - 240) + 'px';
    pop.style.left = Math.max(12, Math.min(r.left, window.innerWidth - 248)) + 'px';
    const render = (state) => {
      pop.innerHTML = '';
      if (state.phase === 'menu') {
        const hd = el('div', 'hd'); hd.appendChild(el('b', null, 'Power'));
        const st = el('span', 'st muted'); st.appendChild(el('i')); st.appendChild(el('span', null, '…')); hd.appendChild(st);
        pop.appendChild(hd);
        const note = el('div', 'note'); note.hidden = true; pop.appendChild(note);
        fetchGpuStatus(rpcCall).then((v) => {
          const l = gpuStatusLine(v);
          const short = v && v.available !== false ? SHORT[v.state] : null;
          st.className = 'st ' + l.tone; st.lastChild.textContent = short || 'No data'; st.title = l.text;
          if (v && NOTE[v.state]) { note.textContent = NOTE[v.state]; note.title = l.text; note.hidden = false; }
        });
        for (const it of ITEMS) {
          if (!it) { pop.appendChild(el('div', 'sep')); continue; }
          const btn = el('button', 'it' + (it.danger ? ' danger' : '')); btn.type = 'button'; btn.setAttribute('role', 'menuitem');
          btn.innerHTML = it.icon; btn.appendChild(el('span', null, it.label));
          btn.onclick = () => render({ phase: 'confirm', mode: it.mode });
          pop.appendChild(btn);
        }
      } else if (state.phase === 'confirm' || state.phase === 'password') {
        const danger = ITEMS.find((x) => x && x.mode === state.mode)?.danger;
        pop.appendChild(el('div', 'q', ASK[state.mode]));
        let input = null;
        if (state.phase === 'password') {
          pop.appendChild(el('div', 'msg err', state.error || 'Admin password required'));
          input = el('input'); input.type = 'password'; input.placeholder = 'Admin password'; input.autocomplete = 'current-password';
          pop.appendChild(input); setTimeout(() => input.focus(), 50);
        }
        const act = el('div', 'act');
        const no = el('button', null, 'Cancel'); no.type = 'button'; no.onclick = () => render({ phase: 'menu' });
        const yes = el('button', 'go' + (danger ? ' danger' : ''), GO[state.mode]); yes.type = 'button';
        yes.onclick = async () => {
          yes.disabled = no.disabled = true; yes.textContent = '…';
          let res;
          try { res = await callPowerOff(state.mode, input ? input.value : undefined); }
          catch (e) { render({ phase: 'done', error: e?.message || String(e) }); return; }
          if (res?.ok) render({ phase: 'done', mode: state.mode });
          else if (needsAdmin(res) || input) render({ phase: 'password', mode: state.mode, error: input ? (res?.error?.message || 'Wrong admin password') : undefined });
          else render({ phase: 'done', error: res?.error?.message || 'Request failed' });
        };
        if (input) input.onkeydown = (e) => { if (e.key === 'Enter') yes.click(); };
        act.append(no, yes); pop.appendChild(act);
        if (!input) setTimeout(() => yes.focus(), 30);
      } else {
        pop.appendChild(el('div', 'msg' + (state.error ? ' err' : ''), state.error ? 'Could not send the signal: ' + state.error : DONE[state.mode]));
        if (!state.error && state.mode === 'model') closeTimer = setTimeout(close, 2500);
      }
    };
    render({ phase: 'menu' });
    document.body.appendChild(pop);
    document.addEventListener('keydown', onKey);
  };
  const ensure = () => {
    for (const row of document.querySelectorAll('div[class*="_logoRow"]')) {
      if (row.querySelector('.dsh-power-btn')) continue;
      const btn = el('button', 'dsh-power-btn');
      btn.type = 'button'; btn.title = 'Power'; btn.setAttribute('aria-label', 'Power'); btn.innerHTML = ICON;
      btn.onclick = (e) => { e.stopPropagation(); open(btn); };
      row.appendChild(btn); // last in the row (order:99): brand … collapse-toggle, power
    }
  };
  ensure();
  new MutationObserver(ensure).observe(document.body, { childList: true, subtree: true });
}
`;
s = s.slice(0, a) + NEW + s.slice(b);

// Settings → Remote access → Power card: no sleep button, no long description.
const cardEdits = [
  ["      btn('🌙 Stop DSH and put the PC to sleep', () => setPhase('confirm-sleep'), true),\n", ''],
  [
    "      React.createElement('div', { style: { ...s.muted, marginTop: 3 } },\n        'Stops the local stand started by the Harness AI launcher: the model server and this web interface. Starting it again is only possible from the PC (the launcher shortcut).'),\n",
    '',
  ],
];
for (const [from, to] of cardEdits) {
  const n = s.split(from).length - 1;
  if (n !== 1) { console.error(`client/index.js: card anchor count ${n}: ${JSON.stringify(from.slice(0, 70))}`); process.exit(1); }
  s = s.replace(from, to);
}
unlinkWrite(path, s);
console.log('client/index.js: power menu v2 applied');
