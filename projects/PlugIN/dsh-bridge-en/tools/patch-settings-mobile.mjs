// Mobile settings fixes (2026-09-14). Idempotent; usage: node patch-settings-mobile.mjs <plugin_dir>
// Appends one @media block to MOBILE_STYLES_CSS (client/mobile-styles.js). Selectors are
// hash-agnostic (suffix match) and scoped to the settings content area, so they survive host
// rebuilds and do not need the runtime hash remap.
//  1. Settings dialog nav (78px column): the "Settings" title overflowed into the content column,
//     labels were split mid-word ("Remote acc / ess") by word-break:break-all.
//  2. Plugin Hub (dsh-plugin, qikqja_/_7tvizq_ classes): header title row, Market/Installed tabs
//     and the sort segment overflowed the 412px viewport (measured right edge 459–668px).
//  3. Power popover (dsh-bridge-en): on ≤768px it pins to the viewport edges (12px) instead of the
//     anchor, so it can never leave the screen; dark DeepSeek palette in both themes.
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
// Плагины лежат в pnpm-store хардлинками: запись «по месту» испортила бы копию в store,
// поэтому файл сначала удаляется (новый inode), потом пишется.
const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

import { join } from 'node:path';
const dir = process.argv[2] || '.';
const MARK = '/* dsh-bridge-en: settings mobile */';
const path = join(dir, 'client/mobile-styles.js');
let s = readFileSync(path, 'utf8');
if (s.includes(MARK)) { console.log('client/mobile-styles.js: settings-mobile already present'); process.exit(0); }
const css = `
    ${MARK}
    @media (max-width: 768px) {
      /* settings nav: title + labels inside the 78px column */
      nav[class*="_nav"] div[class*="_navTitle"] {
        font-size: 12px !important;
        font-weight: 600 !important;
        white-space: nowrap !important;
        overflow: hidden !important;
        text-overflow: ellipsis !important;
        padding: 0 4px !important;
      }
      span[class*="_navLabel"] {
        font-size: 10px !important;
        word-break: normal !important;
        overflow-wrap: anywhere !important;
        hyphens: manual !important;
      }
      /* plugin hub header / tabs / sort row */
      div[class*="_options"] div[class*="_headerTitleRow"] {
        flex-wrap: wrap !important;
        gap: 6px 10px !important;
        align-items: center !important;
      }
      div[class*="_options"] a[class*="_brandTitle"] {
        min-width: 0 !important;
      }
      div[class*="_options"] a[class*="_brandTitle"] h1 {
        font-size: 16px !important;
        white-space: nowrap !important;
      }
      div[class*="_options"] div[class*="_tabsRow"],
      div[class*="_options"] div[class*="_tabsRow"] > div {
        max-width: 100% !important;
        overflow-x: auto !important;
        overflow-y: hidden !important;
        -webkit-overflow-scrolling: touch !important;
        scrollbar-width: none !important;
      }
      div[class*="_options"] div[class*="_tabsRow"] button {
        flex: 0 0 auto !important;
        white-space: nowrap !important;
      }
      div[class*="_options"] div[class*="_controls"] {
        flex-wrap: wrap !important;
        gap: 8px !important;
      }
      div[class*="_options"] div[class*="_sortGroup"],
      div[class*="_options"] div[class*="_segGroup"] {
        max-width: 100% !important;
        overflow-x: auto !important;
        scrollbar-width: none !important;
      }
      /* power popover: pinned to the viewport on phones */
      .dsh-power-pop {
        left: 12px !important;
        right: 12px !important;
        width: auto !important;
        max-height: calc(100dvh - 24px) !important;
        overflow-y: auto !important;
      }
    }
    /* power popover: DeepSeek dark tones in both themes (theme vars gave white-on-white on some phones) */
    .dsh-power-pop {
      background: #141a2e !important;
      color: #e6e8ef !important;
      border-color: rgba(255,255,255,.12) !important;
    }
    .dsh-power-pop p { color: #9aa3b8 !important; }
    .dsh-power-pop button { border-color: rgba(255,255,255,.22) !important; color: #e6e8ef !important; background: transparent !important; }
    .dsh-power-pop button.danger { border-color: #f87171 !important; color: #fca5a5 !important; }
    .dsh-power-pop button.primary { background: #4d6bfe !important; border-color: transparent !important; color: #fff !important; }
    .dsh-power-pop input { background: #0f1117 !important; color: #e6e8ef !important; border-color: rgba(255,255,255,.22) !important; }
    .dsh-power-pop .msg { color: #93b4ff !important; }
    .dsh-power-pop .msg.err { color: #fca5a5 !important; }
`;
const anchor = '\n`;\n';
const idx = s.lastIndexOf(anchor);
if (idx < 0) { console.error('mobile-styles.js: end of MOBILE_STYLES_CSS not found'); process.exit(1); }
s = s.slice(0, idx) + '\n' + css + s.slice(idx);
unlinkWrite(path, s);
console.log('client/mobile-styles.js: settings-mobile patch applied');
