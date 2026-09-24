// CSS-module hash remap (2026-09-13). Idempotent; usage: node patch-hashes.mjs <plugin_dir>
//
// The bridge's mobile CSS (client/mobile-styles.js) and two querySelectors in client/index.js
// hard-code the css-module class hashes of the DSH build the plugin was written against
// (VOzbGW_* settings dialog, hHd-Xa_* sidebar, wSkVaW_* header, ...). This host is built from
// source and hashes every module differently (X94w9W_*, c7oHuW_*, Z9GdRG_*), so all 49 hashed
// selectors are dead — only the hash-agnostic ones (`[class*="_sidebarCol"]`) still work.
// Seen on the phone: settings dialog rendered inside the 290px drawer (position:fixed under the
// drawer's transform) and cut off; edge-swipe opened the drawer without expanding a collapsed
// sidebar (rail of icons in a wide drawer). Reproduced headless at 360x780.
//
// Fix (runtime, survives host rebuilds): at injection the mobile CSS is rewritten by
// remapHostHashes(): every `class*="HASH_suffix"` group whose HASH is absent from the live
// stylesheets is remapped to the ONE live hash that owns all of the group's suffixes; ambiguous
// groups stay untouched. The rewrite is repeated at 2 s / 8 s for lazily loaded host sheets.
// The swipe path reuses the aria-label expand selector the menu button already uses.
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
// Plugin files are hardlinks into the pnpm store: writing in place would corrupt
// the store copy, so the file is unlinked first (new inode) and then written.
const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

import { join } from 'node:path';
const dir = process.argv[2] || '.';
const MARK = '/* dsh-bridge-en: hash remap */';

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
  console.log(`${file}: hash-remap patch applied ${applied}, already present ${skipped}`);
}

patch('client/index.js', [
  [
    "  style.textContent = MOBILE_STYLES_CSS;\n  document.head.appendChild(style);\n}\n",
    `  style.textContent = remapHostHashes(MOBILE_STYLES_CSS);
  document.head.appendChild(style);
  ${MARK} // host sheets may arrive after plugin apply: rewrite again once they are there
  for (const ms of [2000, 8000]) setTimeout(() => {
    const next = remapHostHashes(MOBILE_STYLES_CSS);
    if (next !== style.textContent) style.textContent = next;
  }, ms);
}

${MARK}
// Rewrite \`class*="HASH_suffix"\` selectors whose HASH no longer exists in the host's stylesheets to
// the one live hash that owns every suffix of that group. Unknown/ambiguous groups are left as is.
function remapHostHashes(css) {
  try {
    const live = new Map();
    const collect = (rule) => {
      const t = rule.selectorText;
      if (typeof t === 'string') {
        for (const m of t.matchAll(/\\.([A-Za-z0-9_-]{6})_([A-Za-z][A-Za-z0-9]*)/g)) {
          let s = live.get(m[1]); if (!s) live.set(m[1], s = new Set()); s.add(m[2]);
        }
      }
      if (rule.cssRules) for (const r of rule.cssRules) collect(r);
    };
    for (const sheet of document.styleSheets) {
      let rules; try { rules = sheet.cssRules; } catch { continue; }
      for (const r of rules) collect(r);
    }
    if (live.size === 0) return css;
    const groups = new Map();
    for (const m of css.matchAll(/class\\*="([A-Za-z0-9_-]{6})_([A-Za-z][A-Za-z0-9]*)"/g)) {
      let s = groups.get(m[1]); if (!s) groups.set(m[1], s = new Set()); s.add(m[2]);
    }
    let out = css;
    for (const [hash, suffixes] of groups) {
      if (live.has(hash)) continue;
      const cands = [];
      for (const [k, owned] of live) if ([...suffixes].every((x) => owned.has(x))) cands.push(k);
      if (cands.length !== 1) continue;
      out = out.split('class*="' + hash + '_').join('class*="' + cands[0] + '_');
    }
    return out;
  } catch { return css; }
}
`,
  ],
  [
    `        const collapsedToggle = document.querySelector('div[class*="hHd-Xa_collapsed"] button[class*="hHd-Xa_toggle"]');
        if (collapsedToggle) collapsedToggle.click();
`,
    `        ${MARK} // same expand selector as the header menu button; the hashed one is build-specific
        const collapsedToggle = document.querySelector('button[aria-label*="打开侧边栏"], button[title*="打开侧边栏"], button[aria-label*="Open sidebar"], button[title*="Open sidebar"]');
        if (collapsedToggle) collapsedToggle.click();
`,
  ],
]);
