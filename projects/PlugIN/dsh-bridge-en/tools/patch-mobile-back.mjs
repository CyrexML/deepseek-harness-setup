// The system back gesture closes what is open, instead of leaving the app.
//   node patch-mobile-back.mjs <plugin_dir>
// Idempotent.
//
// Why. The host client never touches history: there is no pushState, no
// popstate and no router anywhere in packages/client. The bridge serves the
// interface as an installed PWA (display: standalone, lib/index.js:150), so on
// Android the edge swipe resolves to history.back() on a stack with a single
// entry - nothing happens, or the app closes. Everything that a back gesture is
// expected to dismiss - the session drawer, the right panel, a dialog - stays
// open, and each has to be closed by finding its own small button.
//
// What this changes. Every dismissible surface that opens pushes one history
// entry, and a back gesture pops the topmost one instead of leaving the page.
// Closing a surface by any other means (its own button, the backdrop, a session
// switch) takes that entry back off the stack, so the counts never drift apart.
// With nothing open, back behaves as it always did and leaves the app.
//
// The surfaces are read through the same selectors the bridge itself uses for
// them (client/index.js: dsh-drawer-open, sidebarOpenPanels, the mobile panel
// close button), so a plugin update that renames one breaks the detection rather
// than the navigation: an unrecognized surface simply is not tracked.
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';

const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

const dir = process.argv[2] || '.';
const MARK = 'dsh-bridge-en: mobile back';
const path = join(dir, 'client/index.js');

let s = readFileSync(path, 'utf8');
if (s.includes(MARK)) { console.log('client/index.js: mobile back already present'); process.exit(0); }

const CODE = `// ${MARK}: the back gesture closes the topmost open surface.
if (typeof window !== "undefined" && !window.__dshBackStack) {
  window.__dshBackStack = true;
  var __dshBackTouch = function () {
    // Only where the gesture exists: a page served through the bridge to a touch
    // device. Opened from this computer the interface keeps the desktop layout -
    // the right panel then stays mounted whatever its state, so its presence
    // would not mean "open", and a swallowed back press would be all the layer
    // achieved.
    var host = window.location.hostname || "";
    if (host === "127.0.0.1" || host === "localhost" || host === "::1" || host === "") return false;
    if (typeof __dshTouchUi === "function") return __dshTouchUi();
    return window.innerWidth <= 768;
  };
  // The panel is anchored on the host's own attribute, not on a CSS-module class:
  // the bridge remaps those hashes at runtime, and the literal nArs4W_panel it
  // greps for also matches nArs4W_panelBody, which is there even when the panel
  // is not. With the attribute, presence in the DOM is the open state.
  var __dshBackPanel = function () { return document.querySelector("[data-sidebar-right-panel]"); };
  var __dshBackDialog = function () {
    var list = document.querySelectorAll('[role="dialog"], [role="alertdialog"]');
    for (var i = 0; i < list.length; i++) {
      var el = list[i];
      if (el.getAttribute("aria-hidden") === "true") continue;
      if (el.offsetParent === null && getComputedStyle(el).position !== "fixed") continue;
      return el;
    }
    return null;
  };
  // Topmost first: what a back gesture should dismiss before anything below it.
  var __DSH_BACK_LAYERS = [
    {
      open: function () { return __dshBackDialog() !== null; },
      close: function () {
        var el = __dshBackDialog();
        if (!el) return;
        var esc = { key: "Escape", code: "Escape", keyCode: 27, which: 27, bubbles: true, cancelable: true };
        el.dispatchEvent(new KeyboardEvent("keydown", esc));
        document.dispatchEvent(new KeyboardEvent("keydown", esc));
      }
    },
    {
      open: function () { return document.body.classList.contains("dsh-drawer-open"); },
      close: function () { document.body.classList.remove("dsh-drawer-open"); }
    },
    {
      open: function () { return __dshBackPanel() !== null; },
      close: function () {
        var btn = document.querySelector(".dsh-mobile-panel-close-btn");
        if (btn) { btn.click(); return; }
        // The host's own collapse control, matched by its label rather than by a
        // class hash. Both locales the stand can run in are covered.
        var panel = __dshBackPanel();
        if (panel) {
          var list = panel.querySelectorAll("button");
          for (var i = 0; i < list.length; i++) {
            var name = list[i].getAttribute("aria-label") || list[i].title || "";
            if (/collapse right sidebar|\u6536\u8d77\u4fa7\u8fb9\u680f/i.test(name)) { list[i].click(); return; }
          }
        }
        var toggle = document.querySelector('[data-dsh-toggle-cluster] button:last-of-type, div[class*="toggleCluster"] button:last-of-type');
        if (toggle && toggle.getAttribute("aria-disabled") !== "true") toggle.click();
      }
    }
  ];
  var __dshBackCount = function () {
    if (!__dshBackTouch()) return 0;
    var n = 0;
    for (var i = 0; i < __DSH_BACK_LAYERS.length; i++) if (__DSH_BACK_LAYERS[i].open()) n++;
    return n;
  };
  var __dshBackDepth = 0;   // history entries this layer pushed
  var __dshBackUnwinding = false;
  var __dshBackSync = function () {
    if (__dshBackUnwinding) return;
    var n = __dshBackCount();
    if (n > __dshBackDepth) {
      while (__dshBackDepth < n) { __dshBackDepth++; history.pushState({ dshBackLayer: __dshBackDepth }, ""); }
    } else if (n < __dshBackDepth) {
      var steps = __dshBackDepth - n;
      __dshBackDepth = n;
      __dshBackUnwinding = true;
      history.go(-steps);
    }
  };
  window.addEventListener("popstate", function () {
    if (__dshBackUnwinding) { __dshBackUnwinding = false; return; }
    if (__dshBackDepth === 0) return;   // nothing of ours on the stack: ordinary navigation
    __dshBackDepth--;
    for (var i = 0; i < __DSH_BACK_LAYERS.length; i++) {
      if (__DSH_BACK_LAYERS[i].open()) { __DSH_BACK_LAYERS[i].close(); return; }
    }
  });
  var __dshBackPending = 0;
  var __dshBackSoon = function () {
    if (__dshBackPending) return;
    __dshBackPending = setTimeout(function () { __dshBackPending = 0; __dshBackSync(); }, 60);
  };
  if (document.body) new MutationObserver(__dshBackSoon).observe(document.body, { attributes: true, attributeFilter: ["class"], childList: true, subtree: true });
  window.addEventListener("resize", __dshBackSoon);
  __dshBackSoon();
}

`;

const anchor = 'function __dshBridgeClientMain';
const at = s.indexOf(anchor);
s = at < 0 ? CODE + s : s.slice(0, at) + CODE + s.slice(at);
unlinkWrite(path, s);
console.log('client/index.js: mobile back applied');
