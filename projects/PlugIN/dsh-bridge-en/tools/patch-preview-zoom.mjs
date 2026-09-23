// Щипок масштабирует СОДЕРЖИМОЕ превью, а не интерфейс панели (2026-09-23).
// Идемпотентен.  node patch-preview-zoom.mjs <plugin_dir>
//
// Зачем. patch-zoom-scope.mjs отдал правой панели штатный зум браузера: щипок
// там масштабировал ВСЮ страницу, то есть вместе с панелью уезжали её вкладки,
// адресная строка и сам чат — рассмотреть мелкий текст в открытом файле это
// помогало плохо. Нужно другое: рамка панели стоит на месте, а приближается
// только то, что показано внутри — страница во встроенном браузере, PDF,
// таблица, картинка.
//
// Как сделано. Щипок перехватывается сами́м мостом (не-пассивный touchmove,
// preventDefault — браузер свой зум не начинает) в ДВУХ местах: в родительском
// документе для панели и ВНУТРИ документа превью — потому что касание, начатое
// в iframe, до родителя не доходит вообще (события получает документ кадра).
// Масштаб применяется к содержимому:
//   * если это <iframe> и документ внутри доступен (у нас так: превью HTML
//     работает без sandbox, см. htmlViewerNoSandbox в настройках стенда) —
//     ставим `zoom` на его <html>. Это НАСТОЯЩЕЕ масштабирование: текст
//     переверстывается, ничего не режется;
//   * иначе (<canvas> pdf.js, <img>) — НАСТОЯЩИЙ размер в разметке (width/height
//     в пикселях, снятый max-width), а не «transform» и не «zoom»: только так у
//     контейнера появляется прокрутка и увеличенную страницу можно возить
//     пальцем. Заодно по пути наверх открывается горизонтальная прокрутка —
//     просмотрщик режет её (overflow-x: hidden);
//   * приближается то место, куда поставили пальцы: у документа внутри кадра
//     прокрутка после каждого шага возвращается так, чтобы точка под пальцами
//     осталась на месте (иначе `zoom` тянет содержимое в левый верхний угол —
//     жалоба 2026-09-23);
//   * двойное касание двумя пальцами возвращает 100%.
// Масштаб держится в пределах 1…5 и запоминается на вкладку (пока она открыта).
//
// Якорь — `[data-sidebar-right-panel]`, атрибут родной панели DSH 0.1.6,
// а не хеш CSS-модуля: переживает пересборку интерфейса.
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2] || '.';
const MARK = 'dsh-bridge-en: preview zoom';

const CSS = `

/* ${MARK} — щипок масштабирует содержимое превью, а не панель */
@media (max-width: 768px) {
  /* Браузер не должен начинать свой зум внутри панели: масштабом управляем сами. */
  [data-sidebar-right-panel],
  [data-sidebar-right-panel] * { touch-action: pan-x pan-y !important; }
  /* Масштабируемое содержимое растёт от левого верхнего угла, контейнер прокручивается. */
  [data-dsh-preview-zoom] {
    transform-origin: 0 0 !important;
    will-change: transform;
  }
}
`;

