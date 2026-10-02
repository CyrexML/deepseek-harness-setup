#!/usr/bin/env bash
# Self-check of the stand's patch layers before DSH starts (called from
# start-web.sh; can also be run by hand: ensure-patches.sh [--check]).
#
# A plugin update (Plugin Hub -> Update = `pnpm add <pkg>@latest`) or a harness
# `pnpm build` silently wipes the edits. Every layer is identified by a marker,
# a missing one is re-applied by its own toolchain (all idempotent), and the
# result is one line per layer. Does nothing when every marker is in place.
# --check only reports and exits 1 when something is missing.
#
# Layers and their markers:
#   bridge        client/index.js   "dsh-bridge-en:"            projects/PlugIN/dsh-bridge-en/translate.sh
#   turn-rewind   lib/client.js     "/* dsh-turn-rewind-en */"  projects/PlugIN/dsh-turn-rewind-en/translate.mjs
#   better-sidebar lib/index.js     "DSH_PREVIEW_TRUSTED_ROOTS"  scripts/patch-sidebar.sh (decision-14)
#   llm-pi-ai     lib/index.js      "dsh-local: replay usage"   scripts/patch-llm-pi-ai-usage.mjs
#   graph-memory  dist/dsh.js       "dsh-local: workspace-scoped recall"  scripts/patch-graph-memory-scope.mjs
#   ui-conversation lib/client.js   "dsh-local: eager image read"   scripts/patch-ui-conversation-eager-read.mjs (harness, not the profile)
#   sidebar-slot-id  lib/client.js   "dsh-local: turnTail slot id"  scripts/patch-better-sidebar-slot-id.mjs (DSH 0.1.6+ compatibility)
#   univer-slot-id   lib/client.js   "dsh-local: turnTail slot id"  scripts/patch-univer-slot-id.mjs (same)
#   sidebar-session-sync lib/client.js "dsh-local: session sync" scripts/patch-better-sidebar-session-sync.mjs (file click on 0.1.6)
#   fs-edit-tolerant fs-local/lib/index.js "dsh-local: tolerant edit match"  scripts/patch-fs-edit-tolerant.mjs (harness, not the profile)
#   fs-missing-path tool-fs/lib/index.js "dsh-local: missing path before unread"  scripts/patch-fs-missing-path.mjs (harness, not the profile)
#   sidebar-binary-handoff lib/client.js "dsh-local: binary handoff" scripts/patch-better-sidebar-binary-handoff.mjs (pdf/office to the native viewers)
#
# The bridge's translate.sh calls the local model for strings it does not know
# yet, which is why start-web.sh runs this AFTER checking that llama-server
# answers. With no model available translate.sh warns and leaves the untranslated
# strings in tools/todo.json.
set -uo pipefail
export PATH="$HOME/.local/node/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
# DSH_HOME, the same way DSH_ROOT is overridable below: without it a second
# stand built beside the working one would have its plugin layers applied to the
# WORKING profile, because this path was pinned to $HOME/.dsh outright.
NM="${DSH_HOME:-$HOME/.dsh}/profiles/web/node_modules"
DSH_ROOT="${DSH_ROOT:-$HOME/tools/deepseek-harness}"
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
missing=0

# layer <name> <file> <marker> <command...>
layer() {
  local name="$1" file="$2" mark="$3"; shift 3
  if [ ! -f "$file" ]; then echo "patches: $name - file missing ($file), skipped"; return; fi
  if grep -qF -- "$mark" "$file"; then echo "patches: $name - ok"; return; fi
  if [ "$CHECK" = 1 ]; then echo "patches: $name - MISSING"; missing=1; return; fi
  echo "patches: $name - marker absent, applying: $*"
  if "$@" >"/tmp/ensure-$name.log" 2>&1 && grep -qF -- "$mark" "$file"; then
    echo "patches: $name - applied"
  else
    echo "patches: $name - FAILED, see /tmp/ensure-$name.log"; missing=1
  fi
}

