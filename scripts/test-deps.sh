#!/usr/bin/env bash
# Fetch test-time plugin dependencies into tests/deps/ so the test suite
# can run on a fresh clone without requiring sibling-directory layouts.
# Idempotent — re-running is a fast-forward update.

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

clone_or_update https://github.com/sakakibara/tablature.nvim tests/deps/tablature.nvim
clone_or_update https://github.com/sakakibara/narrow.nvim    tests/deps/narrow.nvim
clone_or_update https://github.com/machakann/vim-vimhelplint tests/deps/vim-vimhelplint

echo "tests/deps populated:"
ls tests/deps
