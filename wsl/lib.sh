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
    const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const path = process.argv[2].replace(/^\./, "").split(".").filter(Boolean);
    let node = cfg;
    for (const key of path) { if (node === undefined || node === null) break; node = node[key]; }
    if (node === undefined || node === null) process.exit(3);
    process.stdout.write(typeof node === "object" ? JSON.stringify(node) : String(node));
  ' "$CONFIG" "$path" 2>/dev/null)" || { printf '%s' "$fallback"; return 0; }
  printf '%s' "$value"
}

# Windows path -> WSL path: F:\Harness_AI -> /mnt/f/Harness_AI
winpath() {
  local p="${1//\\//}"
  local drive="${p%%:*}"
  printf '/mnt/%s%s' "$(printf '%s' "$drive" | tr 'A-Z' 'a-z')" "${p#*:}"
}

# Whether passwordless sudo exists and whether apt is needed at all.
need_sudo_apt() {
  command -v git >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && return 1
  command -v sudo >/dev/null 2>&1 || die 'no sudo and the packages are missing - install git curl python3 by hand'
  return 0
}

export PATH="$HOME/.local/node/bin:$PATH"
