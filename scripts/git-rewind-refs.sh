#!/usr/bin/env bash
# Точки отката плагина turn-rewind, которые он хранит ПРЯМО В ВАШЕМ репозитории.
#
#   bash git-rewind-refs.sh [каталог]              показать, сколько их и что это
#   bash git-rewind-refs.sh [каталог] --days 14    удалить старше 14 дней
#   bash git-rewind-refs.sh [каталог] --all        удалить все
#
# Что это такое: перед каждым ходом, который правит файлы, плагин делает снимок
# и кладёт его в ссылку refs/dsh-turn-rewind/... того репозитория, где лежит
# проект. Это НЕ ветки (refs/heads) — обычный `git push` их не отправляет, и
# `git branch` не показывает, но многие интерфейсы выводят их вместе с ветками,
# и объекты снимков занимают место.
#
# Цена удаления: откат хода по удалённой точке больше не сработает. Поэтому по
# умолчанию скрипт ничего не трогает, а --days оставляет свежие.
set -euo pipefail
DIR="${1:-$PWD}"; [ "${DIR#--}" = "$DIR" ] || { DIR="$PWD"; set -- "$PWD" "$@"; }
shift || true
DAYS=""; ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="${2:?число дней}"; shift 2 ;;
    --all)  ALL=1; shift ;;
    *) echo "неизвестный ключ: $1" >&2; exit 2 ;;
  esac
done

cd "$DIR"
git rev-parse --git-dir >/dev/null 2>&1 || { echo "$DIR — не git-репозиторий"; exit 1; }
root="$(git rev-parse --show-toplevel)"
NS='refs/dsh-turn-rewind'

total=$(git for-each-ref --format='%(refname)' "$NS" | wc -l)
heads=$(git for-each-ref --format='%(refname)' refs/heads | wc -l)
echo "репозиторий: $root"
echo "  веток (refs/heads):        $heads"
echo "  точек отката ($NS): $total"
[ "$total" -eq 0 ] && exit 0

if [ -z "$DAYS" ] && [ "$ALL" -eq 0 ]; then
  echo
  echo "  самая старая: $(git for-each-ref --sort=committerdate --format='%(committerdate:short)' "$NS" | head -1)"
  echo "  самая свежая: $(git for-each-ref --sort=-committerdate --format='%(committerdate:short)' "$NS" | head -1)"
  echo "  объекты репозитория: $(du -sh "$(git rev-parse --git-dir)/objects" | cut -f1)"
  echo
  echo "  удалить старые:  bash git-rewind-refs.sh \"$root\" --days 14"
  echo "  удалить все:     bash git-rewind-refs.sh \"$root\" --all"
  exit 0
fi

cutoff=0
[ -n "$DAYS" ] && cutoff=$(( $(date +%s) - DAYS * 86400 ))
deleted=0
while read -r ts ref; do
  [ "$ALL" -eq 1 ] || [ "$ts" -lt "$cutoff" ] || continue
  git update-ref -d "$ref"
  deleted=$((deleted + 1))
done < <(git for-each-ref --format='%(committerdate:unix) %(refname)' "$NS")

echo "  удалено точек: $deleted"
if [ "$deleted" -gt 0 ]; then
  # Сами снимки останутся в объектах, пока их кто-то держит: без сборки мусора
  # места не вернуть.
  git reflog expire --expire=now --all >/dev/null 2>&1 || true
  git gc --prune=now --quiet 2>/dev/null || true
  echo "  объекты после сборки мусора: $(du -sh "$(git rev-parse --git-dir)/objects" | cut -f1)"
fi
