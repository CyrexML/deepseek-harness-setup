// dsh-univer-office: совместимость слота turnTail с DSH 0.1.6+ (id + свой matched).
//
// Та же поломка, что у better-sidebar: в 0.1.6 `conversation.chat.turnTail`
// стал list-слотом, хост требует `options.id`
// (packages/client/ui-slots/src/index.ts:1230), а плагин 0.3.2 регистрируется
// по-старому — с `select`, без `id` (lib/client.js:23097). Регистрация бросает
// исключение прямо в activate, и весь плагин не поднимается:
// «web boot: 1 entry did not activate — dsh-univer-office: failed».
//
// У list-записи компонент получает только owner-пропсы, без `matched`
// (ui-slots/src/index.ts:774), поэтому PreviewCard оборачивается: если
// `matched` не пришёл — считаем его тем же `selectUniverTurn(props)`, пустой
// результат отдаёт null.
//
// На 0.1.3 (там слот chain) оба изменения безвредны: лишний `id` игнорируется,
// а обёртка при наличии `matched` сразу зовёт исходный компонент.
// Запись через unlink: файл — хардлинк в pnpm-store.
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2] || `${process.env.HOME}/.dsh/profiles/web/node_modules/dsh-univer-office`;
const MARK = '/* dsh-local: turnTail slot id */';
const path = join(dir, 'lib/client.js');
if (!existsSync(path)) { console.error(`нет ${path}`); process.exit(1); }
let s = readFileSync(path, 'utf8');
if (s.includes(MARK)) { console.log('univer: turnTail id — уже применён'); process.exit(0); }

const edits = [
  [ // 1. id для списочной записи
    '              name: "conversation.chat.turnTail",\n              priority: -10,\n',
    `              name: "conversation.chat.turnTail",\n              id: "univer-turn-preview", ${MARK}\n              priority: -10,\n`,
  ],
  [ // 2. matched считаем сами, если хост его не передал
    '            PreviewCard\n',
    `            (props) => { ${MARK} // list-запись пропа matched не даёт
              const m = props.matched ?? selectUniverTurn(props);
              if (m === null || m === undefined) return null;
              return PreviewCard({ ...props, matched: m });
            }
`,
  ],
];
for (const [a, b] of edits) {
  const n = s.split(a).length - 1;
  if (n !== 1) { console.error(`MATCH COUNT ${n} для ${JSON.stringify(a.slice(0, 60))}`); process.exit(1); }
  s = s.replace(a, b);
}
rmSync(path, { force: true });
writeFileSync(path, s);
console.log('univer: turnTail id — применён');
