#!/usr/bin/env bash
# Шаг 4: патч-слои.
#
# Плагины и харнес доработаны нашими скриптами: без них половина того, ради
# чего стенд собирался, не работает (см. таблицу в README). Каждый слой
# идемпотентен и узнаётся по маркеру в файле, поэтому ensure-patches.sh можно
# звать сколько угодно раз — он трогает только то, чего нет. Этот же скрипт
# зовётся при каждом старте стенда: обновление плагина стирает правки.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

STAND="${STAND_DIR:-$HOME/Harness_AI}"

step "перенос инструментов стенда в $STAND"
mkdir -p "$STAND"
for dir in scripts projects/PlugIN presets templates; do
  [ -d "$ROOT/$dir" ] || continue
  mkdir -p "$STAND/$(dirname "$dir")"
  cp -r "$ROOT/$dir" "$STAND/$(dirname "$dir")/"
  ok "$dir"
done
chmod +x "$STAND"/scripts/*.sh 2>/dev/null || true

step "применение патч-слоёв"
# Мосту (bridge) при недостающих строках перевода нужна живая модель; если её
# нет, translate.sh честно скажет об этом и оставит непереведённое.
bash "$STAND/scripts/ensure-patches.sh" 2>&1 | sed 's/^/    /'

step "проверка"
if bash "$STAND/scripts/ensure-patches.sh" --check >/tmp/patch-check.log 2>&1; then
  ok "все слои на месте"
else
  warn "часть слоёв не легла:"; sed 's/^/    /' /tmp/patch-check.log >&2
  die "патчи не применились полностью — стенд поднимать нельзя"
fi

done_step "патчи готовы"
