#!/usr/bin/env bash
# Step 5: DSH settings - the route to the model, the agent preset, UI options.
#
# Everything is written from templates/ with values substituted from config.json.
# Existing user settings are not overwritten: a file without this installer's
# marker is kept beside the new one with a .before-install suffix.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

DSHDIR="${DSH_HOME:-$HOME/.dsh}"
STAND_DIR_ENV="${STAND_DIR:-$HOME/Harness_AI}/stand.env"
PROFILE="$DSHDIR/profiles/web"
STAND_SCRIPTS="${STAND_DIR:-$HOME/Harness_AI}/scripts"
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

# The same channel carries the read-before-edit rule. DSH refuses an edit of a
# file it has not seen the `read` tool open, and the shell does not count: the
# model that explores with `grep` and `sed -n` loses one call per file to that
# refusal, and one more whenever a `sed -i` invalidates a read it already had.
if [ -f "$TPL/agents-edit-ledger.md" ]; then
  agents="$DSHDIR/AGENTS.md"
  if ! grep -q 'dsh-local: edit-ledger-rule' "$agents" 2>/dev/null; then
    { [ -s "$agents" ] && printf '\n'; cat "$TPL/agents-edit-ledger.md"; } >> "$agents"
    ok 'edit/read rule added to AGENTS.md'
  else
    ok 'edit/read rule already in AGENTS.md'
  fi
fi

# And the same channel carries the path rule. A path the model retypes from its
# own failed call is the single most expensive loop on this stand: every retry
# fails identically, and the fs layer can only say the path is not there.
if [ -f "$TPL/agents-paths.md" ]; then
  agents="$DSHDIR/AGENTS.md"
  if ! grep -q 'dsh-local: path-copy-rule' "$agents" 2>/dev/null; then
    { [ -s "$agents" ] && printf '\n'; cat "$TPL/agents-paths.md"; } >> "$agents"
    ok 'path rule added to AGENTS.md'
  else
    ok 'path rule already in AGENTS.md'
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

# DSH 0.1.7 no longer DISCOVERS preset directories - the whole `.agent-presets`
# mechanism went with the `agent-presets` package. A preset is a row in the
# profile now, so the directory installed above has to be written into
# cordis.patch.yml or the mode menu offers only the four shipped presets. The
# script is a no-op on a host that still discovers directories, because the row
# it appends simply declares the same preset twice under one id.
if [ -f "$STAND_SCRIPTS/port-presets-to-profile.mjs" ]; then
  step 'writing the preset into the profile'
  DSH_HOME="$DSHDIR" node "$STAND_SCRIPTS/port-presets-to-profile.mjs" | sed 's/^/    /'
fi

step 'interface settings (settings.yaml)'
keep_old "$DSHDIR/settings.yaml"
if [ -f "$DSHDIR/settings.yaml" ] && grep -qF "$MARK" "$DSHDIR/settings.yaml"; then
  ok 'already applied - leaving them alone'
else
  subst "$TPL/settings.yaml.tmpl" > "$DSHDIR/settings.yaml"
  ok 'written'
fi

# Where the Windows side of the stand lives, in both spellings, for the scripts
# that run INSIDE WSL and have to reach it: start-web.sh and stop-web.sh carried
# the author's F: outright, so on any other drive the Power button in the web
# interface wrote its signal nowhere and the sleep timeouts were never touched.
step 'path to the Windows side (stand.env)'
WINROOT_RAW="$(cfg .windowsRoot 'F:\Harness_AI')"
{
  printf '# Written by the installer. Both spellings of the same folder.\n'
  printf 'WIN_ROOT_WSL=%s\n' "$(winpath "$WINROOT_RAW")"
  printf "WIN_ROOT_WIN='%s'\n" "$WINROOT_RAW"
} > "$STAND_DIR_ENV"
ok 'written: %s' "$STAND_DIR_ENV"

step 'chat template for llama-server'
WINROOT="$(winpath "$WINROOT_RAW")"
if [ -f "$TPL/chat-agent.jinja" ]; then
  # This said a bare "mkdir: Permission denied" when windowsRoot had fallen back
  # to the example's F: - creating a directory straight under /mnt needs root,
  # and the message named neither the path nor the reason. Probing beforehand is
  # no better: an unmounted drive leaves a root-owned stub at /mnt/<letter> that
  # is mode 777, so it looks both present and writable. Only the attempt tells.
  WINDRIVE="$(printf '%s' "$WINROOT" | cut -d/ -f3 | tr 'a-z' 'A-Z')"
  mkdir -p "$WINROOT/models" 2>/dev/null || {
    warn 'cannot create %s/models' "$WINROOT"
    warn 'that path means drive %s: on the Windows side' "$WINDRIVE"
    die 'check windowsRoot in config.json - and that drive %s: exists' "$WINDRIVE"
  }
  cp "$TPL/chat-agent.jinja" "$WINROOT/models/chat-agent.jinja"
  ok 'copied to %s/models/chat-agent.jinja' "$WINROOT"
else
  warn 'no chat template - the server falls back to the one baked into the model (context grows faster)'
fi

done_step 'settings ready'
