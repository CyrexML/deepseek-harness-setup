#!/usr/bin/env bash
# Сделать из каталога проекта отдельный git-репозиторий, готовый к отправке на
# GitHub — без того мусора, который агент создаёт рядом с кодом.
#
#   bash project-git-init.sh ~/Harness_AI/projects/Cooking_APP
#   bash project-git-init.sh <каталог> --remote git@github.com:имя/репо.git
#
# Что делает: раскладывает .gitignore под следы работы агента (.shots/,
# backups/, out/, node_modules/, *.log), заводит репозиторий с веткой main,
# показывает, ЧТО именно попадёт в первый коммит и сколько это весит, и делает
# коммит. Отправку на GitHub не делает: удалённый репозиторий и момент отправки
# — ваше решение.
#
# Про точки отката: плагин turn-rewind держит снимки ходов в ссылках
# refs/dsh-turn-rewind/... внутри репозитория проекта. Обычный `git push` их не
# отправляет, но `git push --mirror` отправил бы всё; поэтому здесь явно
# задаётся refspec «только ветки», а сами точки чистятся git-rewind-refs.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="${1:?укажите каталог проекта}"; shift || true
REMOTE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --remote) REMOTE="${2:?адрес репозитория}"; shift 2 ;;
    *) echo "неизвестный ключ: $1" >&2; exit 2 ;;
  esac
done
DIR="$(cd "$DIR" && pwd)"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()  { printf '    \033[0;32m✓\033[0m %s\n' "$*"; }
warn(){ printf '    \033[0;33m!\033[0m %s\n' "$*" >&2; }

say "проект: $DIR"

# Каталог может лежать внутри другого репозитория (например, стенда). Это не
# мешает, если тот его игнорирует, — иначе файлы попали бы сразу в два места.
outer=""
if outer="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" && [ "$outer" != "$DIR" ]; then
  if git -C "$outer" check-ignore -q "$DIR"; then
    ok "лежит внутри репозитория $outer, но тот его игнорирует — можно"
  else
    warn "каталог отслеживается репозиторием $outer"
    warn "добавьте его в .gitignore того репозитория, иначе файлы будут в двух репозиториях сразу"
  fi
fi

say ".gitignore под следы работы агента"
bash "$HERE/project-gitignore.sh" "$DIR" >/dev/null
ok "$(wc -l < "$DIR/.gitignore") строк"

cd "$DIR"
if [ -d .git ]; then
  ok "репозиторий уже есть ($(git rev-list --count HEAD 2>/dev/null || echo 0) коммитов)"
else
  git init -q -b main
  ok "репозиторий создан, ветка main"
fi

say "что попадёт в коммит"
git add -A
files=$(git diff --cached --name-only | wc -l)
bytes=$(git diff --cached --name-only -z | xargs -0 -r du -cb 2>/dev/null | tail -1 | cut -f1)
printf '    файлов: %s, размер: %s\n' "$files" "$(numfmt --to=iec --suffix=B "${bytes:-0}" 2>/dev/null || echo "${bytes:-0} Б")"
echo "    самые крупные:"
git diff --cached --name-only -z | xargs -0 -r du -b 2>/dev/null | sort -rn | head -5 |
  while read -r size path; do printf '      %8s  %s\n' "$(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "$size")" "$path"; done
echo "    не попадёт (по .gitignore):"
git status --porcelain --ignored | awk '$1=="!!"{print "      " $2}' | head -6

if git rev-parse HEAD >/dev/null 2>&1; then
  git diff --cached --quiet && { ok "изменений нет — коммит не нужен"; } || { git -c commit.gpgsign=false commit -q -m "Обновление проекта"; ok "коммит сделан"; }
else
  git -c commit.gpgsign=false commit -q -m "Первая версия проекта"
  ok "первый коммит сделан"
fi

# Только ветки: точки отката плагина и прочие служебные ссылки наружу не идут.
git config push.default simple
git config remote.origin.push 'refs/heads/*:refs/heads/*'

if [ -n "$REMOTE" ]; then
  git remote remove origin 2>/dev/null || true
  git remote add origin "$REMOTE"
  ok "удалённый репозиторий: $REMOTE"
  echo
  echo "    отправить:  cd $DIR && git push -u origin main"
else
  echo
  echo "    дальше — создать репозиторий на GitHub и отправить:"
  echo "      cd $DIR"
  echo "      gh repo create <имя> --private --source=. --remote=origin --push"
  echo "    или вручную:"
  echo "      git remote add origin <адрес>"
  echo "      git push -u origin main"
fi
echo "    НЕ используйте git push --mirror: он отправил бы и точки отката плагина."
echo "    Сколько их накопилось:  bash $HERE/git-rewind-refs.sh $DIR"
