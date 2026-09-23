// Recall graph-memory only from sessions of the current workspace.
//
// The graph-memory plugin (dist/dsh.js, agent/pre-step) injects "memories" before
// every user message - turn memories selected by FTS5 over the WHOLE database. It
// has no project boundary (dist/src/format/dsh-recall.js filterDshRecallMemories
// only excludes the current session), so notes from a different project arrived
// in this one: 700-4500 tokens per turn, up to 12.6% of everything entering the
// context.
//
// The plugin's database does not store cwd, but DSH lays session journals out by
// workspace: ~/.dsh/sessions/<key>/session-<id>, where the key is '-' + cwd with
// '/' replaced by '-' + '--'. The patch builds a "session id -> key" map (cached
// for 60 s) and keeps only memories from sessions with the same key as the
// current session's cwd. Navigational triples and episodic context in assemble.js
// are already filtered by the selected memories.
//
// Idempotent (marker). Re-applied by scripts/ensure-patches.sh; after a plugin
// update the anchors may move - then MATCH COUNT is not 1 and it exits 1.
// Written through unlink: the file is a hardlink into the pnpm store.
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
const path = process.argv[2] || `${process.env.HOME}/.dsh/profiles/web/node_modules/graph-memory/dist/dsh.js`;
const MARK = '/* dsh-local: workspace-scoped recall */';
let s = readFileSync(path, 'utf8');
if (s.includes(MARK)) { console.log(`${path}: already patched`); process.exit(0); }
function edit(a, b) {
  const n = s.split(a).length - 1;
  if (n !== 1) { console.error(`MATCH COUNT ${n} for ${JSON.stringify(a.slice(0, 90))}`); process.exit(1); }
  s = s.replace(a, b);
}

// 1. Helper, right after the import block (the first line that is neither an
//    import nor a comment).
edit(
`function sessionKey(id) {`,
`${MARK}
import { readdirSync as __dshReaddir } from "node:fs";
import { join as __dshJoin } from "node:path";
import { homedir as __dshHome } from "node:os";
let __dshWsMap = null, __dshWsAt = 0;
function __dshWorkspaceOfSession() {
    if (__dshWsMap && Date.now() - __dshWsAt < 60000) return __dshWsMap;
    const map = new Map();
    try {
        const root = __dshJoin(process.env.DSH_HOME ?? __dshJoin(__dshHome(), ".dsh"), "sessions");
        for (const ws of __dshReaddir(root, { withFileTypes: true })) {
            if (!ws.isDirectory()) continue;
            for (const e of __dshReaddir(__dshJoin(root, ws.name))) map.set(e.replace(/^session-/, ""), ws.name);
        }
    } catch { /* no directory: the map stays empty and the filter passes everything */ }
    __dshWsMap = map; __dshWsAt = Date.now();
    return map;
}
function __dshScopeMemories(memories, cwd) {
    if (typeof cwd !== "string" || !cwd) return memories;
    const key = "-" + cwd.replace(/\\//g, "-") + "--";
    const map = __dshWorkspaceOfSession();
    if (map.size === 0) return memories;
    return memories.filter(m => map.get(String(m.sessionId).replace(/^dsh:/, "").replace(/^session-/, "")) === key);
}
function sessionKey(id) {`);

// 2. The filter point.
edit(
`            const recalledMemories = filterDshRecallMemories(recalled.turnMemories, currentSession, visibleMessageIds);`,
`            const recalledMemories = __dshScopeMemories(filterDshRecallMemories(recalled.turnMemories, currentSession, visibleMessageIds), agent?.session?.header?.cwd); ${MARK}`);

rmSync(path, { force: true });
writeFileSync(path, s);
console.log(`${path}: workspace-scoped recall applied`);
