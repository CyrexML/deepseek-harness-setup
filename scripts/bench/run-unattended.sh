#!/usr/bin/env bash
# Ночной прогон: короткие сессии под внешним драйвером.
#
# ЗАЧЕМ ИМЕННО ТАК. Агент не может сам перейти в новый чат, когда контекст
# кончается. Поэтому долго живёт не сессия, а ЭТОТ цикл: каждая итерация —
# отдельный процесс `dsh --profile headless` с чистым контекстом, а сквозной
# памятью служит рабочий каталог (docs/bench-04 §5). Любой отказ внутри
# (max-tokens, переполнение окна, падение llama-server) завершает процесс,
# драйвер видит код возврата и запускает следующую итерацию заново.
#
# Почему не `ralph`: его раунды тоже свежие, но «an ordinary child failure
# returns an error naming the failed round» — один упавший раунд убивает весь
# цикл. При нашей истории с max-tokens это отказ на первой тяжёлой отладке.
#
# ГЛАВНОЕ: условие остановки проверяет ДРАЙВЕР, а не модель. Заявление агента
# «готово» — это его отчёт, а не сертификация. Здесь готовность = GATE вернул 0.
#
#   run-unattended.sh <каталог> <файл-с-задачей> [итераций]
#
# Переменные: GATE (команда-критерий), STALL (сколько итераций без изменений
# в дереве считать застреванием), DSH_BIN, DSH_PATCH.
set -uo pipefail

REPO="${1:?укажите каталог проекта}"
TASKFILE="${2:?укажите файл с текстом задачи}"
MAX_ITER="${3:-20}"

GATE="${GATE:-node --test 'test/*.test.js'}"
# Потолок на одну итерацию. Найден замером: сессия может уйти в дегенеративную
# петлю (дословный повтор абзаца) и генерировать часами, НЕ упираясь ни в
# max-tokens, ни в окно. Без потолка ночной прогон встаёт на первой такой.
ITER_TIMEOUT="${ITER_TIMEOUT:-600}"
STALL="${STALL:-3}"
DSH_BIN="${DSH_BIN:-$HOME/tools/deepseek-harness/apps/cli/lib/bin.js}"
DSH_PATCH="${DSH_PATCH:-$HOME/Harness_AI/run/headless-local.yml}"

[ -d "$REPO" ] || { echo "нет каталога: $REPO" >&2; exit 1; }
[ -f "$TASKFILE" ] || { echo "нет файла задачи: $TASKFILE" >&2; exit 1; }
REPO="$(cd "$REPO" && pwd -P)"
TASK="$(cat "$TASKFILE")"

RUNDIR="$REPO/.unattended"
mkdir -p "$RUNDIR"
STATUS="$RUNDIR/status.tsv"
: > "$STATUS"

export PATH="$HOME/.local/node/bin:$PATH"
export DSH_LLAMA_KEY="local-no-auth"

# Слепок дерева — для обнаружения застревания. Служебный каталог исключён,
# иначе собственные логи выглядели бы как прогресс.
tree_hash() {
  find "$REPO" -type f -not -path "$RUNDIR/*" -not -path "*/.git/*" \
    -printf '%p %s %T@\n' 2>/dev/null | sort | md5sum | cut -d' ' -f1
}

say() { echo "[$(date +%H:%M:%S)] $*"; }

prev_hash=""
stall_count=0
started=$(date +%s)

for i in $(seq 1 "$MAX_ITER"); do
  # llama-server проверяем ПЕРВЫМ делом каждую итерацию: он умеет завершаться
  # молча, лог обрывается чисто на `all slots are idle` (getting-started §5).
  # Адрес резолвим заново — шлюз WSL меняется при перезапуске. Но если он
  # задан снаружи, НЕ трогаем: bench-10 пускает трафик через перехватывающий
  # прокси, и безусловная перезапись молча увела бы прогон мимо него —
  # дампы вышли бы пустыми, а слепота детектора осталась бы незамеченной.
  if [ -z "${DSH_LLAMA_BASE_URL:-}" ]; then
    export DSH_LLAMA_BASE_URL="http://$(ip route show default | awk '{print $3}'):8080/v1"
  fi
  if ! curl -sf --max-time 10 "$DSH_LLAMA_BASE_URL/models" > /dev/null; then
    say "итерация $i: llama-server не отвечает, жду 60 с"
    printf '%s\t%s\tno-server\t-\t-\n' "$i" "$(date +%s)" >> "$STATUS"
    sleep 60
    continue
  fi

  say "итерация $i из $MAX_ITER"
  LOG="$RUNDIR/iter-$(printf '%02d' "$i").log"
  # Строку пишем СРАЗУ: пока итерация идёт, монитору иначе нечего показать —
  # ровно в тот момент, когда смотреть нужнее всего.
  printf '%s\t%s\tидёт\t-\t-\n' "$i" "$(date +%s)" >> "$STATUS"
  t0=$(date +%s)
  ( cd "$REPO" && timeout --signal=TERM --kill-after=30 "$ITER_TIMEOUT" \
      node "$DSH_BIN" --profile headless --patch "$DSH_PATCH" "$TASK" ) > "$LOG" 2>&1
  rc=$?
  t1=$(date +%s)
  # 124 — сработал timeout. Отличаем от обычного отказа: это почти всегда петля.
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    say "  ОБОРВАНА по таймауту ${ITER_TIMEOUT}с — вероятна петля повторов"
  fi
  # Убираем строку «идёт», её заменит итоговая.
  awk -F'\t' -v it="$i" '!($1==it && $3=="идёт")' "$STATUS" > "$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"

  # Критерий — наш, не модели.
  gate_out="$RUNDIR/gate-$(printf '%02d' "$i").log"
  ( cd "$REPO" && eval "$GATE" ) > "$gate_out" 2>&1
  gate_rc=$?

  printf '%s\t%s\trc=%s\tgate=%s\t%ss\n' "$i" "$(date +%s)" "$rc" "$gate_rc" "$((t1-t0))" >> "$STATUS"
  say "  сессия rc=$rc, критерий rc=$gate_rc, $((t1-t0)) с"

  if [ "$gate_rc" -eq 0 ]; then
    say "ГОТОВО на итерации $i, всего $(( ($(date +%s)-started)/60 )) мин"
    echo "done $i" > "$RUNDIR/result"
    exit 0
  fi

  # Застревание: дерево не менялось несколько итераций подряд. Без этого цикл
  # честно выжжет все итерации, повторяя один и тот же неудачный ход.
  h="$(tree_hash)"
  if [ "$h" = "$prev_hash" ]; then
    stall_count=$((stall_count+1))
    say "  без изменений в дереве ($stall_count из $STALL)"
    if [ "$stall_count" -ge "$STALL" ]; then
      say "ОСТАНОВ: $STALL итераций подряд без единого изменения"
      echo "stalled $i" > "$RUNDIR/result"
      exit 2
    fi
  else
    stall_count=0
  fi
  prev_hash="$h"
done

say "ОСТАНОВ: исчерпаны $MAX_ITER итераций, критерий не выполнен"
echo "budget $MAX_ITER" > "$RUNDIR/result"
exit 3
