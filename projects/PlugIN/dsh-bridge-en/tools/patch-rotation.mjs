// Rotation fixes for the phone (2026-09-12). Idempotent; usage: node patch-rotation.mjs <plugin_dir>
//
// 1. lib/index.js — PWA manifest declared `orientation: 'any'`. For an installed PWA Android maps
//    "any" to FULL_SENSOR: the app follows the accelerometer even when the system auto-rotate lock
//    is ON. Without the field the app follows the system setting (USER), which is what a user with
//    the lock on expects.
// 2. client/index.js — the sidebar drawer (body.dsh-drawer-open + .dsh-mobile-backdrop, z 9999,
//    inset 0) exists only under the ≤768px media query. Rotate to landscape with the drawer open:
//    the CSS switches to the desktop layout, the class stays; rotate back: backdrop + drawer are
//    shown again and the backdrop eats every tap (header, composer, toolbar). Reproduced headless
//    with viewport 412x915 → 915x412 → 412x915. Fix: on a layout switch across 768px drop the
//    drawer class — a drawer must never survive a layout change.
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
// Plugin files are hardlinks into the pnpm store: writing in place would corrupt
// the store copy, so the file is unlinked first (new inode) and then written.
const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

import { join } from 'node:path';
const dir = process.argv[2] || '.';
const MARK = '/* dsh-bridge-en: rotation fix */';

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
  console.log(`${file}: rotation patch applied ${applied}, already present ${skipped}`);
}

patch('lib/index.js', [[
  "  orientation: 'any',\n",
  `  ${MARK} // no orientation field: follow the system rotation lock ('any' = FULL_SENSOR on Android)\n`,
]]);

patch('client/index.js', [[
  '  injectMobileStyles();\n',
  `  injectMobileStyles();
${MARK}
  // The drawer is a portrait-only construct (its CSS lives under max-width: 768px). A rotation that
  // crosses the breakpoint must drop it, or the hidden backdrop comes back on return and blocks taps.
  (() => {
    if (window.__dshBridgeRotationFix) return;
    window.__dshBridgeRotationFix = true;
    let mobile = window.innerWidth <= 768;
    const sync = () => {
      const now = window.innerWidth <= 768;
      if (now === mobile) return;
      mobile = now;
      document.body.classList.remove('dsh-drawer-open');
    };
    window.addEventListener('resize', sync);
    window.addEventListener('orientationchange', () => setTimeout(sync, 60));
  })();
`,
]]);