# The Exa search provider is built in the harness but absent from the base
# bundle's dependencies (only web-search-deepseek is declared there), so the
# loader cannot resolve it. Two symlinks put it where both resolution anchors
# look: next to the bundle's own copy, and in the profile, because a row
# declared in the PROFILE patch resolves against the profile. A `pnpm install`
# in the harness removes them, which is why this runs on every start.
# Harmless when the row is not used: an unresolvable link is simply not loaded.
link_pkg() {
  local name="$1" target="$2" dir
  for dir in "$DSH_ROOT/packages/bundle/base/node_modules/@deepseek-ai" "$NM/@deepseek-ai"; do
    [ -d "$dir" ] || continue
    if [ -e "$dir/$name" ] && [ "$(readlink -f "$dir/$name")" = "$(readlink -f "$target")" ]; then continue; fi
    ln -sfn "$target" "$dir/$name" && echo "patches: link $name -> $(basename "$dir") - relinked"
  done
}
link_pkg dsh-web-search-exa "$DSH_ROOT/packages/web/web-search-exa"

# The plugin directory is passed EXPLICITLY. translate.sh falls back to
# $HOME/.dsh, so without it a stand built with DSH_HOME pointed its translation
# run at the WORKING profile - where the abort guard stopped it, leaving the new
# profile untranslated while the layer looked fine.
#
# The marker is the abort guard's own string, not the bare "dsh-bridge-en:"
# prefix: eight later layers write that prefix too, so a failed translation was
# reported as ok as soon as any of them had applied - and the translation, power
# button, splash screen, icon and rotation fix were silently absent.
layer bridge "$NM/@wenbin_wb/dsh-bridge/client/index.js" "dsh-bridge-en: better-sidebar mobile fix" \
  bash "$HOME/Harness_AI/projects/PlugIN/dsh-bridge-en/translate.sh" "$NM/@wenbin_wb/dsh-bridge"
# client.js is built by the last step of translate.sh: if a patch landed after
# that build, the bundle is stale while the marker is present (see
# scripts/bridge-rebuild-client.sh).
bash "$HERE/bridge-rebuild-client.sh" "$NM/@wenbin_wb/dsh-bridge" || missing=1

layer turn-rewind "$NM/@anionex/dsh-turn-rewind/lib/client.js" "/* dsh-turn-rewind-en */" \
  node "$HOME/Harness_AI/projects/PlugIN/dsh-turn-rewind-en/translate.mjs"
layer better-sidebar "$NM/dsh-better-sidebar/lib/index.js" "DSH_PREVIEW_TRUSTED_ROOTS" \
  bash "$HERE/patch-sidebar.sh"
# pi-ai hands the model max(1, window - estimate - 4096) tokens of room, and the
# estimate is anchored on the previous response's usage - which graph-memory
# invalidates whenever it archives history between turns. Measured: four of six
# turns in one session ended on max-tokens, two of them after producing a single
# token with a real prompt of 10K and 16K against a 65K window. The floor turns
# that into a short answer instead of a dead turn. Path carries a pnpm hash, so
# it is resolved rather than written out.
PIAI="$(ls -d "$DSH_ROOT"/node_modules/.pnpm/@earendil-works+pi-ai@*/node_modules/@earendil-works/pi-ai/dist/api/simple-options.js 2>/dev/null | head -1)"
if [ -n "$PIAI" ]; then
  layer pi-ai-budget-floor "$PIAI" "dsh-local: output budget floor" \
    node "$HERE/patch-pi-ai-budget-floor.mjs" "$PIAI"
fi

layer llm-pi-ai "$DSH_ROOT/packages/llm/llm-pi-ai/lib/index.js" "dsh-local: replay usage" \
  node "$HERE/patch-llm-pi-ai-usage.mjs"
# Session format v4 refuses a message whose source.kind is "plugin" and fails the
# WHOLE turn; graph-memory still stamps the retired shape, in four places that
# each fire in their own circumstance - the recall snapshot, the extraction
# request, the per-turn trace, the compaction archive marker.
#
# NOT a marker-gated layer on purpose. The marker would sit in whichever file was
# named, and a site in ANOTHER file would then be skipped for as long as that
# marker survived - which is exactly how the second and third of these reached a
# failed turn. The script sweeps every file under dist/ and asserts that no
# retired shape is left, so it is safe and cheap to run every time; a non-zero
# exit refuses the start the same way a missing layer does.
if [ -d "$NM/graph-memory" ]; then
  node "$HERE/patch-graph-memory-source-kind.mjs" "$NM/graph-memory" | sed 's/^/patches: /' || missing=1
