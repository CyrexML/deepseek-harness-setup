#!/usr/bin/env bash
# Общие мелочи для шагов установки: вывод, чтение config.json, пути.
# Подключается через `. "$HERE/lib.sh"`.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${HARNESS_CONFIG:-$ROOT/config.json}"

c_step=$'\033[1;36m'; c_ok=$'\033[0;32m'; c_warn=$'\033[0;33m'; c_err=$'\033[0;31m'; c_off=$'\033[0m'
step()      { printf '%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()        { printf '    %s✓%s %s\n' "$c_ok" "$c_off" "$*"; }
info()      { printf '    · %s\n' "$*"; }
warn()      { printf '    %s!%s %s\n' "$c_warn" "$c_off" "$*" >&2; }
die()       { printf '%sОШИБКА:%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }
done_step() { printf '%s✓ %s%s\n\n' "$c_ok" "$*" "$c_off"; }

# cfg <json-путь> [умолчание] — читает значение из config.json.
#   cfg .harnessTag           → "v0.1.6-alpha.2"
#   cfg .features.mobileBridge true
cfg() {
  local path="$1" fallback="${2-}"
  [ -f "$CONFIG" ] || { [ -n "$fallback" ] && { printf '%s' "$fallback"; return 0; }; die "нет $CONFIG (скопируйте config.example.json)"; }
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

# Путь Windows → путь WSL: F:\Harness_AI → /mnt/f/Harness_AI
winpath() {
  local p="${1//\\//}"
  local drive="${p%%:*}"
  printf '/mnt/%s%s' "$(printf '%s' "$drive" | tr 'A-Z' 'a-z')" "${p#*:}"
}

# Есть ли sudo без пароля / нужен ли apt вообще.
need_sudo_apt() {
  command -v git >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && return 1
  command -v sudo >/dev/null 2>&1 || die "нет sudo, а пакеты не установлены — поставьте git curl python3 вручную"
  return 0
}

export PATH="$HOME/.local/node/bin:$PATH"
