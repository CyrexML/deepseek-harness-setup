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
cd "$P" || exit 1
ln -sfn "$TOOLS/node_modules" node_modules
rm -f client/client.js   # hardlink into the pnpm store: esbuild writes in place
node client/build.mjs >/dev/null || { rm -f node_modules; echo "bridge: building client.js FAILED" >&2; exit 1; }
rm -f node_modules
node --check client/client.js || { echo "bridge: client.js does not pass --check" >&2; exit 1; }
echo "bridge: client.js rebuilt"
