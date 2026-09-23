// better-sidebar: find the active session on DSH 0.1.6 and keep it in the store.
//
// WHY. Plugin 0.19.1 reads the active session from
// `ctx.sessions.list.getSnapshot().current` (lib/client.js:17152). On
// 0.1.6-alpha.2 that field is GONE from the snapshot - verified live, the keys
// are: ids, byId, phase, subagentsByParent, jobsBySession. The host now marks the
// displayed session with a `mainView` retention
// (packages/client/ui-workspace/src/client/tree.ts:43,
// packages/client/ui-session/src/client/index.ts:442):
//   Object.values(byId).find(s => (s.retainedBy.mainView ?? 0) > 0)?.id
//
// CONSEQUENCE BEFORE THE PATCH. `activeSessionId` is always undefined, and the
// plugin only updates its own store from the `Sidebar` component
// (lib/client.js:16031), which never mounts on 0.1.6 because the panel is drawn
// by the native `ui-sidebar-right`. So in `openTab` (lib/client.js:1365)
// `scope?.sessionId ?? store.getSnapshot().sessionId` is undefined and the
// function silently returns - clicking a file in the plugin's explorer does
// NOTHING. For the same reason `place()` always considered the tab off-screen.
//
// THE PATCH. Two steps:
//   1) `activeSessionId` gets a fallback through `retainedBy.mainView`;
//   2) where the store is created, a subscription to the session list calls
//      `sidebarStore.setSession(activeSessionId(ctx))`, regardless of whether the
//      plugin's own panel is mounted.
// Harmless on 0.1.3: `current` exists there and is checked first, and setSession
// is idempotent (early return on the same id).
//
// Written through unlink: plugin files are hardlinks into the pnpm store.
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2] || `${process.env.HOME}/.dsh/profiles/web/node_modules/dsh-better-sidebar`;
const MARK = '/* dsh-local: session sync */';

const ACTIVE_ANCHOR = `\t\tfunction activeSessionId(ctx) {
\t\t\ttry {
\t\t\t\treturn ctx.sessions.list.getSnapshot().current;
\t\t\t} catch {
\t\t\t\treturn;
\t\t\t}
\t\t}
`;
const ACTIVE_PATCH = `\t\tfunction activeSessionId(ctx) { ${MARK} // 0.1.6: no current field; the displayed session is held by mainView
\t\t\ttry {
\t\t\t\tconst snapshot = ctx.sessions.list.getSnapshot();
\t\t\t\tif (snapshot.current !== undefined) return snapshot.current;
\t\t\t\tconst byId = snapshot.byId ?? {};
\t\t\t\tfor (const id of snapshot.ids ?? Object.keys(byId)) {
\t\t\t\t\tif ((byId[id]?.retainedBy?.mainView ?? 0) > 0) return id;
\t\t\t\t}
\t\t\t\treturn;
\t\t\t} catch {
\t\t\t\treturn;
\t\t\t}
\t\t}
`;

const STORE_ANCHOR = '\t\t\tconst sidebarStore = createSidebarStore();\n';
const STORE_PATCH = STORE_ANCHOR + `\t\t\tctx.effect(() => { ${MARK} // the native sidebar never mounts the plugin panel - take the session from the host
\t\t\t\tconst syncSession = () => {
\t\t\t\t\ttry { sidebarStore.setSession(activeSessionId(ctx)); } catch {}
\t\t\t\t};
\t\t\t\tsyncSession();
\t\t\t\tlet off;
\t\t\t\ttry { off = ctx.sessions.list.subscribe(syncSession); } catch {}
\t\t\t\treturn () => { try { off?.(); } catch {} };
\t\t\t}, "dsh-local: session sync");
`;

const files = ['lib/client.js', 'lib/client-registry.js'].filter(f => existsSync(join(dir, f)));
if (files.length === 0) { console.error(`no build files in ${dir}`); process.exit(1); }

let touched = 0, already = 0;
for (const rel of files) {
  const path = join(dir, rel);
  let s = readFileSync(path, 'utf8');
  if (s.includes(MARK)) { already++; continue; }
  for (const [anchor, replacement, what] of [
    [ACTIVE_ANCHOR, ACTIVE_PATCH, 'activeSessionId'],
    [STORE_ANCHOR, STORE_PATCH, 'createSidebarStore'],
  ]) {
    const n = s.split(anchor).length - 1;
    if (n !== 1) { console.error(`${rel}: MATCH COUNT ${n} for the ${what} anchor`); process.exit(1); }
    s = s.replace(anchor, replacement);
  }
  rmSync(path, { force: true });
  writeFileSync(path, s);
  touched++;
}
console.log(`better-sidebar: session sync - updated ${touched}, already patched ${already} (files: ${files.length})`);
