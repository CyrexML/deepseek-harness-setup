#!/usr/bin/env bash
# Re-apply the English translation to an installed @wenbin_wb/dsh-bridge (e.g. after `npm update`).
# Usage: ./translate.sh [plugin_dir]   (default: ~/.dsh/profiles/web/node_modules/@wenbin_wb/dsh-bridge)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="${1:-$HOME/.dsh/profiles/web/node_modules/@wenbin_wb/dsh-bridge}"
[ -d "$HERE/tools/node_modules" ] || (cd "$HERE/tools" && npm install --silent)
cd "$PLUGIN"
# Run ONCE per pristine install. A second pass over already-processed files is not safe: apply.mjs
# + postfix.mjs re-touch text that the later patch scripts key on, so their "already present"
# checks miss and edits get duplicated (seen 2026-09-14: duplicate `const sidebarToggleBtn`).
# To redo, reinstall the pristine package (pnpm add @wenbin_wb/dsh-bridge@<ver>) and run again.
if grep -q "dsh-bridge-en: better-sidebar mobile fix" client/index.js 2>/dev/null && [ -z "${FORCE:-}" ]; then
  echo "ABORT: $PLUGIN already processed by this toolchain; reinstall the pristine package first (or FORCE=1)."; exit 2
fi
FILES=$(find client lib -name "*.js" -o -name "*.mjs" | grep -v "lark-bundled\|client/client.js\|build.mjs" | sort)
node "$HERE/tools/apply.mjs" . $FILES
# anything the curated maps did not cover -> local LLM (llama-server), then apply again
if [ -s "$HERE/tools/todo.json" ] && [ "$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).length)' "$HERE/tools/todo.json")" != "0" ] && [ -z "${NO_AUTO:-}" ]; then
  if node "$HERE/tools/auto-translate.mjs"; then node "$HERE/tools/apply.mjs" . $FILES
  else echo "WARN: auto-translate failed (is llama-server running?) — untranslated strings listed in tools/todo.json"; fi
fi
node "$HERE/tools/postfix.mjs" client/index.js
node "$HERE/tools/patch-sidebar.mjs" .   # better-sidebar toggle/panel fix for mobile
node "$HERE/tools/patch-picker.mjs" .    # host directory picker instead of bridge modal (toggle inside)
node "$HERE/tools/patch-theme.mjs" .       # per-device Appearance memory on remote pages (host persists loopback only)
node "$HERE/tools/patch-rotation.mjs" .  # PWA orientation follows system lock; drawer dropped on rotation
node "$HERE/tools/patch-splash.mjs" .    # dark DeepSeek-toned splash until the client mounts
node "$HERE/tools/patch-preview.mjs" .    # user files via /sidebar/html|file: no head injection, cache-control no-store
node "$HERE/tools/patch-hashes.mjs" .     # remap stale css-module hashes of the host build at runtime
node "$HERE/tools/patch-icon.mjs" .       # DSH whale as PWA/home-screen/apple-touch icon (assets from tools/gen-icon.mjs)
node "$HERE/tools/patch-power.mjs" .      # Power card in Remote access: stop DSH / DSH+WSL via launcher signal file
node "$HERE/tools/patch-settings-mobile.mjs" . # settings nav/plugin-hub overflow on phones; dark power popover
node "$HERE/tools/patch-zoom-scope.mjs" . # щипок: выключен в чате, включён в боковой панели
node "$HERE/tools/patch-header-sidebar-btn.mjs" . # убрать нашу кнопку сайдбара: в 0.1.6 есть родная
node "$HERE/tools/patch-mobile-ux.mjs" . # окно вопросов и подсветка нажатий на телефоне
node "$HERE/tools/patch-preview-zoom.mjs" . # щипок масштабирует содержимое превью, а не панель
node "$HERE/tools/patch-html-no-store.mjs" . # страница не кешируется: иначе телефон держит старый бандл
# rebuild client bundle with esbuild from tools/node_modules
ln -sfn "$HERE/tools/node_modules" node_modules
rm -f client/client.js   # store-хардлинк: esbuild пишет по месту, файл пересоздаём
node client/build.mjs
rm node_modules
for f in $FILES client/client.js; do node --check "$f"; done
echo "OK — restart DSH to load the translated plugin"
