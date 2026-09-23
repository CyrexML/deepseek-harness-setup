#!/usr/bin/env bash
# Веб-интерфейс dsh против локального llama-server.
#
# Ограничения на запуск — те же, что у headless (docs/known-limitations.md §4):
# только собранный бинарник apps/cli/lib/bin.js, `pnpm dsh` не годится.
#
# Рабочий каталог: профиль web создаёт сессию с cwd = process.cwd() этого
# процесса. Каталог можно сменить в самом интерфейсе (выбор каталога работает
# бэкендом `browse`, прямо на странице), но каталог по умолчанию задаётся
# отсюда — первым аргументом или текущим каталогом.
#
# Пресет агента: вторым аргументом. Флага CLI у `dsh web` для этого нет
# (у него только --host/--port/--trusted-host/--no-open), переменной окружения
# тоже нет. Единственная ручка на момент запуска — поле `default` пространства
# настроек `agent-presets`: ровно его пишет кнопка «Set as default» в
# интерфейсе, и именно его хост читает при создании сессии.
# Без второго аргумента файл настроек НЕ трогается.
#
# ВНИМАНИЕ: дефолт действует только на сессии, созданные после. Уже открытая
# сессия остаётся на своём пресете, а поток «открыть каталог» может переиспользовать
# ранее заведённую пустую сессию вместе с её пресетом — см. docs/known-limitations.md §6-9.
#
#   scripts/start-web.sh [рабочий-каталог] [пресет]
set -euo pipefail

DSH_BIN="${DSH_BIN:-$HOME/tools/deepseek-harness/apps/cli/lib/bin.js}"
WORKDIR="${1:-$PWD}"
PRESET="${2:-}"
PORT="${DSH_WEB_PORT:-3080}"
LOG="${DSH_WEB_LOG:-$HOME/Harness_AI/run/web.log}"
PIDFILE="${DSH_WEB_PID:-$HOME/Harness_AI/run/web.pid}"

# Рабочий каталог проверяем ПЕРВЫМ делом: раньше `cd` стоял после правки
# настроек и после предстартовых проверок, и опечатка в пути роняла скрипт
# уже с побочными эффектами и с невнятным сообщением от `cd`.
if [ ! -d "$WORKDIR" ]; then
  echo "нет такого каталога: $WORKDIR" >&2
  echo "создать: mkdir -p '$WORKDIR'" >&2
  exit 1
fi
WORKDIR="$(cd "$WORKDIR" && pwd -P)"

# Лог чистим ДО предстартовых проверок. Иначе при неудачном старте (например,
# llama-server лёг) в файле остаётся строка с токеном от прошлого запуска:
# `grep 'dsh web:' run/web.log` тогда отдаёт ссылку, которая уже никуда не
# ведёт, и кажется, что интерфейс жив. Прошлый лог не теряем — он уезжает
# рядом, в .prev.
mkdir -p "$(dirname "$LOG")"
if [ -s "$LOG" ]; then mv -f "$LOG" "$LOG.prev"; fi
: > "$LOG"

export PATH="$HOME/.local/node/bin:$PATH"

# Адрес Windows-хоста меняется при перезапуске WSL — резолвим, а не храним
# (docs/known-limitations.md §4, decision-01 §7.3).
WINHOST="$(ip route show default | awk '{print $3}')"
# Уже заданный адрес уважаем: так интерфейс можно провести через
# bench/vision/capture-proxy.py, не трогая скрипт. Пусто — обычный путь.
export DSH_LLAMA_BASE_URL="${DSH_LLAMA_BASE_URL:-http://$WINHOST:8080/v1}"
# llama-server ключ не проверяет, но запрос без ключа падает у dsh
# с MISSING_CREDENTIAL (docs/dsh-schema-check.md §2.4).
export DSH_LLAMA_KEY="local-no-auth"

# Кнопки «Power» в bridge (Settings → Remote access) пишут сюда JSON {mode: dsh|wsl};
# лончер harness-start.ps1 -Hidden опрашивает файл и гасит систему. Без лончера
# (ручной запуск) файл никто не читает — RPC вернёт понятную ошибку только если
# переменная не задана, поэтому задаём её всегда: на F: он безвреден.
export DSH_POWER_REQUEST_FILE="${DSH_POWER_REQUEST_FILE:-/mnt/f/Harness_AI/run/power.request}"

