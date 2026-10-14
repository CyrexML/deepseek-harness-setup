// dsh-univer-office: the Univer window must also open over HTTPS (the phone
// through the Cloudflare tunnel). Idempotent.
//
//   node patch-univer-viewer-wss.mjs [plugin_dir]
//
// WHY. Over https://dsh.raadio.online the Univer window opened empty ("No
// files", "No file open"), while over the LAN (plain http) the same file showed
// its slides. The console named it: "Mixed Content ... attempted to connect to
// the insecure WebSocket endpoint 'ws://dsh.raadio.online/univer-viewer/ws?...'".
//
// The viewer builds that address in two steps (artifacts/viewer/assets/
// index-*.js, minified names as of 0.3.7):
//
//   ANe(e)  new URL('/univer-viewer/ws', location.origin), then
//           protocol = https: ? wss: : ws:          -> wss://... (correct)
//   sze(e)  new URL(e), then protocol = https: ? wss: : ws:
//
// sze() is applied to ANe()'s result. It knows only `https:`, so the `wss:` it
// receives counts as "not https" and comes back as `ws:`. On http the bug is
// invisible (ws stays ws); on https the browser refuses the socket and the
// viewer never receives its file. `sze("wss://x/y")` returns `ws://x/y` -
// checked in node.
//
// WHY NOT FIX sze() IN THE BUNDLE. The bundle is served `cache-control: public,
// max-age=31536000, immutable`, and Cloudflare already holds it at the edge
// (cf-cache-status: HIT). An edited file under the same name would not reach a
// phone that has seen the old one, and renaming it means renaming every locale
// chunk that imports it - same caching, same chain.
//
// WHAT THIS DOES. viewer/index.html is not cached (the viewer route is dynamic),
// so a small classic script goes in front of the module script: on an https
// page, a WebSocket to this same host with `ws:` is opened as `wss:` instead.
// Nothing else is touched - other hosts, and every http page, pass through
// unchanged.
//
// SECOND FIX, SAME FILE: on a phone the viewer's own left panel (files,
// modifications, confirmations) took 257 of 412 px and cut the slides off. The
// viewer already reads its initial state from `?sidebar=collapsed|expanded`,
// then from localStorage `univer-collab-client-sidebar-collapsed` (IQn in the
// bundle). On a window narrower than 600 px with no stored choice, the shim
// adds `sidebar=collapsed` before the app boots. The toggle still opens the
// panel, and once the user picks a state it is stored and wins.
//
// Written through unlink: plugin files are hardlinks into the pnpm store.
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2]
  || `${process.env.DSH_HOME ?? `${process.env.HOME}/.dsh`}/profiles/web/node_modules/dsh-univer-office`;
const file = join(dir, 'artifacts/viewer/index.html');
const MARK = '/* dsh-local: viewer wss on https */';

if (!existsSync(file)) { console.error(`no such file: ${file}`); process.exit(1); }
let s = readFileSync(file, 'utf8');
const MARK_NARROW = '/* dsh-local: viewer panel collapsed when narrow */';
if (s.includes(MARK) && s.includes(MARK_NARROW)) { console.log('univer viewer: shims already present'); process.exit(0); }

const ANCHOR = '    <script type="module" crossorigin src="/univer-viewer/assets/';
if (s.split(ANCHOR).length - 1 !== 1) { console.error('univer viewer: module script tag not found (MATCH COUNT != 1)'); process.exit(1); }

const SHIM = `    <script>${MARK}
      (() => {
        if (location.protocol !== 'https:' || typeof WebSocket !== 'function') return;
        const Native = WebSocket;
        const secure = (url) => {
          try {
            const u = new URL(String(url), location.href);
            if (u.protocol === 'ws:' && u.host === location.host) u.protocol = 'wss:';
            return u.toString();
          } catch { return url; }
        };
        window.WebSocket = class extends Native {
          constructor(url, protocols) { super(secure(url), protocols); }
        };
      })();
    </script>
`;
const NARROW = `    <script>${MARK_NARROW}
      (() => {
        try {
          const q = new URLSearchParams(location.search);
          if (q.has('sidebar') || innerWidth >= 600) return;
          if (localStorage.getItem('univer-collab-client-sidebar-collapsed') !== null) return;
          q.set('sidebar', 'collapsed');
          history.replaceState(history.state, '', location.pathname + '?' + q.toString() + location.hash);
        } catch {}
      })();
    </script>
`;
s = s.replace(ANCHOR, (s.includes(MARK) ? '' : SHIM) + (s.includes(MARK_NARROW) ? '' : NARROW) + ANCHOR);
rmSync(file, { force: true });
writeFileSync(file, s);
console.log('univer viewer: shims added');
