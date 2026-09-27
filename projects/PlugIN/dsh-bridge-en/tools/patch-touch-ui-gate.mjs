// The touch fixes apply to every touch screen, not only to phones. Idempotent.
//   node patch-touch-ui-gate.mjs <plugin_dir>
//
// Why. patch-zoom-scope, patch-preview-zoom and patch-mobile-ux are all gated on
// "max-width: 768px" - the bridge's own phone breakpoint (MOBILE_MAX_WIDTH = 767
// in client/index.js). A tablet is wider than that, so on a tablet none of it
// applies: a pinch in the conversation still zooms the whole page, and the
// preview does not zoom its content. The width is the wrong question; what the
// rules actually depend on is whether the pointer is a finger.
//
// What this changes. Every rule the three layers appended to mobile-styles.js
// gets a second condition, "(pointer: coarse)" - true on a phone and on a
// tablet, false for a mouse, including on a touchscreen laptop, where the
// primary pointer stays fine. The bridge's OWN 768px rules are left alone: they
// switch the whole layout to the phone shell (drawer, tab row), which a tablet
// does not want. The same goes for the three JS guards, which move to one
// shared helper.
//
// This runs after those three layers and patches their output, rather than
// changing each of them, so the gate is defined in one place and survives a
// plugin update the same way the rest does.
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';

const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

const dir = process.argv[2] || '.';
const MARK = 'dsh-bridge-en: touch ui gate';
const OUR_MARKERS = ['dsh-bridge-en: zoom scope', 'dsh-bridge-en: preview zoom', 'dsh-bridge-en: mobile ux'];
const NARROW = '@media (max-width: 768px) {';
// The marker sits INSIDE the block, right after the brace: a comment inserted
// before it would land in the middle of the layer's own /* ... */ header and
// leave a stray `*/` in the stylesheet, which silently kills the rules that
// follow it.
const WIDE = `@media (max-width: 768px), (pointer: coarse) { /* ${MARK} */`;

// 1. CSS: widen only the rules our own layers appended.
{
  const path = join(dir, 'client/mobile-styles.js');
  let s = readFileSync(path, 'utf8');
  if (s.includes(MARK)) {
    console.log('client/mobile-styles.js: touch-ui gate already present');
  } else {
    const starts = OUR_MARKERS.map(m => s.indexOf(m)).filter(i => i >= 0);
    if (starts.length === 0) { console.error('mobile-styles.js: none of the touch layers is present yet'); process.exit(1); }
    const from = Math.min(...starts);
    const head = s.slice(0, from);
    const tail = s.slice(from);
    const n = tail.split(NARROW).length - 1;
    if (n === 0) { console.error('mobile-styles.js: no phone-gated rule found in our own block'); process.exit(1); }
    s = head + tail.split(NARROW).join(WIDE);
    unlinkWrite(path, s);
    console.log(`client/mobile-styles.js: touch-ui gate applied to ${n} rule blocks`);
  }
}

// 2. JS: one helper in place of the three width guards.
{
  const path = join(dir, 'client/index.js');
  let s = readFileSync(path, 'utf8');
  if (s.includes(MARK)) { console.log('client/index.js: touch-ui gate already present'); process.exit(0); }
  const GUARD = 'if (window.innerWidth > 768) return;';
  const n = s.split(GUARD).length - 1;
  if (n === 0) { console.error('client/index.js: no width guard found - are the touch layers applied?'); process.exit(1); }
  const helper = [
    `// ${MARK}: a finger, on a phone or on a tablet. A touchscreen laptop keeps`,
    '// the fine pointer as its primary one and is therefore not included.',
    'function __dshTouchUi() {',
    '  if (typeof window === "undefined") return false;',
    '  if (window.innerWidth <= 768) return true;',
    '  return typeof window.matchMedia === "function" && window.matchMedia("(pointer: coarse)").matches;',
    '}',
    '',
  ].join('\n');
  s = s.split(GUARD).join('if (!__dshTouchUi()) return;');
  const anchor = 'function __dshBridgeClientMain';
  const at = s.indexOf(anchor);
  s = at < 0 ? helper + s : s.slice(0, at) + helper + s.slice(at);
  unlinkWrite(path, s);
  console.log(`client/index.js: touch-ui gate applied to ${n} guards`);
}
