#!/usr/bin/env bash
# Turn a project directory into its own git repository, ready for GitHub and
# without the litter the agent leaves beside the code.
#
#   bash project-git-init.sh ~/Harness_AI/projects/Cooking_APP
#   bash project-git-init.sh <directory> --remote git@github.com:user/repo.git
#
# It writes a .gitignore for the agent's working files (.shots/, backups/, out/,
# node_modules/, *.log), creates a repository on `main`, shows WHAT the first
# commit will contain and how big it is, and commits. It does not push: the
# remote and the moment to push are your decision.
#
# About restore points: turn-rewind keeps per-turn snapshots in
# refs/dsh-turn-rewind/... refs inside the project's repository. A normal
# `git push` does not send them, but `git push --mirror` would send everything,
# so a "branches only" refspec is set here explicitly; the points themselves are
# pruned with git-rewind-refs.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="${1:?give the project directory}"; shift || true
REMOTE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --remote) REMOTE="${2:?repository url}"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
DIR="$(cd "$DIR" && pwd)"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()  { printf '    \033[0;32m✓\033[0m %s\n' "$*"; }
warn(){ printf '    \033[0;33m!\033[0m %s\n' "$*" >&2; }

say "project: $DIR"

# The directory may sit inside another repository (the stand's, for instance).
# That is fine as long as the outer one ignores it - otherwise the files would
# land in two repositories at once.
outer=""
if outer="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" && [ "$outer" != "$DIR" ]; then
  if git -C "$outer" check-ignore -q "$DIR"; then
    ok "inside repository $outer, but that one ignores it - fine"
  else
    warn "the directory is tracked by repository $outer"
    warn "add it to that repository's .gitignore, or the files end up in two repositories at once"
  fi
fi

say ".gitignore for the agent's working files"
bash "$HERE/project-gitignore.sh" "$DIR" >/dev/null
ok "$(wc -l < "$DIR/.gitignore") lines"

cd "$DIR"
if [ -d .git ]; then
  ok "repository already here ($(git rev-list --count HEAD 2>/dev/null || echo 0) commits)"
else
  git init -q -b main
  ok "repository created on main"
fi

say "what the commit will contain"
git add -A
files=$(git diff --cached --name-only | wc -l)
bytes=$(git diff --cached --name-only -z | xargs -0 -r du -cb 2>/dev/null | tail -1 | cut -f1)
printf '    files: %s, size: %s\n' "$files" "$(numfmt --to=iec --suffix=B "${bytes:-0}" 2>/dev/null || echo "${bytes:-0} B")"
echo "    largest:"
git diff --cached --name-only -z | xargs -0 -r du -b 2>/dev/null | sort -rn | head -5 |
  while read -r size path; do printf '      %8s  %s\n' "$(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "$size")" "$path"; done
echo "    excluded by .gitignore:"
git status --porcelain --ignored | awk '$1=="!!"{print "      " $2}' | head -6

if git rev-parse HEAD >/dev/null 2>&1; then
  git diff --cached --quiet && { ok "nothing changed - no commit needed"; } || { git -c commit.gpgsign=false commit -q -m "Update"; ok "committed"; }
else
  git -c commit.gpgsign=false commit -q -m "First version"
  ok "first commit done"
fi

# Branches only: restore points and other internal refs never leave.
git config push.default simple
git config remote.origin.push 'refs/heads/*:refs/heads/*'

if [ -n "$REMOTE" ]; then
  git remote remove origin 2>/dev/null || true
  git remote add origin "$REMOTE"
  ok "remote: $REMOTE"
  echo
  echo "    push:  cd $DIR && git push -u origin main"
else
  echo
  echo "    next - create the repository on GitHub and push:"
  echo "      cd $DIR"
  echo "      gh repo create <name> --private --source=. --remote=origin --push"
  echo "    or by hand:"
  echo "      git remote add origin <url>"
  echo "      git push -u origin main"
fi
echo "    Do NOT use git push --mirror: it would send the plugin restore points too."
echo "    How many there are:  bash $HERE/git-rewind-refs.sh $DIR"