# Туннель cloudflared: dsh-bridge запускает его дочерним процессом и передаёт наше
# окружение (cloudflared-manager.mjs:394); флагов плагин не принимает — настраиваем
# env-эквивалентами. QUIC (UDP) через ProtonVPN/WireGuard рвался ~каждые 4–5 мин
# (2026-09-17: quic_client_closed_connections=9 за 41 мин → телефон «теряет связь»)
# → HTTP/2 по TCP. Лог — чтобы видеть причины разрывов (bridge хранит лишь 2 КБ stderr).
export TUNNEL_TRANSPORT_PROTOCOL="${TUNNEL_TRANSPORT_PROTOCOL:-http2}"
export TUNNEL_LOGFILE="${TUNNEL_LOGFILE:-$HOME/Harness_AI/run/cloudflared.log}"
export TUNNEL_LOGLEVEL="${TUNNEL_LOGLEVEL:-info}"
# Обрыв VPN на стороне Windows гасит DNS/маршрут в WSL на минуты. По умолчанию
# cloudflared сдаётся после 5 попыток и выходит, а менеджер плагина — после 12
# перезапусков и больше не поднимает туннель (cloudflared-manager.mjs:16,217):
# 2026-09-22 телефон остался без доступа, пока не перезапустили стенд вручную.
# Держим процесс живым — он сам подключится, когда сеть вернётся.
export TUNNEL_RETRIES="${TUNNEL_RETRIES:-1000}"

# Куча Node: на 0.1.5-rc.2 веб-процесс за ~9 минут дорос до дефолтного потолка 4 ГБ
# и упал (FATAL ERROR: Reached heap limit, 2026-09-22). В WSL 20 ГБ ОЗУ — поднимаем
# потолок и наблюдаем; если рост окажется бесконечным, это утечка, а не нехватка.
export NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=6144"

# graph-memory извлекает граф отдельным запросом и ВСЕГДА передаёт
# reasoningEffort (dist/dsh.js:93, умолчание "off"). Настоящая причина карантина
# была не в значении: модель qwen38-27b-local объявлена руками и без
# reasoningEfforts, поэтому dsh считал её не-reasoning и отклонял любой явный
# effort — см. profiles/web/cordis.patch.yml, где уровни теперь объявлены.
# Здесь остаётся ручка: "off" отправляет параметр как отсутствующий.
export GRAPH_MEMORY_LLM_REASONING_EFFORT="${GRAPH_MEMORY_LLM_REASONING_EFFORT:-off}"

# Телеметрия плагинов выключена. Поводом стал dsh-univer-office: он отправляет
# анонимную статистику использования после активации, если не задать эту
# переменную. Задаётся здесь, а не в окружении пользователя, чтобы правило
# держалось для любого запуска интерфейса — и из ярлыка, и вручную.
# DO_NOT_TRACK — общепринятое соглашение, его читают и другие пакеты.
export DO_NOT_TRACK=1

# Проверка того, что не меняется, — первым делом (docs/HANDOFF.md, метод).
if ! curl -sf --max-time 10 "$DSH_LLAMA_BASE_URL/models" > /dev/null; then
  echo "llama-server не отвечает на $DSH_LLAMA_BASE_URL" >&2
  echo "поднимите его: powershell.exe -File 'F:\\Harness_AI\\run\\start-server.ps1' (умолчания = стенд лончера)" >&2
  exit 1
fi

# Сон по простою — выключить на время работы. Стенд, поднятый напрямую отсюда
# (а не через лончер harness-start.ps1), раньше оставлял штатные таймауты, и
# Windows усыпляла ПК посреди работы агента: нагрузка на CPU/GPU простоем НЕ
# считается, нужен ввод с клавиатуры. 2026-09-23: семь засыпаний за два часа
# (журнал System, Kernel-Power 42) — выглядело как самопроизвольное выключение.
# Прежние значения ложатся в run/power-timeouts.json; их вернёт stop-web.sh, а
# если процесс умрёт — задача планировщика «Harness AI power restore».
( cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass \
    -File 'F:\Harness_AI\run\harness-idle-sleep.ps1' -Off >/dev/null 2>&1 ) || \
  echo "предупреждение: не удалось выключить сон по простою — ПК может уснуть во время работы" >&2

