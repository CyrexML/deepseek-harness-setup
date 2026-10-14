#!/usr/bin/env bash
# Careful update of one profile plugin: backup -> install -> patches -> restart
# -> checks, stopping at the first error.
#
#   bash scripts/update-plugin.sh <package>@<version> [more package@version ...]
#   bash scripts/update-plugin.sh --rollback <backup-directory>
#
# What it does:
#   1. Backs up the profile's package.json, pnpm-workspace.yaml, cordis.patch.yml
#      and version list, plus the patched plugin files, into
#      run/backups/keep/profile-<ts>/.
#   2. `pnpm add` (reinstalls the package; neighbouring packages may fall back to
#      their store versions - step 3 brings the patches back).
#   3. ensure-patches.sh re-applies every layer; a MATCH COUNT other than 1 means
#      the patch did not apply (an anchor moved in the new version) and the script
#      stops so you can roll back.
#   4. Restarts the web (a new bundle is only picked up on restart).
#   5. ensure-patches.sh --check, bridge-verify.mjs, check-chat-template.sh.
set -uo pipefail
export PATH="$HOME/.local/node/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
PROFILE="${DSH_HOME:-$HOME/.dsh}/profiles/web"
KEEP="$HOME/Harness_AI/run/backups/keep"
step() { echo; echo "=== $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

if [ "${1:-}" = "--rollback" ]; then
  src="${2:?give the backup directory}"
  [ -d "$src" ] || die "no such directory: $src"
  step "rolling back from $src"
  cp "$src"/package.json "$src"/pnpm-workspace.yaml "$src"/cordis.patch.yml "$PROFILE"/ || die "copy failed"
  # the Plugin Hub's version record exists only on some hosts (not on 0.1.7)
  [ -f "$src/gro.ngilp-hsd-versions.json" ] && cp "$src/gro.ngilp-hsd-versions.json" "$PROFILE"/
  [ -f "$src/pnpm-lock.yaml" ] && cp "$src/pnpm-lock.yaml" "$PROFILE"/
  # Restore exact versions: a package.json with `^0.18.0` plus a fresh lock could
  # leave 0.19.x installed, so reinstall from the lines in the backup. Registry
  # versions only: git+/github: dependencies are not reinstalled.
  pins="$(node -e '
    const fs = require("node:fs");
    const d = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).dependencies || {};
    console.log(Object.entries(d)
      .filter(([, v]) => /^[\^~]?\d/.test(String(v)))
      .map(([k, v]) => k + "@" + String(v).replace(/^[\^~]/, "")).join(" "));
  ' "$(cd "$(dirname "$src/package.json")" && pwd)/package.json")"
  [ -n "$pins" ] || die "could not build the version list from $src/package.json"
  echo "  versions: $pins"
  (cd "$PROFILE" && pnpm add $pins) || die "pnpm add (version rollback) failed"
  bash "$HERE/ensure-patches.sh" || die "patches"
  echo "rollback done; restart the stand: bash $HERE/start-web.sh"
  exit 0
fi

