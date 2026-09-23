# dsh-bridge — English UI (v2.10.9)

Плагин `@wenbin_wb/dsh-bridge` переведён с китайского на английский.

* Живой плагин: `~/.dsh/profiles/web/node_modules/@wenbin_wb/dsh-bridge` (уже переведён).
* `dist/` — готовая переведённая копия плагина (без `node_modules`).
* Исходный (нетронутый) плагин: `../bridge-i18n/backup/dsh-bridge-2.10.8/ (2.10.8), backup-2.10.9/ (2.10.9)`.
* `tools/` — инструментарий: `extract.mjs` (сбор строк через парсер acorn), `apply.mjs`
  (замена по картам `tr-*.json` / `frag-*.json`), `postfix.mjs` (двуязычные матчеры под хост-UI).
* `translate.sh [dir]` — повторно применить перевод (например, после `npm update` плагина).
  Карты привязаны к китайскому тексту, поэтому на новой версии переведётся всё, что не изменилось.
  **Новые строки** скрипт сам отправляет локальной Qwen (llama-server, `DSH_LLAMA_BASE_URL` или
  `http://<шлюз WSL>:8080/v1`) через `tools/auto-translate.mjs`, проверяет плейсхолдеры и
  отсутствие иероглифов и сохраняет в `tools/tr-auto.json`. Строки-матчеры (`includes`, `===`,
  ключи объектов, CSS-селекторы) в автоперевод не идут — они попадают в `tools/review.json`
  на ручную проверку. `NO_AUTO=1 ./translate.sh` — отключить обращение к модели.
* После каждого обновления плагина: `./translate.sh`, затем перезапустить DSH.

## Что намеренно оставлено по-китайски
* Комментарии в коде и CSS-комментарии (`client/mobile-styles.js`) — пользователю не видны.
* `lib/feishu/lark-bundled.mjs` — бандл SDK Lark.
* Матчеры под aria-label хостового UI DSH (`新建会话`, `添加工作区`, `收起侧边栏` …) — оставлены
  и **дополнены английскими** эквивалентами из локалей хоста (`New session`, `Add workspace`,
  `Collapse sidebar` …). Раньше при `locale: en` они не срабатывали вовсе.
* `以太网` в `lib/index.js` — распознавание имени сетевого адаптера на китайской Windows.
* `README.md`, `CHANGELOG.md`, `releaseNotes` в package.json — есть `README.en.md`.

## Связки клиент ↔ сервер
Сообщения об ошибках сервера, по которым клиент решает показать окно разблокировки, переведены
согласованно: `admin privileges required`, `password to unlock`, `local-machine admin only`
(`lib/bridge-rpc.js`, `lib/auth/manager.js` ↔ `client/index.js`).

## Патч: better-sidebar в мобильной версии (`tools/patch-sidebar.mjs`)
Мобильный CSS dsh-bridge прячет кнопку-тоггл better-sidebar (`div[class*="toggleCluster"]`) и показывает
панель только при `body.dsh-workbench-open`, который ставился лишь по некоторым кликам — отсюда
«нет кнопки» и «файлы открываются через раз». Патч:
* добавляет в мобильную шапку кнопку «Toggle sidebar» (между заголовком и «+»), она программно
  нажимает скрытый тоггл better-sidebar;
* синхронизирует `dsh-workbench-open` с реальным состоянием панели через MutationObserver —
  открытие файла из чата/агентом всегда показывает панель;
* закрытие панели (заголовок, «+», «Back to chat», смена сессии) идёт через настоящий тоггл,
  а не через ручное добавление класса (иначе React возвращал панель).
Применяется автоматически из `translate.sh`; идемпотентен. Если после обновления bridge
он напишет `MATCH COUNT 0` — значит автор изменил этот код, патч надо переложить.

## Патч: родной выбор папки + админ-замок (`tools/patch-picker.mjs`, `tools/picker-gate.js`)
На телефоне bridge подменял диалог выбора workspace своей модалкой (перехват клика + регистрация в слоте
хоста `directoryFlow` с `priority: -10`). Патч отключает оба пути (`USE_NATIVE_PICKER = true`), и с телефона
открывается родной диалог DSH («Select Workspace Directory»: New folder, Show hidden files, edit path).
Перед открытием `picker-gate.js` проверяет админ-доступ bridge (`listRemoteDirectories` с adminToken):
если сервер требует пароль — показывает окно «Admin password required» и пропускает клик только после
`unlockAdmin`. Сессия разблокировки та же, что у панели bridge («Lock the admin panel again» закрывает).
Вернуть модалку bridge: `USE_NATIVE_PICKER = false` → `translate.sh` → перезапуск DSH.

## Headless-проверка на «телефоне»
Playwright chromium из репозитория harness (`~/.cache/ms-playwright`, `LD_LIBRARY_PATH` на локально
распакованный `libasound2`), вьюпорт iPhone 13, вход через `http://<LAN-IP>:3082/?auth=<auth.secretToken>`
из `~/.dsh/dsh-bridge/config.json`. Скрипты-примеры остались в scratchpad сессии; логика — tap по
`.dsh-header-sidebar-btn`, `.dsh-header-menu-btn`, `button[aria-label*="Add workspace"]`.
