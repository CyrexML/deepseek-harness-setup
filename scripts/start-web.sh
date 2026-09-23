#!/usr/bin/env bash
# The dsh web interface against the local llama-server.
#
# Must be started from the built binary apps/cli/lib/bin.js; `pnpm dsh` will not do.
#
# Working directory: the web profile creates a session with cwd = this process's
# cwd. It can be changed in the interface later, but the default comes from here -
# the first argument, or the current directory.
#
# Agent preset: the second argument. `dsh web` has no CLI flag and no environment
# variable for it; the only handle at start time is the `default` field of the
# `agent-presets` settings namespace - exactly what the "Set as default" button
# writes, and what the host reads when creating a session. Without a second
# argument the settings file is NOT touched.
#
# Note: the default only applies to sessions created afterwards. An already open
# session keeps its preset, and the "open a directory" flow may reuse an earlier
# empty session together with its preset.
#
#   scripts/start-web.sh [workdir] [preset]
set -euo pipefail

DSH_BIN="${DSH_BIN:-$HOME/tools/deepseek-harness/apps/cli/lib/bin.js}"
WORKDIR="${1:-$PWD}"
PRESET="${2:-}"
PORT="${DSH_WEB_PORT:-3080}"
LOG="${DSH_WEB_LOG:-$HOME/Harness_AI/run/web.log}"
PIDFILE="${DSH_WEB_PID:-$HOME/Harness_AI/run/web.pid}"

# The working directory is checked FIRST: with `cd` after the settings edit and
# the pre-flight checks, a typo in the path used to fail the script after side
# effects had already happened, with an unhelpful message from `cd`.
if [ ! -d "$WORKDIR" ]; then
  echo "no such directory: $WORKDIR" >&2
  echo "create it: mkdir -p '$WORKDIR'" >&2
  exit 1
fi
WORKDIR="$(cd "$WORKDIR" && pwd -P)"

# Truncate the log BEFORE the pre-flight checks. Otherwise a failed start leaves
# the previous run's token line in the file, `grep 'dsh web:'` returns a link
# that goes nowhere, and the interface looks alive. The old log is kept as .prev.
mkdir -p "$(dirname "$LOG")"
if [ -s "$LOG" ]; then mv -f "$LOG" "$LOG.prev"; fi
: > "$LOG"

export PATH="$HOME/.local/node/bin:$PATH"

# The Windows host address changes when WSL restarts - resolve it, never store it.
WINHOST="$(ip route show default | awk '{print $3}')"
# An address already set is respected, so the interface can be routed through a
# proxy without touching this script.
export DSH_LLAMA_BASE_URL="${DSH_LLAMA_BASE_URL:-http://$WINHOST:8080/v1}"
# llama-server checks no key, but a request without one fails inside dsh with
# MISSING_CREDENTIAL.
export DSH_LLAMA_KEY="local-no-auth"

# The bridge's Power buttons (Settings -> Remote access) write {mode: dsh|wsl}
# here, and harness-start.ps1 -Hidden polls the file and stops the system. Set
# unconditionally: with no launcher nobody reads it, and the RPC only returns a
# clear error when the variable is missing.
export DSH_POWER_REQUEST_FILE="${DSH_POWER_REQUEST_FILE:-/mnt/f/Harness_AI/run/power.request}"

# cloudflared tunnel: dsh-bridge starts it as a child process and passes this
# environment through; the plugin takes no flags, so it is configured by env
# equivalents. QUIC over UDP dropped every few minutes behind a VPN, hence HTTP/2
# over TCP. The log file exists because the bridge keeps only 2 KB of stderr.
export TUNNEL_TRANSPORT_PROTOCOL="${TUNNEL_TRANSPORT_PROTOCOL:-http2}"
export TUNNEL_LOGFILE="${TUNNEL_LOGFILE:-$HOME/Harness_AI/run/cloudflared.log}"
export TUNNEL_LOGLEVEL="${TUNNEL_LOGLEVEL:-info}"
# A VPN drop on the Windows side kills DNS and routing inside WSL for minutes.
# By default cloudflared gives up after 5 attempts and the plugin's manager after
# 12 restarts, leaving the phone without access until the stand is restarted by
# hand. Keep the process alive - it reconnects once the network returns.
export TUNNEL_RETRIES="${TUNNEL_RETRIES:-1000}"

# Node heap: the web process once grew into the default 4 GB ceiling within ten
# minutes and died with "Reached heap limit". Raise the ceiling and watch it; if
# the growth turns out to be unbounded, that is a leak rather than a shortage.
export NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=6144"

# graph-memory extracts its graph in a separate request and ALWAYS sends
# reasoningEffort (dist/dsh.js:93). "off" sends the parameter as absent, which is
# what a locally declared model wants unless its effort levels are declared in
# the profile patch.
export GRAPH_MEMORY_LLM_REASONING_EFFORT="${GRAPH_MEMORY_LLM_REASONING_EFFORT:-off}"

