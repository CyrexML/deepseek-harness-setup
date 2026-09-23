// Per-device theme memory for remote pages (2026-09-15). Idempotent; usage: node patch-theme.mjs <plugin_dir>
//
// DSH persists Settings only from a loopback page (client/ui-settings/src/client/index.ts:58:
// `persistence = ctx.remote.$host.isLoopback ? 'host' : 'memory'`; loopback = localhost/127.x by
// page hostname). Through the bridge (phone, LAN, tunnel) the Appearance choice lives in memory and
// is gone after a reload — the phone always came back to "System". Here the bridge client keeps the
// choice in the device's localStorage and re-applies it through the host's own theme service
// (`ctx.get('theme').setTheme` / `.setFontSize`, events `theme/change`). Loopback pages are left
// alone (the host persists them itself). Guard against the host's own initial adoption ('system'
// from the memory scope) overwriting the saved choice: while a saved choice exists, events are
// ignored/re-applied until 1.5 s after it was applied. (2026-09-16: was a flat 10 s from load —
// a theme picked within the first 10 s was never saved and reverted on the next open.)
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
// Плагины лежат в pnpm-store хардлинками: запись «по месту» испортила бы копию в store,
// поэтому файл сначала удаляется (новый inode), потом пишется.
const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

import { join } from 'node:path';
const dir = process.argv[2] || '.';
const MARK = '/* dsh-bridge-en: theme memory */';
const path = join(dir, 'client/index.js');
let s = readFileSync(path, 'utf8');
if (s.includes(MARK)) { console.log('client/index.js: theme memory already present'); process.exit(0); }
const a1 = "  setupMobileExperience(rpcCall, ctx);\n";
if (s.split(a1).length !== 2) { console.error('anchor not found'); process.exit(1); }
s = s.replace(a1, a1 + `  setupThemeMemory(ctx); ${MARK}\n`);
const a2 = "function setupMobileExperience(rpcCall, ctx) {\n";
s = s.replace(a2, `${MARK}
function setupThemeMemory(ctx) {
  try {
    if (typeof window === 'undefined') return;
    const host = window.location.hostname;
    if (host === 'localhost' || host === '[::1]' || /^127(\\.\\d{1,3}){3}$/.test(host)) return;
    const KEY = 'dsh-bridge-en:theme', FONT = 'dsh-bridge-en:fontSize';
    const read = (k) => { try { return localStorage.getItem(k); } catch { return null; } };
    const write = (k, v) => { try { localStorage.setItem(k, v); } catch {} };
    const theme = () => { try { return (typeof ctx.get === 'function' ? ctx.get('theme') : undefined) || ctx.theme; } catch { return undefined; } };
    let settled = !read(KEY);   // nothing saved → nothing to protect, record from the start
    const apply = () => {
      const t = theme(); if (!t || typeof t.setTheme !== 'function') return false;
      const pref = read(KEY); const px = Number(read(FONT));
      try { if (pref && ['light', 'dark', 'system'].includes(pref)) t.setTheme(pref); } catch {}
      try { if (px && typeof t.setFontSize === 'function') t.setFontSize(px); } catch {}
      if (!settled) setTimeout(() => { settled = true; }, 1500);
      return true;
    };
    if (typeof ctx.on === 'function') ctx.on('theme/change', (snap) => {
      if (!snap) return;
      if (!settled) { const pref = read(KEY); if (pref && snap.preference !== pref) apply(); return; }
      if (snap.preference) write(KEY, snap.preference);
      if (snap.fontSize) write(FONT, String(snap.fontSize));
    });
    let n = 0; const iv = setInterval(() => { if (apply() || ++n > 30) clearInterval(iv); }, 400);
  } catch {}
}

${a2}`);
unlinkWrite(path, s);
console.log('client/index.js: theme memory patch applied');
