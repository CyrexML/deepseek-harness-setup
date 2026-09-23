#!/usr/bin/env bash
# Шаг 5: настройки DSH — маршрут на модель, пресет агента, параметры интерфейса.
#
# Всё пишется из шаблонов templates/ с подстановкой значений из config.json.
# Существующие настройки пользователя не затираются: если файл уже есть и в нём
# нет нашей метки, он сохраняется рядом с суффиксом .before-install.
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

keep_old() { # $1 = файл
  [ -f "$1" ] || return 0
  grep -qF "$MARK" "$1" && return 0
  cp "$1" "$1.before-install"
  warn "$(basename "$1") был свой — сохранил как $(basename "$1").before-install"
}

subst() { # шаблон → stdout
  sed -e "s|@CTX@|$CTX|g" -e "s|@MODEL_ID@|$MODEL_ID|g" -e "s|@PRESET@|$PRESET|g" "$1"
}

step "маршрут на модель (profiles/web/cordis.patch.yml)"
mkdir -p "$PROFILE"
keep_old "$PROFILE/cordis.patch.yml"
subst "$TPL/cordis.patch.yml.tmpl" > "$PROFILE/cordis.patch.yml"
ok "модель $MODEL_ID, окно $CTX"

step "пресет агента ($PRESET)"
# Правило про работу на видеокарте в правилах агента. Файл ~/.dsh/AGENTS.md
# читается в начале каждой сессии, и это единственный канал, который работает,
# когда модель сама выясняет обстановку до первой команды: подсказка на запуске
# срабатывает только если запуск случился. Дописывается ОДИН раз, по маркеру,
# и чужого содержимого не трогает.
if [ -f "$TPL/agents-gpu.md" ]; then
  agents="$DSHDIR/AGENTS.md"
  if ! grep -q 'dsh-local: gpu-work-rule' "$agents" 2>/dev/null; then
    { [ -s "$agents" ] && printf '\n'; cat "$TPL/agents-gpu.md"; } >> "$agents"
    ok "правило про видеокарту добавлено в AGENTS.md"
  else
    ok "правило про видеокарту уже в AGENTS.md"
  fi
fi

mkdir -p "$DSHDIR/.agent-presets"
if [ -d "$TPL/presets/local-64k" ]; then
  rm -rf "$DSHDIR/.agent-presets/$PRESET"
  cp -r "$TPL/presets/local-64k" "$DSHDIR/.agent-presets/$PRESET"
  # Порог сжатия и размер окна внутри пресета должны совпадать с -c сервера.
  # Подстановка во ВСЕ файлы пресета: помимо окна и модели там есть @HARNESS_DIR@ —
  # модули пресета импортируют базовые классы из сборки харнеса по абсолютному пути.
  HARNESS_DIR="${HARNESS_DIR:-$HOME/tools/deepseek-harness}"
  find "$DSHDIR/.agent-presets/$PRESET" -type f \( -name '*.yml' -o -name '*.mjs' \) -print0 |
    xargs -0 sed -i -e "s|@CTX@|$CTX|g" -e "s|@MODEL_ID@|$MODEL_ID|g" -e "s|@HARNESS_DIR@|$HARNESS_DIR|g"
  ok "установлен"
else
  warn "шаблона пресета нет — стенд поднимется на встроенном standard"
fi

step "настройки интерфейса (settings.yaml)"
keep_old "$DSHDIR/settings.yaml"
if [ -f "$DSHDIR/settings.yaml" ] && grep -qF "$MARK" "$DSHDIR/settings.yaml"; then
  ok "уже наши — не трогаю"
else
  subst "$TPL/settings.yaml.tmpl" > "$DSHDIR/settings.yaml"
  ok "записаны"
fi

step "шаблон диалога для llama-server"
WINROOT="$(winpath "$(cfg .windowsRoot 'F:\Harness_AI')")"
if [ -f "$TPL/chat-agent.jinja" ]; then
  mkdir -p "$WINROOT/models"
  cp "$TPL/chat-agent.jinja" "$WINROOT/models/chat-agent.jinja"
  ok "скопирован в $WINROOT/models/chat-agent.jinja"
else
  warn "шаблона диалога нет — сервер возьмёт зашитый в модель (контекст будет расти быстрее)"
fi

done_step "настройки готовы"
