#!/usr/bin/env bash
# Fetch test-time plugin dependencies into tests/deps/ so the test suite
# can run on a fresh clone without requiring sibling-directory layouts.
# Idempotent — re-running is a fast-forward update.
#
# A dep may be pinned to an exact revision by passing one.  tablature is
# pinned because organ's table tests assert its output byte for byte, so
# tracking its default branch would let a push over there turn organ's CI
# red with no change here.  Bump the pin in the same commit that adapts
# the expectations.

set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p tests/deps

# clone_or_update URL DEST [REV]
#
# With REV the checkout is left detached at exactly that revision, and
# the fetch is skipped when it is already there, so the common case costs
# nothing and works offline.  Without REV the default branch is tracked.
clone_or_update() {
  local url="$1" dest="$2" rev="${3:-}"
  if [[ -n "$rev" ]]; then
    if [[ -d "$dest/.git" ]] && [[ "$(git -C "$dest" rev-parse HEAD 2>/dev/null)" == "$rev" ]]; then
      return
    fi
    if [[ ! -d "$dest/.git" ]]; then
      git clone --quiet "$url" "$dest"
    fi
    git -C "$dest" fetch --quiet origin "$rev" 2>/dev/null ||
      git -C "$dest" fetch --quiet origin || true
    if ! git -C "$dest" cat-file -e "$rev^{commit}" 2>/dev/null; then
      echo "$dest: pinned revision $rev is not in $url" >&2
      echo "If it is a local commit, push it before pinning to it." >&2
      exit 1
    fi
    git -C "$dest" checkout --quiet --detach "$rev"
    return
  fi
  if [[ -d "$dest/.git" ]]; then
    git -C "$dest" pull --ff-only --quiet
  else
    git clone --depth=1 --quiet "$url" "$dest"
  fi
}

TABLATURE_REV=d6cdb096ef7212dfb88e618eb7db5ed9b5f4fced

clone_or_update https://github.com/sakakibara/tablature.nvim tests/deps/tablature.nvim "$TABLATURE_REV"
clone_or_update https://github.com/sakakibara/narrow.nvim    tests/deps/narrow.nvim
clone_or_update https://github.com/machakann/vim-vimhelplint tests/deps/vim-vimhelplint
clone_or_update https://github.com/nvim-treesitter/nvim-treesitter-context tests/deps/nvim-treesitter-context

echo "tests/deps populated:"
ls tests/deps