# Plugin telemetry off: dsh-univer-office sends anonymous usage statistics after
# activation unless this is set. Set here rather than in the user's environment so
# the rule holds for every start, from the shortcut and by hand alike.
export DO_NOT_TRACK=1

# Check the thing that does not change first.
if ! curl -sf --max-time 10 "$DSH_LLAMA_BASE_URL/models" > /dev/null; then
  echo "llama-server does not answer on $DSH_LLAMA_BASE_URL" >&2
  echo "start it: powershell.exe -File 'F:\\Harness_AI\\run\\start-server.ps1'" >&2
  exit 1
fi

# Disable idle sleep for the duration. Started directly from here (rather than
# through the launcher) the stand used to leave the normal timeouts in place, and
# Windows put the PC to sleep in the middle of the agent's work: CPU and GPU load
# does NOT count as activity, keyboard input does. The previous values go into
# run/power-timeouts.json; stop-web.sh restores them, and if this process dies the
# "Harness AI power restore" scheduled task does.
( cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass \
    -File 'F:\Harness_AI\run\harness-idle-sleep.ps1' -Off >/dev/null 2>&1 ) || \
  echo "warning: could not disable idle sleep - the PC may fall asleep mid-run" >&2

# Warm the model with a BIG prompt. The first large request after llama-server
# starts runs on a cold Windows file cache and unbuilt CUDA graphs: prefill
# measured 712 tok/s against 1974 afterwards. A small request does not fix it -
# what warms up is the pass over a long prompt. ~8k tokens, no answer needed,
# a few seconds, in the background so the interface start is not delayed.
( python3 - <<'PYWARM' > /tmp/dsh-warmup.json 2>/dev/null
import json
body = "The quick brown fox jumps over the lazy dog near the river bank. "
print(json.dumps({"prompt": (body * 500)[:32000], "n_predict": 1, "temperature": 0, "stream": False}))
PYWARM
  curl -s --max-time 180 -X POST "${DSH_LLAMA_BASE_URL%/v1}/completion" \
       -H 'Content-Type: application/json' --data @/tmp/dsh-warmup.json > /dev/null 2>&1
  rm -f /tmp/dsh-warmup.json ) &

# Re-apply the patch layers if a plugin update wiped them (ensure-patches.sh).
# After the model check, because the bridge toolchain calls the model to
# translate new strings. The report goes into web.log so a hidden launch from the
# launcher still leaves a trace.
bash "$(dirname "$0")/ensure-patches.sh" 2>&1 | tee -a "$LOG"

# Default preset before the process starts: it is read when a session is created.
if [ -n "$PRESET" ]; then
  # bin.js -> lib -> cli -> apps -> dsh repository root
  DSH_ROOT="$(dirname "$(dirname "$(dirname "$(dirname "$DSH_BIN")")")")"
  if [ ! -d "$HOME/.dsh/.agent-presets/$PRESET" ] \
     && [ ! -d "$DSH_ROOT/packages/preset/agent-presets/presets/$PRESET" ]; then
    echo "unknown preset: $PRESET" >&2
    echo "available: $(ls "$DSH_ROOT/packages/preset/agent-presets/presets" 2>/dev/null | tr '\n' ' ')$(ls "$HOME/.dsh/.agent-presets" 2>/dev/null | tr '\n' ' ')" >&2
    exit 1
  fi
  python3 "$(dirname "$0")/set-default-preset.py" "$HOME/.dsh/settings.yaml" "$PRESET"
  echo "(this is a persistent setting; restore it by running the script with the previous value)"
fi

cd "$WORKDIR"

echo "baseURL = $DSH_LLAMA_BASE_URL"
echo "cwd     = $WORKDIR"
echo "log     = $LOG"

# Foreground mode - the entry point for the Windows launcher.
#
# The usual path (nohup below) does NOT work under `wsl.exe`: WSL kills every
# process of the session when the `wsl.exe` that spawned it exits. Neither nohup
# nor setsid nor nested background jobs survive; only a process in the FOREGROUND
# of a living `wsl.exe` does. That is why the launcher keeps `wsl.exe` open with
# node in its foreground.
#
# The token cannot be read from stdout here - it goes to the log.
if [ -n "${DSH_WEB_FOREGROUND:-}" ]; then
  echo $$ > "$PIDFILE"
  exec node "$DSH_BIN" web --no-open --host 127.0.0.1 --port "$PORT" >> "$LOG" 2>&1
fi

# --no-open: there is no browser in WSL; the page is opened on the Windows side.
nohup node "$DSH_BIN" web --no-open --host 127.0.0.1 --port "$PORT" >> "$LOG" 2>&1 &
echo $! > "$PIDFILE"

for _ in $(seq 1 30); do
  sleep 1
  if grep -q "dsh web:" "$LOG" 2>/dev/null; then
    echo
    grep "dsh web:" "$LOG"
    echo "(the token is single-use: it changes on every start)"
    exit 0
  fi
done

echo "the interface did not come up in 30 s, see $LOG" >&2
exit 1
