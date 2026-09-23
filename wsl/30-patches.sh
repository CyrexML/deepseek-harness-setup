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
