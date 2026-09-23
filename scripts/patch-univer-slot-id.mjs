// dsh-univer-office: turnTail slot compatibility with DSH 0.1.6+ (id + own matched).
//
// The same breakage as in better-sidebar: in 0.1.6 `conversation.chat.turnTail`
// became a list slot and the host requires `options.id`
// (packages/client/ui-slots/src/index.ts:1230), while plugin 0.3.2 still
// registers the old way - with `select` and no `id` (lib/client.js:23097). The
// registration throws inside activate and the whole plugin fails to load.
//
// A list entry gives the component only the owner props, without `matched`
// (ui-slots/src/index.ts:774), so PreviewCard is wrapped: when `matched` is
// missing it is computed with the same `selectUniverTurn(props)`, and an empty
// result renders null.
//
// Harmless on 0.1.3 (chain slot): the extra `id` is ignored, and the wrapper
// calls the original component as soon as `matched` is present.
// Written through unlink: the file is a hardlink into the pnpm store.
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2] || `${process.env.HOME}/.dsh/profiles/web/node_modules/dsh-univer-office`;
const MARK = '/* dsh-local: turnTail slot id */';
const path = join(dir, 'lib/client.js');
if (!existsSync(path)) { console.error(`no ${path}`); process.exit(1); }
let s = readFileSync(path, 'utf8');
if (s.includes(MARK)) { console.log('univer: turnTail id already applied'); process.exit(0); }

const edits = [
  [ // 1. id for the list entry
    '              name: "conversation.chat.turnTail",\n              priority: -10,\n',
    `              name: "conversation.chat.turnTail",\n              id: "univer-turn-preview", ${MARK}\n              priority: -10,\n`,
  ],
  [ // 2. compute matched ourselves when the host does not pass it
    '            PreviewCard\n',
    `            (props) => { ${MARK} // a list entry gives no matched prop
              const m = props.matched ?? selectUniverTurn(props);
              if (m === null || m === undefined) return null;
              return PreviewCard({ ...props, matched: m });
            }
`,
  ],
];
for (const [a, b] of edits) {
  const n = s.split(a).length - 1;
  if (n !== 1) { console.error(`MATCH COUNT ${n} for ${JSON.stringify(a.slice(0, 60))}`); process.exit(1); }
  s = s.replace(a, b);
}
rmSync(path, { force: true });
writeFileSync(path, s);
console.log('univer: turnTail id applied');
