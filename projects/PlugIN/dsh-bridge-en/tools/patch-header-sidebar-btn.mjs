// bridge: убрать нашу кнопку сайдбара из мобильной шапки.
//
// ПОЧЕМУ. Кнопка `dsh-header-sidebar-btn` (tools/patch-sidebar.mjs) появилась, когда
// better-sidebar рисовал панель сам, а его собственный переключатель мы прятали
// на телефоне. В DSH 0.1.6 правую панель рисует родной `ui-sidebar-right` со своим
// переключателем — наша кнопка дублирует его и больше не нужна (запрос 2026-09-23).
//
// Патч оставляет helpers `toggleSidebarPanel`/`closeSidebarPanel` (их зовут
// заголовок и переключение сессий) и только не вставляет кнопку в шапку: вместо
// `header.appendChild(sideBtn)` — пустая строка с маркером. Сама кнопка не
// создаётся, её CSS остаётся мёртвым кодом (безвреден).
//
// Запись через unlink: файлы плагина — хардлинки в pnpm-store. После этого
// `bridge-rebuild-client.sh` пересобирает client/client.js (то, что уходит в браузер).
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2] || `${process.env.HOME}/.dsh/profiles/web/node_modules/@wenbin_wb/dsh-bridge`;
const MARK = '/* dsh-bridge-en: header sidebar button removed */';
const file = join(dir, 'client/index.js');
if (!existsSync(file)) { console.error(`нет файла ${file}`); process.exit(1); }

let s = readFileSync(file, 'utf8');
if (s.includes(MARK)) { console.log('bridge: кнопка сайдбара — уже убрана'); process.exit(0); }

// 1. не создавать кнопку: весь блок от комментария до onclick
const CREATE_START = '    // Sidebar (workbench) toggle';
const CREATE_END = '    sideBtn.onclick = (e) => { e.stopPropagation(); toggleSidebarPanel(); };\n';
const start = s.indexOf(CREATE_START);
const end = s.indexOf(CREATE_END);
if (start === -1 || end === -1 || end < start) { console.error('якорь создания кнопки не найден'); process.exit(1); }
s = s.slice(0, start) + `    ${MARK} // родной ui-sidebar-right (0.1.6) даёт свой переключатель\n` + s.slice(end + CREATE_END.length);

// 2. не вставлять её в шапку
const APPEND = '    header.appendChild(sideBtn);\n';
const n = s.split(APPEND).length - 1;
if (n !== 1) { console.error(`MATCH COUNT ${n} для header.appendChild(sideBtn)`); process.exit(1); }
s = s.replace(APPEND, '');

rmSync(file, { force: true });
writeFileSync(file, s);
console.log('bridge: кнопка сайдбара убрана из мобильной шапки');
