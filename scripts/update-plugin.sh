#!/usr/bin/env bash
# Аккуратное обновление одного плагина профиля: бэкап → установка → патчи →
# перезапуск → проверки. По шагам, с остановкой на первой же ошибке.
#
#   bash scripts/update-plugin.sh <пакет>@<версия> [ещё пакет@версия ...]
#   bash scripts/update-plugin.sh --rollback <каталог-бэкапа>
#
# Что делает (README §5):
#   1. Снимает бэкап profile/{package.json,pnpm-workspace.yaml,cordis.patch.yml,
#      gro.ngilp-hsd-versions.json} + пропатченные файлы плагинов в run/backups/keep/profile-<ts>/.
#   2. `pnpm add` (переустановка пакета; соседние пакеты могут откатиться к
#      store-версии — патчи вернёт шаг 3).
#   3. ensure-patches.sh — переприменяет все слои; при MATCH COUNT ≠ 1 патч
#      не лёг (якорь уехал в новой версии) → скрипт падает, откатывайтесь.
#   4. Перезапуск web (новый бандл подхватывается только на рестарте).
#   5. ensure-patches.sh --check, bridge-verify.mjs, check-chat-template.sh.
set -uo pipefail
export PATH="$HOME/.local/node/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
PROFILE="$HOME/.dsh/profiles/web"
KEEP="$HOME/Harness_AI/run/backups/keep"
step() { echo; echo "=== $*"; }
die() { echo "ОШИБКА: $*" >&2; exit 1; }

if [ "${1:-}" = "--rollback" ]; then
  src="${2:?укажите каталог бэкапа}"
  [ -d "$src" ] || die "нет каталога $src"
  step "откат из $src"
  cp "$src"/package.json "$src"/pnpm-workspace.yaml "$src"/cordis.patch.yml "$src"/gro.ngilp-hsd-versions.json "$PROFILE"/ || die "копирование"
  [ -f "$src/pnpm-lock.yaml" ] && cp "$src/pnpm-lock.yaml" "$PROFILE"/
  # Возврат точных версий: package.json с `^0.18.0` + свежий lock мог бы оставить
  # установленным 0.19.x, поэтому переустанавливаем по строкам из бэкапа.
  # Только registry-версии: git+/github:-зависимости (workflow, graph-memory) не переустанавливаем.
  pins="$(node -e '
    const fs = require("node:fs");
    const d = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).dependencies || {};
    console.log(Object.entries(d)
      .filter(([, v]) => /^[\^~]?\d/.test(String(v)))
      .map(([k, v]) => k + "@" + String(v).replace(/^[\^~]/, "")).join(" "));
  ' "$(cd "$(dirname "$src/package.json")" && pwd)/package.json")"
  [ -n "$pins" ] || die "не удалось собрать список версий из $src/package.json"
  echo "  версии: $pins"
  (cd "$PROFILE" && pnpm add $pins) || die "pnpm add (откат версий)"
  bash "$HERE/ensure-patches.sh" || die "патчи"
  echo "откат готов; перезапустите стенд: bash $HERE/start-web.sh"
  exit 0
fi

[ $# -ge 1 ] || die "usage: update-plugin.sh <pkg>@<version> [...]"
TS="$(date +%Y%m%d-%H%M%S)"
BK="$KEEP/profile-$TS"

step "1/5 бэкап → $BK"
mkdir -p "$BK"
cp "$PROFILE"/package.json "$PROFILE"/pnpm-workspace.yaml "$PROFILE"/cordis.patch.yml "$PROFILE"/gro.ngilp-hsd-versions.json "$BK"/ || die "бэкап конфигов"
[ -f "$PROFILE/pnpm-lock.yaml" ] && cp "$PROFILE/pnpm-lock.yaml" "$BK"/
for f in "@wenbin_wb/dsh-bridge/client/index.js" "dsh-better-sidebar/lib/index.js" "@anionex/dsh-turn-rewind/lib/client.js" "graph-memory/dist/dsh.js"; do
  [ -f "$PROFILE/node_modules/$f" ] && cp "$PROFILE/node_modules/$f" "$BK/$(echo "$f" | tr '/' '_').patched"
done
(cd "$PROFILE" && pnpm ls --depth 0 2>/dev/null | tail -n +2 > "$BK/versions-before.txt")
echo "бэкап готов ($(ls "$BK" | wc -l) файлов)"

step "1b/5 совместимость с хостом"
HOSTV="$(node -p "require('$HOME/tools/deepseek-harness/package.json').version" 2>/dev/null)"
for spec in "$@"; do
  need="$(timeout 40 npm view "$spec" peerDependencies --json 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);const v=Object.entries(j).filter(([k])=>k.startsWith("@deepseek-ai/dsh-"));console.log(v.length?v[0][1]:"")}catch{console.log("")}})')"
  # Сравниваем версию харнеса с минимальным требованием плагина (major.minor.patch,
  # затем pre-release строкой): диапазон вида "^0.1.5-rc.1 || ^0.1.6-alpha.1".
  verdict="$(HOSTV="$HOSTV" NEED="$need" node -e '
    const need = process.env.NEED || "", host = process.env.HOSTV || "";
    if (!need) { console.log("unknown"); process.exit(0); }
    const parse = v => { const m = /(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?/.exec(v); return m ? [ +m[1], +m[2], +m[3], m[4] || "~" ] : null; };
    const cmp = (a, b) => a[0] - b[0] || a[1] - b[1] || a[2] - b[2] || String(a[3]).localeCompare(String(b[3]));
    const h = parse(host); const mins = need.split("||").map(parse).filter(Boolean);
    if (!h || !mins.length) { console.log("unknown"); process.exit(0); }
    console.log(mins.some(m => cmp(h, m) >= 0) ? "ok" : "too-old");
  ')"
  echo "  $spec: хост $HOSTV, плагин требует ${need:-—} → $verdict"
  if [ "$verdict" = "too-old" ]; then
    echo "  ВНИМАНИЕ: плагин новее хоста — ожидается React error #130 / «entry did not activate»."
    if [ -t 0 ]; then read -r -p "  продолжать? [y/N] " a; [ "$a" = "y" ] || die "остановлено до установки";
    else die "остановлено до установки (несовместимо; для принудительной установки запустите скрипт в терминале)"; fi
  fi
done

step "2/5 установка: $*"
(cd "$PROFILE" && pnpm add "$@") || die "pnpm add — профиль не тронут дальше, откат: --rollback $BK"

step "3/5 патчи"
bash "$HERE/ensure-patches.sh" || die "патч не лёг (якорь уехал в новой версии). Откат: bash $0 --rollback $BK"

step "4/5 перезапуск web"
bash "$HERE/stop-web.sh" || true
sleep 2
bash "$HERE/start-web.sh" >/dev/null || die "start-web"
sleep 25

step "5/5 проверки"
bash "$HERE/ensure-patches.sh" --check || die "слои на месте не все"
bash "$HERE/check-chat-template.sh" | tail -1
node "$HERE/bridge-verify.mjs" 2>&1 | grep -E "^(PASS|FAIL)" | sort | uniq -c
(cd "$PROFILE" && pnpm ls --depth 0 2>/dev/null | tail -n +2 > "$BK/versions-after.txt")
diff "$BK/versions-before.txt" "$BK/versions-after.txt" | grep -E "^[<>]" || echo "версии: без изменений?"
echo
echo "готово. Откат при проблемах: bash $0 --rollback $BK"
