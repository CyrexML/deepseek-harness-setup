#!/usr/bin/env bash
# Update the DSH harness itself (built from source) with a backup and a rollback.
#
#   bash scripts/update-dsh.sh <tag>            # e.g. dsh-v0.1.6-alpha.2
#   bash scripts/update-dsh.sh --rollback       # back to the previous tag
#   bash scripts/update-dsh.sh <tag> --skip-backup
#
# Order (stops at the first error, state goes into run/dsh-upgrade/state):
#   0. stop the stand; back up ~/.dsh (without node_modules) plus the version list
#      and the current tag
#   1. git fetch --tags; check the tree is clean; check out the tag
#   2. pnpm install --frozen-lockfile=false; pnpm build (slow: a ~1.5 GB monorepo)
#   3. ensure-patches.sh - two layers live inside the harness build
#   4. start the web and verify: CLI version, patches, chat template, bridge-verify
#
# Rollback: check out the previous tag, install, build and optionally unpack the
# ~/.dsh backup.
set -uo pipefail
export PATH="$HOME/.local/node/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
DSH_ROOT="${DSH_ROOT:-$HOME/tools/deepseek-harness}"
WORK="$HOME/Harness_AI/run/dsh-upgrade"
mkdir -p "$WORK"
step() { echo; echo "=== $*"; echo "$(date +%H:%M:%S) $*" >> "$WORK/state"; }
die() { echo "ERROR: $*" >&2; echo "$(date +%H:%M:%S) FAIL: $*" >> "$WORK/state"; exit 1; }

ROLLBACK=0; SKIP_BACKUP=0; TAG=""
for a in "$@"; do
  case "$a" in
    --rollback) ROLLBACK=1;;
    --skip-backup) SKIP_BACKUP=1;;
    *) TAG="$a";;
  esac
done

cd "$DSH_ROOT" || die "no such directory: $DSH_ROOT"

if [ "$ROLLBACK" = 1 ]; then
  PREV="$(cat "$WORK/prev.txt" 2>/dev/null)"
  [ -n "$PREV" ] || die "previous version unknown ($WORK/prev.txt is empty)"
  step "rolling back to $PREV"
  bash "$HERE/stop-web.sh" >/dev/null 2>&1 || true
  git checkout -q "$PREV" || die "git checkout $PREV"
  pnpm install || die "pnpm install"
  pnpm clean || die "pnpm clean"   # lib/ from the previous version breaks the build (RESOLVE_ERROR)
  pnpm build || die "pnpm build"
  node "$HERE/preset-migrate.mjs" || die "preset-migrate"
  bash "$HERE/ensure-patches.sh" || die "patches"
  echo "rollback done. The ~/.dsh backup, if you need it: $WORK/dsh-home-*.tar.gz"
  echo "start the stand: bash $HERE/start-web.sh"
  exit 0
fi

[ -n "$TAG" ] || die "usage: update-dsh.sh <tag> | --rollback   (tags: git tag --sort=-creatordate | head)"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { git fetch --tags -q || true; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "no such tag: $TAG"

step "0/4 stopping the stand and backing up"
bash "$HERE/stop-web.sh" >/dev/null 2>&1 || true
CUR="$(git describe --tags --exact-match 2>/dev/null || git rev-parse --short HEAD)"
echo "$CUR" > "$WORK/prev.txt"
echo "current version: $CUR -> target: $TAG"
# Untracked files are ignored: pnpm install creates artefacts of its own. Only
# modified tracked files stop the update.
dirty="$(git status --porcelain --untracked-files=no)"
[ -z "$dirty" ] || { echo "$dirty" | head -5; die "the harness tree has modified files - sort that out before updating"; }
(cd "$HOME/.dsh/profiles/web" && pnpm ls --depth 0 2>/dev/null | tail -n +2 > "$WORK/plugins-before.txt")
if [ "$SKIP_BACKUP" = 0 ]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  echo "backing up ~/.dsh -> $WORK/dsh-home-$TS.tar.gz (without node_modules)"
  tar --exclude='profiles/web/node_modules' --exclude='profiles/*/node_modules' \
      -czf "$WORK/dsh-home-$TS.tar.gz" -C "$HOME" .dsh || die "backup of ~/.dsh failed"
  ls -lh "$WORK/dsh-home-$TS.tar.gz" | awk '{print "  size:", $5}'
fi

step "1/4 checking out $TAG"
git checkout -q "$TAG" || die "git checkout $TAG"
git describe --tags --exact-match 2>/dev/null || git rev-parse --short HEAD

step "2/4 installing dependencies and building (slow)"
pnpm install || die "pnpm install"
# Stale lib/ from the previous version breaks the build with
# "Could not resolve '@deepseek-ai/dsh-subprocess-local/output'".
pnpm clean || die "pnpm clean"
pnpm build || die "pnpm build failed - roll back: bash $0 --rollback"

step "2b/4 presets for the new version schema"
node "$HERE/preset-migrate.mjs" || die "preset-migrate"

step "3/4 patch layers inside the harness"
bash "$HERE/ensure-patches.sh" || die "patches did not apply (anchors moved). Roll back: bash $0 --rollback"

step "4/4 start and verify"
node "$DSH_ROOT/apps/cli/lib/bin.js" --version || die "the CLI does not start"
bash "$HERE/start-web.sh" >/dev/null || die "start-web"
sleep 30
bash "$HERE/ensure-patches.sh" --check || die "some layers are missing"
bash "$HERE/check-chat-template.sh" | tail -1
node "$HERE/bridge-verify.mjs" 2>&1 | grep -E "^(PASS|FAIL)" | sort | uniq -c
(cd "$HOME/.dsh/profiles/web" && pnpm ls --depth 0 2>/dev/null | tail -n +2 > "$WORK/plugins-after.txt")
diff "$WORK/plugins-before.txt" "$WORK/plugins-after.txt" | grep -E "^[<>]" || echo "plugins: unchanged"
echo
echo "done: $CUR -> $TAG. Roll back: bash $0 --rollback"
