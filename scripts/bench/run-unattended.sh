#!/usr/bin/env bash
# Unattended run: short sessions under an external driver.
#
# WHY THIS SHAPE. The agent cannot move to a new chat by itself when the context
# runs out, so what lives long is THIS loop rather than a session: each iteration
# is a separate `dsh --profile headless` process with a clean context, and the
# working directory serves as the memory between them. Any failure inside
# (max-tokens, an overflowing window, llama-server dying) ends the process, the
# driver sees the exit code and starts the next iteration from scratch.
#
# Why not `ralph`: its rounds are fresh too, but "an ordinary child failure
# returns an error naming the failed round" - one failed round kills the whole
# loop, which with this stand's max-tokens history means stopping at the first
# hard debugging step.
#
# THE POINT: the stop condition is checked by the DRIVER, not by the model. The
# agent saying "done" is its report, not a certification. Here done = GATE
# returned 0.
#
#   run-unattended.sh <directory> <task-file> [iterations]
#
# Variables: GATE (the criterion command), STALL (how many iterations without a
# change in the tree count as stuck), DSH_BIN, DSH_PATCH.
set -uo pipefail

REPO="${1:?give the project directory}"
TASKFILE="${2:?give the file with the task text}"
MAX_ITER="${3:-20}"

GATE="${GATE:-node --test 'test/*.test.js'}"
# Per-iteration ceiling, found by measurement: a session can fall into a
# degenerate loop (repeating a paragraph verbatim) and generate for hours without
# hitting max-tokens or the window. Without the ceiling an unattended run stalls
# on the first one.
ITER_TIMEOUT="${ITER_TIMEOUT:-600}"
STALL="${STALL:-3}"
DSH_BIN="${DSH_BIN:-$HOME/tools/deepseek-harness/apps/cli/lib/bin.js}"
DSH_PATCH="${DSH_PATCH:-$HOME/Harness_AI/run/headless-local.yml}"

[ -d "$REPO" ] || { echo "no such directory: $REPO" >&2; exit 1; }
[ -f "$TASKFILE" ] || { echo "no task file: $TASKFILE" >&2; exit 1; }
REPO="$(cd "$REPO" && pwd -P)"
TASK="$(cat "$TASKFILE")"

RUNDIR="$REPO/.unattended"
mkdir -p "$RUNDIR"
STATUS="$RUNDIR/status.tsv"
: > "$STATUS"

export PATH="$HOME/.local/node/bin:$PATH"
export DSH_LLAMA_KEY="local-no-auth"

# A tree fingerprint for stall detection. The run's own directory is excluded,
# otherwise its logs would look like progress.
tree_hash() {
  find "$REPO" -type f -not -path "$RUNDIR/*" -not -path "*/.git/*" \
    -printf '%p %s %T@\n' 2>/dev/null | sort | md5sum | cut -d' ' -f1
}

say() { echo "[$(date +%H:%M:%S)] $*"; }

prev_hash=""
stall_count=0
started=$(date +%s)

for i in $(seq 1 "$MAX_ITER"); do
  # llama-server is checked FIRST every iteration: it can exit silently with the
  # log ending cleanly on `all slots are idle`. The address is resolved again
  # because the WSL gateway changes on restart - but an externally supplied one is
  # left alone, since a run may be routed through an intercepting proxy and
  # overwriting it would silently bypass that.
  if [ -z "${DSH_LLAMA_BASE_URL:-}" ]; then
    export DSH_LLAMA_BASE_URL="http://$(ip route show default | awk '{print $3}'):8080/v1"
  fi
  if ! curl -sf --max-time 10 "$DSH_LLAMA_BASE_URL/models" > /dev/null; then
    say "iteration $i: llama-server does not answer, waiting 60 s"
    printf '%s\t%s\tno-server\t-\t-\n' "$i" "$(date +%s)" >> "$STATUS"
    sleep 60
    continue
  fi

  say "iteration $i of $MAX_ITER"
  LOG="$RUNDIR/iter-$(printf '%02d' "$i").log"
  # The row is written IMMEDIATELY: while an iteration runs the monitor would
  # otherwise have nothing to show, exactly when watching matters most.
  printf '%s\t%s\trunning\t-\t-\n' "$i" "$(date +%s)" >> "$STATUS"
  t0=$(date +%s)
  ( cd "$REPO" && timeout --signal=TERM --kill-after=30 "$ITER_TIMEOUT" \
      node "$DSH_BIN" --profile headless --patch "$DSH_PATCH" "$TASK" ) > "$LOG" 2>&1
  rc=$?
  t1=$(date +%s)
  # 124 means the timeout fired. Told apart from an ordinary failure: it is almost always a loop.
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    say "  ABORTED by the ${ITER_TIMEOUT}s timeout - a repetition loop is likely"
  fi
  # Drop the "running" row; the final one replaces it.
  awk -F'\t' -v it="$i" '!($1==it && $3=="running")' "$STATUS" > "$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"

  # The criterion is the driver's, not the model's.
  gate_out="$RUNDIR/gate-$(printf '%02d' "$i").log"
  ( cd "$REPO" && eval "$GATE" ) > "$gate_out" 2>&1
  gate_rc=$?

  printf '%s\t%s\trc=%s\tgate=%s\t%ss\n' "$i" "$(date +%s)" "$rc" "$gate_rc" "$((t1-t0))" >> "$STATUS"
  say "  session rc=$rc, criterion rc=$gate_rc, $((t1-t0)) s"

  if [ "$gate_rc" -eq 0 ]; then
    say "DONE at iteration $i, $(( ($(date +%s)-started)/60 )) minutes total"
    echo "done $i" > "$RUNDIR/result"
    exit 0
  fi

  # Stuck: the tree has not changed for several iterations in a row. Without this
  # the loop would burn through every iteration repeating the same failed move.
  h="$(tree_hash)"
  if [ "$h" = "$prev_hash" ]; then
    stall_count=$((stall_count+1))
    say "  no change in the tree ($stall_count of $STALL)"
    if [ "$stall_count" -ge "$STALL" ]; then
      say "STOP: $STALL iterations in a row without a single change"
      echo "stalled $i" > "$RUNDIR/result"
      exit 2
    fi
  else
    stall_count=0
  fi
  prev_hash="$h"
done

say "STOP: $MAX_ITER iterations exhausted, the criterion was not met"
echo "budget $MAX_ITER" > "$RUNDIR/result"
exit 3
