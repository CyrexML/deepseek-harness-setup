#!/usr/bin/env bash
# Уборка следов работы стенда. Без аргументов — только отчёт (ничего не трогает).
#   dsh-cleanup.sh                     отчёт: что и сколько занимает
#   dsh-cleanup.sh --apply [опции]     убрать по правилам ниже
#   --days N        сессии старше N дней (по mtime журнала) — в архив и удалить (умолч. 30)
#   --backup-days N  бэкапы в run/backups старше N дней — удалить (умолч. 90); run/backups/keep/
#                   не трогается никогда
#   --ledger-days N  журнал изменений (~/.dsh/change-ledger) старше N дней — удалить
#                   (умолч. 30). Это снимки файлов для отката хода: свежие нужны, старые
#                   просто занимают место (118 МБ на 2141 файл к 2026-09-23)
#   --caches        дополнительно почистить кэши пакетов (pnpm store, npm cache) — они не
#                   про DSH, но занимают гигабайты
#   --quiet         только итоговая строка
# Правила:
#  1. Сессии: только при ОСТАНОВЛЕННОМ web (иначе список в UI разъедется). Каталог
#     сессии + её projcache уходят в run/archive/sessions-<дата>.tar.gz (восстанавливается
#     распаковкой в ~/.dsh), затем удаляются. Архивы старше 90 дней удаляются.
#  2. Вложения (картинки/файлы из чатов, ~/.dsh/attachments, content-addressed sha256):
#     объект, на который не ссылается ни один оставшийся журнал сессии, удаляется.
#  3. run/backups: файлы старше --backup-days удаляются (2026-09-15: прежнее «оставить 15
#     свежих» стёрло llm-pi-ai-lib-index-*.js — счётчик слеп к важности); подкаталог keep/
#     (pristine-пакеты, снимки перед аудитом) не трогается никогда; run/verify — очистить;
#     web.log.prev — удалить; F:\Harness_AI\run\*.log старше 30 дней — удалить (archive/ не смотрим).
#  Не трогает: graph-memory (память агента), change-ledger (у turn-rewind своя ретенция),
#  профиль/плагины, модели.
set -euo pipefail
# Из лончера скрипт приходит через `wsl.exe -- bash -lc`, где PATH без node
# (.bashrc для неинтерактивного login-shell не читается) — добавляем явно.
export PATH="$HOME/.local/node/bin:/usr/local/bin:$PATH"
DSH="$HOME/.dsh"; RUN="$HOME/Harness_AI/run"; ARCH="$RUN/archive"; WINRUN=/mnt/f/Harness_AI/run
APPLY=0; DAYS=30; BDAYS=90; LDAYS=30; CACHES=0; QUIET=0
while [ $# -gt 0 ]; do case "$1" in
  --apply) APPLY=1;; --days) DAYS="$2"; shift;; --backup-days) BDAYS="$2"; shift;; --ledger-days) LDAYS="$2"; shift;; --caches) CACHES=1;; --quiet) QUIET=1;;
  *) echo "unknown arg $1"; exit 2;; esac; shift; done
say() { [ "$QUIET" = 1 ] || echo "$@"; }
mb() { du -sm "$1" 2>/dev/null | cut -f1; }
# Имя каталога сессии — путь рабочей области со слэшами, заменёнными на дефисы,
# в обрамлении "--". Для короткого вывода срезаем домашний префикс.
HOME_TAG="${HOME#/}"; HOME_TAG="${HOME_TAG//\//-}"
web_running() { pgrep -f 'apps/cli/lib/bin.js web' >/dev/null 2>&1; }

before=$(mb "$DSH")
say "== DSH data: ${before} MB (${DSH})"
say "   sessions     $(mb "$DSH/sessions") MB, $(find "$DSH/sessions" -name 'session.v2.jsonl.zstd' | wc -l) журналов"
find "$DSH/sessions" -maxdepth 1 -mindepth 1 -type d | while read -r d; do
  n=$(find "$d" -name 'session.v2.jsonl.zstd' | wc -l); old=$(find "$d" -name 'session.v2.jsonl.zstd' -mtime +"$DAYS" | wc -l)
  say "     $(printf '%3dM' "$(mb "$d")") $(basename "$d" | sed "s|^--${HOME_TAG}-||; s/--$//")  ($n сессий, старше $DAYS дн.: $old)"
