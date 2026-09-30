// graph-memory: stop failing every turn on DSH 0.1.7. Idempotent.
//
//   node patch-graph-memory-source-kind.mjs [plugin_dir]
//
// WHY. Session format v4 retired the `plugin` message-source wrapper: the writer
// refuses any message whose `source.kind` is `'plugin'`
// (packages/session/session-format-v3-to-v4/src/message-sources.ts:9) and the
// whole TURN dies with "format v4 message requires a producer-owned source
// kind" - no answer, the run lost. A producer is identified by its own
// `plugin:<name>` kind now, which is exactly what DSH's own v3->v4 migration
// derives for rows written earlier (sources.ts:63), so both generations read
// back under one shape. dsh-better-sidebar 0.22.1 already moved to it of its own
// accord; graph-memory 1.6.0-beta.16 has not.
//
// WHERE. Three messages carry the retired shape:
//   * the per-turn trace that REPLACES the archived tool steps
//     (dist/src/format/dsh-turn-projection.js) - this is the one that fires,
//     because it is written at the end of every turn;
//   * the recall snapshot spliced before the user's message (dist/dsh.js);
//   * the extraction request sent to the model (dist/dsh.js) - not persisted,
//     fixed for consistency so no copy of the old shape is left to be revived.
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2]
  || `${process.env.DSH_HOME ?? `${process.env.HOME}/.dsh`}/profiles/web/node_modules/graph-memory`;

const MARK = '/* dsh-local: producer-owned source kind */';
const KIND = '"plugin:graph-memory"';

// Plugin files are hardlinks into the pnpm store: writing in place would corrupt
// the store copy, so the file is unlinked first (new inode) and then written.
const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

// [file, anchor, replacement]. Each anchor must occur exactly once.
const EDITS = [
  ['dist/src/format/dsh-turn-projection.js',
    'source: { kind: "plugin", plugin: "graph-memory" },',
    `source: { kind: ${KIND} }, ${MARK}`],
  ['dist/dsh.js',
    'source: { kind: "plugin", plugin: PLUGIN },',
    `source: { kind: ${KIND} }, ${MARK}`],
  ['dist/dsh.js',
    'kind: "plugin",\n                    plugin: PLUGIN,\n                    form: "snapshot",',
    `kind: ${KIND}, ${MARK}\n                    form: "snapshot",`],
];

let applied = 0, already = 0;
for (const [rel, anchor, replacement] of EDITS) {
  const file = join(dir, rel);
  if (!existsSync(file)) { console.error(`${rel}: missing`); process.exit(1); }
  let s = readFileSync(file, 'utf8');
  if (s.includes(replacement)) { already++; continue; }
  const n = s.split(anchor).length - 1;
  if (n !== 1) {
    console.error(`${rel}: MATCH COUNT ${n} for ${JSON.stringify(anchor.slice(0, 60))} - the plugin changed, re-check before patching`);
    process.exit(1);
  }
  unlinkWrite(file, s.replace(anchor, replacement));
  applied++;
}
console.log(`graph-memory: source kind applied ${applied}, already present ${already}`);