const GUARD = `
  // ${MARK}: щипок внутри правой панели масштабирует только содержимое превью.
  (() => {
    if (window.__dshPreviewZoom) return;
    window.__dshPreviewZoom = true;
    var MIN = 1, MAX = 5;
    var state = null;          // { target, kind, startScale, startDist }
    var scales = new WeakMap(); // элемент -> текущий масштаб
    var lastTwoFingerTap = 0;

    var distance = function (touches) {
      var dx = touches[0].clientX - touches[1].clientX;
      var dy = touches[0].clientY - touches[1].clientY;
      return Math.hypot(dx, dy);
    };

    // Что именно масштабировать под пальцами: iframe превью, холст pdf.js,
    // картинка — в таком порядке, потому что iframe может лежать внутри
    // контейнера с холстом-заглушкой.
    var pickTarget = function (node) {
      if (!(node instanceof Element)) return null;
      var panel = node.closest('[data-sidebar-right-panel]');
      if (panel === null) return null;
      var direct = node.closest('iframe, canvas, img');
      if (direct !== null) return direct;
      var inside = panel.querySelector('iframe, canvas, img');
      return inside;
    };

    // Документ внутри iframe доступен только для своего происхождения; у превью
    // без песочницы он свой, у чужого сайта во встроенном браузере — нет.
    var innerDoc = function (element) {
      if (element.tagName !== 'IFRAME') return null;
      try { return element.contentDocument && element.contentDocument.documentElement ? element.contentDocument : null; }
      catch (e) { return null; }
    };

    // Ближайшие предки с прокруткой — по каждой оси своя: страницу PDF по
    // вертикали возит контейнер страниц, по горизонтали — рамка самой страницы.
    var scrollerFor = function (node, axis) {
      var el = node.parentElement;
      while (el !== null && el !== document.body) {
        if (axis === 'x' ? el.scrollWidth > el.clientWidth + 1 : el.scrollHeight > el.clientHeight + 1) return el;
        el = el.parentElement;
      }
      return null;
    };

    // Контейнеры просмотрщика режут содержимое по горизонтали
    // (overflow-x: hidden). Пока страница была в размер панели, это не мешало;
    // увеличенную подвинуть вбок уже нужно, поэтому по пути наверх открываем
    // горизонтальную прокрутку. Только внутри панели и не глубже шести шагов.
    var openHorizontalScroll = function (node) {
      var el = node.parentElement;
      for (var i = 0; el !== null && i < 6 && el.closest('[data-sidebar-right-panel]') !== null; i++) {
        var cs = getComputedStyle(el);
        if (cs.overflowX === 'hidden' || cs.overflowX === 'clip') el.style.overflowX = 'auto';
        el = el.parentElement;
      }
    };

    var baseSizes = new WeakMap();   // элемент -> размер при масштабе 1

    // ВАЖНО: страница PDF (<canvas>) и картинки увеличиваются НАСТОЯЩИМ
    // размером в разметке, а не «transform: scale» и не «zoom». Преобразование
    // не меняет занимаемое место, поэтому прокручивать нечего — увеличенную
    // страницу нельзя подвинуть пальцем (жалоба 2026-09-23). У самой страницы
    // при этом стоит max-width: 100%, который гасил и «zoom», — снимаем.
    var apply = function (element, scale) {
      scales.set(element, scale);
      var doc = innerDoc(element);
      if (doc !== null) {
        doc.documentElement.style.zoom = scale === 1 ? '' : String(scale);
        return;
      }
      var base = baseSizes.get(element);
      if (base === undefined) {
        var rect = element.getBoundingClientRect();
        var current = scales.get(element) || 1;
        base = { w: rect.width / current, h: rect.height / current };
        baseSizes.set(element, base);
      }
      element.setAttribute('data-dsh-preview-zoom', '');
      element.style.transform = '';
      element.style.zoom = '';
      if (scale === 1) {
        element.style.maxWidth = '';
        element.style.maxHeight = '';
        element.style.width = '';
        element.style.height = '';
        return;
      }
      element.style.maxWidth = 'none';
      element.style.maxHeight = 'none';
      element.style.width = (base.w * scale) + 'px';
      element.style.height = (base.h * scale) + 'px';
      openHorizontalScroll(element);
    };

    document.addEventListener('touchstart', function (event) {
      if (window.innerWidth > 768) return;
      if (event.touches.length !== 2) return;
      var target = pickTarget(event.target);
      if (target === null) return;
      var now = Date.now();
      if (now - lastTwoFingerTap < 400) {
        var sx0 = scrollerFor(target, 'x'), sy0 = scrollerFor(target, 'y');
        apply(target, 1);
        if (sx0 !== null) sx0.scrollLeft = 0;
        if (sy0 !== null) sy0.scrollTop = 0;
        state = null; lastTwoFingerTap = 0; event.preventDefault(); return;
      }
      lastTwoFingerTap = now;
      var midX = (event.touches[0].clientX + event.touches[1].clientX) / 2;
      var midY = (event.touches[0].clientY + event.touches[1].clientY) / 2;
      var current = scales.get(target) || 1;
      // Точка содержимого под пальцами — в координатах самого содержимого при
      // масштабе 1: после каждого шага прокрутка возвращает её под пальцы.
      var box = target.getBoundingClientRect();
      state = {
        target: target, startScale: current, startDist: distance(event.touches),
        docX: (midX - box.left) / current,
        docY: (midY - box.top) / current
      };
      event.preventDefault();
    }, { capture: true, passive: false });

    document.addEventListener('touchmove', function (event) {
      if (state === null || event.touches.length !== 2) return;
      var dist = distance(event.touches);
      if (state.startDist <= 0) return;
      var scale = state.startScale * (dist / state.startDist);
      scale = Math.min(MAX, Math.max(MIN, scale));
      apply(state.target, scale);
      // Содержимое выросло — доводим прокрутку так, чтобы точка, которая была
      // под пальцами, там и осталась (иначе всё уезжает в левый верхний угол).
      var midX = (event.touches[0].clientX + event.touches[1].clientX) / 2;
      var midY = (event.touches[0].clientY + event.touches[1].clientY) / 2;
      var box = state.target.getBoundingClientRect();
      var sx = scrollerFor(state.target, 'x');
      var sy = scrollerFor(state.target, 'y');
      if (sx !== null) sx.scrollLeft = Math.max(0, sx.scrollLeft + (box.left + state.docX * scale) - midX);
      if (sy !== null) sy.scrollTop = Math.max(0, sy.scrollTop + (box.top + state.docY * scale) - midY);
      event.preventDefault();
    }, { capture: true, passive: false });

    var stop = function () { state = null; };
    document.addEventListener('touchend', stop, true);
    document.addEventListener('touchcancel', stop, true);

    // ВАЖНО: касание, начатое ВНУТРИ iframe, до родительского документа не
    // доходит вовсе — события получает документ самого кадра. Поэтому для
    // превью (оно своего происхождения, песочница отключена) тот же обработчик
    // ставится внутрь его документа. Без этого щипок над открытой страницей
    // масштабировал весь интерфейс: браузер обрабатывал жест сам.
    var attachInside = function (doc) {
      if (doc.__dshPreviewZoomBound) return;
      doc.__dshPreviewZoomBound = true;
      var root = doc.documentElement;
      try { root.style.touchAction = 'pan-x pan-y'; } catch (e) {}
      var inner = null, innerTap = 0;
      var scroller = function () { return doc.scrollingElement || root; };
      var innerScale = function () {
        var current = parseFloat(root.style.zoom || '1');
        return isFinite(current) && current > 0 ? current : 1;
      };
      var center = function (touches) {
        return { x: (touches[0].clientX + touches[1].clientX) / 2, y: (touches[0].clientY + touches[1].clientY) / 2 };
      };
      doc.addEventListener('touchstart', function (event) {
        if (event.touches.length !== 2) return;
        var now = Date.now();
        if (now - innerTap < 400) {
          root.style.zoom = '';
          var box = scroller();
          box.scrollLeft = 0; box.scrollTop = 0;
          inner = null; innerTap = 0; event.preventDefault(); return;
        }
        innerTap = now;
        var scale = innerScale();
        var mid = center(event.touches);
        var box = scroller();
        // Точка документа под пальцами: при «zoom» координаты содержимого
        // умножаются на масштаб, поэтому храним её В МАСШТАБЕ 1 и после
        // каждого шага возвращаем прокрутку так, чтобы та же точка осталась
        // под пальцами. Без этого приближение всегда уезжало в левый верхний
        // угол — там начало координат.
        inner = {
          startScale: scale,
          startDist: distance(event.touches),
          docX: (box.scrollLeft + mid.x) / scale,
          docY: (box.scrollTop + mid.y) / scale
        };
        event.preventDefault();
      }, { capture: true, passive: false });
      doc.addEventListener('touchmove', function (event) {
        if (inner === null || event.touches.length !== 2 || inner.startDist <= 0) return;
        var scale = Math.min(MAX, Math.max(MIN, inner.startScale * (distance(event.touches) / inner.startDist)));
        root.style.zoom = scale === 1 ? '' : String(scale);
        var mid = center(event.touches);
        var box = scroller();
        box.scrollLeft = Math.max(0, inner.docX * scale - mid.x);
        box.scrollTop = Math.max(0, inner.docY * scale - mid.y);
        event.preventDefault();
      }, { capture: true, passive: false });
      var innerStop = function () { inner = null; };
      doc.addEventListener('touchend', innerStop, true);
      doc.addEventListener('touchcancel', innerStop, true);
    };

    // Кадры появляются и переоткрываются вместе с вкладками панели, поэтому
    // просто периодически осматриваем панель. Чужой origin (внешний сайт во
    // встроенном браузере) недоступен — там остаётся штатное поведение.
    var scanFrames = function () {
      var frames = document.querySelectorAll('[data-sidebar-right-panel] iframe');
      for (var i = 0; i < frames.length; i++) {
        try {
          var doc = frames[i].contentDocument;
          if (doc && doc.documentElement) attachInside(doc);
        } catch (e) { /* другой origin — пропускаем */ }
      }
    };
    setInterval(scanFrames, 1200);
    document.addEventListener('load', scanFrames, true);
  })();
`;

