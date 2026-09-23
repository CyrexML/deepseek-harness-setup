#!/usr/bin/env bash
# Самопроверка восьми патч-слоёв стенда перед стартом DSH (вызывается из
# start-web.sh; можно и руками: ensure-patches.sh [--check]).
#
# Зачем: обновление плагина (Plugin Hub → Update = `pnpm add <pkg>@latest`,
# routes.ts:878) или `pnpm build` харнеса молча стирают правки. Здесь каждый
# слой узнаётся по маркеру, отсутствующий переприменяется своим тулчейном
# (все идемпотентны), результат — одной строкой на слой. Ничего не делает,
# если маркеры на месте. --check: только доложить, код возврата 1 при пропуске.
#
# Слои и маркеры:
#   bridge        client/index.js   "dsh-bridge-en:"            projects/PlugIN/dsh-bridge-en/translate.sh
#   turn-rewind   lib/client.js     "/* dsh-turn-rewind-en */"  projects/PlugIN/dsh-turn-rewind-en/translate.mjs
#   better-sidebar lib/index.js     "DSH_PREVIEW_TRUSTED_ROOTS"  scripts/patch-sidebar.sh (decision-14)
#   llm-pi-ai     lib/index.js      "dsh-local: replay usage"   scripts/patch-llm-pi-ai-usage.mjs
#   graph-memory  dist/dsh.js       "dsh-local: workspace-scoped recall"  scripts/patch-graph-memory-scope.mjs
#   ui-conversation lib/client.js   "dsh-local: eager image read"   scripts/patch-ui-conversation-eager-read.mjs (харнес, не профиль)
#   sidebar-slot-id  lib/client.js   "dsh-local: turnTail slot id"  scripts/patch-better-sidebar-slot-id.mjs (совместимость с DSH 0.1.6+)
#   univer-slot-id   lib/client.js   "dsh-local: turnTail slot id"  scripts/patch-univer-slot-id.mjs (то же)
#   sidebar-session-sync lib/client.js "dsh-local: session sync" scripts/patch-better-sidebar-session-sync.mjs (клик по файлу на 0.1.6)
#   sidebar-binary-handoff lib/client.js "dsh-local: binary handoff" scripts/patch-better-sidebar-binary-handoff.mjs (pdf/офис — родным просмотрщикам)
#
# translate.sh bridge при недостающих строках зовёт локальную модель
# (auto-translate) — поэтому start-web.sh вызывает нас ПОСЛЕ проверки, что
# llama-server отвечает. Если модель недоступна, translate.sh сам предупредит
# и оставит непереведённое в tools/todo.json.
set -uo pipefail
export PATH="$HOME/.local/node/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
NM="$HOME/.dsh/profiles/web/node_modules"
DSH_ROOT="${DSH_ROOT:-$HOME/tools/deepseek-harness}"
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
missing=0

# layer <имя> <файл> <маркер> <команда...>
layer() {
  local name="$1" file="$2" mark="$3"; shift 3
  if [ ! -f "$file" ]; then echo "patches: $name — файла нет ($file), пропуск"; return; fi
  if grep -qF -- "$mark" "$file"; then echo "patches: $name — ok"; return; fi
  if [ "$CHECK" = 1 ]; then echo "patches: $name — НЕТ ПАТЧА"; missing=1; return; fi
  echo "patches: $name — патч не найден, применяю: $*"
  if "$@" >"/tmp/ensure-$name.log" 2>&1 && grep -qF -- "$mark" "$file"; then
    echo "patches: $name — применён"
  else
    echo "patches: $name — НЕ УДАЛОСЬ, см. /tmp/ensure-$name.log"; missing=1
  fi
}

layer bridge "$NM/@wenbin_wb/dsh-bridge/client/index.js" "dsh-bridge-en:" \
  bash "$HOME/Harness_AI/projects/PlugIN/dsh-bridge-en/translate.sh"
# client.js собирается последним шагом translate.sh: если патч лёг позже сборки,
# бандл устарел, а маркер на месте (см. scripts/bridge-rebuild-client.sh).
bash "$HERE/bridge-rebuild-client.sh" "$NM/@wenbin_wb/dsh-bridge" || missing=1

