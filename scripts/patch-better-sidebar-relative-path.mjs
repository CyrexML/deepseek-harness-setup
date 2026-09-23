// better-sidebar: ссылка на файл ИЗ ЧАТА должна открываться так же, как из проводника.
//
// ПРИЧИНА. Маршрут превью `/sidebar/html/<sessionId>/<путь>` собирает путь из
// сегментов URL и считает его АБСОЛЮТНЫМ (lib/index.js:669 decodeHtmlUrl:
// `path = "/" + tail.join("/")`). Строит адрес `htmlUrl(scope, path)`
// (lib/client.js:3832) — и передаёт путь как есть.
//
// Из проводника сайдбара путь приходит абсолютный ("/home/user/проект/cv.html"),
// и всё работает. А из переписки хост даёт путь ОТНОСИТЕЛЬНО рабочей области
// ("cv.html", "out/shot.png") — тогда получается URL
// `/sidebar/html/session-…/cv.html`, сервер раскрывает его в "/cv.html", файл
// оказывается вне рабочей области и запрос отвечает 400. Пользователь видит:
// по ссылке в чате — ошибка/пустая панель, а тот же файл из проводника
// открывается нормально (проверено 2026-09-23 на cv.html).
//
// ПАТЧ. `htmlUrl` достраивает относительный путь рабочим каталогом сессии —
// ровно тем же помощником `resolveSidebarPath(cwd, path)` (lib/client.js:3180),
// которым плагин уже пользуется в перехвате строки «произведённые файлы».
// Абсолютные пути проходят насквозь: первая же строка помощника возвращает их
// без изменений. Ровно та же беда у соседнего маршрута `/sidebar/file`
// (картинки из чата, скачивание): он передаёт cwd отдельным параметром, но
// сервер всё равно требует абсолютный путь (lib/index.js:295 requireAbsolute),
// поэтому достраивается и он.
//
// В lib/client-editor.js (отдельный чанк редактора) своей копии
// resolveSidebarPath нет, поэтому туда вставляется маленький встроенный
// эквивалент.
//
// Запись через unlink: файлы плагина — хардлинки в pnpm-store.
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2] || `${process.env.HOME}/.dsh/profiles/web/node_modules/dsh-better-sidebar`;
const MARK = '/* dsh-local: relative path in chat links */';

// Файлы, где живёт htmlUrl, и замена для каждого: в основном бандле есть
// resolveSidebarPath, в чанке редактора — нет.
// Маршрут /sidebar/file (картинки в чате, скачивание): сервер тоже требует
// абсолютный путь (lib/index.js:295 requireAbsolute), а параметр cwd служит
// только границей рабочей области, но не основой для достройки. Из чата путь
// приходит относительным ("out/shot.png") — запрос отвечает 400, картинка не
// открывается. Достраиваем так же, как в htmlUrl.
const FILE_URL_ANCHOR = '\t\t\tconst params = new URLSearchParams({\n\t\t\t\tsessionId: scope.sessionId,\n\t\t\t\tpath\n\t\t\t});\n';
const FILE_URL_PATCH = `\t\t\tconst params = new URLSearchParams({ ${MARK} // из чата путь приходит относительным
\t\t\t\tsessionId: scope.sessionId,
\t\t\t\tpath: resolveSidebarPath(scope.cwd, path)
\t\t\t});
`;

const targets = [
  {
    file: 'lib/client.js',
    anchor: '\t\tfunction htmlUrl(scope, path) {\n\t\t\treturn encodeHtmlUrl(scope.sessionId, path);\n\t\t}\n',
    patch: `\t\tfunction htmlUrl(scope, path) { ${MARK} // из чата путь приходит относительным
\t\t\treturn encodeHtmlUrl(scope.sessionId, resolveSidebarPath(scope.cwd, path));
\t\t}
`,
  },
  {
    file: 'lib/client-registry.js',
    anchor: '\t\tfunction htmlUrl(scope, path) {\n\t\t\treturn encodeHtmlUrl(scope.sessionId, path);\n\t\t}\n',
    patch: `\t\tfunction htmlUrl(scope, path) { ${MARK} // из чата путь приходит относительным
\t\t\treturn encodeHtmlUrl(scope.sessionId, resolveSidebarPath(scope.cwd, path));
\t\t}
`,
  },
  {
    file: 'lib/client-editor.js',
    anchor: '\tfunction htmlUrl(scope, path) {\n\t\treturn encodeHtmlUrl(scope.sessionId, path);\n\t}\n',
    patch: `\tfunction htmlUrl(scope, path) { ${MARK} // из чата путь приходит относительным
\t\tconst absolute = (() => {
\t\t\tif (/^([A-Za-z]:[\\\\/]|[\\\\/])/.test(path)) return path;
\t\t\tconst base = (scope.cwd ?? "").replace(/[\\\\/]+$/, "");
\t\t\tif (base === "") return path;
\t\t\treturn base + (base.includes("\\\\") ? "\\\\" : "/") + path;
\t\t})();
\t\treturn encodeHtmlUrl(scope.sessionId, absolute);
\t}
`,
  },
];

let touched = 0, already = 0, missing = 0;
for (const { file, anchor, patch } of targets) {
  const path = join(dir, file);
  if (!existsSync(path)) { missing++; continue; }
  let s = readFileSync(path, 'utf8');
  if (s.includes(MARK)) { already++; continue; }
  const n = s.split(anchor).length - 1;
  if (n !== 1) { console.error(`${file}: MATCH COUNT ${n} для якоря htmlUrl`); process.exit(1); }
  s = s.replace(anchor, patch);
  // второй якорь: только там, где есть fileUrl (основной бандл и реестр)
  const fileHits = s.split(FILE_URL_ANCHOR).length - 1;
  if (fileHits === 1) s = s.replace(FILE_URL_ANCHOR, FILE_URL_PATCH);
  else if (fileHits > 1) { console.error(`${file}: MATCH COUNT ${fileHits} для якоря fileUrl`); process.exit(1); }
  rmSync(path, { force: true });
  writeFileSync(path, s);
  touched++;
}
console.log(`better-sidebar: относительные пути из чата — обновлено ${touched}, уже было ${already}, нет файла ${missing}`);
