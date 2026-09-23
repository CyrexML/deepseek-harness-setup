// Recall graph-memory только из сессий текущего workspace.
//
// Плагин graph-memory (dist/dsh.js, agent/pre-step) перед каждым сообщением
// пользователя вставляет «воспоминания» — turn memories, отобранные FTS5 по
// тексту вопроса из ВСЕЙ базы. Границы проекта у него нет
// (dist/src/format/dsh-recall.js filterDshRecallMemories отсекает только
// текущую сессию), поэтому в Cooking_APP приезжали заметки про холст другого
// проекта: 700–4 500 токенов на ход, до 12.6 % всего, что входило в контекст
// (аудит 2026-09-15, сессии e86c8a24 / 5f83de34).
//
// cwd в базе плагина не хранится, но DSH раскладывает журналы сессий по
// workspace: ~/.dsh/sessions/<ключ>/session-<id>, где ключ = '-' + cwd с '/'
// заменёнными на '-' + '--'. Патч строит карту «id сессии → ключ» (кэш 60 с)
// и оставляет только memories сессий с тем же ключом, что у cwd текущей
// сессии. Навигационные тройки и episodic-контекст в assemble.js уже
// фильтруются по отобранным memories, отдельно их трогать не надо.
//
// Идемпотентен (маркер). Переприменяется scripts/ensure-patches.sh; после
// обновления плагина якоря могут уехать — тогда MATCH COUNT ≠ 1 и выход 1.
// Запись через unlink: файл — хардлинк на pnpm-store.
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

// 1. Помощник — после блока импортов (первая строка, не начинающаяся с import/комментария).
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
    } catch { /* нет каталога — карта пустая, фильтр пропустит всё */ }
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

// 2. Точка фильтра.
edit(
`            const recalledMemories = filterDshRecallMemories(recalled.turnMemories, currentSession, visibleMessageIds);`,
`            const recalledMemories = __dshScopeMemories(filterDshRecallMemories(recalled.turnMemories, currentSession, visibleMessageIds), agent?.session?.header?.cwd); ${MARK}`);

rmSync(path, { force: true });
writeFileSync(path, s);
console.log(`${path}: workspace-scoped recall applied`);
