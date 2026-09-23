#!/usr/bin/env bash
# Step 6: verify the running stand. Fixes nothing, only reports.
#
# Exit 0 means everything came up. One line per check, so a failure points at the
# exact step.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

STAND="${STAND_DIR:-$HOME/Harness_AI}"
DSH_ROOT="${HARNESS_DIR:-$HOME/tools/deepseek-harness}"
WINHOST="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
MODEL_URL="http://${WINHOST}:$(cfg .modelPort 8080)"
fails=0
check() { # имя, команда...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else printf '    ✗ %s\n' "$name" >&2; fails=$((fails+1)); fi
}

step "сборка харнеса"
check "bin.js на месте" test -f "$DSH_ROOT/apps/cli/lib/bin.js"
check "версия читается" node -e 'require("node:fs").readFileSync(process.argv[1])' "$DSH_ROOT/package.json"

step "плагины"
for p in dsh-plugin dsh-better-sidebar @wenbin_wb/dsh-bridge dsh-univer-office; do
  [ -d "$HOME/.dsh/profiles/web/node_modules/$p" ] && ok "$p" || info "$p — не установлен (может быть выключен в config.json)"
done

step "патч-слои"
if bash "$STAND/scripts/ensure-patches.sh" --check 2>&1 | sed 's/^/    /'; then
  ok "все на месте"
else
  fails=$((fails+1))
fi

step "модель"
if curl -sf --max-time 10 "$MODEL_URL/health" 2>/dev/null | grep -q '"status":"ok"'; then
  ok "llama-server отвечает ($MODEL_URL)"
  # Measure generation speed on a real answer: a three-token reply is dominated
  # by request overhead and the number means nothing.
  tps="$(curl -s --max-time 180 -X POST "$MODEL_URL/completion" \
      -H 'Content-Type: application/json' \
      -d '{"prompt":"Explain what a neural network is, in two sentences.","n_predict":128,"temperature":0,"stream":false}' |
    python3 -c 'import json,sys; print(round(json.load(sys.stdin).get("timings",{}).get("predicted_per_second",0)))' 2>/dev/null)"
  info "генерация ${tps:-?} ток/с (на RTX 5080, 16 ГБ — около 95)"
  [ "${tps:-0}" -lt 20 ] 2>/dev/null && warn "генерация ниже 20 ток/с — похоже, модель не влезла в видеопамять (см. docs/MODEL.md §5)"
else
  printf '    ✗ llama-server не отвечает на %s\n' "$MODEL_URL" >&2
  info "поднимите его: windows\\run\\start-server.ps1"
  fails=$((fails+1))
fi

step "интерфейс"
if pgrep -f 'apps/cli/lib/bin.js web' >/dev/null 2>&1; then
  port="$(cfg .webPort 3080)"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$port/" 2>/dev/null)"
  case "$code" in 200|303|401) ok "web отвечает (HTTP $code)";; *) printf '    ✗ web не отвечает (HTTP %s)\n' "$code" >&2; fails=$((fails+1));; esac
else
  info "web не запущен — это нормально сразу после установки, поднимите ярлыком «Harness AI»"
fi

echo
if [ "$fails" = 0 ]; then done_step "стенд в рабочем состоянии"; else die "проверок не прошло: $fails"; fi
