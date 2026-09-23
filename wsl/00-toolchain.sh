#!/usr/bin/env bash
# Step 1: the toolchain inside WSL. Idempotent - running it again breaks nothing.
#
# Installs system packages, Node.js (into ~/.local/node, without sudo and without
# clashing with a system one) and pnpm through corepack.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

NODE_VERSION="${NODE_VERSION:-22.23.2}"
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
if ! command -v pnpm >/dev/null 2>&1; then
  corepack enable --install-directory "$NODE_DIR/bin" >/dev/null 2>&1 || true
  corepack prepare pnpm@latest --activate >/dev/null 2>&1 || npm i -g pnpm >/dev/null 2>&1
fi
ok 'pnpm %s' "$(pnpm --version 2>/dev/null || echo 'NOT INSTALLED')"

step 'PATH in ~/.bashrc'
line='export PATH="$HOME/.local/node/bin:$PATH"'
if ! grep -qF "$line" "$HOME/.bashrc" 2>/dev/null; then
  printf '\n# harness-stand\n%s\n' "$line" >> "$HOME/.bashrc"
  ok 'added'
else
  ok 'already there'
fi

done_step 'toolchain ready'
