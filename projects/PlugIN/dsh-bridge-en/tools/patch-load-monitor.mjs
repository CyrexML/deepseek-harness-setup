// What the machine is doing, next to what the model is doing. Idempotent.
//   node patch-load-monitor.mjs <plugin_dir>
//
// The interface already shows how full the context is; this adds the other half
// of the same question - what the work costs the hardware. A chip in the sidebar
// header (and in the mobile header) carries GPU load, temperature and power
// draw, and opens a card with VRAM, the WSL CPU load, memory, and the energy the
// GPU has drawn since the stand started.
//
// Where the numbers come from, and what they do NOT cover:
//   * GPU - nvidia-smi, which reports the real device even from inside WSL: the
//     27B model is served by llama-server on the Windows side, and its VRAM
//     shows up here all the same. One call is about 50 ms.
//   * CPU - /proc/stat deltas, so it is Ubuntu's view: the stand's own load,
//     not everything the PC is doing.
//   * memory - the WSL VM's, for the same reason.
//   * energy - integrated from power.draw; consumer cards have no energy
//     counter (total_energy_consumption is rejected by this driver). It is the
//     GPU alone, not the machine at the wall: CPU package power and CPU
//     temperature are not exposed to WSL, and reading them would mean installing
//     a monitoring service on the Windows side.
// The card says all of that, so a number is never read for more than it is.
//
// The sampler runs in the bridge service from the moment the plugin loads - that
// is what makes "since the stand started" true rather than "since this page was
// opened". It is idle-cheap: one nvidia-smi every 15 seconds, plus the page's
// own polling while the chip is on screen.
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';

const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };
const dir = process.argv[2] || '.';
const MARK = '/* dsh-bridge-en: load monitor */';

function patch(file, edits) {
  const path = join(dir, file);
  let s = readFileSync(path, 'utf8');
  let applied = 0, skipped = 0;
  for (const [a, b] of edits) {
    if (s.includes(b)) { skipped++; continue; }
    const n = s.split(a).length - 1;
    if (n !== 1) { console.error(`${file}: MATCH COUNT ${n} for ${JSON.stringify(a.slice(0, 70))}`); process.exit(1); }
    s = s.replace(a, b); applied++;
  }
  unlinkWrite(path, s);
  console.log(`${file}: load monitor applied ${applied}, already present ${skipped}`);
}

patch('lib/bridge-rpc-constants.js', [[
  "  restartDsh: 'restartDsh',\n",
  "  restartDsh: 'restartDsh',\n  systemLoad: 'systemLoad', " + MARK + "\n",
]]);

patch('lib/bridge-rpc.js', [[
  "        if (endpoint === BRIDGE_ENDPOINTS.restartDsh) {\n",
  `        if (endpoint === BRIDGE_ENDPOINTS.systemLoad) { ${MARK}
          if (typeof service.systemLoad !== 'function') return fail('bad-request', 'Load monitor unavailable');
          return ok(await service.systemLoad());
        }

        if (endpoint === BRIDGE_ENDPOINTS.restartDsh) {
`,
]]);

