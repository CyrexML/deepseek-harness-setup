#!/usr/bin/env bash
# client/client.js - what the browser actually gets - is built from
# client/index.js by the LAST step of translate.sh. Any patch applied after that
# build leaves the bundle stale: the markers in index.js are in place,
# ensure-patches says "ok", and the phone still receives the old code. This script
# rebuilds the bundle when it is older than its sources, and stays quiet
# otherwise.
set -uo pipefail
export PATH="$HOME/.local/node/bin:$PATH"
P="${1:-$HOME/.dsh/profiles/web/node_modules/@wenbin_wb/dsh-bridge}"
TOOLS="$HOME/Harness_AI/projects/PlugIN/dsh-bridge-en/tools"
OUT="$P/client/client.js"
# There are several sources (index.js, mobile-styles.js, ...) so the newest one is
# compared: patch-settings-mobile.mjs edits mobile-styles.js, and comparing only
# against index.js would skip the rebuild.
SRC="$(ls -t "$P"/client/*.js 2>/dev/null | grep -v '/client\.js$' | head -1)"
[ -n "$SRC" ] || exit 0
if [ -f "$OUT" ] && [ "$OUT" -nt "$SRC" ]; then exit 0; fi
echo "bridge: newest source is $(basename "$SRC")"
echo "bridge: client.js is stale - rebuilding"
[ -d "$TOOLS/node_modules" ] || {
  echo "bridge: $TOOLS/node_modules is missing - run: (cd $TOOLS && npm install)" >&2
  exit 1
}
cd "$P" || exit 1

# build.mjs imports esbuild, and ESM resolves bare names next to the importing
# file - so the tools' node_modules has to appear inside the package. A pnpm
# install leaves a REAL node_modules here, and `ln -sfn` onto a real directory
# puts the link inside it instead of over it: the build then fails to resolve
# esbuild, and the cleanup `rm -f` cannot remove a directory either. So the real
# one is moved aside and put back, whatever happens.
restore_nm() {
  rm -f node_modules
  [ -n "${SAVED_NM:-}" ] && [ -d "$SAVED_NM" ] && mv "$SAVED_NM" node_modules
  return 0
}
SAVED_NM=""
if [ -e node_modules ] && [ ! -L node_modules ]; then
  SAVED_NM="node_modules.harness-stand-saved"
  rm -rf "$SAVED_NM"
  mv node_modules "$SAVED_NM"
fi
trap restore_nm EXIT INT TERM

ln -sfn "$TOOLS/node_modules" node_modules
rm -f client/client.js   # hardlink into the pnpm store: esbuild writes in place
node client/build.mjs >/dev/null || { echo "bridge: building client.js FAILED" >&2; exit 1; }
restore_nm
trap - EXIT INT TERM
node --check client/client.js || { echo "bridge: client.js does not pass --check" >&2; exit 1; }
echo "bridge: client.js rebuilt"
