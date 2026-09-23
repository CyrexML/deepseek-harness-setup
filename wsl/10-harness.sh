#!/usr/bin/env bash
# Step 2: DeepSeek Harness itself - clone the pinned tag and build it.
#
# The tag matters: patch layers are anchored to specific source lines and will
# not apply against 'main'.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

REPO="${HARNESS_REPO:-https://github.com/deepseek-ai/deepseek-harness.git}"
# The tag comes from stand.lock.json (the verified combination); config.json can
# override it for a deliberately different version.
LOCK="$ROOT/stand.lock.json"
TAG="$(cfg .harnessTag '')"
if [ -z "$TAG" ] && [ -f "$LOCK" ]; then
  TAG="$(node -e 'process.stdout.write(JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).harness.tag)' "$LOCK")"
fi
[ -n "$TAG" ] || die "не определён тег харнеса (stand.lock.json / config.json)"
DST="${HARNESS_DIR:-$HOME/tools/deepseek-harness}"

step "харнес $TAG → $DST"
if [ -d "$DST/.git" ]; then
  info "репозиторий уже есть, обновляю ссылки"
  git -C "$DST" fetch --tags --quiet origin || warn "не удалось обновить теги (нет сети?)"
else
  mkdir -p "$(dirname "$DST")"
  info "клонирую $REPO (несколько минут)"
  git clone --quiet "$REPO" "$DST"
fi

current="$(git -C "$DST" describe --tags --exact-match 2>/dev/null || echo '')"
if [ "$current" = "$TAG" ]; then
  ok "уже на $TAG"
else
  git -C "$DST" rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null ||
    die "тега $TAG нет в репозитории — проверьте harnessTag в config.json"
  info "переключаюсь на $TAG"
  git -C "$DST" checkout --quiet --detach "$TAG"
  # Switching tags without cleaning leaves lib/ from the previous version and the
  # build fails on "Could not resolve '@deepseek-ai/dsh-subprocess-local/output'".
  ( cd "$DST" && pnpm clean >/dev/null 2>&1 || true )
  ok "переключено"
fi

step "зависимости"
( cd "$DST" && pnpm install --prefer-offline 2>&1 | tail -3 )
ok "установлены"

step "сборка (долго: 5–15 минут)"
( cd "$DST" && pnpm build 2>&1 | tail -5 )
[ -f "$DST/apps/cli/lib/bin.js" ] || die "сборка не дала apps/cli/lib/bin.js"
ok "собрано"

done_step "харнес готов: $DST ($TAG)"
