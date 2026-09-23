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
check() { # label, command...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else printf '    x %s\n' "$(t "$name")" >&2; fails=$((fails+1)); fi
}

step 'harness build'
check 'bin.js is in place' test -f "$DSH_ROOT/apps/cli/lib/bin.js"
check 'version reads' node -e 'require("node:fs").readFileSync(process.argv[1])' "$DSH_ROOT/package.json"

step 'plugins'
for p in dsh-plugin dsh-better-sidebar @wenbin_wb/dsh-bridge dsh-univer-office; do
  [ -d "$HOME/.dsh/profiles/web/node_modules/$p" ] && ok '%s' "$p" || info '%s - not installed (may be disabled in config.json)' "$p"
done

step 'patch layers'
if bash "$STAND/scripts/ensure-patches.sh" --check 2>&1 | sed 's/^/    /'; then
  ok 'all present'
else
  fails=$((fails+1))
fi

step 'model'
if curl -sf --max-time 10 "$MODEL_URL/health" 2>/dev/null | grep -q '"status":"ok"'; then
  ok 'llama-server responds (%s)' "$MODEL_URL"
  # Measure generation speed on a real answer: a three-token reply is dominated
  # by request overhead and the number means nothing.
  tps="$(curl -s --max-time 180 -X POST "$MODEL_URL/completion" \
      -H 'Content-Type: application/json' \
      -d '{"prompt":"Explain what a neural network is, in two sentences.","n_predict":128,"temperature":0,"stream":false}' |
    python3 -c 'import json,sys; print(round(json.load(sys.stdin).get("timings",{}).get("predicted_per_second",0)))' 2>/dev/null)"
  info 'generation %s tok/s (on an RTX 5080, 16 GB: about 95)' "${tps:-?}"
  [ "${tps:-0}" -lt 20 ] 2>/dev/null && warn 'generation below 20 tok/s - the model likely did not fit into VRAM (see docs/MODEL.md section 5)'
else
  printf '    x %s\n' "$(t 'llama-server does not answer on %s' "$MODEL_URL")" >&2
  info 'start it: windows\\run\\start-server.ps1'
  fails=$((fails+1))
fi

step 'interface'
if pgrep -f 'apps/cli/lib/bin.js web' >/dev/null 2>&1; then
  port="$(cfg .webPort 3080)"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$port/" 2>/dev/null)"
  case "$code" in 200|303|401) ok 'web responds (HTTP %s)' "$code";; *) printf '    x %s\n' "$(t 'web does not answer (HTTP %s)' "$code")" >&2; fails=$((fails+1));; esac
else
  info 'web is not running - normal right after install; start it with the Harness AI shortcut'
fi

echo
if [ "$fails" = 0 ]; then done_step 'the stand is healthy'; else die 'checks failed: %s' "$fails"; fi
