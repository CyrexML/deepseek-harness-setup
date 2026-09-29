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
# Where the Windows side of the stand lives. Written by the installer, because
# these paths used to be the author's F: spelled out - and on any other drive the
# Power button wrote its signal nowhere and the sleep timeouts were never touched.
STAND_ENV="${STAND_ENV:-$HOME/Harness_AI/stand.env}"
# shellcheck source=/dev/null
[ -f "$STAND_ENV" ] && . "$STAND_ENV"
if [ -n "${WIN_ROOT_WIN:-}" ]; then
  ( cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass \
      -File "$WIN_ROOT_WIN\\run\\harness-idle-sleep.ps1" -On >/dev/null 2>&1 ) || true
fi
