// Масштабирование только в боковой панели (2026-09-23). Идемпотентен.
//   node patch-zoom-scope.mjs <plugin_dir>
//
// Зачем: на телефоне щипок в переписке мешает (случайно масштабируется чат),
// а в правой панели он нужен — там открывают результат: HTML-страницу, PDF,
// таблицу. Управлять этим через viewport нельзя: `user-scalable=no` выключает
// зум на всей странице (и всё равно обходится системной настройкой Android
// «Принудительное масштабирование»).
//
// Решение — по областям:
//   • CSS `touch-action: pan-x pan-y` на переписке и композере: браузер не
//     начинает жест масштабирования, если он начался внутри чата;
//   • правой панели (`[data-sidebar-right-panel]`, хост 0.1.6) и превью внутри
//     неё возвращаем `touch-action: auto` — щипок там работает штатно;
//   • страховка на JS: touchmove с двумя и более касаниями внутри чата
//     отменяется (не-пассивный слушатель), внутри панели — нет. Это перекрывает
//     и «принудительное масштабирование» Android.
// Якоря — data-атрибуты хоста (`data-conversation-scroll`, `data-chat-anchor-key`,
// `data-sidebar-right-panel`), а не хеши CSS-модулей: переживают пересборку.
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

const dir = process.argv[2] || '.';
const MARK = '/* dsh-bridge-en: zoom scope */';

// 1. CSS
{
  const path = join(dir, 'client/mobile-styles.js');
  let s = readFileSync(path, 'utf8');
  if (s.includes(MARK)) console.log('client/mobile-styles.js: zoom-scope already present');
  else {
    const css = `
    ${MARK}
    @media (max-width: 768px) {
      /* чат: щипок не начинается */
      [data-conversation-scroll],
      [data-chat-anchor-key],
      [contenteditable="true"] { touch-action: pan-x pan-y !important; }
      /* боковая панель: масштабирование штатное */
      [data-sidebar-right-panel],
      [data-sidebar-right-panel] * { touch-action: auto !important; }
    }
`;
    const anchor = '\n`;\n';
    const idx = s.lastIndexOf(anchor);
    if (idx < 0) { console.error('mobile-styles.js: конец MOBILE_STYLES_CSS не найден'); process.exit(1); }
    s = s.slice(0, idx) + '\n' + css + s.slice(idx);
    unlinkWrite(path, s);
    console.log('client/mobile-styles.js: zoom-scope применён');
  }
}

// 2. JS-страховка — рядом с остальной мобильной логикой клиента
{
  const path = join(dir, 'client/index.js');
  let s = readFileSync(path, 'utf8');
  if (s.includes(MARK)) { console.log('client/index.js: zoom-scope already present'); process.exit(0); }
  const anchor = 'function __dshBridgeClientMain';
  const at = s.indexOf(anchor);
  const inject = `${MARK}
// Щипок внутри переписки отменяем, внутри правой панели — пропускаем.
if (typeof window !== "undefined" && !window.__dshZoomScopeBound) {
  window.__dshZoomScopeBound = true;
  const inSidebar = (t) => !!(t && t.closest && t.closest('[data-sidebar-right-panel], [data-sidebar-right-float-host]'));
  document.addEventListener('touchmove', (e) => {
    if (e.touches.length < 2) return;
    if (inSidebar(e.target)) return;
    if (window.innerWidth > 768) return;
    e.preventDefault();
  }, { passive: false });
}
`;
  if (at < 0) s = inject + s;
  else s = s.slice(0, at) + inject + s.slice(at);
  unlinkWrite(path, s);
  console.log('client/index.js: zoom-scope применён');
}
