// Dark DeepSeek-toned splash while the client bundles load (2026-09-12). Idempotent.
// Usage: node patch-splash.mjs <plugin_dir>
//
// The host shell is an empty <div id="root"> — white until React mounts, which on a phone over the
// tunnel takes seconds. The splash is injected into HTML_HEAD_INJECTIONS (server side, lib/index.js)
// so it is painted before any bundle arrives. It is an overlay only: it never changes the app theme.
// Removed with a fade as soon as #root gets its first child (fallback: 25 s).
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
// Plugin files are hardlinks into the pnpm store: writing in place would corrupt
// the store copy, so the file is unlinked first (new inode) and then written.
const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

import { join } from 'node:path';
const dir = process.argv[2] || '.';
const MARK = 'data-dsh-bridge-splash="1"';

// DSH's own whale mark (ui-primitives FishLogo): path + viewBox read from the harness checkout.
const DSH_ROOT = process.env.DSH_ROOT ?? `${process.env.HOME}/tools/deepseek-harness`;
const FISH = readFileSync(`${DSH_ROOT}/packages/client/ui-primitives/src/FishLogo.tsx`, 'utf8');
const FISH_PATH = /FISH_LOGO_PATH = '([^']+)'/.exec(FISH)?.[1];
const FISH_VB = /width: ([\d.]+), height: ([\d.]+)/.exec(FISH);
if (!FISH_PATH || !FISH_VB) { console.error('FishLogo.tsx: whale path not found'); process.exit(1); }
const WHALE = `<svg class="w" viewBox="0 0 ${FISH_VB[1]} ${FISH_VB[2]}" aria-hidden="true"><path d="${FISH_PATH}" fill="#4d6bfe"/></svg>`;

const SPLASH = `<style ${MARK}>
html.dsh-splash-on{background:#0f1117}
#dsh-bridge-splash{position:fixed;inset:0;z-index:2147483000;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:18px;
 background:radial-gradient(120% 90% at 50% 0%,#1b2340 0%,#141a2e 45%,#0f1117 100%);color:#e6e8ef;
 font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;transition:opacity .28s ease;opacity:1}
#dsh-bridge-splash.out{opacity:0;pointer-events:none}
#root>[data-dsh-boot]{background:#0f1117!important}
#root>[data-dsh-boot] [class*="wordmark"]{color:#f3f4f8!important}
#root>[data-dsh-boot] [class*="hint"]{color:#8b93a7!important}
#root>[data-dsh-boot] [class*="spinner"]{--dsh-boot-brand:#4d6bfe;--dsw-alias-brand-primary:#4d6bfe;border-color:rgba(255,255,255,.12)!important}
#dsh-bridge-splash .w{width:112px;height:auto;filter:drop-shadow(0 10px 30px rgba(77,107,254,.45))}
#dsh-bridge-splash .t{font-size:17px;font-weight:600;letter-spacing:.2px;color:#f3f4f8}
#dsh-bridge-splash .s{font-size:12px;color:#8b93a7}
#dsh-bridge-splash .d{display:flex;gap:7px;margin-top:6px}
#dsh-bridge-splash .d i{width:7px;height:7px;border-radius:50%;background:#4d6bfe;opacity:.25;animation:dshsp 1.1s infinite}
#dsh-bridge-splash .d i:nth-child(2){animation-delay:.18s}#dsh-bridge-splash .d i:nth-child(3){animation-delay:.36s}
@keyframes dshsp{0%,80%,100%{opacity:.25;transform:scale(.85)}40%{opacity:1;transform:scale(1)}}
</style>
<script ${MARK}>!function(){try{
 var h=document.documentElement;h.classList.add('dsh-splash-on');
 var s=document.createElement('div');s.id='dsh-bridge-splash';
 s.innerHTML='${WHALE}<div class="t">DeepSeek Harness</div><div class="s">Loading workspace…</div><div class="d"><i></i><i></i><i></i></div>';
 h.appendChild(s);var done=false;
 var off=function(){if(done)return;done=true;s.classList.add('out');setTimeout(function(){h.classList.remove('dsh-splash-on');if(s.parentNode)s.parentNode.removeChild(s)},320)};
 var check=function(){var r=document.getElementById('root');if(!r||!r.childNodes.length)return false;
  var b=r.querySelector(':scope > [data-dsh-boot]');if(b&&!b.querySelector('[class*="failed"]'))return false;off();return true};
 var mo=new MutationObserver(function(){if(check())mo.disconnect()});mo.observe(h,{childList:true,subtree:true});
 setTimeout(function(){mo.disconnect();off()},25000);
}catch(e){}}();</script>
`;

const path = join(dir, 'lib/index.js');
let s = readFileSync(path, 'utf8');
if (s.includes(MARK)) {
  const a = s.indexOf(`<style ${MARK}>`), b = s.indexOf('</script>\n', s.indexOf(`<script ${MARK}>`)) + '</script>\n'.length;
  const cur = s.slice(a, b);
  if (cur === SPLASH) { console.log('lib/index.js: splash already current'); process.exit(0); }
  unlinkWrite(path, s.slice(0, a) + SPLASH + s.slice(b)); console.log('lib/index.js: splash updated'); process.exit(0);
}
const anchor = '<style data-dsh-bridge-overscroll="1">html,body{overscroll-behavior-y:none;-webkit-overflow-scrolling:touch}</style>\n';
const n = s.split(anchor).length - 1;
if (n !== 1) { console.error(`lib/index.js: MATCH COUNT ${n} for splash anchor`); process.exit(1); }
s = s.replace(anchor, anchor + SPLASH);
unlinkWrite(path, s);
console.log('lib/index.js: splash applied');
