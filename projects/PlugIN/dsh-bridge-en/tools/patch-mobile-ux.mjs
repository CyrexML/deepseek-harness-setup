// bridge: мобильные правки интерфейса — окно вопросов и подсветка нажатий.
//
// 1. ОКНО ВОПРОСОВ (ask_user_question). Хост рисует его карточкой на месте
//    композера (packages/client/ui-user-questions/src/client/QuestionComposer.tsx,
//    класс `.card` с `max-height: min(60vh, 520px)`). На телефоне 60% экрана плюс
//    шапка моста и строка вкладок не оставляют от переписки почти ничего: если
//    модель написала варианты ТЕКСТОМ в чате, прочитать их нельзя, а карточку
//    приходится закрывать. Правки:
//      * рамка карточки растягивалась на всё сиденье композера (на телефоне —
//        на весь экран) и перехватывала касания: переписка под ней не
//        прокручивалась даже у свёрнутой карточки. Теперь события гасятся на
//        рамке и сиденье и возвращаются самой карточке;
//      * высота карточки — clamp(260px, 58vh, 620px): подстраивается под экран;
//      * в свёрнутом виде (тела `[data-question-scroll]` нет) заголовок
//        ужимается до одной строки, то есть карточка превращается в узкую
//        полосу над композером, а переписка открывается целиком;
//      * кнопка «свернуть/развернуть» и крестик увеличены до 40×40 —
//        по рекомендации к размеру цели нажатия они были 24×24.
// 2. КРЕСТИК НЕ ДОЛЖЕН СРАБАТЫВАТЬ СЛУЧАЙНО. Он зовёт `pending.cancel()`
//    (QuestionComposer.tsx:168) — для модели это отмена, и ход продолжается
//    без ответа, что пользователь видит как «отправился пустой ответ».
//    На телефоне промах по 24-пиксельной цели стоит дорого, поэтому перед
//    отменой спрашиваем подтверждение.
// 3. СИНЯЯ ВСПЫШКА ПРИ НАЖАТИИ. Android подсвечивает нажатую цель
//    полупрозрачным синим (-webkit-tap-highlight-color) и оставляет синий
//    фокус-контур после тапа. Мост гасил это лишь для своих кнопок (три
//    правила в mobile-styles.js). Здесь — для всего интерфейса: подсветка
//    убирается, вместо неё короткое затемнение (`:active`), а контур фокуса
//    остаётся для клавиатуры (`:focus-visible`) — он нужен для доступности.
//
// Запись через unlink: файлы плагина — хардлинки в pnpm-store.
// После этого bridge-rebuild-client.sh пересобирает client/client.js.
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2] || '.';
const MARK = 'dsh-bridge-en: mobile ux';

const CSS = `

/* ${MARK} — окно вопросов и подсветка нажатий на телефоне */
@media (max-width: 768px) {
  /* Рамка карточки вопроса растягивается на всё сиденье композера (на телефоне
     это вся высота экрана) и перехватывает касания: переписка под ней не
     прокручивается и не нажимается — даже когда карточка свёрнута в полоску.
     Гасим события на рамке и на сиденье, возвращаем их самой карточке. */
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
    /* Размер по экрану: на высоком телефоне больше места под варианты, на
       низком карточка не съедает переписку. */
    max-height: clamp(260px, 58vh, 620px) !important;
  }
  /* Свёрнутое состояние: тела нет — оставляем узкую полосу с одной строкой
     заголовка, чтобы переписка была видна целиком. */
  [data-question-key] > section:not(:has([data-question-scroll])) {
    max-height: none !important;
  }
  [data-question-key] > section:not(:has([data-question-scroll])) h2 {
    display: -webkit-box !important;
    -webkit-line-clamp: 1 !important;
    -webkit-box-orient: vertical !important;
    overflow: hidden !important;
  }
  /* Цели нажатия в шапке карточки: 24px мало для пальца. */
  [data-question-key] > section > header button {
    min-width: 40px !important;
    min-height: 40px !important;
  }
  /* Подсветка нажатий: убрать синюю вспышку и синий контур после тапа,
     оставив контур для управления с клавиатуры. */
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
  // ${MARK}: крестик окна вопросов зовёт pending.cancel() — модель получает
  // отмену и продолжает ход без ответа. На телефоне промах по маленькой цели
  // стоит слишком дорого, поэтому спрашиваем подтверждение. Свернуть карточку
  // (соседняя кнопка) подтверждения не требует: это чисто визуальное действие.
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
      if (!/dismiss|cancel|отмен|закр/i.test(label)) return;
      if (target.dataset.dshCancelConfirmed === '1') { delete target.dataset.dshCancelConfirmed; return; }
      event.preventDefault();
      event.stopPropagation();
      const ok = window.confirm('Закрыть вопрос? Модель получит отмену и продолжит без вашего ответа.\\n\\nЧтобы просто убрать окно и почитать переписку, нажмите «Отмена», а затем стрелку рядом с крестиком — она сворачивает карточку.');
      if (ok) { target.dataset.dshCancelConfirmed = '1'; target.click(); }
    }, true);
  })();
`;

// --- CSS в mobile-styles.js -------------------------------------------------
const stylesPath = join(dir, 'client/mobile-styles.js');
if (!existsSync(stylesPath)) { console.error(`нет ${stylesPath}`); process.exit(1); }
let styles = readFileSync(stylesPath, 'utf8');
if (styles.includes(MARK)) {
  console.log('bridge: mobile ux — CSS уже на месте');
} else {
  const at = styles.lastIndexOf('`');
  if (at === -1) { console.error('не нашёл конец шаблонной строки MOBILE_STYLES_CSS'); process.exit(1); }
  styles = styles.slice(0, at) + CSS + styles.slice(at);
  rmSync(stylesPath, { force: true });
  writeFileSync(stylesPath, styles);
  console.log('bridge: mobile ux — CSS добавлен');
}

// --- JS-страж в client/index.js --------------------------------------------
const indexPath = join(dir, 'client/index.js');
if (!existsSync(indexPath)) { console.error(`нет ${indexPath}`); process.exit(1); }
let index = readFileSync(indexPath, 'utf8');
if (index.includes('__dshQuestionCancelGuard')) {
  console.log('bridge: mobile ux — страж отмены уже на месте');
  process.exit(0);
}
const ANCHOR = 'function setupMobileExperience(rpcCall, ctx) {\n  if (typeof document === \'undefined\' || typeof window === \'undefined\') return;\n  injectMobileStyles();\n';
const n = index.split(ANCHOR).length - 1;
if (n !== 1) { console.error(`MATCH COUNT ${n} для якоря setupMobileExperience`); process.exit(1); }
index = index.replace(ANCHOR, ANCHOR + GUARD);
rmSync(indexPath, { force: true });
writeFileSync(indexPath, index);
console.log('bridge: mobile ux — страж отмены добавлен');
