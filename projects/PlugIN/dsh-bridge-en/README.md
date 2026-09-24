# dsh-bridge - English UI

The `@wenbin_wb/dsh-bridge` plugin translated from Chinese into English.

* Live plugin: `~/.dsh/profiles/web/node_modules/@wenbin_wb/dsh-bridge` (already translated).
* `tools/` - the toolchain: `extract.mjs` (collects strings through the acorn parser),
  `apply.mjs` (replaces them from the `tr-*.json` / `frag-*.json` maps), `postfix.mjs`
  (bilingual matchers for the host UI).
* `translate.sh [dir]` - re-apply the translation, for example after the plugin is updated.
  The maps are keyed by the Chinese text, so on a new version everything unchanged is
  translated again. **New strings** are sent to the local model (llama-server,
  `DSH_LLAMA_BASE_URL`) through `tools/auto-translate.mjs`, which checks placeholders and the
  absence of Chinese characters and stores the result in `tools/tr-auto.json`. Matcher strings
  (`includes`, `===`, object keys, CSS selectors) are never auto-translated - they go into
  `tools/review.json` for a human. `NO_AUTO=1 ./translate.sh` disables the model call.
* After every plugin update: `./translate.sh`, then restart DSH.

## Deliberately left in Chinese
* Code and CSS comments (`client/mobile-styles.js`) - invisible to the user.
* `lib/feishu/lark-bundled.mjs` - a bundled SDK.
* Matchers for the DSH host UI aria-labels - kept and **extended with the English**
  equivalents from the host locales, since with `locale: en` they did not match at all.
* The network adapter name in `lib/index.js` - recognising it on a Chinese Windows.
* `README.md`, `CHANGELOG.md` and `releaseNotes` in package.json - `README.en.md` exists.

## Client-server pairs
Server error messages that make the client show the unlock dialog are translated consistently:
`admin privileges required`, `password to unlock`, `local-machine admin only`
(`lib/bridge-rpc.js`, `lib/auth/manager.js` <-> `client/index.js`).

## Patch: better-sidebar on mobile (`tools/patch-sidebar.mjs`)
The bridge's mobile CSS hides better-sidebar's toggle (`div[class*="toggleCluster"]`) and shows
the panel only when `body.dsh-workbench-open` is set, which happened on some clicks only - hence
"there is no button" and "files open every other time". The patch:
* adds a "Toggle sidebar" button to the mobile header, which programmatically presses the hidden
  better-sidebar toggle;
* syncs `dsh-workbench-open` with the panel's real state through a MutationObserver, so opening a
  file from the chat or by the agent always shows the panel;
* closes the panel through the real toggle rather than by removing the class by hand (React put
  the panel back otherwise).
Applied automatically from `translate.sh`; idempotent. A `MATCH COUNT 0` after a bridge update
means the author changed that code and the patch has to be re-anchored.

## Patch: native folder picker plus admin lock (`tools/patch-picker.mjs`, `tools/picker-gate.js`)
On a phone the bridge replaced the workspace picker with its own modal (a click interception plus
a registration in the host's `directoryFlow` slot with `priority: -10`). The patch disables both
paths (`USE_NATIVE_PICKER = true`), so the phone opens the native DSH dialog ("Select Workspace
Directory": New folder, Show hidden files, edit path). Before opening, `picker-gate.js` checks the
bridge's admin access (`listRemoteDirectories` with adminToken): if the server requires a password
it shows an "Admin password required" dialog and lets the click through only after `unlockAdmin`.
The unlock session is the same one the bridge panel uses ("Lock the admin panel again" ends it).
To bring the bridge modal back: `USE_NATIVE_PICKER = false` -> `translate.sh` -> restart DSH.

## Headless check on a "phone"
Playwright chromium from the harness repository (`~/.cache/ms-playwright`, with `LD_LIBRARY_PATH`
pointing at a locally unpacked `libasound2`), an iPhone 13 viewport, entering through
`http://<LAN-IP>:3082/?auth=<auth.secretToken>` from `~/.dsh/dsh-bridge/config.json`. The logic is
taps on `.dsh-header-sidebar-btn`, `.dsh-header-menu-btn` and
`button[aria-label*="Add workspace"]`.
