#!/usr/bin/env bash
# Fetch demo-time plugin dependencies into tests/deps/.  These are
# only needed by `make demos` (VHS rendering); the test suite runs
# without them.  Idempotent — re-running is a fast-forward update.

set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p tests/deps

clone_or_update() {
  local url="$1" dest="$2"
  if [[ -d "$dest/.git" ]]; then
    git -C "$dest" pull --ff-only --quiet
  else
    git clone --depth=1 --quiet "$url" "$dest"
  fi
}

# snacks.nvim — picker UI used by the find / refile / capture demo
# tapes.  Optional at runtime: organ falls back to vim.ui.select
# when snacks isn't loaded, but the demo GIFs read better with a
# real picker.
clone_or_update https://github.com/folke/snacks.nvim    tests/deps/snacks.nvim
# Catppuccin colorscheme for a consistent palette across machines.
clone_or_update https://github.com/catppuccin/nvim      tests/deps/catppuccin

echo "demo-time deps populated:"
ls tests/deps | grep -E "snacks|catppuccin" || true
