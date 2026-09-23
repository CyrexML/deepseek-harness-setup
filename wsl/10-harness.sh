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
[ -n "$TAG" ] || die 'no harness tag resolved (stand.lock.json / config.json)'
DST="${HARNESS_DIR:-$HOME/tools/deepseek-harness}"

step 'harness %s -> %s' "$TAG" "$DST"
if [ -d "$DST/.git" ]; then
  info 'repository already here, refreshing refs'
  git -C "$DST" fetch --tags --quiet origin || warn 'could not refresh tags (no network?)'
else
  mkdir -p "$(dirname "$DST")"
  info 'cloning %s (a few minutes)' "$REPO"
  git clone --quiet "$REPO" "$DST"
fi

current="$(git -C "$DST" describe --tags --exact-match 2>/dev/null || echo '')"
if [ "$current" = "$TAG" ]; then
  ok 'already at %s' "$TAG"
else
  git -C "$DST" rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null ||
    die 'tag %s is not in the repository - check harnessTag in config.json' "$TAG"
  info 'checking out %s' "$TAG"
  git -C "$DST" checkout --quiet --detach "$TAG"
  # Switching tags without cleaning leaves lib/ from the previous version and the
  # build fails on "Could not resolve '@deepseek-ai/dsh-subprocess-local/output'".
  ( cd "$DST" && pnpm clean >/dev/null 2>&1 || true )
  ok 'checked out'
fi

step 'dependencies'
( cd "$DST" && pnpm install --prefer-offline 2>&1 | tail -3 )
ok 'installed'

step 'build (long: 5-15 minutes)'
( cd "$DST" && pnpm build 2>&1 | tail -5 )
[ -f "$DST/apps/cli/lib/bin.js" ] || die 'the build produced no apps/cli/lib/bin.js'
ok 'built'

done_step 'harness ready: %s (%s)' "$DST" "$TAG"
