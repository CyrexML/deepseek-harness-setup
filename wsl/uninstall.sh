#!/usr/bin/env bash
# Remove the stand from inside WSL (what uninstall.ps1 does, minus the Windows side).
#
#   bash wsl/uninstall.sh [--keep-data] [--yes]
#
# Removes ~/Harness_AI (scripts and toolchains), ~/tools/deepseek-harness, the
# installer copy in ~/harness-stand and, unless --keep-data, ~/.dsh (chats, agent
# memory, the plugin profile, settings).
# Leaves Node.js in ~/.local/node and system packages: other software may use them.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

KEEP_DATA=0; YES=0
while [ $# -gt 0 ]; do case "$1" in
  --keep-data) KEEP_DATA=1;; --yes) YES=1;;
  *) t 'unknown flag: %s\n' "$1"; exit 2;; esac; shift; done

targets=("$HOME/Harness_AI" "$HOME/tools/deepseek-harness" "$HOME/harness-stand")
[ "$KEEP_DATA" = 0 ] && targets+=("$HOME/.dsh")

echo
t 'To be removed:\n'
for t in "${targets[@]}"; do
  [ -e "$t" ] && printf '    %s (%s)\n' "$t" "$(du -sh "$t" 2>/dev/null | cut -f1)" || printf '    %s (%s)\n' "$t" "$(t 'already gone')"
done
[ "$KEEP_DATA" = 1 ] && t '    ~/.dsh STAYS (--keep-data)\n'
echo
t 'Left alone: Node.js (~/.local/node), system packages, your projects outside the stand.\n'
echo

if [ "$YES" = 0 ]; then
  word="$(t 'delete')"
  t 'Remove it? Type "%s": ' "$word"
  read -r answer
  [ "$answer" = "$word" ] || { t 'cancelled\n'; exit 0; }
fi

step 'stopping the stand'
pkill -f 'bin.js web' 2>/dev/null && ok 'interface stopped' || info 'the interface was not running'
pkill -f cloudflared 2>/dev/null && ok 'tunnel stopped' || true

step 'restoring sleep timeouts'
( cd /mnt/c 2>/dev/null && powershell.exe -NoProfile -ExecutionPolicy Bypass \
    -File 'F:\Harness_AI\run\harness-idle-sleep.ps1' -On >/dev/null 2>&1 ) && ok 'restored' || info 'skipped (no Windows side)'

for t in "${targets[@]}"; do
  step 'removing %s' "$t"
  rm -rf "$t" && ok 'removed'
done

step 'PATH line in ~/.bashrc'
if grep -q '# harness-stand' "$HOME/.bashrc" 2>/dev/null; then
  sed -i '/# harness-stand/,+1d' "$HOME/.bashrc"
  ok 'removed'
else
  ok 'was not there'
fi

done_step 'stand removed from WSL'
t 'The Windows side (models, engine, shortcuts) is removed separately: uninstall.ps1\n'
