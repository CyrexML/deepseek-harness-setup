// pdf.js: полифил Map.prototype.getOrInsert / getOrInsertComputed.
//
// ПРИЧИНА. Хост показывает PDF через pdfjs-dist 6.3.289, а та использует
// `Map.prototype.getOrInsertComputed` — метод из свежего предложения к
// стандарту (Map.prototype.getOrInsert). В Chrome он появился совсем недавно,
// и на телефоне с более старым браузером просмотрщик падает с
//   Cannot display PDF: this[#methodPromises].getOrInsertComputed is not a function
// (сообщение пользователя 2026-09-23). На компьютере со свежим Chrome того же
// стенда PDF при этом открывается — отсюда ощущение «на телефоне сломалось».
//
// ПАТЧ. Полифил (несколько строк, поведение по предложению: вернуть значение,
// а если ключа нет — вычислить и записать) вставляется В ДВА места собранного
// чанка просмотрщика:
//   1) в начало файла — это главный поток, где и падало;
//   2) в начало строки-исходника рабочего потока (`_dsh_pdf_worker_default`),
//      из которой создаётся Blob-воркер: воркер — отдельный контекст, полифил
//      главного потока туда не попадает, а `getOrInsertComputed` он тоже зовёт.
//
// Полифил не трогает браузеры, где метод уже есть: проверка `typeof ... !== 'function'`.
//
// Файл перезаписывается `pnpm build` харнеса — слой переприменяет
// scripts/ensure-patches.sh при каждом старте.
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';

const DSH_ROOT = process.env.DSH_ROOT ?? `${process.env.HOME}/tools/deepseek-harness`;
const file = process.argv[2] ?? `${DSH_ROOT}/packages/client/ui-sidebar-documentpreview/lib/client.pdf.js`;
const MARK = '/* dsh-local: Map.getOrInsert polyfill */';

if (!existsSync(file)) { console.error(`нет файла ${file}`); process.exit(1); }
let s = readFileSync(file, 'utf8');
if (s.includes(MARK)) { console.log('pdf.js: полифил Map.getOrInsert — уже на месте'); process.exit(0); }

// Один и тот же код нужен и как обычный текст (главный поток), и как содержимое
// JS-строки (исходник воркера), поэтому вторую копию экранируем.
const POLYFILL = `${MARK}
(function () {
  try {
    var define = function (Ctor, name, impl) {
      if (Ctor && Ctor.prototype && typeof Ctor.prototype[name] !== 'function') {
        Object.defineProperty(Ctor.prototype, name, { value: impl, writable: true, configurable: true });
      }
    };
    var getOrInsert = function (key, value) { if (!this.has(key)) this.set(key, value); return this.get(key); };
    var getOrInsertComputed = function (key, compute) { if (!this.has(key)) this.set(key, compute(key)); return this.get(key); };
    define(typeof Map === 'function' ? Map : null, 'getOrInsert', getOrInsert);
    define(typeof Map === 'function' ? Map : null, 'getOrInsertComputed', getOrInsertComputed);
    define(typeof WeakMap === 'function' ? WeakMap : null, 'getOrInsert', getOrInsert);
    define(typeof WeakMap === 'function' ? WeakMap : null, 'getOrInsertComputed', getOrInsertComputed);
  } catch (error) { /* полифил необязателен: в свежих браузерах метод уже есть */ }
})();
`;

// 1. главный поток — в самое начало файла
s = POLYFILL + s;

// 2. рабочий поток — в начало строки с исходником воркера
const WORKER_ANCHOR = 'var _dsh_pdf_worker_default = "';
const hits = s.split(WORKER_ANCHOR).length - 1;
if (hits !== 1) { console.error(`MATCH COUNT ${hits} для якоря исходника воркера`); process.exit(1); }
const escaped = JSON.stringify(POLYFILL).slice(1, -1);   // без обрамляющих кавычек
s = s.replace(WORKER_ANCHOR, `${WORKER_ANCHOR}${escaped}`);

rmSync(file, { force: true });
writeFileSync(file, s);
console.log('pdf.js: полифил Map.getOrInsert — добавлен (главный поток + воркер)');
