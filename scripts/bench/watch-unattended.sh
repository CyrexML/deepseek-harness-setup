#!/usr/bin/env bash
# Summary of an unattended run. Reads files only, starts and changes nothing, so
# it can be called at any time, including while the driver is working.
#
#   watch-unattended.sh <directory> [-f]
#
# -f refreshes every 30 s until .unattended/result appears.
set -uo pipefail

REPO="${1:?give the project directory}"
FOLLOW="${2:-}"
RUNDIR="$REPO/.unattended"

show() {
  [ -d "$RUNDIR" ] || { echo "no run started: no $RUNDIR"; return; }
  echo "=== $REPO — $(date +%H:%M:%S) ==="

  H="http://$(ip route show default | awk '{print $3}'):8080/v1"
  if curl -sf --max-time 5 "$H/models" >/dev/null; then echo "llama-server: alive"
  else echo "llama-server: НЕ ОТВЕЧАЕТ"; fi

  if [ -s "$RUNDIR/status.tsv" ]; then
    echo
    printf '%-4s %-9s %-8s %-9s %s\n' "iter" "dur" "session" "gate" "time"
    while IFS=$'\t' read -r i ts rc gate dur; do
      printf '%-4s %-9s %-8s %-9s %s\n' "$i" "${dur:--}" "$rc" "$gate" "$(date -d @"$ts" +%H:%M:%S 2>/dev/null)"
    done < "$RUNDIR/status.tsv"
    echo
    echo "iterations: $(wc -l < "$RUNDIR/status.tsv")"
  fi

  # The last reason a session stopped - the most frequently puzzling thing.
  LAST="$(ls -1 "$RUNDIR"/iter-*.log 2>/dev/null | tail -1)"
  if [ -n "$LAST" ]; then
    echo
    echo "--- tail of $(basename "$LAST") ---"
    tail -6 "$LAST"
    if grep -qi "max-tokens\|CONTEXT_WINDOW_EXCEEDED" "$LAST"; then
      echo "  ! this iteration hit a limit - expected, the driver starts again"
    fi
  fi

  # Degenerate-loop detector. When looping, the tail of the log still reads like a
  # sensible paragraph, so the eye does not catch it - what does is the share of
  # repeated lines at the end. A session can run like that for hours without
  # hitting max-tokens or the window.
  if [ -n "$LAST" ]; then
    rep=$(tail -c 20000 "$LAST" | tr -s ' ' | grep -vE '^\s*$' | sort | uniq -c | sort -rn | head -1)
    cnt=$(echo "$rep" | awk '{print $1}')
    tot=$(tail -c 20000 "$LAST" | tr -s ' ' | grep -cvE '^\s*$')
    if [ "${cnt:-0}" -ge 5 ] && [ "${tot:-1}" -gt 0 ]; then
      pct=$(( cnt * 100 / tot ))
      echo
      echo "  !! LOOP: one line repeated $cnt times (${pct}% of the tail)"
      echo "     $(echo "$rep" | cut -c1-100 | sed 's/^ *[0-9]* //')"
      echo "     the cure is the sampler (--dry-multiplier), not the prompt"
    fi
  fi

  LASTG="$(ls -1 "$RUNDIR"/gate-*.log 2>/dev/null | tail -1)"
  if [ -n "$LASTG" ]; then
    echo
    echo "--- criterion, $(basename "$LASTG") ---"
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
