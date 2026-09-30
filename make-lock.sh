#!/usr/bin/env bash
# Snapshot the working stand into stand.lock.json: the system as it is now.
#
#   bash make-lock.sh
#
# The file pins exactly what was verified together: harness tag, plugin versions,
# patch layers with their markers, model server settings. The install steps read
# it, so another machine gets the same combination instead of whatever "latest"
# has drifted to.
#
# Updating the stand means changing the numbers here (or re-running this script
# after a manual update) and publishing the new lock; update.cmd applies it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# The stand root, the way make-repo.sh finds it: the installer lives inside it.
STAND="$(cd "$HERE/.." && pwd)"
export PATH="$HOME/.local/node/bin:$PATH"
PROFILE="$HOME/.dsh/profiles/web"
DSH_ROOT="${DSH_ROOT:-$HOME/tools/deepseek-harness}"
OUT="$HERE/stand.lock.json"

tag="$(git -C "$DSH_ROOT" describe --tags --exact-match 2>/dev/null || git -C "$DSH_ROOT" rev-parse --short HEAD)"
commit="$(git -C "$DSH_ROOT" rev-parse HEAD)"

# Which layers this stand ACTUALLY registers. Some are conditional - a layer whose
# fix upstream has since adopted is retired on the newer plugin, and the
# settingsScope layer only exists on a host that lost the service. Reading the
# script's own report is the only honest source: a grep over the file would pin
# layers this combination does not use, and the installer would then demand them.
REGISTERED="$(bash "$STAND/scripts/ensure-patches.sh" --check | sed -n 's/^patches: \([^ ]*\) - \(ok\|MISSING\)$/\1/p' | tr '\n' ' ')"
[ -n "$REGISTERED" ] || { echo "ensure-patches.sh --check produced no layers" >&2; exit 1; }

node - "$PROFILE" "$HERE" "$tag" "$commit" "$OUT" "$REGISTERED" <<'NODE'
const fs = require('node:fs');
const { execSync } = require('node:child_process');
const [profile, here, tag, commit, out, registered] = process.argv.slice(2);

const pkg = JSON.parse(fs.readFileSync(`${profile}/package.json`, 'utf8'));
// Write the EXACT installed versions rather than the ranges from package.json:
// a range resolves to a different build a month later.
const plugins = {};
for (const name of Object.keys(pkg.dependencies ?? {})) {
  try {
    const installed = JSON.parse(fs.readFileSync(`${profile}/node_modules/${name}/package.json`, 'utf8'));
    plugins[name] = pkg.dependencies[name].startsWith('git') || pkg.dependencies[name].startsWith('github:')
      ? pkg.dependencies[name]          // a git dependency: the version says nothing
      : installed.version;
  } catch { plugins[name] = pkg.dependencies[name]; }
}

// Markers come from ensure-patches.sh - it is their registry - but the SET comes
// from what that script reported as registered a moment ago, in its own order.
// The leading \s* matters: conditional layers sit indented inside an `if`.
const ensure = fs.readFileSync(`${here}/scripts/ensure-patches.sh`, 'utf8');
const marker = new Map([...ensure.matchAll(/^\s*layer\s+(\S+)\s+"[^"]+"\s+"([^"]+)"/gm)].map(m => [m[1], m[2]]));
const layers = registered.trim().split(/\s+/).map(name => {
  if (!marker.has(name)) { console.error(`layer ${name} reported but not found in ensure-patches.sh`); process.exit(1); }
  return { name, marker: marker.get(name) };
});

// The toolchain belongs in the lock as much as the plugins do. pnpm was taken
// as @latest, so a fresh machine got a newer major than the one this stand was
// verified with - and that major turns "ignored build scripts" from a warning
// into a failure, which stopped the install at the plugin step.
const tools = {
  node: process.version.replace(/^v/, ''),
  pnpm: (() => { try { return execSync('pnpm --version', { encoding: 'utf8' }).trim(); } catch { return ''; } })(),
};

const lock = {
  _: 'Snapshot of the verified combination. Changed deliberately: edit the numbers and publish a new lock.',
  createdAt: new Date().toISOString().slice(0, 10),
  tools,
  harness: { tag, commit },
  plugins,
  patchLayers: layers,
  bundles: pkg.dsh?.profile?.bundles ?? [],
};
fs.writeFileSync(out, JSON.stringify(lock, null, 2) + '\n');
console.log(`harness ${tag}, plugins ${Object.keys(plugins).length}, layers ${layers.length}`);
NODE

echo "written $OUT"
