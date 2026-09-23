#!/usr/bin/env bash
set -euo pipefail
PIDFILE="${DSH_WEB_PID:-$HOME/Harness_AI/run/web.pid}"
if [ -f "$PIDFILE" ]; then
  kill "$(cat "$PIDFILE")" 2>/dev/null && echo "stopped PID $(cat "$PIDFILE")" || echo "process was not running"
  rm -f "$PIDFILE"
else
  echo "no pid file"
fi
pkill -f "bin.js web" 2>/dev/null || true

# Restore the sleep timeouts disabled by start-web.sh. That script checks by
# itself that the launcher is not running: while it lives, it owns the state.
( cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass \
    -File 'F:\Harness_AI\run\harness-idle-sleep.ps1' -On >/dev/null 2>&1 ) || true
