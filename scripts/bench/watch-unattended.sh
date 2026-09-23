#!/usr/bin/env bash
# Сводка по ночному прогону. Читает только файлы, ничего не запускает и не
# трогает — можно звать в любой момент, в том числе пока драйвер работает.
#
#   watch-unattended.sh <каталог> [-f]
#
# -f — обновлять каждые 30 с, пока не появится .unattended/result.
set -uo pipefail

REPO="${1:?укажите каталог проекта}"
FOLLOW="${2:-}"
RUNDIR="$REPO/.unattended"

show() {
  [ -d "$RUNDIR" ] || { echo "прогон не начинался: нет $RUNDIR"; return; }
  echo "=== $REPO — $(date +%H:%M:%S) ==="

  H="http://$(ip route show default | awk '{print $3}'):8080/v1"
  if curl -sf --max-time 5 "$H/models" >/dev/null; then echo "llama-server: жив"
  else echo "llama-server: НЕ ОТВЕЧАЕТ"; fi

  if [ -s "$RUNDIR/status.tsv" ]; then
    echo
    printf '%-4s %-9s %-8s %-9s %s\n' "итер" "длит." "сессия" "критерий" "время"
    while IFS=$'\t' read -r i ts rc gate dur; do
      printf '%-4s %-9s %-8s %-9s %s\n' "$i" "${dur:--}" "$rc" "$gate" "$(date -d @"$ts" +%H:%M:%S 2>/dev/null)"
    done < "$RUNDIR/status.tsv"
    echo
    echo "итераций: $(wc -l < "$RUNDIR/status.tsv")"
  fi

  # Последняя причина остановки сессии — она же самая частая непонятная вещь.
  LAST="$(ls -1 "$RUNDIR"/iter-*.log 2>/dev/null | tail -1)"
  if [ -n "$LAST" ]; then
    echo
    echo "--- хвост $(basename "$LAST") ---"
    tail -6 "$LAST"
    if grep -qi "max-tokens\|CONTEXT_WINDOW_EXCEEDED" "$LAST"; then
      echo "  ! в этой итерации был обрыв по лимиту — это ожидаемо, драйвер начнёт заново"
    fi
  fi

  # Детектор дегенеративной петли. Хвост лога при зацикливании выглядит
  # осмысленным абзацем, поэтому глазами это не ловится — нужна доля
  # повторяющихся строк в конце. Замерено: сессия может так идти часами,
  # не упираясь ни в max-tokens, ни в окно.
  if [ -n "$LAST" ]; then
    rep=$(tail -c 20000 "$LAST" | tr -s ' ' | grep -vE '^\s*$' | sort | uniq -c | sort -rn | head -1)
    cnt=$(echo "$rep" | awk '{print $1}')
    tot=$(tail -c 20000 "$LAST" | tr -s ' ' | grep -cvE '^\s*$')
    if [ "${cnt:-0}" -ge 5 ] && [ "${tot:-1}" -gt 0 ]; then
      pct=$(( cnt * 100 / tot ))
      echo
      echo "  !! ПЕТЛЯ: одна строка повторена $cnt раз (${pct}% хвоста)"
      echo "     $(echo "$rep" | cut -c1-100 | sed 's/^ *[0-9]* //')"
      echo "     лечится сэмплером (--dry-multiplier), а не промптом"
    fi
  fi

  LASTG="$(ls -1 "$RUNDIR"/gate-*.log 2>/dev/null | tail -1)"
  if [ -n "$LASTG" ]; then
    echo
    echo "--- критерий, $(basename "$LASTG") ---"
    grep -E "^# (tests|pass|fail)|^not ok|PASS|FAIL" "$LASTG" | tail -8 || tail -4 "$LASTG"
  fi

  if [ -f "$RUNDIR/result" ]; then echo; echo "ИТОГ: $(cat "$RUNDIR/result")"; fi
}

if [ "$FOLLOW" = "-f" ]; then
  while true; do
    clear 2>/dev/null || true
    show
    [ -f "$RUNDIR/result" ] && break
    sleep 30
  done
else
  show
fi
