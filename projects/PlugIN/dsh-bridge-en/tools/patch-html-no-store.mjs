// bridge: the app page must not be cached by the phone's browser.
// Idempotent.  node patch-html-no-store.mjs <plugin_dir>
//
// Why. The HTML response arrives WITHOUT a Cache-Control header, so the browser
// caches it "at its discretion" (a Last-Modified heuristic). Meanwhile the plugin
// bundles referenced by that page are served with
// `public, max-age=31536000, immutable` and differ only by a `rev` parameter
// computed from the file contents.
//
// The result: a phone holding an OLD page also holds an old `rev`, whose bundle
// is cached for a year and never re-requested. From the outside it looks as if
// fixes had been "rolled back" - everything is new on the desktop while the phone
// keeps the previous behaviour. That is exactly how the PDF and zoom complaints
// came back.
//
// The patch adds `Cache-Control: no-store` to HTML responses (where the bridge
// already rewrites the body to insert its header). The bundles stay "eternal" -
// which is right, since their address changes with every edit.
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2] || '.';
const MARK = '/* dsh-bridge-en: html no-store */';
const file = join(dir, 'lib/index.js');
if (!existsSync(file)) { console.error(`no ${file}`); process.exit(1); }

let s = readFileSync(file, 'utf8');
if (s.includes(MARK)) { console.log('bridge: html no-store already in place'); process.exit(0); }

const ANCHOR = `              delete outHeaders['content-length'];
              delete outHeaders['transfer-encoding'];
              outHeaders['content-length'] = String(out.length);
`;
const n = s.split(ANCHOR).length - 1;
if (n !== 1) { console.error(`MATCH COUNT ${n} for the response-headers anchor`); process.exit(1); }

const PATCH = ANCHOR + `              if (contentType.includes('text/html')) { ${MARK} // otherwise the phone keeps an old page with an old bundle rev
                outHeaders['cache-control'] = 'no-store';
                outHeaders['cdn-cache-control'] = 'no-store';
                delete outHeaders['etag'];
                delete outHeaders['last-modified'];
              }
`;
s = s.replace(ANCHOR, PATCH);
rmSync(file, { force: true });
writeFileSync(file, s);
console.log('bridge: html no-store added');
