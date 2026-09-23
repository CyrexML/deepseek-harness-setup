#!/usr/bin/env bash
# Снять слепок рабочего стенда в stand.lock.json — «система в этом состоянии».
#
#   bash make-lock.sh
#
# Файл фиксирует ровно то, что проверено вместе: тег харнеса, версии плагинов,
# список патч-слоёв с маркерами, настройки сервера модели. Шаги установки читают
# его, поэтому у другого человека соберётся та же связка, а не «последние»
# версии, которые могли разойтись.
#
# Обновление стенда = поменять числа здесь (или запустить этот скрипт после
# ручного обновления) и выложить новый lock. На машине пользователя его
# применит `update.cmd` / `wsl/60-update.sh`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/.local/node/bin:$PATH"
PROFILE="$HOME/.dsh/profiles/web"
DSH_ROOT="${DSH_ROOT:-$HOME/tools/deepseek-harness}"
OUT="$HERE/stand.lock.json"

tag="$(git -C "$DSH_ROOT" describe --tags --exact-match 2>/dev/null || git -C "$DSH_ROOT" rev-parse --short HEAD)"
commit="$(git -C "$DSH_ROOT" rev-parse HEAD)"

node - "$PROFILE" "$HERE" "$tag" "$commit" "$OUT" <<'NODE'
const fs = require('node:fs');
const [profile, here, tag, commit, out] = process.argv.slice(2);

const pkg = JSON.parse(fs.readFileSync(`${profile}/package.json`, 'utf8'));
// Пишем ТОЧНЫЕ установленные версии, а не диапазоны из package.json: диапазон
// через месяц приведёт к другой сборке.
const plugins = {};
for (const name of Object.keys(pkg.dependencies ?? {})) {
  try {
    const installed = JSON.parse(fs.readFileSync(`${profile}/node_modules/${name}/package.json`, 'utf8'));
    plugins[name] = pkg.dependencies[name].startsWith('git') || pkg.dependencies[name].startsWith('github:')
      ? pkg.dependencies[name]          // git-зависимость: версия ничего не скажет
      : installed.version;
  } catch { plugins[name] = pkg.dependencies[name]; }
}

// Слои читаем из самого ensure-patches.sh: он и есть их реестр.
const ensure = fs.readFileSync(`${here}/scripts/ensure-patches.sh`, 'utf8');
const layers = [...ensure.matchAll(/^layer\s+(\S+)\s+"[^"]+"\s+"([^"]+)"/gm)].map(m => ({ name: m[1], marker: m[2] }));

const lock = {
  _: 'Слепок проверенной связки. Меняется осознанно: правим числа и выкладываем новый lock.',
  createdAt: new Date().toISOString().slice(0, 10),
  harness: { tag, commit },
  plugins,
  patchLayers: layers,
  bundles: pkg.dsh?.profile?.bundles ?? [],
};
fs.writeFileSync(out, JSON.stringify(lock, null, 2) + '\n');
console.log(`харнес ${tag}, плагинов ${Object.keys(plugins).length}, слоёв ${layers.length}`);
NODE

echo "записан $OUT"
