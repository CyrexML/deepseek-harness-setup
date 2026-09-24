// Power-off from the web UI (2026-09-14). Idempotent; usage: node patch-power.mjs <plugin_dir>
//
// Settings → Remote access → ops tab gets a "Power" card next to "Restart DSH": two buttons,
// "Stop DSH (keep Ubuntu)" and "Stop DSH and Ubuntu (WSL)". Both go through the same admin gate
// as restartDsh (checkAdminAuth, requireConfigured). The service only writes a JSON signal file
// ({mode, at}) at $DSH_POWER_REQUEST_FILE (set by start-web.sh); the Windows launcher
// (harness-start.ps1 -Hidden) polls that file and does the actual Stop-Everything / wsl --shutdown.
// The bridge itself stays platform-neutral: without the env var the RPC fails with a clear message.
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
// Plugin files are hardlinks into the pnpm store: writing in place would corrupt
// the store copy, so the file is unlinked first (new inode) and then written.
const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

import { join } from 'node:path';
const dir = process.argv[2] || '.';
const MARK = '/* dsh-bridge-en: power */';

// The anchor can move with a new plugin version (`async restartDsh()` became
// `async restartDsh(opts = {})` in 2.10.12), so it is a list of variants: the
// first one occurring exactly once is used, and `{ANCHOR}` in the replacement
// text is substituted with it.
function patch(file, edits) {
  const path = join(dir, file);
  let s = readFileSync(path, 'utf8');
  let applied = 0, skipped = 0;
  for (const [anchors, bRaw] of edits) {
    const list = Array.isArray(anchors) ? anchors : [anchors];
    const a = list.find(x => s.split(x).length - 1 === 1);
    const b = a === undefined ? bRaw : bRaw.split('{ANCHOR}').join(a);
    if (s.includes(b)) { skipped++; continue; }
    if (a === undefined) {
      const counts = list.map(x => `${JSON.stringify(x.slice(0, 70))}=${s.split(x).length - 1}`).join(', ');
      console.error(`${file}: MATCH COUNT ${counts}`); process.exit(1);
    }
    s = s.replace(a, b); applied++;
  }
  unlinkWrite(path, s);
  console.log(`${file}: power patch applied ${applied}, already present ${skipped}`);
}

patch('lib/bridge-rpc-constants.js', [[
  "  restartDsh: 'restartDsh',\n",
  "  restartDsh: 'restartDsh',\n  powerOff: 'powerOff', " + MARK + "\n",
]]);

patch('lib/bridge-rpc.js', [[
  "        if (endpoint === BRIDGE_ENDPOINTS.restartDsh) {\n",
  `        if (endpoint === BRIDGE_ENDPOINTS.powerOff) { ${MARK}
          const adminErr = checkAdminAuth(authManager, payload, { requireConfigured: true });
          if (adminErr) return adminErr;
          if (typeof service.powerOff !== 'function') return fail('bad-request', 'Power service unavailable');
          return ok(await service.powerOff(payload?.mode));
        }

        if (endpoint === BRIDGE_ENDPOINTS.restartDsh) {
`,
]]);

patch('lib/index.js', [[
  ["  async restartDsh() {\n", "  async restartDsh(opts = {}) {\n"],
  `  ${MARK} // signal file for the Windows launcher; see tools/patch-power.mjs
  async powerOff(mode) {
    const file = process.env.DSH_POWER_REQUEST_FILE;
    if (!file) throw new Error('DSH_POWER_REQUEST_FILE is not set — DSH was not started by the launcher, nothing to signal');
    const m = ['wsl', 'sleep', 'shutdown'].includes(mode) ? mode : 'dsh';
    await writeFile(file, JSON.stringify({ mode: m, at: Date.now() }));
    this.logger?.info('Power-off requested (%s) → %s', m, file);
    return { mode: m };
  }

{ANCHOR}`,
]]);

