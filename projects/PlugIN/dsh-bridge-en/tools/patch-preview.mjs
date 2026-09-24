// Preview passthrough (2026-09-13). Idempotent; usage: node patch-preview.mjs <plugin_dir>
//
// dsh-better-sidebar serves the user's OWN project files through /sidebar/html/<session>/<abs path>
// (HTML preview iframe + its js/css subresources) and /sidebar/file. The bridge proxy treated them
// like the DSH shell:
// 1. Every text/html response got HTML_HEAD_INJECTIONS: a viewport meta with user-scalable=no,
//    the PWA manifest/icons, overscroll CSS and the splash overlay. Inside a previewed app there is
//    no #root, so the splash sat over the app until its 25 s fallback; the viewport meta disabled
//    pinch zoom in the previewed page. Measured: Cooking_APP index.html via the bridge = 13 injected
//    markers, via 127.0.0.1:3080 = 0.
// 2. The route sends `cache-control: no-cache` without validators. Through the Cloudflare tunnel the
//    edge rewrote it to `max-age=14400` (cf-cache-status MISS/EXPIRED, Browser Cache TTL default), so
//    the PHONE BROWSER kept js/css for 4 h; reloading the DSH page does not refetch iframe
//    subresources → the app on the phone lagged behind the files on disk. `no-store` is passed
//    through unchanged by Cloudflare and is never cached by the browser.
// Fix: preview paths skip the HTML buffering/injection branch and go out with cache-control: no-store
// (+ cdn-cache-control: no-store for the edge).
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
// Plugin files are hardlinks into the pnpm store: writing in place would corrupt
// the store copy, so the file is unlinked first (new inode) and then written.
const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

import { join } from 'node:path';
const dir = process.argv[2] || '.';
const MARK = '/* dsh-bridge-en: preview passthrough */';

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
  console.log(`${file}: preview patch applied ${applied}, already present ${skipped}`);
}

patch('lib/index.js', [
  [
    "          const sessionProjectionBuffered = isSessionProjection && proxyRes.statusCode === 200;\n          const shouldBuffer = (contentType.includes('text/html') && !isCompressed(proxyRes.headers))\n",
    `          const sessionProjectionBuffered = isSessionProjection && proxyRes.statusCode === 200;
          ${MARK} // user's own files (better-sidebar preview): no head injection, no caching
          const isPreview = pathname.startsWith('/sidebar/html/') || pathname.startsWith('/sidebar/file');
          const shouldBuffer = (!isPreview && contentType.includes('text/html') && !isCompressed(proxyRes.headers))
`,
  ],
  [
    "          res.writeHead(proxyRes.statusCode ?? 502, sanitizeProxyHeaders(proxyRes.headers));\n          proxyRes.pipe(res);\n",
    `          const passHeaders = sanitizeProxyHeaders(proxyRes.headers);
          if (isPreview) { passHeaders['cache-control'] = 'no-store'; passHeaders['cdn-cache-control'] = 'no-store'; } ${MARK}
          res.writeHead(proxyRes.statusCode ?? 502, passHeaders);
          proxyRes.pipe(res);
`,
  ],
]);
