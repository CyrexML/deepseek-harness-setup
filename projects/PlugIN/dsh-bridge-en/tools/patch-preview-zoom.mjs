// Pinch zooms the CONTENT of the preview, not the panel interface. Idempotent.
//   node patch-preview-zoom.mjs <plugin_dir>
//
// Why. patch-zoom-scope.mjs gave the right panel the browser's normal zoom, so a
// pinch there scaled the WHOLE page: the panel's tabs, the address bar and the
// chat moved along with it, which helps little when you want to read small text
// in an open file. What is needed is the opposite: the panel frame stays put and
// only what is shown inside comes closer - a page in the embedded browser, a PDF,
// a spreadsheet, an image.
//
// How. The bridge intercepts the pinch itself (non-passive touchmove with
// preventDefault, so the browser never starts its own zoom) in TWO places: in the
// parent document for the panel, and INSIDE the preview document - because a
// touch that begins in an iframe never reaches the parent at all (the frame's
// document gets the events). The scale is applied to the content:
//   * for an <iframe> whose document is reachable (which is the case here: the
//     HTML preview runs without sandbox, see htmlViewerNoSandbox in the stand
//     settings) - `zoom` is set on its <html>. That is REAL zooming: the text
//     reflows and nothing is cut off;
//   * otherwise (<canvas> from pdf.js, <img>) - a REAL size in the markup
//     (width/height in pixels, max-width removed) rather than `transform` or
//     `zoom`: only then does the container get scrollbars and the enlarged page
//     can be dragged with a finger. On the way up horizontal scrolling is opened
//     as well, because the viewer clips it (overflow-x: hidden);
//   * the zoom focuses where the fingers are: inside the frame the scroll is
//     corrected after each step so the point under the fingers stays put
//     (otherwise `zoom` drags the content into the top-left corner);
//   * a double tap with two fingers returns to 100%.
// The scale is kept between 1 and 5 and remembered per tab while it is open.
//
// The anchor is `[data-sidebar-right-panel]`, an attribute of the native DSH
// 0.1.6 panel rather than a CSS-module hash, so it survives an interface rebuild.
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2] || '.';
const MARK = 'dsh-bridge-en: preview zoom';

const CSS = `

/* ${MARK} - pinch zooms the preview content, not the panel */
@media (max-width: 768px) {
  /* The browser must not start its own zoom inside the panel: we drive it. */
  [data-sidebar-right-panel],
  [data-sidebar-right-panel] * { touch-action: pan-x pan-y !important; }
  /* Scaled content grows from the top-left corner and the container scrolls. */
  [data-dsh-preview-zoom] {
    transform-origin: 0 0 !important;
    will-change: transform;
  }
}
`;

