// better-sidebar: turnTail slot compatibility with DSH 0.1.6+ (id + own matched).
//
// In 0.1.6-alpha.2 the `conversation.chat.turnTail` slot changed from chain to
// list, and the host requires `options.id` on list registrations
// (packages/client/ui-slots/src/index.ts:1230). Plugin 0.19.1 does not pass it,
// so the registration throws "list slot registration requires options.id" and the
// whole sidebar dies with a minified React error #130.
//
// The second difference: on a chain entry the component receives the result of
// `select` in the `matched` prop, on a list entry only the owner props (turn,
// seq, openFile) - ui-slots/src/index.ts:774 and :290. The plugin is written for
// chain and crashes on `matched.slice(...)` (lib/client.js:3421). So the second
// step wraps the component: when `matched` is missing it is computed here with
// the same rules as in `select`, and an empty result renders null (a list entry
// is allowed to draw nothing).
//
// Harmless on older hosts (0.1.3, where the slot is chain): the extra `id` is
// ignored, and the wrapper calls the original component as soon as `matched` is
// present.
//
// EVERY build file of the plugin carrying the registration is patched (client.js
// is what the browser gets, client-registry.js is the registry variant).
// Written through unlink: plugin files are hardlinks into the pnpm store.
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2] || `${process.env.HOME}/.dsh/profiles/web/node_modules/dsh-better-sidebar`;
const MARK = '/* dsh-local: turnTail slot id */';
const ID = 'better-sidebar-turn-tail';
const ANCHOR = '\t\t\t\tname: "conversation.chat.turnTail",\n';
const files = ['lib/client.js', 'lib/client-registry.js'].filter(f => existsSync(join(dir, f)));
if (files.length === 0) { console.error(`no build files in ${dir}`); process.exit(1); }

const COMPONENT_ANCHOR = '\t\t\t}, SidebarProducedFiles));\n';
const COMPONENT_PATCH = `\t\t\t}, (props) => { ${MARK} // a list entry gives no matched prop - compute it here
\t\t\t\tlet m = props.matched;
\t\t\t\tif (m === undefined) {
\t\t\t\t\tif (store.getSuspended()) return null;
\t\t\t\t\tif (store.getPrefs().tabsEnabled["editor"] === false) return null;
\t\t\t\t\tm = selectProducedFiles(props);
\t\t\t\t\tif (m !== null) lastProduced = m;
\t\t\t\t}
\t\t\t\tif (m === null || m === undefined || m.length === 0) return null;
\t\t\t\treturn SidebarProducedFiles({ ...props, matched: m });
\t\t\t}));
`;

let touched = 0, already = 0;
for (const rel of files) {
  const path = join(dir, rel);
  let s = readFileSync(path, 'utf8');
  if (s.includes(MARK)) { already++; continue; }
  for (const [anchor, replacement, what] of [
    [ANCHOR, `${ANCHOR}\t\t\t\tid: "${ID}", ${MARK}\n`, 'id'],
    [COMPONENT_ANCHOR, COMPONENT_PATCH, 'component'],
  ]) {
    const n = s.split(anchor).length - 1;
    if (n !== 1) { console.error(`${rel}: MATCH COUNT ${n} for the ${what} anchor`); process.exit(1); }
    s = s.replace(anchor, replacement);
  }
  rmSync(path, { force: true });
  writeFileSync(path, s);
  touched++;
}
console.log(`better-sidebar: turnTail id - updated ${touched}, already patched ${already} (files: ${files.length})`);
