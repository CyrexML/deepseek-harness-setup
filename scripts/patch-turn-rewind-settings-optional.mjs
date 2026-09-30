// turn-rewind: stop requiring a service the host no longer has (2026-09-30).
//
// DSH 0.1.7 removed `settingsScope` (74 files on 0.1.6, zero on 0.1.7 — the
// ui-settings package replaced settings-scope.ts with configForms/settingsSchema).
// The plugin lists it in the CLIENT's required `inject` array, so on 0.1.7 it
// never activates - and one pending entry blocks the whole client: the page
// renders nothing but "Failed to load plugins".
//
// The plugin's own code already tolerates the absence. Line 136 reads
//   scope: ctx.settingsScope?.bind({ namespace: 'turn-rewind' }),
// with optional chaining, and the comment above it says so outright. Only the
// dependency list was never relaxed to match. Removing the name from `inject`
// lets the plugin start; its settings card then binds to undefined, which is the
// documented fallback, and the ↶ rewind button works as before.
//
// Usage: node patch-turn-rewind-settings-optional.mjs [plugin_dir]
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';

// DSH_HOME, like every sibling patch: a second stand built beside the working
// one must not have its layers applied to the working profile.
const dir = process.argv[2]
  || `${process.env.DSH_HOME ?? `${process.env.HOME}/.dsh`}/profiles/web/node_modules/@anionex/dsh-turn-rewind`;

const MARK = '/* dsh-local: settingsScope optional */';
const FILE = join(dir, 'lib/client.js');

// Plugin files are hardlinks into the pnpm store: writing in place would corrupt
// the store copy, so the file is unlinked first (new inode) and then written.
const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

// On a host that still HAS the service (0.1.6 and earlier) this patch would be a
// regression: the settings card binds to undefined and the plugin's own options
// stop working. So the host is asked first, and the layer is a no-op there.
const root = process.env.DSH_ROOT ?? `${process.env.HOME}/tools/deepseek-harness`;
const scopeFile = join(root, 'packages/client/ui-settings/src/client/settings-scope.ts');
if (existsSync(scopeFile)) {
  console.log('turn-rewind: host still provides settingsScope - nothing to do');
  process.exit(0);
}

let s = readFileSync(FILE, 'utf8');
if (s.includes(MARK)) { console.log('turn-rewind: settingsScope already optional'); process.exit(0); }

// The list is matched whole rather than by the bare name: `settingsScope` also
// appears in the comment and in the guarded call, and neither must be touched.
const ANCHOR = `exports.inject = ['slots', 'sessions', 'conversation', 'settingsScope'];`;
const n = s.split(ANCHOR).length - 1;
if (n !== 1) {
  console.error(`lib/client.js: MATCH COUNT ${n} for the inject list — the plugin changed, re-check before patching`);
  process.exit(1);
}

s = s.replace(ANCHOR, `${MARK} // settingsScope is gone in DSH 0.1.7; ctx.settingsScope?.bind() below already handles that
exports.inject = ['slots', 'sessions', 'conversation'];`);
unlinkWrite(FILE, s);
console.log('turn-rewind: settingsScope removed from the required inject list');
