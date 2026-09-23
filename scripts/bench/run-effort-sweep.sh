#!/usr/bin/env bash
# reasoning_effort measured on a REAL loop, not on a probe.
#
# reasoning_effort is set by the server through --chat-template-kwargs rather than
# by the dsh config, so every mode needs its own server start. pi-ai has a
# `reasoning` field on the route, but whether it reaches llama-server as
# reasoning_effort is unverified, hence the server-side path confirmed through
# /apply-template.
set -euo pipefail

OUTDIR="${1:-$HOME/Harness_AI/bench/results/effort-sweep}"
RUNS="${RUNS:-3}"
REPO="$HOME/Harness_AI/bench/agent-task-01/repo"
mkdir -p "$OUTDIR"
: > "$OUTDIR/summary.txt"

for effort in low medium xhigh; do
  echo "### server: reasoning_effort=$effort"
  ( cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass \
      -File 'F:\Harness_AI\run\stop-server.ps1' >/dev/null 2>&1 ) || true
  sleep 4
  rm -f "/mnt/f/Harness_AI/run/effort-$effort.log"
  ( cd /mnt/c && nohup powershell.exe -NoProfile -ExecutionPolicy Bypass \
      -File 'F:\Harness_AI\run\start-server.ps1' -Verbosity 4 \
      -ReasoningEffort "$effort" -Log "F:\\Harness_AI\\run\\effort-$effort.log" \
      >/dev/null 2>&1 & ) 
  until grep -qa "listening on" <(tr -d '\000\r' < "/mnt/f/Harness_AI/run/effort-$effort.log" 2>/dev/null); do sleep 4; done
  echo "    up"

  for i in $(seq 1 "$RUNS"); do
    tag="$effort-$i"
    git -C "$HOME/Harness_AI" checkout -- bench/agent-task-01/repo 2>/dev/null || true
    git -C "$HOME/Harness_AI" clean -fdq bench/agent-task-01/repo
    "$HOME/Harness_AI/scripts/bench/run-agent-task-01.sh" "$OUTDIR/$tag.log" > "$OUTDIR/$tag.wrapper" 2>&1 || true
    st=$(cat "$OUTDIR/$tag.log.start" 2>/dev/null || echo 0)
    en=$(cat "$OUTDIR/$tag.log.end" 2>/dev/null || echo 0)
    rc=$(grep -a "EXIT=" "$OUTDIR/$tag.log" 2>/dev/null | tail -1 | sed 's/EXIT=//')
    if (cd "$REPO" && python3 -m pytest -q > "$OUTDIR/$tag.pytest" 2>&1); then solved=ДА; else solved=НЕТ; fi
    steps=$(tr -d '\000\r' < "/mnt/f/Harness_AI/run/effort-$effort.log" | grep -ac "prompt eval time")
    printf '%-10s wall=%3ss rc=%s solved=%-3s steps_total=%s | %s\n' \
      "$tag" "$((en-st))" "$rc" "$solved" "$steps" "$(tail -1 "$OUTDIR/$tag.pytest" | tr -d '\r')" \
      | tee -a "$OUTDIR/summary.txt"
  done
done
echo; echo "=== ИТОГ ==="; cat "$OUTDIR/summary.txt"
