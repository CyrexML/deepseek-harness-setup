#!/usr/bin/env bash
# client/client.js (то, что реально отдаётся браузеру) собирается из client/index.js
# ПОСЛЕДНИМ шагом translate.sh. Любой патч, применённый после сборки (например,
# переприменение patch-power.mjs после обновления плагина), оставляет бандл
# устаревшим: маркеры в index.js на месте, ensure-patches говорит «ok», а телефон
# получает старый код (2026-09-22: китайский заголовок в мобильной шапке).
# Скрипт пересобирает бандл, если он старше index.js. Тихий, если всё свежо.
set -uo pipefail
export PATH="$HOME/.local/node/bin:$PATH"
P="${1:-$HOME/.dsh/profiles/web/node_modules/@wenbin_wb/dsh-bridge}"
TOOLS="$HOME/Harness_AI/projects/PlugIN/dsh-bridge-en/tools"
OUT="$P/client/client.js"
# Источников несколько (index.js, mobile-styles.js, …) — сравниваем с самым свежим:
# patch-settings-mobile.mjs правит mobile-styles.js, и сравнение только с index.js
# пропускало бы пересборку (2026-09-22: тёмный попап питания не доехал до телефона).
SRC="$(ls -t "$P"/client/*.js 2>/dev/null | grep -v '/client\.js$' | head -1)"
[ -n "$SRC" ] || exit 0
if [ -f "$OUT" ] && [ "$OUT" -nt "$SRC" ]; then exit 0; fi
echo "bridge: новее всех — $(basename "$SRC")"
echo "bridge: client.js устарел — пересобираю"
cd "$P" || exit 1
ln -sfn "$TOOLS/node_modules" node_modules
rm -f client/client.js   # хардлинк в pnpm-store: esbuild пишет по месту
node client/build.mjs >/dev/null || { rm -f node_modules; echo "bridge: сборка client.js НЕ УДАЛАСЬ" >&2; exit 1; }
rm -f node_modules
node --check client/client.js || { echo "bridge: client.js не проходит --check" >&2; exit 1; }
echo "bridge: client.js пересобран"
