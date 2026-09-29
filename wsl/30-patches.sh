#!/usr/bin/env bash
# Step 4: the patch layers.
#
# Without them half of what the stand is built for does not work (see the table
# in the README). Every layer is idempotent and identified by a marker inside the
# patched file, so ensure-patches.sh can run any number of times and only touches
# what is missing. It also runs on every start, because a plugin update wipes the
# edits.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

STAND="${STAND_DIR:-$HOME/Harness_AI}"

step 'copying stand tooling into %s' "$STAND"
mkdir -p "$STAND"
for dir in scripts projects/PlugIN presets templates i18n; do
  [ -d "$ROOT/$dir" ] || continue
  mkdir -p "$STAND/$(dirname "$dir")"
  cp -r "$ROOT/$dir" "$STAND/$(dirname "$dir")/"
  ok '%s' "$dir"
done
chmod +x "$STAND"/scripts/*.sh 2>/dev/null || true

# The bridge patch toolchain has dependencies of its own - esbuild rebuilds the
# client bundle the phone receives, acorn parses the sources - and nothing ever
# installed them. On a machine where they happened to be there already this was
# invisible; on a fresh one the client rebuild failed and the phone kept getting
# the unpatched bundle.
BRIDGE_TOOLS="$STAND/projects/PlugIN/dsh-bridge-en/tools"
if [ -f "$BRIDGE_TOOLS/package.json" ] && [ ! -d "$BRIDGE_TOOLS/node_modules" ]; then
  step 'bridge patch toolchain'
  run_logged bridge-tools "$BRIDGE_TOOLS" npm install --no-audit --no-fund
  ok 'installed'
fi

step 'applying patch layers'
# Translating new bridge strings needs a live model; without one translate.sh
# says so and leaves them untranslated.
bash "$STAND/scripts/ensure-patches.sh" 2>&1 | sed 's/^/    /'

step 'verifying'
if bash "$STAND/scripts/ensure-patches.sh" --check >/tmp/patch-check.log 2>&1; then
  ok 'every layer is in place'
else
  warn 'some layers did not apply:'; sed 's/^/    /' /tmp/patch-check.log >&2
  die 'the patches are incomplete - do not start the stand'
fi

done_step 'patches ready'
