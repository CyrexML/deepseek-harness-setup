// DSH whale as the PWA icon (2026-09-14). Idempotent; usage: node patch-icon.mjs <plugin_dir>
// Assets from tools/gen-icon.mjs (tools/assets/): SVG + PNG 512/192 (manifest, any+maskable) +
// 180 (apple-touch-icon). Replaces the bridge's generic robot; manifest colours = splash dark
// (#0f1117), so the Android launch screen (icon on background_color) matches the in-app splash.
// Note: an already-installed home-screen shortcut keeps its old icon — remove and re-add it.
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
// Plugin files are hardlinks into the pnpm store: writing in place would corrupt
// the store copy, so the file is unlinked first (new inode) and then written.
const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

import { join } from 'node:path';
const dir = process.argv[2] || '.';
const ASSETS = new URL('./assets/', import.meta.url).pathname;
const MARK = '/* dsh-bridge-en: whale icon */';
const path = join(dir, 'lib/index.js');
let s = readFileSync(path, 'utf8');
if (s.includes(MARK)) { console.log('lib/index.js: whale icon already present'); process.exit(0); }

const svg = readFileSync(ASSETS + 'pwa-icon.svg', 'utf8').trim();
const b64 = (f) => readFileSync(ASSETS + f).toString('base64');
let n = 0;
function edit(re, to) {
  const m = s.match(re);
  if (!m) { console.error(`no match: ${re}`); process.exit(1); }
  s = s.replace(re, to); n++;
}
// 1. icon SVG
edit(/const PWA_ICON_SVG = `<svg[\s\S]*?<\/svg>`;/, `${MARK}\nconst PWA_ICON_SVG = ${JSON.stringify(svg)};
const PWA_ICON_PNG = {
  '/__dsh_bridge__/pwa-icon-512.png': Buffer.from('${b64('pwa-icon-512.png')}', 'base64'),
  '/__dsh_bridge__/pwa-icon-192.png': Buffer.from('${b64('pwa-icon-192.png')}', 'base64'),
  '/apple-touch-icon.png': Buffer.from('${b64('apple-touch-icon.png')}', 'base64'),
};`);
// 2. manifest colours + icons
edit(/  background_color: '#181825',\n  theme_color: '#1e1e2e',/, `  background_color: '#0f1117', ${MARK}\n  theme_color: '#0f1117',`);
edit(/  icons: \[\n    \{\n      src: '\/__dsh_bridge__\/pwa-icon\.svg',\n      sizes: 'any',\n      type: 'image\/svg\+xml',\n      purpose: 'any maskable'\n    \}\n  \]/, `  icons: [
    { src: '/__dsh_bridge__/pwa-icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
    { src: '/__dsh_bridge__/pwa-icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
    { src: '/__dsh_bridge__/pwa-icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'maskable' },
    { src: '/__dsh_bridge__/pwa-icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
    { src: '/__dsh_bridge__/pwa-icon.svg', sizes: 'any', type: 'image/svg+xml', purpose: 'any' }
  ]`);
// 3. routes
edit(/      if \(pathname === '\/__dsh_bridge__\/pwa-icon\.svg' \|\| pathname === '\/apple-touch-icon\.png'\) \{\n        res\.writeHead\(200, \{ 'Content-Type': 'image\/svg\+xml; charset=utf-8', 'Access-Control-Allow-Origin': '\*' \}\);\n        res\.end\(PWA_ICON_SVG\);\n        return;\n      \}/, `      if (pathname === '/__dsh_bridge__/pwa-icon.svg') { ${MARK}
        res.writeHead(200, { 'Content-Type': 'image/svg+xml; charset=utf-8', 'Access-Control-Allow-Origin': '*', 'Cache-Control': 'public, max-age=86400' });
        res.end(PWA_ICON_SVG);
        return;
      }
      if (Object.prototype.hasOwnProperty.call(PWA_ICON_PNG, pathname)) {
        res.writeHead(200, { 'Content-Type': 'image/png', 'Content-Length': PWA_ICON_PNG[pathname].length, 'Access-Control-Allow-Origin': '*', 'Cache-Control': 'public, max-age=86400' });
        res.end(PWA_ICON_PNG[pathname]);
        return;
      }`);
// 4. head links
edit(/<meta name="theme-color" content="#1e1e2e">/, '<meta name="theme-color" content="#0f1117">');
edit(/<link rel="apple-touch-icon" href="\/__dsh_bridge__\/pwa-icon\.svg">/, '<link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png">');
unlinkWrite(path, s);
console.log(`lib/index.js: whale icon patch applied (${n} edits)`);
