#!/usr/bin/env bash
# §3.7 decision-08: контрольные прогоны с песочницей.
# По три прогона каждой задачи. Шаги и максимум контекста считаются
# посегментно: по отметкам длины лога сервера до и после прогона.
set -euo pipefail

OUT="${1:-$HOME/Harness_AI/bench/results/sandbox-control}"
RUNS="${RUNS:-3}"
SRVLOG=/mnt/f/Harness_AI/run/server-A.log
mkdir -p "$OUT"; : > "$OUT/summary.txt"

seg_stats() {   # $1=от_строки  -> "шагов максконтекст"
  local from="$1"
  tr -d '\000\r' < "$SRVLOG" | tail -n +"$from" > /tmp/_seg.$$
  local steps ctx
  steps=$(grep -ac "prompt eval time" /tmp/_seg.$$ || true)
  ctx=$(grep -aoE "cached n_tokens = [0-9]+" /tmp/_seg.$$ | grep -oE "[0-9]+" | sort -n | tail -1 || true)
  rm -f /tmp/_seg.$$
  echo "${steps:-0} ${ctx:-0}"
}

for task in 01 02; do
  repo="$HOME/Harness_AI/bench/agent-task-$task/repo"
  for i in $(seq 1 "$RUNS"); do
    tag="t$task-$i"
    git -C "$HOME/Harness_AI" checkout -- "bench/agent-task-$task/repo" 2>/dev/null || true
    git -C "$HOME/Harness_AI" clean -fdq "bench/agent-task-$task/repo"
    docker rm -f harness-sandbox >/dev/null 2>&1 || true
    mark=$(( $(tr -d '\000\r' < "$SRVLOG" | wc -l) + 1 ))
    "$HOME/Harness_AI/scripts/bench/run-agent-task-$task.sh" "$OUT/$tag.log" > "$OUT/$tag.wrapper" 2>&1 || true
    read -r steps ctx <<< "$(seg_stats "$mark")"
    st=$(cat "$OUT/$tag.log.start" 2>/dev/null || echo 0)
    en=$(cat "$OUT/$tag.log.end" 2>/dev/null || echo 0)
    rc=$(grep -a "EXIT=" "$OUT/$tag.log" 2>/dev/null | tail -1 | sed 's/EXIT=//')
    if (cd "$repo" && python3 -m pytest -q > "$OUT/$tag.pytest" 2>&1); then solved=ДА; else solved=НЕТ; fi
    printf '%-8s wall=%4ss шагов=%-3s контекст=%-6s rc=%s решена=%-3s | %s\n' \
      "$tag" "$((en-st))" "$steps" "$ctx" "$rc" "$solved" \
      "$(tail -1 "$OUT/$tag.pytest" | tr -d '\r')" | tee -a "$OUT/summary.txt"
  done
done
echo; echo "=== ИТОГ ==="; cat "$OUT/summary.txt"
