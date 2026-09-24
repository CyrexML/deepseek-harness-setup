// bridge: mobile interface fixes - the question card and the tap highlight.
//
// 1. THE QUESTION CARD (ask_user_question). The host draws it in place of the
//    composer (packages/client/ui-user-questions/src/client/QuestionComposer.tsx,
//    class `.card` with `max-height: min(60vh, 520px)`). On a phone 60% of the
//    screen plus the bridge header and the tab row leave almost nothing of the
//    conversation: if the model wrote the options as TEXT in the chat they cannot
//    be read, and the card has to be closed. The fixes:
//      * the card's frame stretched across the whole composer seat (the whole
//        screen on a phone) and intercepted touches, so the conversation beneath
//        would not scroll even with the card folded. Events are now dropped on
//        the frame and the seat and returned to the card itself;
//      * the card height is clamp(260px, 58vh, 620px), so it follows the screen;
//      * when folded (no `[data-question-scroll]` body) the header shrinks to one
//        line, turning the card into a narrow strip above the composer and
//        opening the conversation completely;
//      * the fold and close buttons are enlarged to 40x40 - they were 24x24,
//        below the recommended touch target size.
// 2. THE CLOSE BUTTON MUST NOT FIRE BY ACCIDENT. It calls `pending.cancel()`
//    (QuestionComposer.tsx:168), which the model reads as a cancellation: the turn
//    continues without an answer, which the user sees as "an empty answer was
//    sent". On a phone, missing a 24-pixel target is expensive, so a confirmation
//    is asked before cancelling.
// 3. THE BLUE TAP FLASH. Android highlights a tapped target in translucent blue
//    (-webkit-tap-highlight-color) and leaves a blue focus ring afterwards. The
//    bridge suppressed that only for its own buttons (three rules in
//    mobile-styles.js). Here it is done for the whole interface: the highlight is
//    removed in favour of a short dimming (`:active`), while the focus ring stays
//    for keyboard users (`:focus-visible`), which accessibility needs.
//
// Written through unlink: plugin files are hardlinks into the pnpm store.
// Afterwards bridge-rebuild-client.sh rebuilds client/client.js.
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2] || '.';
const MARK = 'dsh-bridge-en: mobile ux';

const CSS = `

/* ${MARK} - question card and tap highlight on the phone */
@media (max-width: 768px) {
  /* The question card's frame stretches across the whole composer seat (the full
     screen height on a phone) and intercepts touches: the conversation beneath
     neither scrolls nor responds, even when the card is folded into a strip.
     Drop the events on the frame and the seat, return them to the card. */
  [class*="composerSeat"]:has([data-question-key]),
  [data-question-key] {
    pointer-events: none !important;
  }
  [data-question-key] {
    align-self: flex-end !important;
    height: auto !important;
  }
  [data-question-key] > section {
    pointer-events: auto !important;
    /* Sized to the screen: a tall phone gets more room for the options, a short
       one does not lose the conversation to the card. */
    max-height: clamp(260px, 58vh, 620px) !important;
  }
  /* Folded state: with no body, leave a narrow strip with a single header line
     so the conversation stays fully visible. */
  [data-question-key] > section:not(:has([data-question-scroll])) {
    max-height: none !important;
  }
  [data-question-key] > section:not(:has([data-question-scroll])) h2 {
    display: -webkit-box !important;
    -webkit-line-clamp: 1 !important;
    -webkit-box-orient: vertical !important;
    overflow: hidden !important;
  }
  /* Touch targets in the card header: 24px is too small for a finger. */
  [data-question-key] > section > header button {
    min-width: 40px !important;
    min-height: 40px !important;
  }
  /* Tap feedback: remove the blue flash and the blue ring left after a tap,
     keeping the ring for keyboard navigation. */
  *, *::before, *::after {
    -webkit-tap-highlight-color: transparent !important;
  }
  button:focus:not(:focus-visible),
  a:focus:not(:focus-visible),
  [role="button"]:focus:not(:focus-visible),
  [contenteditable="true"]:focus:not(:focus-visible) {
    outline: none !important;
    box-shadow: none !important;
  }
  button:active,
  [role="button"]:active {
    filter: brightness(0.94);
  }
}
`;

const GUARD = `
  // ${MARK}: the question card's close button calls pending.cancel() - the model
  // receives a cancellation and continues the turn without an answer. On a phone
  // missing a small target costs too much, so a confirmation is asked. Folding the
  // card (the neighbouring button) needs none: that is purely visual.
  (() => {
    if (window.__dshQuestionCancelGuard) return;
    window.__dshQuestionCancelGuard = true;
    document.addEventListener('click', (event) => {
      if (window.innerWidth > 768) return;
      const target = event.target instanceof Element ? event.target.closest('button') : null;
      if (target === null) return;
      const card = target.closest('[data-question-key]');
      if (card === null) return;
      const label = (target.getAttribute('aria-label') || '') + ' ' + (target.getAttribute('title') || '');
      // The Russian variants are deliberate: the same patch also applies to an
      // untranslated bridge, where the label is in the plugin's own language.
      if (!/dismiss|cancel|отмен|закр/i.test(label)) return;
      if (target.dataset.dshCancelConfirmed === '1') { delete target.dataset.dshCancelConfirmed; return; }
      event.preventDefault();
      event.stopPropagation();
      const ok = window.confirm('Close this question? The model receives a cancellation and continues without your answer.\\n\\nTo simply get the card out of the way and read the conversation, press Cancel and then the arrow next to the cross - it folds the card.');
      if (ok) { target.dataset.dshCancelConfirmed = '1'; target.click(); }
    }, true);
  })();
`;

// --- CSS in mobile-styles.js ------------------------------------------------
const stylesPath = join(dir, 'client/mobile-styles.js');
if (!existsSync(stylesPath)) { console.error(`no ${stylesPath}`); process.exit(1); }
let styles = readFileSync(stylesPath, 'utf8');
if (styles.includes(MARK)) {
  console.log('bridge: mobile ux - CSS already in place');
} else {
  const at = styles.lastIndexOf('`');
  if (at === -1) { console.error('could not find the end of the MOBILE_STYLES_CSS template string'); process.exit(1); }
  styles = styles.slice(0, at) + CSS + styles.slice(at);
  rmSync(stylesPath, { force: true });
  writeFileSync(stylesPath, styles);
  console.log('bridge: mobile ux - CSS added');
}

// --- JS guard in client/index.js --------------------------------------------
const indexPath = join(dir, 'client/index.js');
if (!existsSync(indexPath)) { console.error(`no ${indexPath}`); process.exit(1); }
let index = readFileSync(indexPath, 'utf8');
if (index.includes('__dshQuestionCancelGuard')) {
  console.log('bridge: mobile ux - cancel guard already in place');
  process.exit(0);
}
const ANCHOR = 'function setupMobileExperience(rpcCall, ctx) {\n  if (typeof document === \'undefined\' || typeof window === \'undefined\') return;\n  injectMobileStyles();\n';
const n = index.split(ANCHOR).length - 1;
if (n !== 1) { console.error(`MATCH COUNT ${n} for the setupMobileExperience anchor`); process.exit(1); }
index = index.replace(ANCHOR, ANCHOR + GUARD);
rmSync(indexPath, { force: true });
writeFileSync(indexPath, index);
console.log('bridge: mobile ux - cancel guard added');
