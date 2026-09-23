#!/usr/bin/env bash
# Прогон эталонной задачи 01 против локального llama-server.
#
# Запускать ТОЛЬКО собранным бинарником apps/cli/lib/bin.js и ТОЛЬКО из
# каталога задачи:
#   - профиль headless берёт рабочий каталог агента из process.cwd()
#     (packages/bundle/headless/src/index.ts:186), поле cwd в agent-loop
#     под ним холостое;
#   - `pnpm dsh` всегда стартует из корня workspace;
#   - прямой вызов исходников из чужого cwd падает на разрешении модулей
#     (@deepseek-ai/cordis не отдаёт FiberState).
set -euo pipefail

DSH_BIN="${DSH_BIN:-$HOME/tools/deepseek-harness/apps/cli/lib/bin.js}"
REPO="${DSH_TASK_REPO:-$HOME/Harness_AI/bench/agent-task-01/repo}"
PATCH="${DSH_PATCH:-$HOME/Harness_AI/bench/agent-task-01/dsh-patch.yml}"
OUT="${1:-/tmp/agent-task-01.log}"

export PATH="$HOME/.local/node/bin:$PATH"
export DSH_LLAMA_BASE_URL="http://$(ip route show default | awk '{print $3}'):8080/v1"
export DSH_LLAMA_KEY="local-no-auth"

echo "baseURL = $DSH_LLAMA_BASE_URL"
echo "cwd     = $REPO"

TASK='В репозитории падают тесты в tests/test_priority.py. Почини так, чтобы весь набор python3 -m pytest проходил целиком. Остальные тесты ломать нельзя.'

# decision-07 s3: расход VRAM рабочим столом не константа, состав машины
# записываем для сопоставимости прогонов.
{
  echo "=== состояние машины на момент прогона ==="
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
echo "готово, rc=$rc"
