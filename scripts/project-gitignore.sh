#!/usr/bin/env bash
# Give a workspace a .gitignore so the agent's working litter stays out of git.
#
#   bash scripts/project-gitignore.sh <project path> [more projects...]
#   bash scripts/project-gitignore.sh --all          every workspace of the stand
#
# What actually gets in the way when a project goes to GitHub:
#   .shots/        screenshots the agent takes while checking a layout
#   backups/       copies of files made before a large edit
#   out/           exports (PDFs, images) produced by tasks
#   node_modules/  dependencies
# The change ledger (what the panel shows as "changes") is NOT in the project: it
# lives in ~/.dsh/change-ledger, never reaches a repository, and is trimmed with
# `scripts/dsh-cleanup.sh --apply --ledger-days 30`.
#
# An existing .gitignore is not overwritten: missing lines are appended under
# their own heading.
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
  [ -d "$dir" ] || { echo "no such directory: $dir" >&2; return 1; }
  local file="$dir/.gitignore"
  if [ -f "$file" ] && grep -qF "$MARK" "$file"; then
    echo "$dir - already there"
    return 0
  fi
  if [ -f "$file" ]; then
    printf '\n%s' "$BLOCK" >> "$file"
    echo "$dir - appended to the existing .gitignore"
  else
    printf '%s' "$BLOCK" > "$file"
    echo "$dir - .gitignore created"
  fi
}

if [ "${1:-}" = "--all" ]; then
  ws="$HOME/.dsh/storages/workspace.json"
  [ -f "$ws" ] || { echo "no $ws" >&2; exit 1; }
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
