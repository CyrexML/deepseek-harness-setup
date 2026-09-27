// Two things the composer gets wrong on a touch screen. Idempotent.
//   node patch-mobile-input.mjs <plugin_dir>
//
// 1. ENTER SENDS INSTEAD OF BREAKING THE LINE. The host binds Enter to submit
//    and reserves Shift+Enter for the line break
//    (packages/client/ui-conversation/src/client/input/editor/keymap.ts:131-134).
//    A phone keyboard has no Shift, so on a phone every Enter sends the message
//    and a multi-line message cannot be typed at all. Here a plain Enter on a
//    touch screen is turned into the Shift+Enter the host already understands:
//    the keydown is caught in the capture phase before the editor sees it and
//    re-dispatched with shiftKey set, so the line break comes from the host's
//    own code path rather than from a hand-rolled text insertion. Sending stays
//    on the send button, which is where a phone expects it. IME composition is
//    left alone (isComposing / keyCode 229), and nothing changes for a mouse.
//
// 2. A CLIPBOARD WITHOUT text/plain PASTES NOTHING. The host reads only
//    `text/plain` from the clipboard and, when it is empty and no files came
//    with it, hands the event back unhandled
//    (ui-conversation/src/client/input/editor/keymap.ts:162) - and nothing is
//    inserted. Copying rich text out of some apps puts `text/html` on the
//    clipboard without a plain-text flavour, and the paste silently does
//    nothing. Verified in the browser: a paste event carrying only text/html
//    leaves the draft untouched. Here the HTML is flattened to text (block tags
//    and <br> become newlines) and re-dispatched as an ordinary text/plain
//    paste, so the host's own path does the inserting. Not gated on touch: the
//    clipboard behaves the same everywhere.
//
// 3. A LONG QUESTION LEAVES NO ROOM FOR ITS ANSWERS. The question card is a flex
//    column capped in height, and its header carries `flex-shrink: 0`
//    (packages/client/ui-user-questions/src/client/QuestionComposer.module.css),
//    so a long question title pushes the option list down to a sliver - on a
//    phone the answers become almost invisible. The title gets its own height
//    cap and scrolls inside itself; the header buttons stay put and the options
//    keep the rest of the card.
//
// Written through unlink: plugin files are hardlinks into the pnpm store.
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';

const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

const dir = process.argv[2] || '.';
const MARK = 'dsh-bridge-en: mobile input';

// ---- 1. CSS: the question title stops eating the answers --------------------
{
  const path = join(dir, 'client/mobile-styles.js');
  let s = readFileSync(path, 'utf8');
  if (s.includes(MARK)) {
    console.log('client/mobile-styles.js: mobile input already present');
  } else {
    const css = `

/* ${MARK} - a long question must not squeeze out its own answers */
@media (max-width: 768px), (pointer: coarse) {
  /* The card is height-capped and its header does not shrink, so a long title
     takes the space the options need. Cap the title instead and let it scroll
     inside itself; the fold and close buttons are outside it and stay put. */
  [data-question-key] > section > header h2 {
    max-height: 18vh !important;
    overflow-y: auto !important;
    overscroll-behavior: contain;
  }
  /* What is left of the card belongs to the answers. */
  [data-question-key] > section > [data-question-scroll] {
    flex: 1 1 auto !important;
    min-height: 30vh !important;
  }
}
`;
    const anchor = '\n`;\n';
    const idx = s.lastIndexOf(anchor);
    if (idx < 0) { console.error('mobile-styles.js: end of MOBILE_STYLES_CSS not found'); process.exit(1); }
    s = s.slice(0, idx) + '\n' + css + s.slice(idx);
    unlinkWrite(path, s);
    console.log('client/mobile-styles.js: mobile input applied');
  }
}

// ---- 2. JS: Enter breaks the line on a touch screen -------------------------
{
  const path = join(dir, 'client/index.js');
  let s = readFileSync(path, 'utf8');
  if (s.includes(MARK)) { console.log('client/index.js: mobile input already present'); process.exit(0); }

  const CODE = `// ${MARK}: on a touch screen Enter breaks the line; the send button sends.
if (typeof window !== "undefined" && !window.__dshEnterNewline) {
  window.__dshEnterNewline = true;
  var __dshEnterTouch = function () {
    if (typeof __dshTouchUi === "function") return __dshTouchUi();
    return window.innerWidth <= 768;
  };
  document.addEventListener("keydown", function (e) {
    if (e.key !== "Enter") return;
    // Shift/Ctrl/Cmd/Alt+Enter keep whatever the host made of them - and the
    // event this handler re-dispatches carries shiftKey, so it returns here.
    if (e.shiftKey || e.ctrlKey || e.metaKey || e.altKey) return;
    if (e.isComposing || e.keyCode === 229) return;   // the IME owns this Enter
    if (!__dshEnterTouch()) return;
    var box = e.target && e.target.closest ? e.target.closest('[contenteditable="true"]') : null;
    if (!box) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    box.dispatchEvent(new KeyboardEvent("keydown", {
      key: "Enter", code: "Enter", keyCode: 13, which: 13,
      shiftKey: true, bubbles: true, cancelable: true, composed: true
    }));
  }, true);
}

// ${MARK}: a clipboard that carries only HTML still pastes.
if (typeof window !== "undefined" && !window.__dshHtmlPaste) {
  window.__dshHtmlPaste = true;
  document.addEventListener("paste", function (e) {
    var dt = e.clipboardData;
    if (!dt) return;
    if (dt.getData("text/plain")) return;   // the host reads this itself
    var html = dt.getData("text/html");
    if (!html) return;
    var text;
    try {
      var doc = new DOMParser().parseFromString(html, "text/html");
      if (!doc.body) return;
      // textContent, not innerText: the parsed document is never laid out, so
      // innerText would come back empty. Block boundaries are turned into
      // newlines by hand first, or the paragraphs would run together.
      doc.body.querySelectorAll("br").forEach(function (n) { n.replaceWith("\\n"); });
      doc.body.querySelectorAll("p,div,li,tr,h1,h2,h3,h4,h5,h6,blockquote,pre").forEach(function (n) { n.append("\\n"); });
      text = (doc.body.textContent || "").replace(/\\u00a0/g, " ").replace(/[ \\t]+\\n/g, "\\n").replace(/\\n{3,}/g, "\\n\\n").trim();
    } catch (err) { return; }
    if (!text) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    var next = new DataTransfer();
    next.setData("text/plain", text);
    e.target.dispatchEvent(new ClipboardEvent("paste", { clipboardData: next, bubbles: true, cancelable: true }));
  }, true);
}

`;

  const anchor = 'function __dshBridgeClientMain';
  const at = s.indexOf(anchor);
  s = at < 0 ? CODE + s : s.slice(0, at) + CODE + s.slice(at);
  unlinkWrite(path, s);
  console.log('client/index.js: mobile input applied');
}
