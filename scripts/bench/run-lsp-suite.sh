#!/usr/bin/env bash
# Three runs of task 02 with LSP enabled. Steps and peak context are counted per
# segment from the server log marks.
set -euo pipefail
OUT="${1:-$HOME/Harness_AI/bench/results/lsp}"
RUNS="${RUNS:-3}"
REPO="$HOME/Harness_AI/bench/agent-task-02/repo"
SRVLOG=/mnt/f/Harness_AI/run/server-A.log
mkdir -p "$OUT"; : > "$OUT/summary.txt"
for i in $(seq 1 "$RUNS"); do
  git -C "$HOME/Harness_AI" checkout -- bench/agent-task-02/repo 2>/dev/null || true
  git -C "$HOME/Harness_AI" clean -fdq bench/agent-task-02/repo
  mark=$(( $(tr -d '\000\r' < "$SRVLOG" | wc -l) + 1 ))
  "$HOME/Harness_AI/scripts/bench/run-agent-task-02.sh" "$OUT/run$i.log" > "$OUT/run$i.wrapper" 2>&1 || true
  seg=$(tr -d '\000\r' < "$SRVLOG" | tail -n +"$mark")
  steps=$(printf '%s\n' "$seg" | grep -ac "prompt eval time" || true)
  ctx=$(printf '%s\n' "$seg" | grep -aoE "cached n_tokens = [0-9]+" | grep -oE "[0-9]+" | sort -n | tail -1 || true)
  lsp=$(grep -aoci "lsp" "$OUT/run$i.log" || true)
  st=$(cat "$OUT/run$i.log.start" 2>/dev/null || echo 0)
  en=$(cat "$OUT/run$i.log.end" 2>/dev/null || echo 0)
  rc=$(grep -a "EXIT=" "$OUT/run$i.log" 2>/dev/null | tail -1 | sed 's/EXIT=//')
  if (cd "$REPO" && python3 -m pytest -q > "$OUT/run$i.pytest" 2>&1); then solved=ДА; else solved=НЕТ; fi
  printf 'run%-2s wall=%4ss steps=%-3s context=%-6s lsp=%-3s rc=%s solved=%-3s | %s\n' \
    "$i" "$((en-st))" "${steps:-0}" "${ctx:-0}" "${lsp:-0}" "$rc" "$solved" \
    "$(tail -1 "$OUT/run$i.pytest" | tr -d '\r')" | tee -a "$OUT/summary.txt"
done
echo; echo "=== ИТОГ ==="; cat "$OUT/summary.txt"
