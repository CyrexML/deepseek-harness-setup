// Zoom only inside the side panel. Idempotent.
//   node patch-zoom-scope.mjs <plugin_dir>
//
// Why: on a phone a pinch inside the conversation gets in the way (the chat zooms
// by accident), while in the right panel it is needed - that is where the result
// is opened: an HTML page, a PDF, a spreadsheet. The viewport cannot express
// this: `user-scalable=no` disables zoom for the whole page (and is overridden by
// Android's "force enable zoom" setting anyway).
//
// The solution is per area:
//   * CSS `touch-action: pan-x pan-y` on the conversation and the composer: the
//     browser never starts a zoom gesture that began inside the chat;
//   * the right panel (`[data-sidebar-right-panel]` on host 0.1.6) and the
//     preview inside it get `touch-action: auto` back, so pinch works there;
//   * a JS backstop: a touchmove with two or more touches inside the chat is
//     cancelled (non-passive listener), inside the panel it is not. This also
//     covers Android's forced zoom.
// The anchors are host data attributes (`data-conversation-scroll`,
// `data-chat-anchor-key`, `data-sidebar-right-panel`) rather than CSS-module
// hashes, so they survive a rebuild.
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

const dir = process.argv[2] || '.';
const MARK = '/* dsh-bridge-en: zoom scope */';

// 1. CSS
{
  const path = join(dir, 'client/mobile-styles.js');
  let s = readFileSync(path, 'utf8');
  if (s.includes(MARK)) console.log('client/mobile-styles.js: zoom-scope already present');
  else {
    const css = `
    ${MARK}
    @media (max-width: 768px) {
      /* chat: no zoom gesture starts here */
      [data-conversation-scroll],
      [data-chat-anchor-key],
      [contenteditable="true"] { touch-action: pan-x pan-y !important; }
      /* side panel: zoom behaves normally */
      [data-sidebar-right-panel],
      [data-sidebar-right-panel] * { touch-action: auto !important; }
    }
`;
    const anchor = '\n`;\n';
    const idx = s.lastIndexOf(anchor);
    if (idx < 0) { console.error('mobile-styles.js: end of MOBILE_STYLES_CSS not found'); process.exit(1); }
    s = s.slice(0, idx) + '\n' + css + s.slice(idx);
    unlinkWrite(path, s);
    console.log('client/mobile-styles.js: zoom-scope applied');
  }
}

// 2. JS backstop, next to the rest of the mobile client logic
{
  const path = join(dir, 'client/index.js');
  let s = readFileSync(path, 'utf8');
  if (s.includes(MARK)) { console.log('client/index.js: zoom-scope already present'); process.exit(0); }
  const anchor = 'function __dshBridgeClientMain';
  const at = s.indexOf(anchor);
  const inject = `${MARK}
// Cancel a pinch inside the conversation; let it through inside the right panel.
if (typeof window !== "undefined" && !window.__dshZoomScopeBound) {
  window.__dshZoomScopeBound = true;
  const inSidebar = (t) => !!(t && t.closest && t.closest('[data-sidebar-right-panel], [data-sidebar-right-float-host]'));
  document.addEventListener('touchmove', (e) => {
    if (e.touches.length < 2) return;
    if (inSidebar(e.target)) return;
    if (window.innerWidth > 768) return;
    e.preventDefault();
  }, { passive: false });
}
`;
  if (at < 0) s = inject + s;
  else s = s.slice(0, at) + inject + s.slice(at);
  unlinkWrite(path, s);
  console.log('client/index.js: zoom-scope applied');
}
