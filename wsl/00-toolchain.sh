#!/usr/bin/env bash
# Step 1: the toolchain inside WSL. Idempotent - running it again breaks nothing.
#
# Installs system packages, Node.js (into ~/.local/node, without sudo and without
# clashing with a system one) and pnpm through corepack.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

# The toolchain versions come from the lock, like everything else that has to
# match. Taking pnpm as @latest is how a fresh machine ended up a major ahead of
# the stand this was verified with - and that major fails the plugin install
# instead of warning about it.
LOCK="$ROOT/stand.lock.json"
lock_tool() {
  [ -f "$LOCK" ] || return 0
  python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("tools",{}).get(sys.argv[2],""))
except Exception: print("")' "$LOCK" "$1" 2>/dev/null || true
}
NODE_VERSION="${NODE_VERSION:-$(lock_tool node)}"
NODE_VERSION="${NODE_VERSION:-22.23.2}"
PNPM_VERSION="${PNPM_VERSION:-$(lock_tool pnpm)}"
NODE_DIR="$HOME/.local/node"

step 'system packages'
if need_sudo_apt; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq git curl ca-certificates build-essential python3 python3-pip \
      unzip zstd jq libatk1.0-0 libnss3 libxss1 libasound2t64 2>/dev/null ||
  sudo apt-get install -y -qq git curl ca-certificates build-essential python3 python3-pip \
      unzip zstd jq
  ok 'packages installed'
else
  ok 'packages already present'
fi

# Checked here, not at build time: the harness compiles a native module, and
# without a compiler the failure surfaces twenty minutes later as a C toolchain
# stack trace that never says which package is missing.
command -v cc >/dev/null 2>&1 ||
  die 'no C compiler (cc) - the harness has a native module that needs one. Install it: sudo apt-get install -y build-essential'

step 'Node.js %s' "$NODE_VERSION"
if [ -x "$NODE_DIR/bin/node" ] && [ "v$NODE_VERSION" = "$("$NODE_DIR/bin/node" --version 2>/dev/null)" ]; then
  ok 'already installed'
else
  arch="$(uname -m)"; case "$arch" in x86_64) arch=x64;; aarch64) arch=arm64;; esac
  tmp="$(mktemp -d)"
  url="https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-$arch.tar.xz"
  info 'downloading %s' "$url"
  curl -fsSL "$url" -o "$tmp/node.tar.xz"
  rm -rf "$NODE_DIR"; mkdir -p "$NODE_DIR"
  tar -xJf "$tmp/node.tar.xz" -C "$NODE_DIR" --strip-components=1
  rm -rf "$tmp"
  ok 'installed into %s' "$NODE_DIR"
fi
export PATH="$NODE_DIR/bin:$PATH"

step 'pnpm'
have_pnpm="$(pnpm --version 2>/dev/null || echo '')"
want_pnpm="${PNPM_VERSION:-latest}"
if [ "$want_pnpm" = 'latest' ]; then
  target='pnpm@latest'
else
  target="pnpm@$want_pnpm"
fi
# A pnpm that is already there but is NOT the pinned one gets replaced: that is
# the whole point of pinning it, and the wrong major is exactly what broke.
if [ -z "$have_pnpm" ] || { [ "$want_pnpm" != 'latest' ] && [ "$have_pnpm" != "$want_pnpm" ]; }; then
  corepack enable --install-directory "$NODE_DIR/bin" >/dev/null 2>&1 || true
  corepack prepare "$target" --activate >/dev/null 2>&1 || npm i -g "$target" >/dev/null 2>&1 || true
  have_pnpm="$(pnpm --version 2>/dev/null || echo '')"
fi
if [ -n "$want_pnpm" ] && [ "$want_pnpm" != 'latest' ] && [ "$have_pnpm" != "$want_pnpm" ]; then
  warn 'pnpm %s is installed, the lock asks for %s - continuing, but this combination is not the verified one' "${have_pnpm:-none}" "$want_pnpm"
fi
ok 'pnpm %s' "${have_pnpm:-NOT INSTALLED}"

step 'PATH in ~/.bashrc'
line='export PATH="$HOME/.local/node/bin:$PATH"'
if ! grep -qF "$line" "$HOME/.bashrc" 2>/dev/null; then
  printf '\n# harness-stand\n%s\n' "$line" >> "$HOME/.bashrc"
  ok 'added'
else
  ok 'already there'
fi

done_step 'toolchain ready'
