#!/usr/bin/env bash
# Reference task run against the local llama-server.
#
# Run ONLY the built binary apps/cli/lib/bin.js and ONLY from the task directory:
#   - the headless profile takes the agent's working directory from process.cwd()
#     (packages/bundle/headless/src/index.ts:186); the cwd field in agent-loop is
#     inert under it;
#   - `pnpm dsh` always starts from the workspace root;
#   - calling the sources directly from another cwd fails on module resolution.
set -euo pipefail

DSH_BIN="${DSH_BIN:-$HOME/tools/deepseek-harness/apps/cli/lib/bin.js}"
REPO="${DSH_TASK_REPO:-$HOME/Harness_AI/bench/agent-task-02/repo}"
PATCH="${DSH_PATCH:-$HOME/Harness_AI/bench/agent-task-02/dsh-patch.yml}"
OUT="${1:-/tmp/agent-task-02.log}"

export PATH="$HOME/.local/node/bin:$PATH"
export DSH_LLAMA_BASE_URL="http://$(ip route show default | awk '{print $3}'):8080/v1"
export DSH_LLAMA_KEY="local-no-auth"

echo "baseURL = $DSH_LLAMA_BASE_URL"
echo "cwd     = $REPO"

TASK='Tests in tests/test_attribution.py are failing in this repository. Fix it so that the whole python3 -m pytest suite passes. Do not break the other tests.'

# Desktop VRAM usage is not a constant, so the machine state is recorded to keep
# runs comparable.
{
  echo "=== machine state at run time ==="
  nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader
  /mnt/c/Windows/System32/nvidia-smi.exe --query-compute-apps=pid,process_name \
    --format=csv,noheader 2>/dev/null | sed 's/^/  /'
} > "$OUT.machine" 2>&1

cd "$REPO"
date +%s > "$OUT.start"
set +e
node "$DSH_BIN" --profile headless --patch "$PATCH" "$TASK" > "$OUT" 2>&1
rc=$?
set -e
echo "EXIT=$rc" >> "$OUT"
date +%s > "$OUT.end"
echo "done, rc=$rc"
