// bridge: страница приложения не должна кешироваться браузером телефона.
// Идемпотентен.  node patch-html-no-store.mjs <plugin_dir>
//
// Зачем. Ответ с HTML приходит БЕЗ заголовка Cache-Control (проверено
// 2026-09-23: `cache: —`), поэтому браузер кеширует его «на своё усмотрение»
// (эвристика по Last-Modified). А ссылки на бандлы плагинов внутри этой
// страницы отдаются с `public, max-age=31536000, immutable` и различаются
// только параметром `rev`, который считается от содержимого файла
// (packages/client/modules/src/index.ts:211 artifactRevision).
//
// Итог: если телефон держит СТАРУЮ страницу, он держит и старый `rev`, а его
// бандл закеширован на год и не перезапрашивается. Внешне это выглядит так,
// будто исправления «откатились»: на компьютере всё новое, на телефоне —
// прежнее поведение. Именно так вернулись жалобы на PDF и масштабирование.
//
// Патч добавляет `Cache-Control: no-store` к ответам с HTML (там, где мост и
// так переписывает тело, вставляя свою шапку). Бандлы при этом остаются
// «вечными» — они и должны быть такими, их адрес меняется при каждой правке.
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2] || '.';
const MARK = '/* dsh-bridge-en: html no-store */';
const file = join(dir, 'lib/index.js');
if (!existsSync(file)) { console.error(`нет ${file}`); process.exit(1); }

let s = readFileSync(file, 'utf8');
if (s.includes(MARK)) { console.log('bridge: html no-store — уже на месте'); process.exit(0); }

const ANCHOR = `              delete outHeaders['content-length'];
              delete outHeaders['transfer-encoding'];
              outHeaders['content-length'] = String(out.length);
`;
const n = s.split(ANCHOR).length - 1;
if (n !== 1) { console.error(`MATCH COUNT ${n} для якоря заголовков ответа`); process.exit(1); }

const PATCH = ANCHOR + `              if (contentType.includes('text/html')) { ${MARK} // иначе телефон держит старую страницу со старым rev бандла
                outHeaders['cache-control'] = 'no-store';
                outHeaders['cdn-cache-control'] = 'no-store';
                delete outHeaders['etag'];
                delete outHeaders['last-modified'];
              }
`;
s = s.replace(ANCHOR, PATCH);
rmSync(file, { force: true });
writeFileSync(file, s);
console.log('bridge: html no-store — добавлен');
