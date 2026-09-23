#!/usr/bin/env bash
set -euo pipefail
PIDFILE="${DSH_WEB_PID:-$HOME/Harness_AI/run/web.pid}"
if [ -f "$PIDFILE" ]; then
  kill "$(cat "$PIDFILE")" 2>/dev/null && echo "остановлен PID $(cat "$PIDFILE")" || echo "процесс уже не работает"
  rm -f "$PIDFILE"
else
  echo "нет pid-файла"
fi
pkill -f "bin.js web" 2>/dev/null || true

# Вернуть таймауты сна, выключенные в start-web.sh. Скрипт сам проверит, что
# лончер (harness-start.ps1) не работает: пока он жив, состоянием владеет он.
( cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass \
    -File 'F:\Harness_AI\run\harness-idle-sleep.ps1' -On >/dev/null 2>&1 ) || true
