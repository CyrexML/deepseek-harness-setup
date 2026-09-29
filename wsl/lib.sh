#!/usr/bin/env bash
# Shared helpers for the install steps: output, config.json access, paths.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${HARNESS_CONFIG:-$ROOT/config.json}"

c_step=$'\033[1;36m'; c_ok=$'\033[0;32m'; c_warn=$'\033[0;33m'; c_err=$'\033[0;31m'; c_off=$'\033[0m'

# Output language. Messages are written in English in the source; a catalog in
# i18n/<lang>.json maps each English string to its translation, so another
# language is a data file rather than a second copy of every script.
#   config.json -> "lang": "ru"   or   HARNESS_LANG=ru bash wsl/10-harness.sh
# A string missing from the catalog falls through untranslated, so a partial
# catalog degrades to English instead of breaking.
HARNESS_LANG="${HARNESS_LANG:-$(python3 -c '
import json, sys
try: print(json.load(open(sys.argv[1], encoding="utf-8")).get("lang", "en"))
except Exception: print("en")' "$CONFIG" 2>/dev/null || echo en)}"

declare -A I18N=()
if [ "$HARNESS_LANG" != "en" ] && [ -f "$ROOT/i18n/$HARNESS_LANG.json" ]; then
  while IFS=$'\t' read -r k v; do [ -n "$k" ] && I18N["$k"]="$v"; done < <(python3 -c '
import json, sys
try: table = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception: table = {}
for k, v in table.items():
    if isinstance(v, str):
        print(k.replace("\n", " ") + "\t" + v.replace("\n", " "))' "$ROOT/i18n/$HARNESS_LANG.json")
fi

# t <format> [args...] - translate the format string, then apply printf.
t() {
  local fmt="${I18N[$1]:-$1}"
  shift
  # shellcheck disable=SC2059
  printf "$fmt" "$@"
}

step()      { printf '%s==> %s%s\n' "$c_step" "$(t "$@")" "$c_off"; }
ok()        { printf '    %s✓%s %s\n' "$c_ok" "$c_off" "$(t "$@")"; }
info()      { printf '    · %s\n' "$(t "$@")"; }
warn()      { printf '    %s!%s %s\n' "$c_warn" "$c_off" "$(t "$@")" >&2; }
die()       { printf '%s%s%s %s\n' "$c_err" "$(t 'ERROR:')" "$c_off" "$(t "$@")" >&2; exit 1; }
done_step() { printf '%s✓ %s%s\n\n' "$c_ok" "$(t "$@")" "$c_off"; }

# cfg <json-path> [default] - read a value out of config.json.
#   cfg .harnessTag           → "v0.1.6-alpha.2"
#   cfg .features.mobileBridge true
cfg() {
  local path="$1" fallback="${2-}"
  [ -f "$CONFIG" ] || { [ -n "$fallback" ] && { printf '%s' "$fallback"; return 0; }; die 'no %s (copy config.example.json)' "$CONFIG"; }
  local value
  value="$(node -e '
    const fs = require("node:fs");
    // A BOM breaks JSON.parse. The installer no longer writes one, but Notepad
    // and any PowerShell `Set-Content -Encoding UTF8` still do, and a silent
    // fall back to every default is the worst possible way to find out.
    const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8").replace(/^\uFEFF/, ""));
    const path = process.argv[2].replace(/^\./, "").split(".").filter(Boolean);
    let node = cfg;
    for (const key of path) { if (node === undefined || node === null) break; node = node[key]; }
    if (node === undefined || node === null) process.exit(3);
    process.stdout.write(typeof node === "object" ? JSON.stringify(node) : String(node));
  ' "$CONFIG" "$path" 2>&1)" && { printf '%s' "$value"; return 0; }
  # Exit 3 is "that key is not in the file", and the default is the right answer.
  # Anything else means the file itself could not be read, and defaulting on THAT
  # is how a broken config.json silently produced a stand configured for someone
  # else's GPU - every value quietly wrong, nothing on screen.
  [ $? -eq 3 ] && { printf '%s' "$fallback"; return 0; }
  # node prints the offending line plus a full stack; only the SyntaxError line
  # says anything to whoever has to fix the file.
  die 'config.json cannot be read (%s): %s' "$CONFIG" \
      "$(printf '%s' "$value" | grep -m1 -E 'Error|error' || printf 'see %s' "$CONFIG")"
}

# Windows path -> WSL path: F:\Harness_AI -> /mnt/f/Harness_AI
winpath() {
  local p="${1//\\//}"
  local drive="${p%%:*}"
  printf '/mnt/%s%s' "$(printf '%s' "$drive" | tr 'A-Z' 'a-z')" "${p#*:}"
}

# Whether apt is needed at all.
#
# The probe has to cover what the BUILD uses, not what is convenient to check.
# A stock Ubuntu image already ships git, curl and python3, so probing only
# those reported "packages already present" on a brand-new distribution and left
# it without a C compiler - and the harness has a native module, whose build
# then died compiling flock.c with a stack trace that named no missing package.
need_sudo_apt() {
  local c
  for c in git curl python3 cc make unzip zstd jq; do
    if ! command -v "$c" >/dev/null 2>&1; then
      command -v sudo >/dev/null 2>&1 || die 'no sudo and %s is missing - install git curl python3 build-essential unzip zstd jq by hand' "$c"
      return 0
    fi
  done
  return 1
}

# Run a long step with its output in a file, and a heartbeat on screen.
#
# The file is what makes a failure readable: the tail of a stack trace says
# nothing, and piping through `tail -5` threw the rest away. The heartbeat is
# what makes SUCCESS readable - a build that prints nothing for a quarter of an
# hour looks exactly like a hung one, and there is nothing to press either way.
#
#   run_logged <name> <working directory> <command...>
LOG_DIR="$HOME/.harness-stand-logs"
run_logged() {
  local what="$1" dir="$2"; shift 2
  mkdir -p "$LOG_DIR"
  local log="$LOG_DIR/$what.log"
  info 'full output: %s' "$log"
  ( cd "$dir" && "$@" ) >"$log" 2>&1 </dev/null &
  local pid=$! secs=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 15
    secs=$((secs + 15))
    if [ $((secs % 60)) -eq 0 ]; then
      printf '    · %s min, %s lines of output so far\n' "$((secs / 60))" "$(wc -l < "$log" 2>/dev/null || echo 0)"
    fi
  done
  if wait "$pid"; then
    tail -3 "$log" | sed 's/^/    /'
    return 0
  fi
  warn '%s failed - last 25 lines:' "$what"
  tail -25 "$log" | sed 's/^/    /'
  die 'full log: %s' "$log"
}

export PATH="$HOME/.local/node/bin:$PATH"
