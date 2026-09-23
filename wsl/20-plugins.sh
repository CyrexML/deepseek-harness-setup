#!/usr/bin/env bash
# Step 3: the DSH profile and its plugins.
#
# The profile is ~/.dsh/profiles/web with an ordinary package.json listing the
# plugins and their load order. Versions are pinned: harness + plugins + patches
# was verified as a whole, and an arbitrary latest breaks it (better-sidebar
# 0.19.1 on harness 0.1.3 = white screen).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

PROFILE="$HOME/.dsh/profiles/web"
mkdir -p "$PROFILE"

want() { [ "$(cfg ".features.$1" true)" = "true" ]; }

step 'profile contents'
# Versions come from stand.lock.json. Ranges (^1.2.3) are wrong here: a month
# later they resolve to a different build, and patch layers are anchored to
# specific lines of code.
LOCK="$ROOT/stand.lock.json"
[ -f "$LOCK" ] || die 'no %s - without it the versions to install are unknown' "$LOCK"
ver() { node -e '
  const lock = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  const v = lock.plugins?.[process.argv[2]];
  if (v === undefined) process.exit(3);
  process.stdout.write(v);
' "$LOCK" "$1"; }

deps=()
bundles=('"@deepseek-ai/dsh-base"' '"@deepseek-ai/dsh-web-app"')
add() {
  local name="$1" v
  v="$(ver "$name")" || { warn '%s is not in the lock file - skipping' "$name"; return 0; }
  deps+=("\"$name\": \"$v\""); bundles+=("\"$name\""); info '%s@%s' "$name" "$v"
}

add "dsh-plugin"                              # plugin catalog (Plugin Hub)
want turnRewind    && add "@anionex/dsh-turn-rewind"
want betterSidebar && add "dsh-better-sidebar"
want graphMemory   && add "graph-memory"
want officePreview && add "dsh-univer-office"
want mobileBridge  && add "@wenbin_wb/dsh-bridge"
add "dsh-context"                             # context meter

step 'profile package.json'
{
  printf '{\n  "name": "dsh-profile-web",\n  "private": true,\n  "dependencies": {\n    '
  (IFS=$',\n    '; printf '%s' "${deps[*]}")
  printf '\n  },\n  "dsh": {\n    "profile": {\n      "bundles": [\n        '
  (IFS=$',\n        '; printf '%s' "${bundles[*]}")
  printf '\n      ],\n      "patchReload": "live"\n    }\n  }\n}\n'
} > "$PROFILE/package.json"
node -e 'JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"))' "$PROFILE/package.json" ||
  die 'the generated package.json is invalid'
ok 'written: %s/package.json' "$PROFILE"

step 'installing plugins'
( cd "$PROFILE" && pnpm install 2>&1 | tail -4 )
ok 'installed'

done_step 'plugins ready'
