#!/usr/bin/env bash
# Положить в рабочую область .gitignore, чтобы служебное не уезжало в репозиторий.
#
#   bash scripts/project-gitignore.sh <путь к проекту> [ещё проекты...]
#   bash scripts/project-gitignore.sh --all          все рабочие области стенда
#
# Что именно мешает при подключении проекта к GitHub (проверено на живых
# проектах 2026-09-23):
#   .shots/        снимки экрана, которые агент делает при проверке вёрстки
#   backups/       копии файлов перед крупной правкой
#   out/           выгрузки (PDF, картинки) из задач
#   node_modules/  зависимости
# Журнал изменений (тот, что виден в панели как «changes») в проекте НЕ лежит:
# он в ~/.dsh/change-ledger и в репозиторий не попадает; его размер чистится
# командой `scripts/dsh-cleanup.sh --apply --ledger-days 30`.
#
# Существующий .gitignore не перезаписывается: недостающие строки дописываются
# в конец под своим заголовком.
set -euo pipefail

MARK='# --- harness stand ---'
BLOCK="$MARK
.shots/
backups/
out/
node_modules/
*.log
"

add_to() {
  local dir="$1"
  [ -d "$dir" ] || { echo "нет каталога: $dir" >&2; return 1; }
  local file="$dir/.gitignore"
  if [ -f "$file" ] && grep -qF "$MARK" "$file"; then
    echo "$dir — уже есть"
    return 0
  fi
  if [ -f "$file" ]; then
    printf '\n%s' "$BLOCK" >> "$file"
    echo "$dir — дописано в существующий .gitignore"
  else
    printf '%s' "$BLOCK" > "$file"
    echo "$dir — создан .gitignore"
  fi
}

if [ "${1:-}" = "--all" ]; then
  ws="$HOME/.dsh/storages/workspace.json"
  [ -f "$ws" ] || { echo "нет $ws" >&2; exit 1; }
  export PATH="$HOME/.local/node/bin:$PATH"
  node -e '
    const fs = require("node:fs");
    const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const rows = Object.values(data?.tables?.workspaces ?? {});
    for (const row of rows) if (typeof row.path === "string") console.log(row.path);
  ' "$ws" | while read -r dir; do add_to "$dir" || true; done
  exit 0
fi

[ $# -gt 0 ] || { sed -n '2,20p' "$0"; exit 2; }
for dir in "$@"; do add_to "$dir"; done