[ $# -ge 1 ] || die "usage: update-plugin.sh <pkg>@<version> [...]"
TS="$(date +%Y%m%d-%H%M%S)"
BK="$KEEP/profile-$TS"

step "1/5 backup -> $BK"
mkdir -p "$BK"
cp "$PROFILE"/package.json "$PROFILE"/pnpm-workspace.yaml "$PROFILE"/cordis.patch.yml "$BK"/ || die "config backup failed"
[ -f "$PROFILE/gro.ngilp-hsd-versions.json" ] && cp "$PROFILE/gro.ngilp-hsd-versions.json" "$BK"/
[ -f "$PROFILE/pnpm-lock.yaml" ] && cp "$PROFILE/pnpm-lock.yaml" "$BK"/
for f in "@wenbin_wb/dsh-bridge/client/index.js" "dsh-better-sidebar/lib/index.js" "@anionex/dsh-turn-rewind/lib/client.js" "graph-memory/dist/dsh.js"; do
  [ -f "$PROFILE/node_modules/$f" ] && cp "$PROFILE/node_modules/$f" "$BK/$(echo "$f" | tr '/' '_').patched"
done
(cd "$PROFILE" && pnpm ls --depth 0 2>/dev/null | tail -n +2 > "$BK/versions-before.txt")
echo "backup done ($(ls "$BK" | wc -l) files)"

step "1b/5 host compatibility"
HOSTV="$(node -p "require('$HOME/tools/deepseek-harness/package.json').version" 2>/dev/null)"
for spec in "$@"; do
  need="$(timeout 40 npm view "$spec" peerDependencies --json 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);const v=Object.entries(j).filter(([k])=>k.startsWith("@deepseek-ai/dsh-"));console.log(v.length?v[0][1]:"")}catch{console.log("")}})')"
  # Compare the harness version with the plugin's minimum requirement
  # (major.minor.patch, then the pre-release as a string).
  verdict="$(HOSTV="$HOSTV" NEED="$need" node -e '
    const need = process.env.NEED || "", host = process.env.HOSTV || "";
    if (!need) { console.log("unknown"); process.exit(0); }
    const parse = v => { const m = /(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?/.exec(v); return m ? [ +m[1], +m[2], +m[3], m[4] || "~" ] : null; };
    const cmp = (a, b) => a[0] - b[0] || a[1] - b[1] || a[2] - b[2] || String(a[3]).localeCompare(String(b[3]));
    const h = parse(host); const mins = need.split("||").map(parse).filter(Boolean);
    if (!h || !mins.length) { console.log("unknown"); process.exit(0); }
    console.log(mins.some(m => cmp(h, m) >= 0) ? "ok" : "too-old");
  ')"
  echo "  $spec: host $HOSTV, plugin requires ${need:--} -> $verdict"
  if [ "$verdict" = "too-old" ]; then
    echo "  WARNING: the plugin is newer than the host - expect React error #130 or 'entry did not activate'."
    if [ -t 0 ]; then read -r -p "  continue? [y/N] " a; [ "$a" = "y" ] || die "stopped before installing";
    else die "stopped before installing (incompatible; run the script in a terminal to force it)"; fi
  fi
done

step "2/5 installing: $*"
(cd "$PROFILE" && pnpm add "$@") || die "pnpm add failed - the profile is untouched beyond this point, roll back: --rollback $BK"

step "3/5 patches"
bash "$HERE/ensure-patches.sh" || die "a patch did not apply (an anchor moved in the new version). Roll back: bash $0 --rollback $BK"

step "4/5 restarting the web"
# A stand started from the shortcut is owned by the hidden launcher: it holds the
# web process and the GPU watchdog. stop-web.sh + start-web.sh from here would take
# the web away from it and leave DSH living in this shell's WSL session. So the
# restart goes through the launcher itself: the Power signal, then the shortcut.
STAND_ENV="${STAND_ENV:-$HOME/Harness_AI/stand.env}"
# shellcheck source=/dev/null
[ -f "$STAND_ENV" ] && . "$STAND_ENV"
LLOG="${WIN_ROOT_WSL:-/mnt/f/Harness_AI}/run/launcher.log"
launcher_hidden() {
  ( cd /mnt/c 2>/dev/null && powershell.exe -NoProfile -Command \
    "@(Get-CimInstance Win32_Process | Where-Object { \$_.ProcessId -ne \$PID -and \$_.CommandLine -like '*harness-start.ps1*-Hidden*' }).Count" 2>/dev/null ) | tr -d '\r' | grep -qv '^0$'
}
if [ -n "${WIN_ROOT_WIN:-}" ] && launcher_hidden; then
  echo "  through the launcher (Power signal, then the shortcut)"
  # the launcher copies its scripts from the repository only for the NEXT run
  cp "$HERE/harness-start.ps1" "${WIN_ROOT_WSL}/run/harness-start.ps1" 2>/dev/null || true
  before="$(wc -l < "$LLOG" 2>/dev/null || echo 0)"
  echo '{"mode":"dsh"}' > "${WIN_ROOT_WSL}/run/power.request"
  for _ in $(seq 1 90); do sleep 2; tail -n +"$((before + 1))" "$LLOG" 2>/dev/null | grep -q '\] exit' && break; done
  before="$(wc -l < "$LLOG" 2>/dev/null || echo 0)"
  # Started THROUGH EXPLORER (the Start menu shortcut), never as a child of this
  # shell: a process started from here lands in the job object of whatever runs
  # this shell (the Claude desktop app, a terminal), and Windows kills the whole
  # job with it - on 2026-10-14 an app update at 11:30 took the stand down that
  # way. Explorer's children belong to no job.
  appdata="$( (cd /mnt/c && cmd.exe /c 'echo %APPDATA%') 2>/dev/null | tr -d '\r')"
  lnk="$appdata\\Microsoft\\Windows\\Start Menu\\Programs\\Harness AI\\Harness AI.lnk"
  if [ -n "$appdata" ] && [ -f "$(wslpath -u "$lnk" 2>/dev/null)" ]; then
    ( cd /mnt/c && explorer.exe "$lnk" ) >/dev/null 2>&1 || true
  else
    echo "  WARNING: no Start menu shortcut - starting as a child of this shell (it dies with it)"
    ( cd /mnt/c && cmd.exe /c start "" wscript.exe //B "${WIN_ROOT_WIN}\\run\\harness-launch.vbs" ) >/dev/null 2>&1
  fi
  for _ in $(seq 1 120); do sleep 3; tail -n +"$((before + 1))" "$LLOG" 2>/dev/null | grep -q '\] ready' && break; done
  tail -n +"$((before + 1))" "$LLOG" | grep -q '\] ready' || die "the launcher did not report ready, see $LLOG"
  sleep 5
else
  bash "$HERE/stop-web.sh" || true
  sleep 2
  bash "$HERE/start-web.sh" >/dev/null || die "start-web"
  sleep 25
fi

step "5/5 checks"
bash "$HERE/ensure-patches.sh" --check || die "some layers are missing"
bash "$HERE/check-chat-template.sh" | tail -1
node "$HERE/bridge-verify.mjs" 2>&1 | grep -E "^(PASS|FAIL)" | sort | uniq -c
(cd "$PROFILE" && pnpm ls --depth 0 2>/dev/null | tail -n +2 > "$BK/versions-after.txt")
# `diff` exits 1 when the lists differ - which is the expected case - and under
# pipefail that used to print "unchanged?" right under the changed lines.
changes="$(diff "$BK/versions-before.txt" "$BK/versions-after.txt" | grep -E "^[<>]" || true)"
if [ -n "$changes" ]; then printf '%s\n' "$changes"; else echo "versions: unchanged?"; fi
echo
echo "done. If something breaks: bash $0 --rollback $BK"