const SERVICE = `${MARK}
// Hardware sampling for the load chip. Module state, started at plugin load, so
// the energy total covers the whole run of the stand and not just the time a
// page happened to be open.
const __dshLoad = {
  startedAt: Date.now(),
  energyWs: 0,        // GPU joules, integrated from power.draw
  lastPowerAt: 0,
  lastPowerW: 0,
  cpuPrev: null,      // previous /proc/stat totals, for the delta
  timer: null,
  gpuBroken: false,   // no nvidia-smi: stop asking
};

function __dshRunGpuQuery() {
  return new Promise((resolve) => {
    if (__dshLoad.gpuBroken) { resolve(null); return; }
    let done = false;
    const finish = (v) => { if (!done) { done = true; resolve(v); } };
    let child;
    try {
      child = spawn('nvidia-smi', ['--query-gpu=name,utilization.gpu,temperature.gpu,power.draw,power.limit,memory.used,memory.total,clocks.sm', '--format=csv,noheader,nounits'], { stdio: ['ignore', 'pipe', 'ignore'] });
    } catch { __dshLoad.gpuBroken = true; finish(null); return; }
    let out = '';
    child.stdout.on('data', (b) => { out += b.toString(); });
    child.on('error', () => { __dshLoad.gpuBroken = true; finish(null); });
    child.on('close', () => {
      const row = out.split('\\n')[0];
      if (!row || !row.includes(',')) { finish(null); return; }
      const f = row.split(',').map((x) => x.trim());
      const num = (i) => { const v = Number(f[i]); return Number.isFinite(v) ? v : null; };
      finish({ name: f[0], utilPct: num(1), tempC: num(2), powerW: num(3), powerLimitW: num(4), memUsedMb: num(5), memTotalMb: num(6), clockMhz: num(7) });
    });
    setTimeout(() => finish(null), 2000);
  });
}

async function __dshReadCpu() {
  let text;
  try { text = await readFile('/proc/stat', 'utf8'); } catch { return null; }
  const line = text.split('\\n').find((l) => l.startsWith('cpu '));
  if (!line) return null;
  const v = line.split(/\\s+/).slice(1).map(Number).filter((n) => Number.isFinite(n));
  if (v.length < 4) return null;
  const idle = (v[3] || 0) + (v[4] || 0);
  const total = v.reduce((a, b) => a + b, 0);
  const prev = __dshLoad.cpuPrev;
  __dshLoad.cpuPrev = { idle, total };
  if (!prev || total <= prev.total) return null;
  const busy = (total - prev.total) - (idle - prev.idle);
  return Math.max(0, Math.min(100, Math.round((busy / (total - prev.total)) * 100)));
}

async function __dshSampleLoad() {
  const gpu = await __dshRunGpuQuery();
  const now = Date.now();
  if (gpu && typeof gpu.powerW === 'number') {
    // Trapezoid between samples: the draw swings hard between a generating GPU
    // and an idle one, and the midpoint is a much better estimate than either end.
    if (__dshLoad.lastPowerAt) {
      const dt = (now - __dshLoad.lastPowerAt) / 1000;
      if (dt > 0 && dt < 600) __dshLoad.energyWs += ((__dshLoad.lastPowerW + gpu.powerW) / 2) * dt;
    }
    __dshLoad.lastPowerAt = now;
    __dshLoad.lastPowerW = gpu.powerW;
  }
  return gpu;
}

if (!__dshLoad.timer) {
  __dshLoad.timer = setInterval(() => { __dshSampleLoad().catch(() => {}); }, 15000);
  if (typeof __dshLoad.timer.unref === 'function') __dshLoad.timer.unref();
  __dshSampleLoad().catch(() => {});
  __dshReadCpu().catch(() => {});
}

`;

patch('lib/index.js', [
  // helpers above the service class, so the module state is created once at plugin load
  ['class BridgeService {', SERVICE + 'class BridgeService {'],
  [
    "  async restartDsh(opts = {}) {\n",
    `  ${MARK} // the load chip's data; see tools/patch-load-monitor.mjs
  async systemLoad() {
    const gpu = await __dshSampleLoad();
    const cpuPct = await __dshReadCpu();
    const totalMem = totalmem();
    const freeMem = freemem();
    return {
      gpu,
      cpu: { pct: cpuPct, cores: (cpus() || []).length, model: (cpus() || [])[0]?.model || null },
      memory: { usedBytes: totalMem - freeMem, totalBytes: totalMem },
      energy: { wh: __dshLoad.energyWs / 3600, sinceMs: Date.now() - __dshLoad.startedAt, measured: __dshLoad.lastPowerAt > 0 },
    };
  }

  async restartDsh(opts = {}) {
`,
  ],
]);

