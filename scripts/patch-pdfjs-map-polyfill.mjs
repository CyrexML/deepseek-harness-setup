// pdf.js: polyfill for Map.prototype.getOrInsert / getOrInsertComputed.
//
// WHY. The host renders PDFs through pdfjs-dist 6.3.289, which calls
// `Map.prototype.getOrInsertComputed` - a method from a recent proposal that
// only reached Chrome lately. On a phone with an older browser the viewer dies
// with "Cannot display PDF: this[#methodPromises].getOrInsertComputed is not a
// function", while the same stand opens the file fine on a desktop with a
// current Chrome - hence the impression that "it broke on the phone".
//
// THE PATCH. A few lines implementing the proposed behaviour (return the value,
// or compute and store it when the key is missing) are inserted in TWO places of
// the built viewer chunk:
//   1) at the top of the file - the main thread, where it crashed;
//   2) at the top of the worker source string (`_dsh_pdf_worker_default`) used to
//      build the Blob worker: the worker is a separate context that the main
//      thread's polyfill never reaches, and it calls the method too.
//
// Browsers that already have the method are untouched: the guard is
// `typeof ... !== 'function'`.
//
// The file is rewritten by the harness build, so ensure-patches.sh re-applies
// this layer on every start.
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';

const DSH_ROOT = process.env.DSH_ROOT ?? `${process.env.HOME}/tools/deepseek-harness`;
const file = process.argv[2] ?? `${DSH_ROOT}/packages/client/ui-sidebar-documentpreview/lib/client.pdf.js`;
const MARK = '/* dsh-local: Map.getOrInsert polyfill */';

if (!existsSync(file)) { console.error(`no such file: ${file}`); process.exit(1); }
let s = readFileSync(file, 'utf8');
if (s.includes(MARK)) { console.log('pdf.js: Map.getOrInsert polyfill already in place'); process.exit(0); }

// The same code is needed both as plain text (main thread) and as the contents
// of a JS string (worker source), so the second copy is escaped.
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
  } catch (error) { /* optional: current browsers already have the method */ }
})();
`;

// 1. main thread - at the very top of the file
s = POLYFILL + s;

// 2. worker - at the start of the worker source string
const WORKER_ANCHOR = 'var _dsh_pdf_worker_default = "';
const hits = s.split(WORKER_ANCHOR).length - 1;
if (hits !== 1) { console.error(`MATCH COUNT ${hits} for the worker source anchor`); process.exit(1); }
const escaped = JSON.stringify(POLYFILL).slice(1, -1);   // without the surrounding quotes
s = s.replace(WORKER_ANCHOR, `${WORKER_ANCHOR}${escaped}`);

rmSync(file, { force: true });
writeFileSync(file, s);
console.log('pdf.js: Map.getOrInsert polyfill added (main thread + worker)');
