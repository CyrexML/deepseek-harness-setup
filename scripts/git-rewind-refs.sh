#!/usr/bin/env bash
# Restore points that the turn-rewind plugin keeps INSIDE YOUR REPOSITORY.
#
#   bash git-rewind-refs.sh [directory]              show how many there are
#   bash git-rewind-refs.sh [directory] --days 14    delete those older than 14 days
#   bash git-rewind-refs.sh [directory] --all        delete all of them
#
# What they are: before every turn that edits files the plugin takes a snapshot
# and stores it in a refs/dsh-turn-rewind/... ref of the repository containing the
# project. These are NOT branches (refs/heads) - a normal `git push` does not send
# them and `git branch` does not list them - but many interfaces show them next to
# branches, and the snapshot objects take space.
#
# The cost of deleting: that turn can no longer be rewound. So by default the
# script changes nothing, and --days keeps the recent ones.
set -euo pipefail
DIR="${1:-$PWD}"; [ "${DIR#--}" = "$DIR" ] || { DIR="$PWD"; set -- "$PWD" "$@"; }
shift || true
DAYS=""; ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="${2:?number of days}"; shift 2 ;;
    --all)  ALL=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

cd "$DIR"
git rev-parse --git-dir >/dev/null 2>&1 || { echo "$DIR is not a git repository"; exit 1; }
root="$(git rev-parse --show-toplevel)"
NS='refs/dsh-turn-rewind'

total=$(git for-each-ref --format='%(refname)' "$NS" | wc -l)
heads=$(git for-each-ref --format='%(refname)' refs/heads | wc -l)
echo "repository: $root"
echo "  branches (refs/heads):     $heads"
echo "  restore points ($NS): $total"
[ "$total" -eq 0 ] && exit 0

if [ -z "$DAYS" ] && [ "$ALL" -eq 0 ]; then
  echo
  echo "  oldest: $(git for-each-ref --sort=committerdate --format='%(committerdate:short)' "$NS" | head -1)"
  echo "  newest: $(git for-each-ref --sort=-committerdate --format='%(committerdate:short)' "$NS" | head -1)"
  echo "  repository objects: $(du -sh "$(git rev-parse --git-dir)/objects" | cut -f1)"
  echo
  echo "  delete old ones: bash git-rewind-refs.sh \"$root\" --days 14"
  echo "  delete all:      bash git-rewind-refs.sh \"$root\" --all"
  exit 0
fi

cutoff=0
[ -n "$DAYS" ] && cutoff=$(( $(date +%s) - DAYS * 86400 ))
deleted=0
while read -r ts ref; do
  [ "$ALL" -eq 1 ] || [ "$ts" -lt "$cutoff" ] || continue
  git update-ref -d "$ref"
  deleted=$((deleted + 1))
done < <(git for-each-ref --format='%(committerdate:unix) %(refname)' "$NS")

echo "  restore points deleted: $deleted"
if [ "$deleted" -gt 0 ]; then
  # The snapshots stay among the objects while anything holds them: without a
  # garbage collection the space does not come back.
  git reflog expire --expire=now --all >/dev/null 2>&1 || true
  git gc --prune=now --quiet 2>/dev/null || true
  echo "  objects after garbage collection: $(du -sh "$(git rev-parse --git-dir)/objects" | cut -f1)"
fi
