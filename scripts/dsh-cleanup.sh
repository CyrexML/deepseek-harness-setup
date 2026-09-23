#!/usr/bin/env bash
# Clean up after the stand. With no arguments it only reports and touches nothing.
#   dsh-cleanup.sh                     report: what is there and how big it is
#   dsh-cleanup.sh --apply [options]   clean according to the rules below
#   --days N         sessions older than N days (by journal mtime) - archived and
#                    removed (default 30)
#   --backup-days N  files in run/backups older than N days - removed (default 90);
#                    run/backups/keep/ is never touched
#   --ledger-days N  the change ledger (~/.dsh/change-ledger) older than N days -
#                    removed (default 30). These are per-turn file snapshots for
#                    rewinding: recent ones are needed, old ones only take space
#   --bench-days N   benchmark working directories (~/Harness_AI/bench/*/repo,
#                    pristine, tools, run*-*, bench/results) older than N days -
#                    removed. Run summaries stay and anything tracked by git is
#                    left alone. Off by default
#   --caches         also clean package caches (pnpm store, npm cache) - not part
#                    of DSH, but they take gigabytes
#   --quiet          print the summary line only
# Rules:
#  1. Sessions: only while the web is STOPPED (otherwise the list in the UI goes
#     out of sync). The session directory and its projcache go into
#     run/archive/sessions-<date>.tar.gz (restored by unpacking into ~/.dsh) and
#     are then removed. Archives older than 90 days are deleted.
#  2. Attachments (images and files from chats, ~/.dsh/attachments, addressed by
#     sha256): an object no remaining session journal refers to is removed.
#  3. run/backups: files older than --backup-days are removed (a previous "keep
#     the 15 newest" rule once deleted a file that mattered - a counter is blind
#     to importance); the keep/ subdirectory is never touched; run/verify is
#     emptied; web.log.prev is removed; Windows-side run/*.log older than 30 days
#     is removed.
#  Not touched: graph-memory (agent memory), the profile and its plugins, models.
set -euo pipefail
# From the launcher this arrives through `wsl.exe -- bash -lc`, where PATH has no
# node (.bashrc is not read for a non-interactive login shell) - add it here.
export PATH="$HOME/.local/node/bin:/usr/local/bin:$PATH"
DSH="$HOME/.dsh"; RUN="$HOME/Harness_AI/run"; ARCH="$RUN/archive"; WINRUN=/mnt/f/Harness_AI/run
APPLY=0; DAYS=30; BDAYS=90; LDAYS=30; BENCHDAYS=""; CACHES=0; QUIET=0
while [ $# -gt 0 ]; do case "$1" in
  --apply) APPLY=1;; --days) DAYS="$2"; shift;; --backup-days) BDAYS="$2"; shift;; --ledger-days) LDAYS="$2"; shift;; --bench-days) BENCHDAYS="$2"; shift;; --caches) CACHES=1;; --quiet) QUIET=1;;
  *) echo "unknown arg $1"; exit 2;; esac; shift; done
say() { [ "$QUIET" = 1 ] || echo "$@"; }
mb() { du -sm "$1" 2>/dev/null | cut -f1; }
# A session directory is named after the workspace path with slashes replaced by
# dashes and wrapped in "--". Strip the home prefix to keep the output short.
HOME_TAG="${HOME#/}"; HOME_TAG="${HOME_TAG//\//-}"
web_running() { pgrep -f 'apps/cli/lib/bin.js web' >/dev/null 2>&1; }

before=$(mb "$DSH")
say "== DSH data: ${before} MB (${DSH})"
say "   sessions     $(mb "$DSH/sessions") MB, $(find "$DSH/sessions" -name 'session.v2.jsonl.zstd' | wc -l) journals"
find "$DSH/sessions" -maxdepth 1 -mindepth 1 -type d | while read -r d; do
  n=$(find "$d" -name 'session.v2.jsonl.zstd' | wc -l); old=$(find "$d" -name 'session.v2.jsonl.zstd' -mtime +"$DAYS" | wc -l)
  say "     $(printf '%3dM' "$(mb "$d")") $(basename "$d" | sed "s|^--${HOME_TAG}-||; s/--$//")  ($n sessions, older than $DAYS days: $old)"
