#!/usr/bin/env bash
# Step 5: DSH settings - the route to the model, the agent preset, UI options.
#
# Everything is written from templates/ with values substituted from config.json.
# Existing user settings are not overwritten: a file without this installer's
# marker is kept beside the new one with a .before-install suffix.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

DSHDIR="$HOME/.dsh"
PROFILE="$DSHDIR/profiles/web"
TPL="$ROOT/templates"
MARK="# harness-stand"

CTX="$(cfg .server.ctx 65536)"
MODEL_ID="$(cfg .model.id qwen38-27b-local)"
PRESET="local-${CTX}"
[ "$CTX" = "65536" ] && PRESET="local-64k"

keep_old() { # $1 = file
  [ -f "$1" ] || return 0
  grep -qF "$MARK" "$1" && return 0
  cp "$1" "$1.before-install"
  warn 'kept your %s as %s.before-install' "$(basename "$1")" "$(basename "$1")"
}

subst() { # template -> stdout
  sed -e "s|@CTX@|$CTX|g" -e "s|@MODEL_ID@|$MODEL_ID|g" -e "s|@PRESET@|$PRESET|g" "$1"
}

step 'route to the model (profiles/web/cordis.patch.yml)'
mkdir -p "$PROFILE"
keep_old "$PROFILE/cordis.patch.yml"
subst "$TPL/cordis.patch.yml.tmpl" > "$PROFILE/cordis.patch.yml"
ok 'model %s, window %s' "$MODEL_ID" "$CTX"

step 'agent preset (%s)' "$PRESET"
# The GPU rule goes into the agent's working rules. ~/.dsh/AGENTS.md is read at
# the start of every session, and it is the only channel that works when the
# model probes the machine before running anything - a launch-time notice only
# fires if a launch happened. Appended ONCE, by marker, leaving the rest alone.
if [ -f "$TPL/agents-gpu.md" ]; then
  agents="$DSHDIR/AGENTS.md"
  if ! grep -q 'dsh-local: gpu-work-rule' "$agents" 2>/dev/null; then
    { [ -s "$agents" ] && printf '\n'; cat "$TPL/agents-gpu.md"; } >> "$agents"
    ok 'GPU rule added to AGENTS.md'
  else
    ok 'GPU rule already in AGENTS.md'
  fi
fi

mkdir -p "$DSHDIR/.agent-presets"
if [ -d "$TPL/presets/local-64k" ]; then
  rm -rf "$DSHDIR/.agent-presets/$PRESET"
  cp -r "$TPL/presets/local-64k" "$DSHDIR/.agent-presets/$PRESET"
  # Compaction threshold and window size inside the preset must match the
  # server's -c. Substitution covers every preset file: besides the window and
  # the model they carry @HARNESS_DIR@, since preset modules import base classes
  # from the harness build by absolute path.
  HARNESS_DIR="${HARNESS_DIR:-$HOME/tools/deepseek-harness}"
  find "$DSHDIR/.agent-presets/$PRESET" -type f \( -name '*.yml' -o -name '*.mjs' \) -print0 |
    xargs -0 sed -i -e "s|@CTX@|$CTX|g" -e "s|@MODEL_ID@|$MODEL_ID|g" -e "s|@HARNESS_DIR@|$HARNESS_DIR|g"
  ok 'installed'
else
  warn 'no preset template - the stand will run on the built-in standard preset'
fi

step 'interface settings (settings.yaml)'
keep_old "$DSHDIR/settings.yaml"
if [ -f "$DSHDIR/settings.yaml" ] && grep -qF "$MARK" "$DSHDIR/settings.yaml"; then
  ok 'already applied - leaving them alone'
else
  subst "$TPL/settings.yaml.tmpl" > "$DSHDIR/settings.yaml"
  ok 'written'
fi

step 'chat template for llama-server'
WINROOT="$(winpath "$(cfg .windowsRoot 'F:\Harness_AI')")"
if [ -f "$TPL/chat-agent.jinja" ]; then
  mkdir -p "$WINROOT/models"
  cp "$TPL/chat-agent.jinja" "$WINROOT/models/chat-agent.jinja"
  ok 'copied to %s/models/chat-agent.jinja' "$WINROOT"
else
  warn 'no chat template - the server falls back to the one baked into the model (context grows faster)'
fi

done_step 'settings ready'
