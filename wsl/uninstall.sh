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
  *) echo "неизвестный ключ: $1"; exit 2;; esac; shift; done

targets=("$HOME/Harness_AI" "$HOME/tools/deepseek-harness" "$HOME/harness-stand")
[ "$KEEP_DATA" = 0 ] && targets+=("$HOME/.dsh")

echo
echo "Будет удалено:"
for t in "${targets[@]}"; do
  [ -e "$t" ] && printf '    %s (%s)\n' "$t" "$(du -sh "$t" 2>/dev/null | cut -f1)" || printf '    %s (уже нет)\n' "$t"
done
[ "$KEEP_DATA" = 1 ] && echo "    ~/.dsh — ОСТАЁТСЯ (--keep-data)"
echo
echo "Останется: Node.js (~/.local/node), системные пакеты, ваши проекты вне стенда."
echo

if [ "$YES" = 0 ]; then
  printf 'Удалить? Напишите "удалить": '
  read -r answer
  [ "$answer" = "удалить" ] || { echo "отменено"; exit 0; }
fi

step "останавливаю стенд"
pkill -f 'bin.js web' 2>/dev/null && ok "интерфейс остановлен" || info "интерфейс не работал"
pkill -f cloudflared 2>/dev/null && ok "туннель остановлен" || true

step "возвращаю таймауты сна"
( cd /mnt/c 2>/dev/null && powershell.exe -NoProfile -ExecutionPolicy Bypass \
    -File 'F:\Harness_AI\run\harness-idle-sleep.ps1' -On >/dev/null 2>&1 ) && ok "возвращены" || info "пропущено (нет Windows-части)"

for t in "${targets[@]}"; do
  step "удаляю $t"
  rm -rf "$t" && ok "удалено"
done

step "строка PATH в ~/.bashrc"
if grep -q '# harness-stand' "$HOME/.bashrc" 2>/dev/null; then
  sed -i '/# harness-stand/,+1d' "$HOME/.bashrc"
  ok "убрана"
else
  ok "её не было"
fi

done_step "стенд удалён из WSL"
echo "Windows-часть (модели, движок, ярлыки) удаляется отдельно: uninstall.ps1"