done
say "   attachments  $(mb "$DSH/attachments") MB, $(find "$DSH/attachments" -type f | wc -l) файлов"
say "   projcache    $(mb "$DSH/storages") MB · graph-memory $(mb "$DSH/graph-memory") MB · change-ledger $(mb "$DSH/change-ledger") MB"
# Журнал изменений turn-rewind: снимки файлов на каждый ход. Своей ретенции у
# него нет, поэтому чистим по возрасту — откат остаётся возможен для недавних
# ходов, а старые снимки высвобождают место. Только при остановленном web:
# на живом стенде плагин может писать в те же каталоги.
LEDGER="$DSH/change-ledger"
if [ -d "$LEDGER" ]; then
  lsize=$(mb "$LEDGER")
  lold=$(find "$LEDGER" -type f -mtime +"$LDAYS" 2>/dev/null | wc -l)
  say "== журнал изменений: ${lsize} MB, файлов старше ${LDAYS} дн.: $lold"
  if [ "$APPLY" = 1 ] && [ "$lold" -gt 0 ]; then
    if web_running; then
      say "   пропускаю: web запущен (остановите стенд и повторите)"
    else
      find "$LEDGER" -type f -mtime +"$LDAYS" -delete 2>/dev/null
      find "$LEDGER" -type d -empty -delete 2>/dev/null
      say "   удалено файлов: $lold, стало $(mb "$LEDGER") MB"
    fi
  fi
fi

say "== run: backups $(mb "$RUN/backups") MB ($(ls "$RUN/backups" 2>/dev/null | wc -l) файлов) · verify $(mb "$RUN/verify" 2>/dev/null || echo 0) MB · archive $(mb "$ARCH" 2>/dev/null || echo 0) MB"
say "== кэши пакетов (не DSH): pnpm store $(mb "$HOME/.local/share/pnpm") MB · npm $(mb "$HOME/.npm") MB · ~/.cache $(mb "$HOME/.cache") MB"
[ "$APPLY" = 1 ] || { say "(отчёт; для уборки: --apply)"; exit 0; }

# ---- 1. сессии
if web_running; then
  say "!! web работает — сессии не трогаю (остановите стенд и повторите); остальное убираю"
else
  mapfile -t OLD < <(find "$DSH/sessions" -mindepth 2 -maxdepth 2 -name 'session.v2.jsonl.zstd' -mtime +"$DAYS" -printf '%h\n')
  if [ "${#OLD[@]}" -gt 0 ]; then
    mkdir -p "$ARCH"; tarf="$ARCH/sessions-$(date +%Y%m%d-%H%M).tar.gz"
    rel=(); for d in "${OLD[@]}"; do rel+=("${d#$DSH/}"); id=$(basename "$d"); pc="$DSH/storages/session_projcache/sessions/$id.json"; [ -f "$pc" ] && rel+=("${pc#$DSH/}"); done
    tar czf "$tarf" -C "$DSH" "${rel[@]}"
    for d in "${OLD[@]}"; do rm -rf "$d"; rm -f "$DSH/storages/session_projcache/sessions/$(basename "$d").json"; done
    say "сессии: ${#OLD[@]} старше $DAYS дн. → $tarf"
  else say "сессии: старше $DAYS дн. нет"; fi
  find "$ARCH" -name 'sessions-*.tar.gz' -mtime +90 -delete 2>/dev/null || true
fi

# ---- 2. вложения без ссылок
node - "$DSH" <<'JS' | { read -r n s; say "вложения: удалено $n файлов, $s MB (без ссылок из журналов)"; }
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

# ---- 3. бэкапы, verify, логи
if [ -d "$RUN/backups" ]; then
  n=$(find "$RUN/backups" -maxdepth 1 -type f -mtime +"$BDAYS" -print -delete | wc -l)
  say "бэкапы: удалено старше $BDAYS дн.: $n; осталось $(find "$RUN/backups" -maxdepth 1 -type f | wc -l) + keep/ $(ls "$RUN/backups/keep" 2>/dev/null | wc -l)"
fi
rm -rf "$RUN/verify"/* 2>/dev/null || true; rm -f "$RUN/web.log.prev"
[ -d "$WINRUN" ] && find "$WINRUN" -maxdepth 1 -name '*.log' -mtime +30 -delete 2>/dev/null || true
[ -f "$DSH/profiles/web/hub.log" ] && [ "$(stat -c %s "$DSH/profiles/web/hub.log")" -gt 5000000 ] && : > "$DSH/profiles/web/hub.log"

# ---- 4. кэши пакетов (по запросу)
if [ "$CACHES" = 1 ]; then
  command -v pnpm >/dev/null && pnpm store prune >/dev/null 2>&1 && say "pnpm store: prune"
  command -v npm >/dev/null && npm cache clean --force >/dev/null 2>&1 && say "npm cache: clean"
fi
echo "итог: DSH data ${before} → $(mb "$DSH") MB; pnpm store $(mb "$HOME/.local/share/pnpm") MB, npm $(mb "$HOME/.npm") MB"
