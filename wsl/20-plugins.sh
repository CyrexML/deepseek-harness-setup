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

PROFILE="${DSH_HOME:-$HOME/.dsh}/profiles/web"
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
names=()
bundles=('"@deepseek-ai/dsh-base"' '"@deepseek-ai/dsh-web-app"')
add() {
  local name="$1" v
  v="$(ver "$name")" || { warn '%s is not in the lock file - skipping' "$name"; return 0; }
  deps+=("\"$name\": \"$v\""); bundles+=("\"$name\""); names+=("$name"); info '%s@%s' "$name" "$v"
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
  printf '\n  },\n'
  printf '  "dsh": {\n    "profile": {\n      "bundles": [\n        '
  (IFS=$',\n        '; printf '%s' "${bundles[*]}")
  printf '\n      ],\n      "patchReload": "live"\n    }\n  }\n}\n'
} > "$PROFILE/package.json"
node -e 'JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"))' "$PROFILE/package.json" ||
  die 'the generated package.json is invalid'
ok 'written: %s/package.json' "$PROFILE"

# pnpm reads the profile's settings from HERE, not from package.json (whose
# `pnpm` field pnpm 11 ignores with a warning) and not from .npmrc (which it
# ignores in silence). The working stand has carried these four settings by hand
# since it was built; the installer never wrote them, so a fresh profile got
# pnpm's defaults and behaved differently from the stand this repository pins.
step 'profile settings (pnpm-workspace.yaml)'
{
  printf 'packages:\n  - .\n\n'
  printf '# The harness provides @deepseek-ai/* itself - the plugins only declare them\n'
  printf '# as peers. Fetching them from the registry fails outright (there is no\n'
  printf '# stable 0.1.x of dsh-session published) and would be wrong even if it\n'
  printf '# worked: the copy that must be used is the one the harness was built with.\n'
  printf 'autoInstallPeers: false\n\n'
  printf '# The harness resolves plugin modules by walking node_modules, so the tree\n'
  printf '# has to be flat rather than the symlinked one pnpm builds by default.\n'
  printf 'nodeLinker: hoisted\n\n'
  printf '# node-pty is a native module the terminal needs; without this line pnpm\n'
  printf '# refuses to run its build script and stops the install over it.\n'
  printf 'allowBuilds:\n  node-pty: true\n\n'
  printf '# Plugins are installed at the version this repository verified, which may\n'
  printf '# be newer than the new-release quarantine allows. A bare name lifts it; a\n'
  printf '# name@version entry does not survive the lockfile check.\n'
  printf 'minimumReleaseAgeExclude:\n'
  # Quoted: a scoped name starts with @, which YAML will not accept bare.
  for n in "${names[@]}"; do printf "  - '%s'\n" "$n"; done
} > "$PROFILE/pnpm-workspace.yaml"
python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$PROFILE/pnpm-workspace.yaml" 2>/dev/null ||
  node -e 'require("node:fs").readFileSync(process.argv[1],"utf8")' "$PROFILE/pnpm-workspace.yaml"
ok 'written: %s/pnpm-workspace.yaml' "$PROFILE"

step 'installing plugins'
run_logged plugins "$PROFILE" pnpm install
ok 'installed'

done_step 'plugins ready'
