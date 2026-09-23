// better-sidebar: совместимость слота turnTail с DSH 0.1.6+ (id + свой matched).
//
// В 0.1.6-alpha.2 слот `conversation.chat.turnTail` из chain стал list, а хост
// требует у списочных регистраций `options.id`
// (packages/client/ui-slots/src/index.ts:1230). Плагин 0.19.1 его не передаёт
// (lib/client.js:3478) → `list slot "conversation.chat.turnTail" requires
// options.id`, весь сайдбар падает с Minified React error #130.
//
// Второе отличие list от chain: у chain-записи компонент получает результат
// `select` в пропе `matched`, у list-записи — только owner-пропсы (turn, seq,
// openFile), см. ui-slots/src/index.ts:774 и :290. Плагин написан под chain и
// падает на `matched.slice(...)` (lib/client.js:3421, «slot entry crashed in
// conversation.chat.turnTail»). Поэтому вторым шагом компонент оборачивается:
// если `matched` не пришёл — он вычисляется тут же теми же правилами, что в
// `select`, а пустой результат отдаёт null (list-запись вправе ничего не рисовать).
//
// Для старых хостов (0.1.3, где слот chain) оба изменения безвредны: лишний `id`
// игнорируется (там проверяется только `select`, ui-slots/src/index.ts:852), а
// обёртка при наличии `matched` сразу зовёт исходный компонент.
//
// Правятся ВСЕ файлы сборки плагина, где встречается регистрация (client.js —
// то, что отдаётся браузеру, client-registry.js — его вариант для реестра).
// Запись через unlink: файлы плагина — хардлинки в pnpm-store.
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2] || `${process.env.HOME}/.dsh/profiles/web/node_modules/dsh-better-sidebar`;
const MARK = '/* dsh-local: turnTail slot id */';
const ID = 'better-sidebar-turn-tail';
const ANCHOR = '\t\t\t\tname: "conversation.chat.turnTail",\n';
const files = ['lib/client.js', 'lib/client-registry.js'].filter(f => existsSync(join(dir, f)));
if (files.length === 0) { console.error(`нет файлов сборки в ${dir}`); process.exit(1); }

const COMPONENT_ANCHOR = '\t\t\t}, SidebarProducedFiles));\n';
const COMPONENT_PATCH = `\t\t\t}, (props) => { ${MARK} // list-запись пропа matched не даёт — считаем сами
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
    if (n !== 1) { console.error(`${rel}: MATCH COUNT ${n} для якоря ${what}`); process.exit(1); }
    s = s.replace(anchor, replacement);
  }
  rmSync(path, { force: true });
  writeFileSync(path, s);
  touched++;
}
console.log(`better-sidebar: turnTail id — обновлено ${touched}, уже было ${already} (файлов: ${files.length})`);