const GUARD = `
  // ${MARK}: a pinch inside the right panel scales only the preview content.
  (() => {
    if (window.__dshPreviewZoom) return;
    window.__dshPreviewZoom = true;
    var MIN = 1, MAX = 5;
    var state = null;          // { target, kind, startScale, startDist }
    var scales = new WeakMap(); // element -> current scale
    var lastTwoFingerTap = 0;

    var distance = function (touches) {
      var dx = touches[0].clientX - touches[1].clientX;
      var dy = touches[0].clientY - touches[1].clientY;
      return Math.hypot(dx, dy);
    };

    // What to scale under the fingers: the preview iframe, a pdf.js canvas, an
    // image - in that order, because the iframe may sit inside a container that
    // also holds a placeholder canvas.
    var pickTarget = function (node) {
      if (!(node instanceof Element)) return null;
      var panel = node.closest('[data-sidebar-right-panel]');
      if (panel === null) return null;
      var direct = node.closest('iframe, canvas, img');
      if (direct !== null) return direct;
      var inside = panel.querySelector('iframe, canvas, img');
      return inside;
    };

    // The document inside an iframe is reachable only for the same origin: the
    // sandbox-free preview is same-origin, an external site in the embedded
    // browser is not.
    var innerDoc = function (element) {
      if (element.tagName !== 'IFRAME') return null;
      try { return element.contentDocument && element.contentDocument.documentElement ? element.contentDocument : null; }
      catch (e) { return null; }
    };

    // The nearest scrolling ancestor differs per axis: a PDF page scrolls
    // vertically in the page container and horizontally in the page frame.
    var scrollerFor = function (node, axis) {
      var el = node.parentElement;
      while (el !== null && el !== document.body) {
        if (axis === 'x' ? el.scrollWidth > el.clientWidth + 1 : el.scrollHeight > el.clientHeight + 1) return el;
        el = el.parentElement;
      }
      return null;
    };

    // The viewer's containers clip content horizontally (overflow-x: hidden).
    // That was fine while the page fitted the panel; an enlarged one has to move
    // sideways, so horizontal scrolling is opened on the way up - inside the
    // panel only, and no deeper than six levels.
    var openHorizontalScroll = function (node) {
      var el = node.parentElement;
      for (var i = 0; el !== null && i < 6 && el.closest('[data-sidebar-right-panel]') !== null; i++) {
        var cs = getComputedStyle(el);
        if (cs.overflowX === 'hidden' || cs.overflowX === 'clip') el.style.overflowX = 'auto';
        el = el.parentElement;
      }
    };

    var baseSizes = new WeakMap();   // element -> size at scale 1

    // IMPORTANT: a PDF page (<canvas>) and images are enlarged by a REAL size in
    // the markup rather than by "transform: scale" or "zoom". A transform does not
    // change the space taken, so there is nothing to scroll and the enlarged page
    // cannot be dragged with a finger. The page itself carries max-width: 100%,
    // which also suppressed "zoom", so that is removed.
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
      // The content point under the fingers, in the content's own coordinates at
      // scale 1: after each step the scroll brings it back under the fingers.
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
      // The content grew, so the scroll is adjusted to keep the point that was
      // under the fingers in place (otherwise everything drifts to the top-left).
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

    // IMPORTANT: a touch that starts INSIDE an iframe never reaches the parent
    // document - the frame's own document gets the events. So for the preview
    // (same origin, sandbox off) the same handler is installed inside its
    // document. Without that, a pinch over an open page scaled the whole
    // interface, because the browser handled the gesture itself.
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
        // The document point under the fingers: with "zoom" the content
        // coordinates are multiplied by the scale, so it is stored AT SCALE 1 and
        // after each step the scroll is restored to keep that point under the
        // fingers. Without this the zoom always drifted to the top-left corner,
        // where the origin is.
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

    // Frames appear and reopen together with the panel's tabs, so the panel is
    // simply inspected periodically. A foreign origin (an external site in the
    // embedded browser) is unreachable and keeps the default behaviour.
    var scanFrames = function () {
      var frames = document.querySelectorAll('[data-sidebar-right-panel] iframe');
      for (var i = 0; i < frames.length; i++) {
        try {
          var doc = frames[i].contentDocument;
          if (doc && doc.documentElement) attachInside(doc);
        } catch (e) { /* different origin - skip */ }
      }
    };
    setInterval(scanFrames, 1200);
    document.addEventListener('load', scanFrames, true);
  })();
`;

// --- CSS --------------------------------------------------------------------
const stylesPath = join(dir, 'client/mobile-styles.js');
if (!existsSync(stylesPath)) { console.error(`no ${stylesPath}`); process.exit(1); }
let styles = readFileSync(stylesPath, 'utf8');
if (styles.includes(MARK)) {
  console.log('bridge: preview zoom - CSS already in place');
} else {
  const at = styles.lastIndexOf('`');
  if (at === -1) { console.error('could not find the end of the MOBILE_STYLES_CSS template string'); process.exit(1); }
  styles = styles.slice(0, at) + CSS + styles.slice(at);
  rmSync(stylesPath, { force: true });
  writeFileSync(stylesPath, styles);
  console.log('bridge: preview zoom - CSS added');
}

// --- JS ---------------------------------------------------------------------
const indexPath = join(dir, 'client/index.js');
if (!existsSync(indexPath)) { console.error(`no ${indexPath}`); process.exit(1); }
let index = readFileSync(indexPath, 'utf8');
if (index.includes('__dshPreviewZoom')) {
  console.log('bridge: preview zoom - handler already in place');
  process.exit(0);
}
const ANCHOR = 'function setupMobileExperience(rpcCall, ctx) {\n  if (typeof document === \'undefined\' || typeof window === \'undefined\') return;\n  injectMobileStyles();\n';
const n = index.split(ANCHOR).length - 1;
if (n !== 1) { console.error(`MATCH COUNT ${n} for the setupMobileExperience anchor`); process.exit(1); }
index = index.replace(ANCHOR, ANCHOR + GUARD);
rmSync(indexPath, { force: true });
writeFileSync(indexPath, index);
console.log('bridge: preview zoom - handler added');
