// better-sidebar: отдать PDF и офисные файлы тем, кто умеет их рисовать.
//
// ПРИЧИНА. Плагин регистрирует свой тип `editor` на ВСЕ файловые адреса
// (`patterns: ["dsh-resource://file/**"]`, `canOpen: address => parseFileAddress(address) !== void 0`,
// lib/client.js:17047) с полосой приоритета "extension". Реестр вкладок родного
// правого сайдбара выбирает лучшего кандидата и пропускает тех, у кого `canOpen`
// вернул false (packages/client/ui-sidebar-right/src/client/tab-registry.ts:353).
// Пока плагин соглашается открыть всё, он забирает и .pdf, и .xlsx — а рисовать
// их не умеет: показывает «This file type cannot be previewed / Download to view»
// (проверено 2026-09-23 на office-test.xlsx).
//
// ЧТО ДАЁТ ПАТЧ. `canOpen` отказывается от расширений, для которых в стенде есть
// настоящий просмотрщик:
//   * pdf   → родной `ui-sidebar-documentpreview`: pdf.js рисует страницы в
//             <canvas> (src/client/pdf/document.ts:45) — работает и в мобильном
//             браузере, где iframe с blob-PDF Android просто скачивает;
//   * офис  → плагин dsh-univer-office (интерактивная таблица/документ), а если
//             его нет — родной office-просмотрщик (конвертация в PDF + тот же
//             pdf.js).
// HTML, markdown, картинки, код и всё остальное по-прежнему открывает плагин —
// его песочница (htmlViewerNoSandbox) нужна для многостраничных приложений.
//
// Запись через unlink: файлы плагина — хардлинки в pnpm-store.
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2] || `${process.env.HOME}/.dsh/profiles/web/node_modules/dsh-better-sidebar`;
const MARK = '/* dsh-local: binary handoff */';
const ANCHOR = '\t\t\t\t\t\t\tcanOpen: (address) => parseFileAddress(address) !== void 0\n';
const PATCH = `\t\t\t\t\t\t\tcanOpen: (address) => { ${MARK} // pdf → pdf.js хоста, офис → univer/офисный просмотрщик
\t\t\t\t\t\t\t\tconst parsed = parseFileAddress(address);
\t\t\t\t\t\t\t\tif (parsed === void 0) return false;
\t\t\t\t\t\t\t\treturn !/\\.(pdf|xlsx?|xlsm|xlsb|docx?|pptx?|odt|ods|odp)$/i.test(parsed.path ?? "");
\t\t\t\t\t\t\t}
`;

const files = ['lib/client.js', 'lib/client-registry.js'].filter(f => existsSync(join(dir, f)));
if (files.length === 0) { console.error(`нет файлов сборки в ${dir}`); process.exit(1); }

let touched = 0, already = 0;
for (const rel of files) {
  const path = join(dir, rel);
  let s = readFileSync(path, 'utf8');
  if (s.includes(MARK)) { already++; continue; }
  const n = s.split(ANCHOR).length - 1;
  if (n !== 1) { console.error(`${rel}: MATCH COUNT ${n} для якоря canOpen`); process.exit(1); }
  s = s.replace(ANCHOR, PATCH);
  rmSync(path, { force: true });
  writeFileSync(path, s);
  touched++;
}
console.log(`better-sidebar: binary handoff — обновлено ${touched}, уже было ${already} (файлов: ${files.length})`);