const CLIENT = `${MARK}
// The load chip: GPU load / temperature / draw in the sidebar header and in the
// mobile header, opening a card with the rest. Polls slowly while closed.
function setupLoadMonitor(rpcCall) {
  if (typeof document === 'undefined' || typeof window === 'undefined') return;
  if (window.__dshLoadMonitor) return;
  window.__dshLoadMonitor = true;

  const style = document.createElement('style');
  style.dataset.plugin = '@wenbin_wb/dsh-bridge';
  style.dataset.pluginCss = '@wenbin_wb/dsh-bridge/load-monitor';
  style.textContent = [
    '.dsh-load-chip{display:inline-flex;align-items:center;gap:5px;height:26px;padding:0 8px;margin-left:4px;margin-right:4px;order:98;border:1px solid var(--dsw-alias-border-l2,#e5e7eb);border-radius:999px;background:transparent;color:var(--dsw-alias-label-secondary,#6b7280);font:500 11px/1 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;cursor:pointer;white-space:nowrap;flex-shrink:0;pointer-events:auto !important}',
    '.dsh-load-chip:hover{background:var(--dsw-alias-bg-layer-2,rgba(0,0,0,.06))}',
    // The mobile top bar is transparent to touches on purpose
    // (.dsh-mobile-app-header carries pointer-events: none so the conversation
    // under it still scrolls), and every control in it re-enables them for
    // itself - which is why the chip above declares pointer-events: auto. Without
    // it a tap goes straight through the chip into the page beneath.
    '.dsh-load-chip .dot{width:7px;height:7px;border-radius:50%;background:currentColor;flex-shrink:0}',
    // The sidebar header has room for the wordmark or for the chip, not both:
    // at 256px the brand is squeezed to an unreadable stub. The mark stays, the
    // name moves to the button's tooltip. Scoped with :has, so a header without
    // a chip (the phone, where the chip goes elsewhere) keeps its name.
    'div[class*="_logoRow"]:has(.dsh-load-chip) [class*="_brandName"]{display:none !important}',
    // On a narrow header the draw drops out and load plus temperature remain.
    '@media (max-width: 768px){.dsh-load-chip .w{display:none}}',
    '.dsh-load-pop{position:fixed;z-index:2147483000;box-sizing:border-box;width:min(300px,calc(100vw - 24px));padding:14px;border-radius:12px;background:var(--dsw-alias-bg-layer-1,#fff);color:var(--dsw-alias-label-primary,#111827);box-shadow:0 12px 40px rgba(0,0,0,.28);border:1px solid var(--dsw-alias-border-l2,#e5e7eb);font:13px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}',
    '.dsh-load-pop h4{margin:0 0 2px;font-size:13px}',
    '.dsh-load-pop .sub{margin:0 0 10px;font-size:11px;color:var(--dsw-alias-label-tertiary,#9ca3af)}',
    '.dsh-load-pop .r{display:flex;justify-content:space-between;gap:10px;padding:3px 0;font-size:12px}',
    '.dsh-load-pop .r span:first-child{color:var(--dsw-alias-label-secondary,#6b7280)}',
    '.dsh-load-pop .r span:last-child{font-variant-numeric:tabular-nums}',
    '.dsh-load-pop .bar{height:5px;border-radius:3px;background:var(--dsw-alias-bg-layer-2,rgba(0,0,0,.08));overflow:hidden;margin:3px 0 9px}',
    '.dsh-load-pop .bar i{display:block;height:100%;background:var(--dsw-alias-state-info-primary,#2563eb)}',
    '.dsh-load-pop .note{margin-top:10px;padding-top:9px;border-top:1px solid var(--dsw-alias-border-l2,#eee);font-size:11px;color:var(--dsw-alias-label-tertiary,#9ca3af)}',
  ].join('\\n');
  document.head.appendChild(style);

  let data = null;
  let lastError = null;
  let pop = null;
  let timer = null;

  const pct = (v) => (typeof v === 'number' ? Math.round(v) + '%' : '—');
  const heat = (c) => (typeof c === 'number' ? Math.round(c) + '\\u00b0' : '—');
  const watt = (w) => (typeof w === 'number' ? Math.round(w) + ' W' : '—');
  const gib = (mb) => (typeof mb === 'number' ? (mb / 1024).toFixed(1) + ' GiB' : '—');
  const hhmm = (ms) => {
    const m = Math.floor(ms / 60000);
    return m < 60 ? m + ' min' : Math.floor(m / 60) + ' h ' + (m % 60) + ' min';
  };

  const paint = () => {
    const g = data && data.gpu;
    for (const chip of document.querySelectorAll('.dsh-load-chip')) {
      const text = g
        ? pct(g.utilPct) + ' \\u00b7 ' + heat(g.tempC) + '<span class="w"> \\u00b7 ' + watt(g.powerW) + '</span>'
        : 'no GPU data';
      chip.innerHTML = '<i class="dot"></i>' + text;
      chip.title = g ? g.name + ' \\u2014 load, temperature, power draw' : (lastError || 'nvidia-smi did not answer');
      // Idle stays neutral; a hot or hard-working card colours the dot.
      const dot = chip.querySelector('.dot');
      if (dot && g) {
        const hot = (g.tempC || 0) >= 80 || (g.utilPct || 0) >= 90;
        const busy = (g.utilPct || 0) >= 40;
        dot.style.background = hot ? 'var(--dsw-alias-state-error-primary,#dc2626)' : busy ? 'var(--dsw-alias-state-warning-primary,#d97706)' : 'var(--dsw-alias-state-success-primary,#16a34a)';
      }
    }
    if (pop) pop.innerHTML = card();
  };

  const card = () => {
    const g = data && data.gpu;
    const c = data && data.cpu;
    const m = data && data.memory;
    const e = data && data.energy;
    const row = (k, v) => '<div class="r"><span>' + k + '</span><span>' + v + '</span></div>';
    const bar = (v) => '<div class="bar"><i style="width:' + Math.max(0, Math.min(100, v || 0)) + '%"></i></div>';
    let html = '<h4>' + (g ? g.name : 'GPU') + '</h4>';
    html += '<p class="sub">what the machine is doing right now</p>';
    if (!data && lastError) html += '<p class="sub">The figures could not be read: ' + lastError + '</p>';
    if (g) {
      html += row('Load', pct(g.utilPct)) + bar(g.utilPct);
      html += row('Temperature', heat(g.tempC));
      html += row('Power draw', watt(g.powerW) + (typeof g.powerLimitW === 'number' ? ' of ' + watt(g.powerLimitW) : ''));
      html += row('Video memory', gib(g.memUsedMb) + ' of ' + gib(g.memTotalMb));
      if (typeof g.clockMhz === 'number') html += row('Clock', g.clockMhz + ' MHz');
    } else {
      html += '<p class="sub">nvidia-smi did not answer, so there are no GPU figures.</p>';
    }
    if (e && e.measured) html += row('Energy since start', (e.wh < 10 ? e.wh.toFixed(2) : Math.round(e.wh)) + ' Wh over ' + hhmm(e.sinceMs));
    if (c) { html += row('CPU (Ubuntu)', pct(c.pct) + (c.cores ? ' of ' + c.cores + ' cores' : '')); html += bar(c.pct); }
    if (m) html += row('Memory (Ubuntu)', (m.usedBytes / 1073741824).toFixed(1) + ' of ' + (m.totalBytes / 1073741824).toFixed(1) + ' GiB');
    html += '<div class="note">GPU figures come from the card itself and cover the whole machine. CPU, memory and the energy total are Ubuntu\\u2019s view and the GPU alone \\u2014 CPU power and temperature are not exposed to WSL.</div>';
    return html;
  };

  const poll = async () => {
    try {
      const res = await rpcCall(BRIDGE_ENDPOINTS.systemLoad, {});
      // The channel answers { ok, value }; older builds answered with the payload itself.
      data = (res && (res.value || res.data)) || res || null;
      lastError = null;
      paint();
    } catch (e) {
      // Kept rather than swallowed: without it a chip that never fills in gives
      // no clue whether the sensors or the channel is the problem.
      lastError = String((e && e.message) || e).slice(0, 160);
      paint();
    }
  };

  const schedule = () => {
    if (timer) clearInterval(timer);
    timer = setInterval(() => { if (!document.hidden) poll(); }, pop ? 2000 : 10000);
  };

  const closePop = () => { if (pop) { pop.remove(); pop = null; schedule(); } };
  const openPop = (anchor) => {
    closePop();
    pop = document.createElement('div');
    pop.className = 'dsh-load-pop';
    pop.innerHTML = card();
    document.body.appendChild(pop);
    const r = anchor.getBoundingClientRect();
    const w = pop.getBoundingClientRect().width;
    pop.style.left = Math.max(12, Math.min(window.innerWidth - w - 12, r.left)) + 'px';
    pop.style.top = Math.min(window.innerHeight - 20, r.bottom + 8) + 'px';
    schedule();
    poll();
    setTimeout(() => {
      const away = (ev) => {
        if (pop && !pop.contains(ev.target) && !ev.target.closest('.dsh-load-chip')) { closePop(); document.removeEventListener('click', away, true); }
      };
      document.addEventListener('click', away, true);
    }, 0);
  };

  const makeChip = () => {
    const chip = document.createElement('button');
    chip.type = 'button';
    chip.className = 'dsh-load-chip';
    chip.setAttribute('aria-label', 'Machine load');
    chip.innerHTML = '<i class="dot"></i>\\u2026';
    chip.addEventListener('click', (ev) => { ev.stopPropagation(); if (pop) closePop(); else openPop(chip); });
    return chip;
  };

  const ensure = () => {
    // One chip, in the header that is actually on screen: the sidebar keeps a
    // second logo row for its collapsed state, and mounting in both puts two
    // chips in the interface at once.
    // querySelectorAll returns document order, not selector order, and the
    // drawer's sidebar header comes before the mobile top bar - mounting there
    // hides the chip behind a closed drawer. Ask for the top bar first.
    const visible = (el) => el && el.getBoundingClientRect().width > 0;
    const host = [...document.querySelectorAll('.dsh-mobile-app-header')].find(visible)
      || [...document.querySelectorAll('div[class*="_logoRow"]')].find(visible);
    for (const chip of document.querySelectorAll('.dsh-load-chip')) {
      if (!host || !host.contains(chip)) chip.remove();
    }
    if (host && !host.querySelector('.dsh-load-chip')) host.appendChild(makeChip());
    // The hidden wordmark keeps its text as the button's tooltip, so the build
    // and version stay one hover away rather than disappearing with it.
    const brand = host && host.querySelector('[class*="_brand"]');
    if (brand && !brand.getAttribute('title')) {
      const name = (brand.textContent || '').trim();
      if (name) brand.setAttribute('title', name);
    }
    if (data) paint();
  };
  // Coalesced to one pass per frame: the interface mutates the DOM constantly
  // while a turn streams, and a document-wide query on every mutation record is
  // felt as jank on a phone.
  let pending = 0;
  const ensureSoon = () => {
    if (pending) return;
    pending = requestAnimationFrame(() => { pending = 0; ensure(); });
  };
  ensure();
  new MutationObserver(ensureSoon).observe(document.body, { childList: true, subtree: true });
  window.addEventListener('resize', () => closePop());
  poll();
  schedule();
}

`;

patch('client/index.js', [
  ['function setupPowerButton(rpcCall) {', CLIENT + 'function setupPowerButton(rpcCall) {'],
  [
    "  setupPowerButton(rpcCall); /* dsh-bridge-en: power */\n",
    "  setupPowerButton(rpcCall); /* dsh-bridge-en: power */\n  setupLoadMonitor(rpcCall); " + MARK + "\n",
  ],
]);
