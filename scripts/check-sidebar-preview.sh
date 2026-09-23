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

curl -s -o /dev/null -m 2 "$BASE/" || { echo "the host does not answer on $BASE - is it running?"; exit 1; }

KEY="--$(echo "${PROJ#/}" | tr '/' '-')--"
DIR="$HOME/.dsh/sessions/$KEY"
[ -d "$DIR" ] || { echo "no sessions for $PROJ"; exit 1; }
SID="$(ls -1t "$DIR" | head -1 | sed 's/^session-//')"
URL="$BASE/sidebar/html/$SID$PROJ/$FILE"

echo "project : $PROJ"
echo "session : $SID"
echo "target  : $FILE"
echo

probe() {
  local label="$1"; shift
  local code body ctype
  code=$(curl -s -o /dev/null -w '%{http_code}' "$@" "$URL")
  ctype=$(curl -s -D- -o /dev/null "$@" "$URL" | tr -d '\r' | grep -i '^content-type' | cut -d' ' -f2-)
  printf '%-34s %s  %s\n' "$label" "$code" "$ctype"
  case "$code" in
    403) echo "     GATE 1: the fence rejects the origin. Turn the preview sandbox off." ;;
    500) body=$(curl -s "$@" "$URL")
         case "$body" in
           *inspect*) echo "     GATE 2: the persistence.stat patch is missing, or the host was not restarted." ;;
           *) echo "     500: $body" ;;
         esac ;;
    200) case "$ctype" in
           *javascript*) echo "     OK - the script will execute." ;;
           *) echo "     GATE 3: type '$ctype' + nosniff means the browser refuses to execute it." ;;
         esac ;;
  esac
}

probe "sandboxed iframe (Origin: null)" -H 'Origin: null' -H 'Sec-Fetch-Site: cross-site'
probe "ordinary iframe (same-origin)"  -H "Origin: $BASE" -H 'Sec-Fetch-Site: same-origin'


# GATE 5: the CSP sandbox directive forces an opaque origin on the previewed
# document whatever the iframe attribute says. Without allow-same-origin the
# document is opaque, subresources go out with Origin: null, and gate 1 refuses
# them - so "sandbox off" in the UI cannot work while this header says otherwise.
CSP=$(curl -s -D- -o /dev/null -H "Origin: $BASE" "$BASE/sidebar/html/$SID$PROJ/index.html" \
      | tr -d '\r' | grep -i '^content-security-policy' | cut -d' ' -f2-)
echo
echo "CSP on index.html:"
echo "  $CSP"
case "$CSP" in
  *allow-same-origin*) echo "     OK - the document gets the interface origin." ;;
  *sandbox*)           echo "     GATE 5: no allow-same-origin - the document is opaque and sub-resources go out with Origin: null." ;;
  *)                   echo "     no header - the response does not impose a sandbox." ;;
esac

echo
echo "The goal: the second line is 200 + text/javascript."
echo "The first line stays 403 - that is the sandbox, switched off in the interface."