fi

layer graph-memory "$NM/graph-memory/dist/dsh.js" "dsh-local: workspace-scoped recall" \
  node "$HERE/patch-graph-memory-scope.mjs"
layer ui-conversation "$DSH_ROOT/packages/client/ui-conversation/lib/client.js" "dsh-local: eager image read" \
  node "$HERE/patch-ui-conversation-eager-read.mjs"
layer fs-edit-tolerant "$DSH_ROOT/packages/fs/fs-local/lib/index.js" "dsh-local: tolerant edit match" \
  node "$HERE/patch-fs-edit-tolerant.mjs" "$DSH_ROOT"
layer fs-missing-path "$DSH_ROOT/packages/fs/tool-fs/lib/index.js" "dsh-local: missing path before unread" \
  node "$HERE/patch-fs-missing-path.mjs" "$DSH_ROOT"
layer pdfjs-map-polyfill "$DSH_ROOT/packages/client/ui-sidebar-documentpreview/lib/client.pdf.js" "dsh-local: Map.getOrInsert polyfill" \
  node "$HERE/patch-pdfjs-map-polyfill.mjs"
layer zoom-scope "$NM/@wenbin_wb/dsh-bridge/client/mobile-styles.js" "dsh-bridge-en: zoom scope" \
  node "$HOME/Harness_AI/projects/PlugIN/dsh-bridge-en/tools/patch-zoom-scope.mjs" "$NM/@wenbin_wb/dsh-bridge"
layer header-sidebar-btn "$NM/@wenbin_wb/dsh-bridge/client/index.js" "dsh-bridge-en: header sidebar button removed" \
  node "$HOME/Harness_AI/projects/PlugIN/dsh-bridge-en/tools/patch-header-sidebar-btn.mjs" "$NM/@wenbin_wb/dsh-bridge"
layer mobile-ux "$NM/@wenbin_wb/dsh-bridge/client/mobile-styles.js" "dsh-bridge-en: mobile ux" \
  node "$HOME/Harness_AI/projects/PlugIN/dsh-bridge-en/tools/patch-mobile-ux.mjs" "$NM/@wenbin_wb/dsh-bridge"
layer preview-zoom "$NM/@wenbin_wb/dsh-bridge/client/mobile-styles.js" "dsh-bridge-en: preview zoom" \
  node "$HOME/Harness_AI/projects/PlugIN/dsh-bridge-en/tools/patch-preview-zoom.mjs" "$NM/@wenbin_wb/dsh-bridge"
layer touch-ui-gate "$NM/@wenbin_wb/dsh-bridge/client/mobile-styles.js" "dsh-bridge-en: touch ui gate" \
  node "$HOME/Harness_AI/projects/PlugIN/dsh-bridge-en/tools/patch-touch-ui-gate.mjs" "$NM/@wenbin_wb/dsh-bridge"
layer load-monitor "$NM/@wenbin_wb/dsh-bridge/client/index.js" "dsh-bridge-en: load monitor" \
  node "$HOME/Harness_AI/projects/PlugIN/dsh-bridge-en/tools/patch-load-monitor.mjs" "$NM/@wenbin_wb/dsh-bridge"
layer mobile-input "$NM/@wenbin_wb/dsh-bridge/client/index.js" "dsh-bridge-en: mobile input" \
  node "$HOME/Harness_AI/projects/PlugIN/dsh-bridge-en/tools/patch-mobile-input.mjs" "$NM/@wenbin_wb/dsh-bridge"
layer mobile-attach "$NM/@wenbin_wb/dsh-bridge/client/index.js" "dsh-bridge-en: mobile attach" \
  node "$HOME/Harness_AI/projects/PlugIN/dsh-bridge-en/tools/patch-mobile-attach.mjs" "$NM/@wenbin_wb/dsh-bridge"
layer mobile-back "$NM/@wenbin_wb/dsh-bridge/client/index.js" "dsh-bridge-en: mobile back" \
  node "$HOME/Harness_AI/projects/PlugIN/dsh-bridge-en/tools/patch-mobile-back.mjs" "$NM/@wenbin_wb/dsh-bridge"