# Прогрев модели БОЛЬШИМ промптом. Замер 2026-09-23 (bench/results/batch-sweep):
# первый крупный запрос после старта llama-server идёт по холодному файловому
# кэшу Windows и непостроенным графам CUDA — префилл 712 ток/с против 1974 на
# той же руке дальше. Маленький запрос это не лечит: разогревает именно проход
# по длинному промпту. ~8k токенов, ответ не нужен (n_predict=1), занимает
# несколько секунд и делается в фоне, чтобы не задерживать старт интерфейса.
( python3 - <<'PYWARM' > /tmp/dsh-warmup.json 2>/dev/null
import json
body = "The quick brown fox jumps over the lazy dog near the river bank. "
print(json.dumps({"prompt": (body * 500)[:32000], "n_predict": 1, "temperature": 0, "stream": False}))
PYWARM
  curl -s --max-time 180 -X POST "${DSH_LLAMA_BASE_URL%/v1}/completion" \
       -H 'Content-Type: application/json' --data @/tmp/dsh-warmup.json > /dev/null 2>&1
  rm -f /tmp/dsh-warmup.json ) &

# Патч-слои поверх плагинов и харнеса (bridge, turn-rewind, better-sidebar,
# llm-pi-ai) — переприменить, если обновление их стёрло; см. ensure-patches.sh.
# После проверки модели: тулчейн bridge зовёт её для перевода новых строк.
# Отчёт — в web.log, чтобы след остался и при скрытом запуске из лончера.
bash "$(dirname "$0")/ensure-patches.sh" 2>&1 | tee -a "$LOG"

# Пресет по умолчанию — до старта процесса: он читается при создании сессии.
if [ -n "$PRESET" ]; then
  # bin.js -> lib -> cli -> apps -> корень репозитория dsh
  DSH_ROOT="$(dirname "$(dirname "$(dirname "$(dirname "$DSH_BIN")")")")"
  if [ ! -d "$HOME/.dsh/.agent-presets/$PRESET" ] \
     && [ ! -d "$DSH_ROOT/packages/preset/agent-presets/presets/$PRESET" ]; then
    echo "неизвестный пресет: $PRESET" >&2
    echo "доступны: $(ls "$DSH_ROOT/packages/preset/agent-presets/presets" 2>/dev/null | tr '\n' ' ')$(ls "$HOME/.dsh/.agent-presets" 2>/dev/null | tr '\n' ' ')" >&2
    exit 1
  fi
  python3 "$(dirname "$0")/set-default-preset.py" "$HOME/.dsh/settings.yaml" "$PRESET"
  echo "(это постоянная настройка; вернуть — тем же скриптом с прежним значением)"
fi

cd "$WORKDIR"

echo "baseURL = $DSH_LLAMA_BASE_URL"
echo "cwd     = $WORKDIR"
echo "log     = $LOG"

# Режим переднего плана — для запуска из Windows (scripts/harness-start.ps1).
#
# Обычный путь (nohup ниже) из-под `wsl.exe` НЕ РАБОТАЕТ: WSL снимает все
# процессы сессии, когда порождивший её `wsl.exe` завершается. Проверено —
# ни nohup, ни setsid, ни фон внутри фона не выживают. Единственное, что
# переживает, — процесс на ПЕРЕДНЕМ плане живого `wsl.exe`. Поэтому launcher
# держит `wsl.exe` открытым, а node работает под ним первым планом.
#
# Токен из stdout здесь не прочитать, он уходит в лог: читать оттуда.
if [ -n "${DSH_WEB_FOREGROUND:-}" ]; then
  echo $$ > "$PIDFILE"
  exec node "$DSH_BIN" web --no-open --host 127.0.0.1 --port "$PORT" >> "$LOG" 2>&1
fi

# --no-open: в WSL браузера нет, страницу открываем на стороне Windows.
nohup node "$DSH_BIN" web --no-open --host 127.0.0.1 --port "$PORT" >> "$LOG" 2>&1 &
echo $! > "$PIDFILE"

for _ in $(seq 1 30); do
  sleep 1
  if grep -q "dsh web:" "$LOG" 2>/dev/null; then
    echo
    grep "dsh web:" "$LOG"
    echo "(токен одноразовый: он меняется при каждом запуске)"
    exit 0
  fi
done

echo "интерфейс не поднялся за 30 с, смотрите $LOG" >&2
exit 1
