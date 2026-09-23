// better-sidebar: определить активную сессию на DSH 0.1.6 и держать её в store.
//
// ПРИЧИНА. Плагин 0.19.1 берёт активную сессию из
// `ctx.sessions.list.getSnapshot().current` (lib/client.js:17152,
// `function activeSessionId(ctx)`). На 0.1.6-alpha.2 в снимке списка такого поля
// больше НЕТ — проверено вживую, ключи снимка:
//   ids, byId, phase, subagentsByParent, jobsBySession
// Хост теперь помечает показываемую сессию удержанием `mainView`, см.
// packages/client/ui-workspace/src/client/tree.ts:43 и
// packages/client/ui-session/src/client/index.ts:442:
//   Object.values(byId).find(s => (s.retainedBy.mainView ?? 0) > 0)?.id
//
// СЛЕДСТВИЕ ДО ПАТЧА. `activeSessionId` всегда undefined, а свой store плагин
// обновляет только из компонента `Sidebar` (lib/client.js:16031), который на
// 0.1.6 не монтируется — панель рисует родной `ui-sidebar-right`. Поэтому в
// `openTab` (lib/client.js:1365) `scope?.sessionId ?? store.getSnapshot().sessionId`
// = undefined и происходит молчаливый выход `if (targetSessionId === void 0) return;`
// — клик по файлу в проводнике плагина не делает НИЧЕГО. По той же причине
// `place()` (native/surface.ts) всегда считал вкладку «не на экране».
//
// ПАТЧ. Два шага:
//   1) `activeSessionId` получает запасной путь через `retainedBy.mainView`;
//   2) в точке создания store вешается подписка на список сессий, которая зовёт
//      `sidebarStore.setSession(activeSessionId(ctx))` — независимо от того,
//      смонтирована ли собственная панель плагина.
// На 0.1.3 безвреден: `current` там есть и проверяется первым, а setSession
// идемпотентен (ранний выход при том же id).
//
// Запись через unlink: файлы плагина — хардлинки в pnpm-store.
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
const ACTIVE_PATCH = `\t\tfunction activeSessionId(ctx) { ${MARK} // 0.1.6: поля current нет, показываемую сессию держит mainView
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
const STORE_PATCH = STORE_ANCHOR + `\t\t\tctx.effect(() => { ${MARK} // родной сайдбар не монтирует панель плагина — сессию берём у хоста
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
if (files.length === 0) { console.error(`нет файлов сборки в ${dir}`); process.exit(1); }

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
    if (n !== 1) { console.error(`${rel}: MATCH COUNT ${n} для якоря ${what}`); process.exit(1); }
    s = s.replace(anchor, replacement);
  }
  rmSync(path, { force: true });
  writeFileSync(path, s);
  touched++;
}
console.log(`better-sidebar: session sync — обновлено ${touched}, уже было ${already} (файлов: ${files.length})`);
