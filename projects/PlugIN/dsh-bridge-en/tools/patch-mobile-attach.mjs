// A direct attach button on the touch composer, plus a photo one. Idempotent.
//   node patch-mobile-attach.mjs <plugin_dir>
//
// Why. The host has no attach button at all: the file input is hidden
// (packages/client/ui-conversation/src/client/skeleton/InputBar.tsx:425) and the
// only way to it is the "+" menu, where the file entry is registered as a
// command (client/apply.ts:210). The "+" button carries onMouseDown={keepFocus}
// (InputBar.tsx:418), so on a phone the tap returns focus to the draft, the
// keyboard comes up and covers the menu that was just opened - the file entry
// has to be reached around the keyboard. There is also no separate photo entry:
// the input declares no accept, so the system offers a file manager and the
// gallery has to be found inside it.
//
// What this changes. On a touch screen two buttons are placed in the composer's
// tool row, next to the "+": one opens the file dialog, the other the same
// dialog with accept="image/*", which on Android and iOS offers the camera and
// the gallery directly.
//
// The two buttons declare different accepts on purpose. A file input with no
// accept at all makes Android offer every content source it has, camera and
// gallery included - which is noise next to a photo button that already does
// exactly that. The paperclip therefore asks for documents only
// (application/* covers pdf, archives, office files and anything unknown, which
// Android maps to application/octet-stream; text/* covers txt, csv, md, source
// files), and that is what takes the camera out of its list. Images and video
// belong to the other button. To have the paperclip offer everything again,
// set ATTACH_FILE_ACCEPT below to an empty string. Both click the host's own input, so the file travels the
// host's normal intake path - nothing is uploaded by the bridge. The buttons
// cancel pointerdown instead of taking focus, so neither of them raises the
// keyboard.
//
// The buttons are re-created when the interface remounts them away, borrow the
// class list of the "+" next to them so they carry the host's own styling, and
// are removed when the window stops being a touch one.
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';

const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

const dir = process.argv[2] || '.';
const MARK = 'dsh-bridge-en: mobile attach';
const path = join(dir, 'client/index.js');

let s = readFileSync(path, 'utf8');
if (s.includes(MARK)) { console.log('client/index.js: mobile attach already present'); process.exit(0); }

const CODE = `// ${MARK}: a one-tap attach button on a touch composer, and a photo one.
if (typeof window !== "undefined" && !window.__dshAttachButtons) {
  window.__dshAttachButtons = true;
  var __dshAttachTouch = function () {
    if (typeof __dshTouchUi === "function") return __dshTouchUi();
    return window.innerWidth <= 768;
  };
  var __DSH_ATTACH_ICONS = {
    file: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48"/></svg>',
    photo: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="M21 15l-5-5L5 21"/></svg>'
  };
  // Documents only, so Android does not put the camera in the paperclip's list.
  // Empty string = no filter at all (every source, as before).
  var ATTACH_FILE_ACCEPT = "application/*,text/*";
  var __dshAttachOpen = function (input, photo) {
    if (!input || input.disabled) return;
    var had = input.getAttribute("accept");
    var want = photo ? "image/*" : ATTACH_FILE_ACCEPT;
    var restore = function () {
      if (!want) return;
      if (had === null) input.removeAttribute("accept");
      else input.setAttribute("accept", had);
    };
    if (want) input.setAttribute("accept", want);
    input.addEventListener("change", restore, { once: true });
    window.addEventListener("focus", restore, { once: true });
    setTimeout(restore, 60000);
    input.click();
  };
  var __dshAttachButton = function (input, photo, sample) {
    var btn = document.createElement("button");
    btn.type = "button";
    btn.dataset.dshAttach = photo ? "photo" : "file";
    if (sample) btn.className = sample.className;
    btn.setAttribute("aria-label", photo ? "Attach photo" : "Attach file");
    btn.title = photo ? "Attach photo" : "Attach file";
    btn.innerHTML = photo ? __DSH_ATTACH_ICONS.photo : __DSH_ATTACH_ICONS.file;
    // Do not let the tap move focus into the draft: that is what raises the keyboard.
    btn.addEventListener("pointerdown", function (e) { e.preventDefault(); });
    btn.addEventListener("mousedown", function (e) { e.preventDefault(); });
    btn.addEventListener("click", function (e) {
      e.preventDefault();
      e.stopPropagation();
      __dshAttachOpen(input, photo);
    });
    return btn;
  };
  var __dshAttachSync = function () {
    var on = __dshAttachTouch();
    if (!on) {
      document.querySelectorAll("[data-dsh-attach]").forEach(function (b) { b.remove(); });
      return;
    }
    document.querySelectorAll('input[type="file"]').forEach(function (input) {
      var row = input.parentElement;
      if (!row || row.querySelector("[data-dsh-attach]")) return;
      var sample = row.querySelector("button");
      row.insertBefore(__dshAttachButton(input, false, sample), input.nextSibling);
      row.insertBefore(__dshAttachButton(input, true, sample), input.nextSibling);
    });
  };
  var __dshAttachPending = 0;
  var __dshAttachSoon = function () {
    if (__dshAttachPending) return;
    __dshAttachPending = requestAnimationFrame(function () {
      __dshAttachPending = 0;
      __dshAttachSync();
    });
  };
  if (document.body) new MutationObserver(__dshAttachSoon).observe(document.body, { childList: true, subtree: true });
  window.addEventListener("resize", __dshAttachSoon);
  __dshAttachSoon();
}

`;

const anchor = 'function __dshBridgeClientMain';
const at = s.indexOf(anchor);
s = at < 0 ? CODE + s : s.slice(0, at) + CODE + s.slice(at);
unlinkWrite(path, s);
console.log('client/index.js: mobile attach applied');