layer html-no-store "$NM/@wenbin_wb/dsh-bridge/lib/index.js" "dsh-bridge-en: html no-store" \
  node "$HOME/Harness_AI/projects/PlugIN/dsh-bridge-en/tools/patch-html-no-store.mjs" "$NM/@wenbin_wb/dsh-bridge"

# DSH 0.1.7 removed the `settingsScope` service, and the plugin still lists it as
# a REQUIRED client dependency - so it never activates, and one pending entry
# blocks the whole client ("Failed to load plugins", blank page). Its own code
# already guards the call with `?.`, so only the dependency list was wrong.
# A no-op on 0.1.6, where the service still exists.
# Registered ONLY on a host without the service. Declaring it unconditionally
# made --check report it MISSING on 0.1.6 - and start-web.sh refuses to start a
# stand with an incomplete layer set, so the working stand would not have come up.
if [ ! -f "$DSH_ROOT/packages/client/ui-settings/src/client/settings-scope.ts" ]; then
  layer turn-rewind-settings "$NM/@anionex/dsh-turn-rewind/lib/client.js" "dsh-local: settingsScope optional" \
    node "$HERE/patch-turn-rewind-settings-optional.mjs" "$NM/@anionex/dsh-turn-rewind"
fi

# The next four layers are RETIRED on builds that carry the fix upstream has
# since adopted. A layer whose anchor is gone for good can never apply again:
# --check reports MISSING for ever and start-web.sh refuses to boot the stand.
# The probes below are things our own patches never remove, so a plugin
# downgrade (or a pnpm reinstall that drops the patch) brings the layer back.

# better-sidebar up to 0.19.x drew its own panel through the
# `conversation.chat.turnTail` slot, and all three layers exist because of that:
# the list-slot contract needs an `id` (slot-id), the panel never mounted so the
# active session had to be found another way (session-sync), and the plugin
# claimed .pdf/.xlsx it could not draw (binary-handoff). 0.22.1 registers
# `sidebar.right.pane.tab` instead - it is a tab of the NATIVE right sidebar,
# with its own `canOpen` that hands host-owned paths back and its own pdf.js
# rendering. Verified live on the 0.1.7 stand: the explorer lists the workspace
# and a click on DECISIONS.md opens a rendered tab, which is precisely what
# session-sync existed to fix.
if grep -qF 'conversation.chat.turnTail' "$NM/dsh-better-sidebar/lib/client.js" 2>/dev/null; then
  layer sidebar-slot-id "$NM/dsh-better-sidebar/lib/client.js" "dsh-local: turnTail slot id" \
    node "$HERE/patch-better-sidebar-slot-id.mjs"
  layer sidebar-session-sync "$NM/dsh-better-sidebar/lib/client.js" "dsh-local: session sync" \
    node "$HERE/patch-better-sidebar-session-sync.mjs"
  layer sidebar-binary-handoff "$NM/dsh-better-sidebar/lib/client.js" "dsh-local: binary handoff" \
    node "$HERE/patch-better-sidebar-binary-handoff.mjs"
fi

# dsh-univer-office 0.3.5 took the same fix verbatim - `id: "univer-turn-preview"`
# with a comment citing the 0.1.6-alpha.2 list-slot contract, plus a fallback to
# the old chain form for older hosts. Our marker is checked first: on 0.3.2 the
# id is there only because we put it there, and that layer must stay verified.
if grep -qF 'dsh-local: turnTail slot id' "$NM/dsh-univer-office/lib/client.js" 2>/dev/null \
   || ! grep -qF 'id: "univer-turn-preview"' "$NM/dsh-univer-office/lib/client.js" 2>/dev/null; then
  layer univer-slot-id "$NM/dsh-univer-office/lib/client.js" "dsh-local: turnTail slot id" \
    node "$HERE/patch-univer-slot-id.mjs"
fi
layer sidebar-relative-path "$NM/dsh-better-sidebar/lib/client.js" "dsh-local: relative path in chat links" \
  node "$HERE/patch-better-sidebar-relative-path.mjs"

exit $missing