patch('client/index.js', [
  [
    "// 运维 Tab 内的远程工作区管理卡片\nfunction RemoteWorkspaceCard({ rpcCall }) {\n",
    `${MARK}
// Power card: stop the whole stand (model + web) from the UI, optionally WSL too.
function PowerOffCard({ rpcCall }) {
  const [phase, setPhase] = React.useState(null); // null | 'confirm-dsh' | 'confirm-wsl' | 'sent' | 'error'
  const [text, setText] = React.useState('');
  const send = React.useCallback(async (mode) => {
    try {
      await rpcCall(BRIDGE_ENDPOINTS.powerOff, { mode });
      setPhase('sent');
      setText({
        wsl: 'Shutdown signal sent. The model, the web interface and Ubuntu (WSL) will stop within a few seconds; this page will lose its connection.',
        sleep: 'Signal sent. The stand will stop and the PC will go to sleep within a few seconds; this page will lose its connection.',
        shutdown: 'Signal sent. The stand will stop and the PC will shut down within about 10 seconds; this page will lose its connection.',
      }[mode] || 'Shutdown signal sent. The model and the web interface will stop within a few seconds; this page will lose its connection.');
    } catch (e) {
      setPhase('error');
      setText('Could not send the shutdown signal: ' + (e?.message || String(e)));
    }
  }, [rpcCall]);
  const btn = (label, onClick, danger) => React.createElement('button', {
    type: 'button',
    style: { ...s.btnGhost, height: 32, fontSize: 12, padding: '0 14px', ...(danger ? { borderColor: 'var(--dsw-alias-state-error-primary,#dc2626)', color: 'var(--dsw-alias-state-error-primary,#dc2626)' } : {}) },
    onClick,
  }, label);
  return React.createElement('div', { style: { ...s.card, marginBottom: 16 } },
    React.createElement('div', { style: { marginBottom: 10 } },
      React.createElement('div', { style: { ...s.label, fontSize: 13, display: 'flex', alignItems: 'center', gap: 6 } }, '⏻ Power'),
      React.createElement('div', { style: { ...s.muted, marginTop: 3 } },
        'Stops the local stand started by the Harness AI launcher: the model server and this web interface. Starting it again is only possible from the PC (the launcher shortcut).'),
    ),
    phase === null && React.createElement('div', { style: { display: 'flex', gap: 8, flexWrap: 'wrap' } },
      btn('⏻ Stop DSH (keep Ubuntu)', () => setPhase('confirm-dsh'), false),
      btn('⏻ Stop DSH and Ubuntu (WSL)', () => setPhase('confirm-wsl'), true),
      btn('🌙 Stop DSH and put the PC to sleep', () => setPhase('confirm-sleep'), true),
      btn('⏻ Stop everything and shut down the PC', () => setPhase('confirm-shutdown'), true),
    ),
    phase && phase.startsWith('confirm-') && React.createElement('div', { style: { display: 'flex', flexDirection: 'column', gap: 8 } },
      React.createElement('div', { style: { fontSize: 12, color: 'var(--dsw-alias-state-error-primary,#dc2626)', fontWeight: 500 } },
        ({
          'confirm-wsl': 'This also shuts down WSL: every Ubuntu process ends — Claude Code sessions, Docker, open terminals. Continue?',
          'confirm-sleep': 'The stand stops and the PC goes to sleep. It cannot be woken from the phone — only at the PC. Continue?',
          'confirm-shutdown': 'The stand and Ubuntu (WSL) stop and the PC powers off completely. It can only be turned on again at the PC. Continue?',
        })[phase] || 'The model and the web interface will stop; the phone loses access until the launcher is started on the PC. Continue?'),
      React.createElement('div', { style: { display: 'flex', gap: 8 } },
        btn(({ 'confirm-wsl': 'Yes, stop DSH and WSL', 'confirm-sleep': 'Yes, stop and sleep', 'confirm-shutdown': 'Yes, shut down the PC' })[phase] || 'Yes, stop DSH', () => send(phase.slice(8)), true),
        btn('Cancel', () => setPhase(null), false),
      ),
    ),
    (phase === 'sent' || phase === 'error') && React.createElement('div', {
      style: { fontSize: 12, fontWeight: 500, color: phase === 'error' ? 'var(--dsw-alias-state-error-primary,#dc2626)' : 'var(--dsw-alias-state-info-primary,#2563eb)' },
    }, text),
  );
}

// 运维 Tab 内的远程工作区管理卡片
function RemoteWorkspaceCard({ rpcCall }) {
`,
  ],
  // Dedicated "Power" tab (first draft appended the card to the bottom of Ops & monitoring — the
  // user never found it there). The reversal edit below undoes that draft on an already-patched file.
  [
    "      React.createElement(RestartDshCard, { rpcCall: authRpcCall }),\n      React.createElement(PowerOffCard, { rpcCall: authRpcCall }), " + MARK + "\n    );\n",
    "      React.createElement(RestartDshCard, { rpcCall: authRpcCall }),\n    );\n",
  ],
  [
    "  { id: 'ops',      label: 'Ops & monitoring',  icon: Icons.ops },\n];\n",
    "  { id: 'ops',      label: 'Ops & monitoring',  icon: Icons.ops },\n  { id: 'power',    label: 'Power',  icon: Icons.power }, " + MARK + "\n];\n",
  ],
  [
    "  ops: (props) => React.createElement('svg', ",
    MARK + " power: (props) => React.createElement('svg', { viewBox: '0 0 24 24', width: 16, height: 16, fill: 'none', stroke: 'currentColor', strokeWidth: 2, strokeLinecap: 'round', strokeLinejoin: 'round', ...props },\n    React.createElement('path', { d: 'M18.36 6.64a9 9 0 1 1-12.73 0' }), React.createElement('line', { x1: 12, y1: 2, x2: 12, y2: 12 })),\n  ops: (props) => React.createElement('svg', ",
  ],
  [
    "  } else if (activeTab === 'ops') {\n",
    `  } else if (activeTab === 'power') { ${MARK}
    tabContent = React.createElement(React.Fragment, null,
      React.createElement(PowerOffCard, { rpcCall: authRpcCall }),
      React.createElement(RestartDshCard, { rpcCall: authRpcCall }),
    );
  } else if (activeTab === 'ops') {
`,
  ],
  // Sidebar button: ⏻ next to the DSH logo in the left sidebar (desktop and the mobile drawer).
  // Plain DOM, re-attached after React re-renders; admin token via unlock-manager (loopback on the
  // PC, password prompt inside the popover elsewhere), same powerOff RPC as the settings card.
  [
    "  setupMobileExperience(rpcCall, ctx);\n",
    "  setupMobileExperience(rpcCall, ctx);\n  setupPowerButton(rpcCall); " + MARK + "\n",
  ],
  [
    "function setupMobileExperience(rpcCall, ctx) {\n",
    `${MARK}
function setupPowerButton(rpcCall) {
  if (typeof document === 'undefined') return;
  const isLocalhost = !window.location.hostname || ['127.0.0.1', 'localhost', '::1'].includes(window.location.hostname) || window.location.hostname.endsWith('.local');
  const style = document.createElement('style');
  style.dataset.plugin = '@wenbin_wb/dsh-bridge';
  style.dataset.pluginCss = '@wenbin_wb/dsh-bridge/power-button';
  style.textContent = \`
    .dsh-power-btn{display:inline-flex;align-items:center;justify-content:center;width:32px;height:32px;margin-left:4px;order:99;border:none;border-radius:8px;background:transparent;color:var(--dsw-alias-label-secondary,#6b7280);cursor:pointer;flex-shrink:0}
    .dsh-power-btn:hover{background:var(--dsw-alias-bg-layer-2,rgba(0,0,0,.06));color:var(--dsw-alias-state-error-primary,#dc2626)}
    .dsh-power-btn svg{width:18px;height:18px}
    .dsh-power-pop{position:fixed;z-index:2147483000;box-sizing:border-box;width:min(320px,calc(100vw - 24px));padding:14px;border-radius:12px;background:var(--dsw-alias-bg-layer-1,#fff);color:var(--dsw-alias-label-primary,#111827);box-shadow:0 12px 40px rgba(0,0,0,.28);border:1px solid var(--dsw-alias-border-l2,#e5e7eb);font:13px/1.45 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif}
    .dsh-power-pop h4{margin:0 0 6px;font-size:14px}
    .dsh-power-pop p{margin:0 0 10px;color:var(--dsw-alias-label-secondary,#6b7280);font-size:12px}
    .dsh-power-pop .row{display:flex;flex-direction:column;gap:8px}
    .dsh-power-pop button{font:inherit;height:34px;padding:0 12px;border-radius:8px;border:1px solid var(--dsw-alias-border-l2,#d1d5db);background:transparent;color:inherit;cursor:pointer;text-align:left}
    .dsh-power-pop button.danger{border-color:var(--dsw-alias-state-error-primary,#dc2626);color:var(--dsw-alias-state-error-primary,#dc2626)}
    .dsh-power-pop button.primary{background:var(--dsw-alias-brand-primary,#4d6bfe);border-color:transparent;color:#fff}
    .dsh-power-pop input{font:inherit;height:34px;padding:0 10px;border-radius:8px;border:1px solid var(--dsw-alias-border-l2,#d1d5db);background:var(--dsw-alias-bg-layer-2,#f9fafb);color:inherit}
    .dsh-power-pop .msg{font-size:12px;font-weight:500;color:var(--dsw-alias-state-info-primary,#2563eb)}
    .dsh-power-pop .msg.err{color:var(--dsw-alias-state-error-primary,#dc2626)}
    .dsh-power-backdrop{position:fixed;inset:0;z-index:2147482999;background:rgba(0,0,0,.25)}
  \`;
  document.head.appendChild(style);
  const ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18.36 6.64a9 9 0 1 1-12.73 0"/><line x1="12" y1="2" x2="12" y2="12"/></svg>';
  let pop = null, backdrop = null;
  const close = () => { pop?.remove(); backdrop?.remove(); pop = backdrop = null; };
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
    backdrop = el('div', 'dsh-power-backdrop'); backdrop.onclick = close; document.body.appendChild(backdrop);
    pop = el('div', 'dsh-power-pop');
    const r = anchor.getBoundingClientRect();
    pop.style.top = Math.min(r.bottom + 8, window.innerHeight - 260) + 'px';
    pop.style.left = Math.max(12, Math.min(r.left, window.innerWidth - 332)) + 'px';
    const render = (state) => {
      pop.innerHTML = '';
      pop.appendChild(el('h4', null, '⏻ Power'));
      if (state.phase === 'menu') {
        pop.appendChild(el('p', null, 'Stops the local stand started by the Harness AI launcher. Starting it again is only possible from the PC.'));
        const row = el('div', 'row');
        const b1 = el('button', null, 'Stop DSH (keep Ubuntu)'); b1.onclick = () => render({ phase: 'confirm', mode: 'dsh' });
        const b2 = el('button', 'danger', 'Stop DSH and Ubuntu (WSL)'); b2.onclick = () => render({ phase: 'confirm', mode: 'wsl' });
        const b4 = el('button', 'danger', 'Stop DSH and put the PC to sleep'); b4.onclick = () => render({ phase: 'confirm', mode: 'sleep' });
        const b5 = el('button', 'danger', 'Stop everything and shut down the PC'); b5.onclick = () => render({ phase: 'confirm', mode: 'shutdown' });
        const b3 = el('button', null, 'Cancel'); b3.onclick = close;
        row.append(b1, b2, b4, b5, b3); pop.appendChild(row);
      } else if (state.phase === 'confirm' || state.phase === 'password') {
        pop.appendChild(el('p', null, ({
          wsl: 'This also shuts down WSL: every Ubuntu process ends — Claude Code sessions, Docker, open terminals. Continue?',
          sleep: 'The stand stops and the PC goes to sleep. It cannot be woken from the phone — only at the PC. Continue?',
          shutdown: 'The stand and Ubuntu (WSL) stop and the PC powers off completely. It can only be turned on again at the PC. Continue?',
        })[state.mode] || 'The model and the web interface will stop; the phone loses access until the launcher is started on the PC. Continue?'));
        const row = el('div', 'row');
        let input = null;
        if (state.phase === 'password') {
          pop.appendChild(el('div', 'msg err', state.error || 'Admin password required'));
          input = el('input'); input.type = 'password'; input.placeholder = 'admin password'; input.autocomplete = 'current-password';
          row.appendChild(input); setTimeout(() => input.focus(), 50);
        }
        const yes = el('button', 'primary', ({ wsl: 'Yes, stop DSH and WSL', sleep: 'Yes, stop and sleep', shutdown: 'Yes, shut down the PC' })[state.mode] || 'Yes, stop DSH');
        yes.onclick = async () => {
          yes.disabled = true; yes.textContent = 'Sending…';
          let res;
          try { res = await callPowerOff(state.mode, input ? input.value : undefined); }
          catch (e) { render({ phase: 'done', error: e?.message || String(e) }); return; }
          if (res?.ok) render({ phase: 'done', mode: state.mode });
          else if (needsAdmin(res) || input) render({ phase: 'password', mode: state.mode, error: input ? (res?.error?.message || 'Wrong admin password') : undefined });
          else render({ phase: 'done', error: res?.error?.message || 'Request failed' });
        };
        if (input) input.onkeydown = (e) => { if (e.key === 'Enter') yes.click(); };
        const no = el('button', null, 'Cancel'); no.onclick = close;
        row.append(yes, no); pop.appendChild(row);
      } else {
        pop.appendChild(el('div', 'msg' + (state.error ? ' err' : ''), state.error
          ? 'Could not send the shutdown signal: ' + state.error
          : (({
            wsl: 'Shutdown signal sent. The model, the web interface and Ubuntu (WSL) will stop within a few seconds; this page will lose its connection.',
            sleep: 'Signal sent. The stand will stop and the PC will go to sleep within a few seconds; this page will lose its connection.',
            shutdown: 'Signal sent. The stand will stop and the PC will shut down within about 10 seconds; this page will lose its connection.',
          })[state.mode] || 'Shutdown signal sent. The model and the web interface will stop within a few seconds; this page will lose its connection.')));
        const ok = el('button', null, 'Close'); ok.style.marginTop = '10px'; ok.onclick = close; pop.appendChild(ok);
      }
    };
    render({ phase: 'menu' });
    document.body.appendChild(pop);
  };
  const ensure = () => {
    for (const row of document.querySelectorAll('div[class*="_logoRow"]')) {
      if (row.querySelector('.dsh-power-btn')) continue;
      const btn = el('button', 'dsh-power-btn');
      btn.type = 'button'; btn.title = 'Power: stop the stand'; btn.setAttribute('aria-label', 'Power'); btn.innerHTML = ICON;
      btn.onclick = (e) => { e.stopPropagation(); open(btn); };
      row.appendChild(btn); // last in the row (order:99): brand … collapse-toggle, power
    }
  };
  ensure();
  new MutationObserver(ensure).observe(document.body, { childList: true, subtree: true });
}

function setupMobileExperience(rpcCall, ctx) {
`,
  ],
]);