done
say "   attachments  $(mb "$DSH/attachments") MB, $(find "$DSH/attachments" -type f | wc -l) files"
say "   projcache    $(mb "$DSH/storages") MB · graph-memory $(mb "$DSH/graph-memory") MB · change-ledger $(mb "$DSH/change-ledger") MB"
BENCH="$HOME/Harness_AI/bench"
[ -d "$BENCH" ] && say "   benchmarks   $(mb "$BENCH") MB (bench/; cleaned only with --bench-days)"

# Benchmarks: working copies of the tasks and run outputs. They are measurement
# results and take more space than everything else together. Only what git does
# not track is removed: otherwise the directory would vanish from the working
# copy and turn into a pile of deletions in the changes panel.
if [ -n "$BENCHDAYS" ] && [ -d "$BENCH" ]; then
  freed=0
  while IFS= read -r -d "" d; do
    rel="${d#$HOME/Harness_AI/}"
    [ -z "$(git -C "$HOME/Harness_AI" ls-files -- "$rel" 2>/dev/null | head -1)" ] || continue
    sz=$(du -sm "$d" 2>/dev/null | cut -f1)
    if [ "$APPLY" = 1 ]; then rm -rf "$d"; fi
    freed=$((freed + ${sz:-0}))
  done < <(find "$BENCH" -maxdepth 2 -type d \( -name repo -o -name pristine -o -name tools -o -name results -o -name "run[0-9]*-[0-9]*" \) -mtime "+$BENCHDAYS" -print0 2>/dev/null)
  if [ "$APPLY" = 1 ]; then say "   benchmarks:  freed ${freed} MB"; else say "   benchmarks:  would free ${freed} MB (older than ${BENCHDAYS} days)"; fi
fi
# The turn-rewind change ledger: per-turn file snapshots with no retention of its
# own, so it is cleaned by age - recent turns stay rewindable and old snapshots
# give the space back. Only while the web is stopped: on a live stand the plugin
# may be writing into the same directories.
LEDGER="$DSH/change-ledger"
if [ -d "$LEDGER" ]; then
  lsize=$(mb "$LEDGER")
  lold=$(find "$LEDGER" -type f -mtime +"$LDAYS" 2>/dev/null | wc -l)
  say "== change ledger: ${lsize} MB, files older than ${LDAYS} days: $lold"
  if [ "$APPLY" = 1 ] && [ "$lold" -gt 0 ]; then
    if web_running; then
      say "   skipped: the web is running (stop the stand and repeat)"
    else
      find "$LEDGER" -type f -mtime +"$LDAYS" -delete 2>/dev/null
      find "$LEDGER" -type d -empty -delete 2>/dev/null
      say "   removed $lold files, now $(mb "$LEDGER") MB"
    fi
  fi
fi

say "== run: backups $(mb "$RUN/backups") MB ($(ls "$RUN/backups" 2>/dev/null | wc -l) files) . verify $(mb "$RUN/verify" 2>/dev/null || echo 0) MB · archive $(mb "$ARCH" 2>/dev/null || echo 0) MB"
say "== package caches (not DSH): pnpm store $(mb "$HOME/.local/share/pnpm") MB · npm $(mb "$HOME/.npm") MB · ~/.cache $(mb "$HOME/.cache") MB"
[ "$APPLY" = 1 ] || { say "(report only; to clean: --apply)"; exit 0; }

# ---- 1. sessions
if web_running; then
  say "!! the web is running - sessions left alone (stop the stand and repeat); cleaning the rest"
