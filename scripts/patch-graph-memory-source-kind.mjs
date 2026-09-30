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
// WHY IT SWEEPS INSTEAD OF LISTING ANCHORS. The first version of this script
// patched the three sites a search had turned up, and the failure came back
// twice from sites it had not listed - the turn trace, then the compaction
// archive marker, each firing only in its own circumstance (end of a turn, then
// a compaction), so each looked fixed until the next one fired. A list of
// anchors cannot be trusted here. This rewrites EVERY occurrence of the retired
// shape under dist/ and then asserts that none is left; a new one added upstream
// is patched on the next start rather than found by a failed turn.
import { readFileSync, writeFileSync, rmSync, existsSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2]
  || `${process.env.DSH_HOME ?? `${process.env.HOME}/.dsh`}/profiles/web/node_modules/graph-memory`;
const root = join(dir, 'dist');
if (!existsSync(root)) { console.error(`${root}: missing`); process.exit(1); }

const MARK = '/* dsh-local: producer-owned source kind */';
const KIND = '"plugin:graph-memory"';

// `kind: "plugin"` followed by `plugin: PLUGIN` (or the literal name), in either
// order of whitespace and across lines - the shapes this plugin actually writes:
//   { kind: "plugin", plugin: PLUGIN }
//   { kind: "plugin", plugin: "graph-memory" }
//   { kind: "plugin",\n  plugin: PLUGIN,\n  form: "snapshot", ... }
const RETIRED = /kind:\s*(["'])plugin\1\s*,\s*plugin:\s*(?:PLUGIN|(["'])graph-memory\2)\s*,?/g;
// What must not survive: a source kind of exactly "plugin".
const LEFTOVER = /kind:\s*(["'])plugin\1(?!:)/;

// Plugin files are hardlinks into the pnpm store: writing in place would corrupt
// the store copy, so the file is unlinked first (new inode) and then written.
const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

function* jsFiles(d) {
  for (const entry of readdirSync(d)) {
    const p = join(d, entry);
    if (statSync(p).isDirectory()) yield* jsFiles(p);
    else if (/\.(js|mjs|cjs)$/.test(entry) && !entry.includes('.bak')) yield p;
  }
}

let changed = 0, sites = 0;
const files = [...jsFiles(root)];
for (const file of files) {
  const before = readFileSync(file, 'utf8');
  let n = 0;
  const after = before.replace(RETIRED, () => { n++; return `kind: ${KIND}, ${MARK}`; });
  if (n === 0) continue;
  unlinkWrite(file, after);
  changed++; sites += n;
}

// The assertion is the point of this script: a site it did not know how to
// rewrite must stop the start, not surface later as a failed turn.
const left = files
  .map(f => [f, readFileSync(f, 'utf8')])
  .filter(([, s]) => LEFTOVER.test(s))
  .map(([f]) => f.slice(dir.length + 1));
if (left.length > 0) {
  console.error(`graph-memory: retired source kind still present in ${left.join(', ')} - the shape changed, re-check before patching`);
  process.exit(1);
}
console.log(`graph-memory: source kind rewritten at ${sites} site(s) in ${changed} file(s); none left`);