// --- CSS --------------------------------------------------------------------
const stylesPath = join(dir, 'client/mobile-styles.js');
if (!existsSync(stylesPath)) { console.error(`нет ${stylesPath}`); process.exit(1); }
let styles = readFileSync(stylesPath, 'utf8');
if (styles.includes(MARK)) {
  console.log('bridge: preview zoom — CSS уже на месте');
} else {
  const at = styles.lastIndexOf('`');
  if (at === -1) { console.error('не нашёл конец шаблонной строки MOBILE_STYLES_CSS'); process.exit(1); }
  styles = styles.slice(0, at) + CSS + styles.slice(at);
  rmSync(stylesPath, { force: true });
  writeFileSync(stylesPath, styles);
  console.log('bridge: preview zoom — CSS добавлен');
}

// --- JS ---------------------------------------------------------------------
const indexPath = join(dir, 'client/index.js');
if (!existsSync(indexPath)) { console.error(`нет ${indexPath}`); process.exit(1); }
let index = readFileSync(indexPath, 'utf8');
if (index.includes('__dshPreviewZoom')) {
  console.log('bridge: preview zoom — обработчик уже на месте');
  process.exit(0);
}
const ANCHOR = 'function setupMobileExperience(rpcCall, ctx) {\n  if (typeof document === \'undefined\' || typeof window === \'undefined\') return;\n  injectMobileStyles();\n';
const n = index.split(ANCHOR).length - 1;
if (n !== 1) { console.error(`MATCH COUNT ${n} для якоря setupMobileExperience`); process.exit(1); }
index = index.replace(ANCHOR, ANCHOR + GUARD);
rmSync(indexPath, { force: true });
writeFileSync(indexPath, index);
console.log('bridge: preview zoom — обработчик добавлен');
