#!/usr/bin/env bash
# Probe the sidebar HTML previewer end to end, naming which gate fails.
#
# Each gate answers with its own signature, so one run says exactly where the
# preview stands. See scripts/patch-sidebar.sh for what the gates are.
#
#   check-sidebar-preview.sh [project-dir] [port]
set -uo pipefail

PROJ="${1:-$HOME/Harness_AI/projects/Cooking_APP}"
PORT="${2:-3080}"
FILE="${3:-js/main.js}"
BASE="http://127.0.0.1:$PORT"

curl -s -o /dev/null -m 2 "$BASE/" || { echo "хост не отвечает на $BASE - запущен?"; exit 1; }

KEY="--$(echo "${PROJ#/}" | tr '/' '-')--"
DIR="$HOME/.dsh/sessions/$KEY"
[ -d "$DIR" ] || { echo "нет сессий для $PROJ"; exit 1; }
SID="$(ls -1t "$DIR" | head -1 | sed 's/^session-//')"
URL="$BASE/sidebar/html/$SID$PROJ/$FILE"

echo "проект : $PROJ"
echo "сессия : $SID"
echo "цель   : $FILE"
echo

probe() {
  local label="$1"; shift
  local code body ctype
  code=$(curl -s -o /dev/null -w '%{http_code}' "$@" "$URL")
  ctype=$(curl -s -D- -o /dev/null "$@" "$URL" | tr -d '\r' | grep -i '^content-type' | cut -d' ' -f2-)
  printf '%-34s %s  %s\n' "$label" "$code" "$ctype"
  case "$code" in
    403) echo "     GATE 1: фенс отвергает origin. Выключить песочницу превью." ;;
    500) body=$(curl -s "$@" "$URL")
         case "$body" in
           *inspect*) echo "     GATE 2: патч persistence.stat не наложен или хост не перезапущен." ;;
           *) echo "     500: $body" ;;
         esac ;;
    200) case "$ctype" in
           *javascript*) echo "     OK - скрипт исполнится." ;;
           *) echo "     GATE 3: тип '$ctype' + nosniff = браузер откажется исполнять." ;;
         esac ;;
  esac
}

probe "песочный iframe (Origin: null)" -H 'Origin: null' -H 'Sec-Fetch-Site: cross-site'
probe "обычный iframe (same-origin)"   -H "Origin: $BASE" -H 'Sec-Fetch-Site: same-origin'


# GATE 5: the CSP sandbox directive forces an opaque origin on the previewed
# document whatever the iframe attribute says. Without allow-same-origin the
# document is opaque, subresources go out with Origin: null, and gate 1 refuses
# them - so "sandbox off" in the UI cannot work while this header says otherwise.
CSP=$(curl -s -D- -o /dev/null -H "Origin: $BASE" "$BASE/sidebar/html/$SID$PROJ/index.html" \
      | tr -d '\r' | grep -i '^content-security-policy' | cut -d' ' -f2-)
echo
echo "CSP на index.html:"
echo "  $CSP"
case "$CSP" in
  *allow-same-origin*) echo "     OK - документ получает origin интерфейса." ;;
  *sandbox*)           echo "     GATE 5: нет allow-same-origin - документ opaque, подресурсы уйдут с Origin: null." ;;
  *)                   echo "     заголовка нет - песочница ответом не навязывается." ;;
esac

echo
echo "Рабочая цель: вторая строка = 200 + text/javascript."
echo "Первая строка останется 403 - это и есть песочница, её выключают в интерфейсе."
