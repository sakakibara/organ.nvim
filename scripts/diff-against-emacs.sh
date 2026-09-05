#!/bin/bash
# Diff organ's parse of one or more .org files against Emacs's.
#
# Usage:
#   scripts/diff-against-emacs.sh FILE.org [FILE.org ...]
#
# Both sides print the canonical structural dump described in
# scripts/emacs-element-dump.el (headline level / TODO / priority / tags /
# title, COMMENT + ARCHIVE markers, SCHEDULED / DEADLINE / CLOSED raw
# timestamps, and every node property).  A difference between the two is a
# parser divergence.
#
# Exit status:
#   0  every file parses identically
#   1  at least one file diverged; a unified diff is printed
#   2  the comparison could not be made (missing emacs, nvim, dumper or
#      built grammar) -- never confuse this with a pass
#
# Passing every file in one invocation is much faster than one call per
# file: each side pays its interpreter startup once.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)

die() {
  echo "diff-against-emacs: $1" >&2
  exit 2
}

if [ "$#" -eq 0 ]; then
  echo "usage: $0 FILE.org [FILE.org ...]" >&2
  exit 2
fi

command -v emacs >/dev/null 2>&1 || die "emacs not on PATH"
command -v nvim >/dev/null 2>&1 || die "nvim not on PATH"

EMACS_DUMP="$ROOT/scripts/emacs-element-dump.el"
ORGAN_DUMP="$ROOT/scripts/organ-element-dump.lua"
[ -f "$EMACS_DUMP" ] || die "missing $EMACS_DUMP"
[ -f "$ORGAN_DUMP" ] || die "missing $ORGAN_DUMP"

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/organ-parity.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$tmpdir"' EXIT

list="$tmpdir/files.txt"
: > "$list"
for f in "$@"; do
  [ -f "$f" ] || die "no such file: $f"
  # Absolute paths so the two dumpers, which run from different working
  # directories, label the same file identically.
  printf '%s\n' "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")" >> "$list"
done

if ! emacs --batch -Q -l "$EMACS_DUMP" \
     --eval "(organ-element-dump \"$list\")" \
     > "$tmpdir/emacs.txt" 2> "$tmpdir/emacs.err"; then
  sed 's/^/  /' "$tmpdir/emacs.err" >&2
  die "emacs dump failed"
fi

if ! (cd "$ROOT" && nvim --headless -l "$ORGAN_DUMP" "$list") \
     > "$tmpdir/organ.txt" 2> "$tmpdir/organ.err"; then
  sed 's/^/  /' "$tmpdir/organ.err" >&2
  die "organ dump failed"
fi

[ -s "$tmpdir/emacs.txt" ] || die "emacs dump produced no output"
[ -s "$tmpdir/organ.txt" ] || die "organ dump produced no output"

if diff -u --label emacs "$tmpdir/emacs.txt" --label organ "$tmpdir/organ.txt"; then
  exit 0
fi
exit 1
