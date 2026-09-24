// English UI for @anionex/dsh-turn-rewind (2026-09-14). Idempotent; usage: node translate.mjs [plugin_dir]
// The plugin ships a compiled lib/client.js with Chinese-only strings (raw UTF-8 in string literals,
// \uXXXX escapes in JSX text). Every fragment in strings.json is replaced in both forms, longest
// first. Rerun after a plugin update; unmatched fragments are reported, not fatal.
import { readFileSync, writeFileSync, copyFileSync, existsSync, rmSync } from 'node:fs';
// Plugin files are hardlinks into the pnpm store: writing in place would corrupt
// the store copy, so the file is unlinked first (new inode) and then written.
const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

import { join } from 'node:path';
const dir = process.argv[2] || `${process.env.HOME}/.dsh/profiles/web/node_modules/@anionex/dsh-turn-rewind`;
const MARK = '/* dsh-turn-rewind-en */';
const file = join(dir, 'lib/client.js');
let s = readFileSync(file, 'utf8');
if (s.includes(MARK)) { console.log('already translated'); process.exit(0); }
if (!existsSync(file + '.zh')) copyFileSync(file, file + '.zh');
const map = JSON.parse(readFileSync(new URL('./strings.json', import.meta.url), 'utf8'));
const keys = Object.keys(map).sort((a, b) => b.length - a.length);
const esc = (str, upper) => [...str].map(ch => ch.charCodeAt(0) > 127 ? '\\u' + ch.charCodeAt(0).toString(16).padStart(4, '0')[upper ? 'toUpperCase' : 'toLowerCase']() : ch).join('');
let hits = 0, misses = [];
for (const k of keys) {
  const v = map[k];
  let n = 0;
  for (const form of [k, esc(k, true), esc(k, false)]) {
    if (form === k && !s.includes(form)) continue;
    const parts = s.split(form);
    if (parts.length > 1) { n += parts.length - 1; s = parts.join(form === k ? v : esc(v, form === esc(k, true))); }
  }
  if (n) hits += n; else misses.push(k);
}
s = MARK + '\n' + s;
unlinkWrite(file, s);
const left = (s.match(/[一-鿿]/g) || []).length + (s.match(/\\u(4[e-f]|[5-9][0-9a-f])[0-9a-f]{2}/gi) || []).length;
console.log(`replaced ${hits} occurrences; ${misses.length} keys unused; CJK chars left: ${left}`);
if (left) console.log('remaining fragments:', [...new Set((s.replace(/\\u([0-9a-fA-F]{4})/g, (m, h) => String.fromCharCode(parseInt(h, 16))).match(/[一-鿿][^"'`\n<]{0,40}/g) || []))].slice(0, 20).join(' | '));
