#!/usr/bin/env bash
# Create a project folder under ~/Harness_AI/projects with its handoff file
# already in place.
#
# WHY A SCRIPT AND NOT A RULE
#
# Everything else that keeps context cheap is global and carries to a new
# project by itself: the rules in ~/.dsh/AGENTS.md, the file-size and
# read-budget notices in the preset, the compaction settings, the sidebar
# preview patches. The ONE thing that does not carry is DECISIONS.md - a new
# folder has none, and the most valuable part of it (the map of which file owns
# which symbols) is exactly the part an agent skips writing when busy.
#
# Measured 2026-09-10: a project split into nine modules with no usable map cost
# 17 762 tokens of exploratory reading in a single session - 97% of a compaction
# cycle, and no better than the 18 423 of the one big file it replaced. Nine map
# lines cost about 150 tokens and answer the same question.
#
# So the skeleton is created up front, by hand, once. The agent fills the map as
# it writes files; the headings being already there is what makes that likely.
#
#   new-project.sh <name> [one-line description]
set -uo pipefail

NAME="${1:?give the project name}"
DESC="${2:-<one line: what it is>}"
ROOT="$HOME/Harness_AI/projects/$NAME"

if [ -e "$ROOT" ]; then
  echo "already exists: $ROOT"
  exit 1
fi

mkdir -p "$ROOT"

cat > "$ROOT/DECISIONS.md" <<EOF
# $NAME — $DESC

## Where the code is

<one row per file, listing the symbols a reader would grep for. Fill this in as
you create files - it is what stops the next session reading the whole tree.>

| module | owns |
|---|---|
| | |

## Decisions

- <decision in force> — <why>

## State

- Works: <nothing yet>
- Open: <what to do first>
EOF

echo "created $ROOT"
echo "  DECISIONS.md - a skeleton map, filled in as files appear"
echo
echo "Next: start an agent session with $ROOT as the working directory"
echo "(sidebar preview works for everything under ~/Harness_AI/projects)."