layer turn-rewind "$NM/@anionex/dsh-turn-rewind/lib/client.js" "/* dsh-turn-rewind-en */" \
  node "$HOME/Harness_AI/projects/PlugIN/dsh-turn-rewind-en/translate.mjs"
layer better-sidebar "$NM/dsh-better-sidebar/lib/index.js" "DSH_PREVIEW_TRUSTED_ROOTS" \
  bash "$HERE/patch-sidebar.sh"
layer llm-pi-ai "$DSH_ROOT/packages/llm/llm-pi-ai/lib/index.js" "dsh-local: replay usage" \
  node "$HERE/patch-llm-pi-ai-usage.mjs"
layer graph-memory "$NM/graph-memory/dist/dsh.js" "dsh-local: workspace-scoped recall" \
  node "$HERE/patch-graph-memory-scope.mjs"
layer ui-conversation "$DSH_ROOT/packages/client/ui-conversation/lib/client.js" "dsh-local: eager image read" \
  node "$HERE/patch-ui-conversation-eager-read.mjs"
layer pdfjs-map-polyfill "$DSH_ROOT/packages/client/ui-sidebar-documentpreview/lib/client.pdf.js" "dsh-local: Map.getOrInsert polyfill" \
  node "$HERE/patch-pdfjs-map-polyfill.mjs"
layer zoom-scope "$NM/@wenbin_wb/dsh-bridge/client/mobile-styles.js" "dsh-bridge-en: zoom scope" \
  node "$HOME/Harness_AI/projects/PlugIN/dsh-bridge-en/tools/patch-zoom-scope.mjs" "$NM/@wenbin_wb/dsh-bridge"
layer header-sidebar-btn "$NM/@wenbin_wb/dsh-bridge/client/index.js" "dsh-bridge-en: header sidebar button removed" \
  node "$HOME/Harness_AI/projects/PlugIN/dsh-bridge-en/tools/patch-header-sidebar-btn.mjs" "$NM/@wenbin_wb/dsh-bridge"
layer mobile-ux "$NM/@wenbin_wb/dsh-bridge/client/mobile-styles.js" "dsh-bridge-en: mobile ux" \
  node "$HOME/Harness_AI/projects/PlugIN/dsh-bridge-en/tools/patch-mobile-ux.mjs" "$NM/@wenbin_wb/dsh-bridge"
layer preview-zoom "$NM/@wenbin_wb/dsh-bridge/client/mobile-styles.js" "dsh-bridge-en: preview zoom" \
  node "$HOME/Harness_AI/projects/PlugIN/dsh-bridge-en/tools/patch-preview-zoom.mjs" "$NM/@wenbin_wb/dsh-bridge"
layer html-no-store "$NM/@wenbin_wb/dsh-bridge/lib/index.js" "dsh-bridge-en: html no-store" \
  node "$HOME/Harness_AI/projects/PlugIN/dsh-bridge-en/tools/patch-html-no-store.mjs" "$NM/@wenbin_wb/dsh-bridge"

layer sidebar-slot-id "$NM/dsh-better-sidebar/lib/client.js" "dsh-local: turnTail slot id" \
  node "$HERE/patch-better-sidebar-slot-id.mjs"
layer univer-slot-id "$NM/dsh-univer-office/lib/client.js" "dsh-local: turnTail slot id" \
  node "$HERE/patch-univer-slot-id.mjs"
layer sidebar-session-sync "$NM/dsh-better-sidebar/lib/client.js" "dsh-local: session sync" \
  node "$HERE/patch-better-sidebar-session-sync.mjs"
layer sidebar-binary-handoff "$NM/dsh-better-sidebar/lib/client.js" "dsh-local: binary handoff" \
  node "$HERE/patch-better-sidebar-binary-handoff.mjs"
layer sidebar-relative-path "$NM/dsh-better-sidebar/lib/client.js" "dsh-local: relative path in chat links" \
  node "$HERE/patch-better-sidebar-relative-path.mjs"

exit $missing
