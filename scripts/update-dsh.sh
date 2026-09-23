#!/usr/bin/env bash
# Обновление самого харнеса DSH (сборка из исходников) с бэкапом и откатом.
#
#   bash scripts/update-dsh.sh <тег>            # напр. dsh-v0.1.6-alpha.2
#   bash scripts/update-dsh.sh --rollback       # вернуть прежний тег (из run/dsh-upgrade/prev.txt)
#   bash scripts/update-dsh.sh <тег> --skip-backup
#
# Порядок (падает на первой ошибке, состояние пишется в run/dsh-upgrade/state):
#   0. стенд остановить; бэкап ~/.dsh (без node_modules) + список версий + текущий тег
#   1. git fetch --tags; проверка чистоты дерева; checkout тега
#   2. pnpm install --frozen-lockfile=false; pnpm build   (долго: монорепо ~1.5 ГБ)
#   3. ensure-patches.sh — два слоя живут в сборке харнеса (llm-pi-ai, ui-conversation)
#   4. старт web + проверки: версия CLI, патчи, шаблон чата, bridge-verify, сессия открывается
#
# Откат: checkout прежнего тега + install + build + (по желанию) распаковать бэкап ~/.dsh.
set -uo pipefail
export PATH="$HOME/.local/node/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
DSH_ROOT="${DSH_ROOT:-$HOME/tools/deepseek-harness}"
WORK="$HOME/Harness_AI/run/dsh-upgrade"
mkdir -p "$WORK"
step() { echo; echo "=== $*"; echo "$(date +%H:%M:%S) $*" >> "$WORK/state"; }
die() { echo "ОШИБКА: $*" >&2; echo "$(date +%H:%M:%S) FAIL: $*" >> "$WORK/state"; exit 1; }

ROLLBACK=0; SKIP_BACKUP=0; TAG=""
for a in "$@"; do
  case "$a" in
    --rollback) ROLLBACK=1;;
    --skip-backup) SKIP_BACKUP=1;;
    *) TAG="$a";;
  esac
done

cd "$DSH_ROOT" || die "нет каталога $DSH_ROOT"

if [ "$ROLLBACK" = 1 ]; then
  PREV="$(cat "$WORK/prev.txt" 2>/dev/null)"
  [ -n "$PREV" ] || die "не знаю прежнюю версию ($WORK/prev.txt пуст)"
  step "откат на $PREV"
  bash "$HERE/stop-web.sh" >/dev/null 2>&1 || true
  git checkout -q "$PREV" || die "git checkout $PREV"
  pnpm install || die "pnpm install"
  pnpm clean || die "pnpm clean"   # lib/ от прошлой версии ломает сборку (RESOLVE_ERROR)
  pnpm build || die "pnpm build"
  node "$HERE/preset-migrate.mjs" || die "preset-migrate"
  bash "$HERE/ensure-patches.sh" || die "патчи"
  echo "откат завершён. Бэкап ~/.dsh (если нужен): $WORK/dsh-home-*.tar.gz"
  echo "запустите стенд: bash $HERE/start-web.sh"
  exit 0
fi

[ -n "$TAG" ] || die "usage: update-dsh.sh <тег> | --rollback   (теги: git tag --sort=-creatordate | head)"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { git fetch --tags -q || true; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "нет тега $TAG"

step "0/4 остановка стенда и бэкап"
bash "$HERE/stop-web.sh" >/dev/null 2>&1 || true
CUR="$(git describe --tags --exact-match 2>/dev/null || git rev-parse --short HEAD)"
echo "$CUR" > "$WORK/prev.txt"
echo "текущая версия: $CUR → целевая: $TAG"
# Неотслеживаемое игнорируем: pnpm install создаёт артефакты вроде native/system
# (node_modules + packages). Останавливаемся только на изменённых отслеживаемых файлах.
dirty="$(git status --porcelain --untracked-files=no)"
[ -z "$dirty" ] || { echo "$dirty" | head -5; die "в дереве харнеса есть изменённые файлы — разберитесь перед обновлением"; }
(cd "$HOME/.dsh/profiles/web" && pnpm ls --depth 0 2>/dev/null | tail -n +2 > "$WORK/plugins-before.txt")
if [ "$SKIP_BACKUP" = 0 ]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  echo "бэкап ~/.dsh → $WORK/dsh-home-$TS.tar.gz (без node_modules, ~2–4 мин)"
  tar --exclude='profiles/web/node_modules' --exclude='profiles/*/node_modules' \
      -czf "$WORK/dsh-home-$TS.tar.gz" -C "$HOME" .dsh || die "бэкап ~/.dsh"
  ls -lh "$WORK/dsh-home-$TS.tar.gz" | awk '{print "  размер:", $5}'
fi

step "1/4 переключение на $TAG"
git checkout -q "$TAG" || die "git checkout $TAG"
git describe --tags --exact-match 2>/dev/null || git rev-parse --short HEAD

step "2/4 установка зависимостей и сборка (долго)"
pnpm install || die "pnpm install"
# Стаялые lib/ от прежней версии ломают сборку: 0.1.5-rc.2 упал на
# "Could not resolve '@deepseek-ai/dsh-subprocess-local/output'" из lib/ от 0.1.6.
pnpm clean || die "pnpm clean"
pnpm build || die "pnpm build — откат: bash $0 --rollback"

step "2b/4 пресеты под схему новой версии"
node "$HERE/preset-migrate.mjs" || die "preset-migrate"

step "3/4 патч-слои внутри харнеса"
bash "$HERE/ensure-patches.sh" || die "патчи не легли (якоря уехали). Откат: bash $0 --rollback"

step "4/4 запуск и проверки"
node "$DSH_ROOT/apps/cli/lib/bin.js" --version || die "CLI не запускается"
bash "$HERE/start-web.sh" >/dev/null || die "start-web"
sleep 30
bash "$HERE/ensure-patches.sh" --check || die "слои на месте не все"
bash "$HERE/check-chat-template.sh" | tail -1
node "$HERE/bridge-verify.mjs" 2>&1 | grep -E "^(PASS|FAIL)" | sort | uniq -c
(cd "$HOME/.dsh/profiles/web" && pnpm ls --depth 0 2>/dev/null | tail -n +2 > "$WORK/plugins-after.txt")
diff "$WORK/plugins-before.txt" "$WORK/plugins-after.txt" | grep -E "^[<>]" || echo "плагины: без изменений"
echo
echo "готово: $CUR → $TAG. Откат: bash $0 --rollback"
