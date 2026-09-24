#!/usr/bin/env bash
# Experiment B: three runs of task 02 on a 32k working window.
set -euo pipefail
OUT="${1:-$HOME/Harness_AI/bench/results/task02}"
RUNS="${RUNS:-3}"
REPO="$HOME/Harness_AI/bench/agent-task-02/repo"
mkdir -p "$OUT"; : > "$OUT/summary.txt"
for i in $(seq 1 "$RUNS"); do
  git -C "$HOME/Harness_AI" checkout -- bench/agent-task-02/repo 2>/dev/null || true
  git -C "$HOME/Harness_AI" clean -fdq bench/agent-task-02/repo
  before=$(tr -d '\000\r' < /mnt/f/Harness_AI/run/task02.log 2>/dev/null | grep -ac "prompt eval time"); before=${before:-0}
  "$HOME/Harness_AI/scripts/bench/run-agent-task-02.sh" "$OUT/run$i.log" > "$OUT/run$i.wrapper" 2>&1 || true
  after=$(tr -d '\000\r' < /mnt/f/Harness_AI/run/task02.log 2>/dev/null | grep -ac "prompt eval time"); after=${after:-0}
  st=$(cat "$OUT/run$i.log.start" 2>/dev/null || echo 0)
  en=$(cat "$OUT/run$i.log.end" 2>/dev/null || echo 0)
  rc=$(grep -a "EXIT=" "$OUT/run$i.log" 2>/dev/null | tail -1 | sed 's/EXIT=//')
  if (cd "$REPO" && python3 -m pytest -q > "$OUT/run$i.pytest" 2>&1); then solved=yes; else solved=no; fi
  printf 'run%-2s wall=%3ss rc=%s solved=%-3s steps=%s | %s\n' \
    "$i" "$((en-st))" "$rc" "$solved" "$((after-before))" "$(tail -1 "$OUT/run$i.pytest" | tr -d '\r')" \
    | tee -a "$OUT/summary.txt"
done
echo; echo "=== RESULT ==="; cat "$OUT/summary.txt"