else
  mapfile -t OLD < <(find "$DSH/sessions" -mindepth 2 -maxdepth 2 -name 'session.v2.jsonl.zstd' -mtime +"$DAYS" -printf '%h\n')
  if [ "${#OLD[@]}" -gt 0 ]; then
    mkdir -p "$ARCH"; tarf="$ARCH/sessions-$(date +%Y%m%d-%H%M).tar.gz"
    rel=(); for d in "${OLD[@]}"; do rel+=("${d#$DSH/}"); id=$(basename "$d"); pc="$DSH/storages/session_projcache/sessions/$id.json"; [ -f "$pc" ] && rel+=("${pc#$DSH/}"); done
    tar czf "$tarf" -C "$DSH" "${rel[@]}"
    for d in "${OLD[@]}"; do rm -rf "$d"; rm -f "$DSH/storages/session_projcache/sessions/$(basename "$d").json"; done
    say "sessions: ${#OLD[@]} older than $DAYS days -> $tarf"
  else say "sessions: none older than $DAYS days"; fi
  find "$ARCH" -name 'sessions-*.tar.gz' -mtime +90 -delete 2>/dev/null || true
fi

# ---- 2. unreferenced attachments
node - "$DSH" <<'JS' | { read -r n s; say "attachments: removed $n files, $s MB (unreferenced by any journal)"; }
const { readdirSync, readFileSync, statSync, unlinkSync, rmSync } = require('node:fs');
const { join } = require('node:path');
const zlib = require('node:zlib');
const DSH = process.argv[2];
const refs = new Set();
const walk = (d, out = []) => { for (const e of readdirSync(d, { withFileTypes: true })) { const p = join(d, e.name); e.isDirectory() ? walk(p, out) : out.push(p); } return out; };
for (const f of walk(join(DSH, 'sessions')).filter(p => p.endsWith('.jsonl.zstd'))) {
  try { // multi-frame zstd: decode frame by frame
    let buf = readFileSync(f), off = 0, text = '';
    while (off < buf.length) { const rest = buf.subarray(off); const dec = zlib.zstdDecompressSync(rest, { info: true }); text += dec.buffer.toString('utf8'); off += dec.engine.bytesWritten; }
    for (const m of text.matchAll(/sha256:([0-9a-f]{64})/g)) refs.add(m[1]);
  } catch { /* unreadable log: keep every attachment rather than guess */ process.stdout.write('0 0\n'); process.exit(0); }
}
let n = 0, bytes = 0;
for (const sub of ['objects', 'file-objects']) {
  const root = join(DSH, 'attachments', 'v1', sub); let files = []; try { files = walk(root); } catch { continue; }
  for (const p of files) { const h = p.split('/').pop(); if (refs.has(h)) continue; const st = statSync(p); if (Date.now() - st.mtimeMs < 86400000) continue; bytes += st.size; unlinkSync(p); n++;
    if (sub === 'file-objects') { try { rmSync(join(DSH, 'attachments', 'v1', 'files', h.slice(0, 2), h), { recursive: true, force: true }); } catch {} } }
}
process.stdout.write(`${n} ${(bytes / 1048576).toFixed(1)}\n`);
JS

# ---- 3. backups, verify, logs
if [ -d "$RUN/backups" ]; then
  n=$(find "$RUN/backups" -maxdepth 1 -type f -mtime +"$BDAYS" -print -delete | wc -l)
  say "backups: removed older than $BDAYS days: $n; left $(find "$RUN/backups" -maxdepth 1 -type f | wc -l) + keep/ $(ls "$RUN/backups/keep" 2>/dev/null | wc -l)"
fi
rm -rf "$RUN/verify"/* 2>/dev/null || true; rm -f "$RUN/web.log.prev"
[ -d "$WINRUN" ] && find "$WINRUN" -maxdepth 1 -name '*.log' -mtime +30 -delete 2>/dev/null || true
[ -f "$DSH/profiles/web/hub.log" ] && [ "$(stat -c %s "$DSH/profiles/web/hub.log")" -gt 5000000 ] && : > "$DSH/profiles/web/hub.log"

# ---- 4. package caches (on request)
if [ "$CACHES" = 1 ]; then
  command -v pnpm >/dev/null && pnpm store prune >/dev/null 2>&1 && say "pnpm store: prune"
  command -v npm >/dev/null && npm cache clean --force >/dev/null 2>&1 && say "npm cache: clean"
fi
echo "total: DSH data ${before} -> $(mb "$DSH") MB; pnpm store $(mb "$HOME/.local/share/pnpm") MB, npm $(mb "$HOME/.npm") MB"
