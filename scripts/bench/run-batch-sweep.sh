#!/usr/bin/env bash
# Замер скорости llama-server: префилл и декод на разных руках запуска.
#
# Зачем: в start-server.ps1 (комментарий к -Extra) сказано, что -b/-ub мы не
# задавали никогда и проверить их можно только замером. Здесь — проба без
# пересборки: перезапуск сервера с набором флагов и запросы через РОДНОЙ
# маршрут /completion (он всегда возвращает timings, в отличие от
# /v1/chat/completions).
#
#   bash run-batch-sweep.sh [каталог_результатов]
# Переменные: RUNS (умолч. 3), BLOCKS (умолч. 2 — сколько раз пройти весь список
# рук; чередование A/B/A/B гасит разогрев), PREFILL_CHARS (32000 ≈ 8k токенов),
# DECODE_TOKENS (256).
#
# Важное про разогрев: ПЕРВЫЙ запрос после старта сервера идёт по холодному
# файловому кэшу Windows и по непостроенным графам CUDA — он занижает префилл
# втрое (замер 2026-09-23: 712 против 1920 т/с на той же руке). Поэтому здесь
# два прогрева и несколько блоков.
set -uo pipefail

OUT="${1:-$HOME/Harness_AI/bench/results/batch-sweep}"
RUNS="${RUNS:-3}"
BLOCKS="${BLOCKS:-2}"
PREFILL_CHARS="${PREFILL_CHARS:-32000}"
DECODE_TOKENS="${DECODE_TOKENS:-256}"
# Адрес Windows-хоста из WSL — шлюз по умолчанию; он свой на каждой машине,
# поэтому берётся из таблицы маршрутов, а не записан числом.
HOSTPORT="${HOSTPORT:-http://$(ip route show default | awk '{print $3}'):8080}"
mkdir -p "$OUT"
SUM="$OUT/summary.txt"; : > "$SUM"
RAW="$OUT/raw"; mkdir -p "$RAW"

ARMS=(
  "base|"
  "b2048-ub512|-Extra '-b 2048 -ub 512'"
)

ps_run() { ( cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass "$@" ) ; }

start_arm() {
  local name="$1"; shift
  local log="F:\\Harness_AI\\run\\bench-$name.log"
  local win="/mnt/f/Harness_AI/run/bench-$name.log"
  ps_run -File 'F:\Harness_AI\run\stop-server.ps1' >/dev/null 2>&1 || true
  sleep 4
  rm -f "$win"
  ( cd /mnt/c && nohup powershell.exe -NoProfile -ExecutionPolicy Bypass \
      -File 'F:\Harness_AI\run\start-server.ps1' -Log "$log" "$@" >/dev/null 2>&1 & )
  # /health отвечает "ok" только когда модель загружена; сокет открывается раньше.
  local i=0
  until curl -s --max-time 5 "$HOSTPORT/health" 2>/dev/null | grep -q '"status":"ok"'; do
    sleep 5; i=$((i+1)); [ $i -gt 90 ] && { echo "  НЕ ПОДНЯЛСЯ (см. $win)"; return 1; }
  done
  return 0
}

payload() { # $1 = n_predict, $2 = длина промпта в символах
  python3 - "$1" "$2" <<'PY'
import json, sys, random, string
n, chars = int(sys.argv[1]), int(sys.argv[2])
tag = ''.join(random.choices(string.ascii_lowercase, k=12))
body = f"[{tag}] " + "The quick brown fox jumps over the lazy dog near the river bank. "
prompt = (body * (chars // len(body) + 1))[:chars]
print(json.dumps({"prompt": prompt, "n_predict": n, "temperature": 0, "cache_prompt": False, "stream": False}))
PY
}

# measure <n_predict> <chars> <тег_для_сырого_ответа> → "prompt/s predicted/s"
# Пустой или ошибочный ответ повторяется до трёх раз; тело сохраняется в raw/.
measure() {
  local n="$1" chars="$2" tag="$3" attempt=1 body out
  while [ $attempt -le 3 ]; do
    payload "$n" "$chars" > /tmp/dsh-bench-payload.json
    body="$(curl -s --max-time 600 -X POST "$HOSTPORT/completion" \
        -H 'Content-Type: application/json' --data @/tmp/dsh-bench-payload.json)"
    out="$(printf '%s' "$body" | python3 -c '
import json, sys
try: t = json.load(sys.stdin).get("timings", {})
except Exception: sys.exit(1)
p, d = t.get("prompt_per_second"), t.get("predicted_per_second")
if p is None and d is None: sys.exit(1)
print(round(p or 0, 1), round(d or 0, 1))' 2>/dev/null)" && { printf '%s' "$out"; return 0; }
    printf '%s' "$body" > "$RAW/$tag-attempt$attempt.json"
    attempt=$((attempt+1)); sleep 3
  done
  echo "0 0"; return 1
}

med() { tr ' ' '\n' | grep -v '^$' | sort -g | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}'; }

declare -A PF DC
for block in $(seq 1 "$BLOCKS"); do
  for entry in "${ARMS[@]}"; do
    name="${entry%%|*}"; args="${entry#*|}"
    echo "### блок $block, рука $name ${args:-(рабочая)}"
    if ! eval start_arm "$name" $args; then
      echo "$name: сервер не поднялся" >> "$SUM"; continue
    fi
    info_prefix="    "
    echo "${info_prefix}поднят, два прогрева"
    measure 64 4000 "$name-b$block-warm1" >/dev/null
    measure 64 "$PREFILL_CHARS" "$name-b$block-warm2" >/dev/null
    for i in $(seq 1 "$RUNS"); do
      read -r p _ < <(measure 1 "$PREFILL_CHARS" "$name-b$block-pf$i")
      read -r _ d < <(measure "$DECODE_TOKENS" 2000 "$name-b$block-dc$i")
      PF[$name]+="$p "; DC[$name]+="$d "
      echo "${info_prefix}блок $block прогон $i: префилл ${p} т/с, декод ${d} т/с"
    done
  done
done

echo
for entry in "${ARMS[@]}"; do
  name="${entry%%|*}"
  pm=$(printf '%s' "${PF[$name]:-}" | med); dm=$(printf '%s' "${DC[$name]:-}" | med)
  acc=$(tr -d '\000\r' < "/mnt/f/Harness_AI/run/bench-$name.log" 2>/dev/null | grep -a "draft acceptance" | tail -10 |
        sed 's/.*draft acceptance = \([0-9.]*\).*/\1/' | awk '{s+=$1; n++} END{if(n) printf "%.2f", s/n; else print "—"}')
  printf '%-14s префилл(медиана)=%8s т/с  декод=%7s т/с  приём_черновика=%s\n' "$name" "$pm" "$dm" "$acc" | tee -a "$SUM"
  printf '   префилл: %s\n   декод:   %s\n' "${PF[$name]:-}" "${DC[$name]:-}" >> "$SUM"
done

echo; echo "=== ИТОГ ==="; cat "$SUM"
echo "сырые ответы на неудачные запросы: $RAW"
echo "(рабочая рука восстанавливается отдельно: start-server.ps1 без параметров)"
