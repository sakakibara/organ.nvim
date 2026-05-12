#!/usr/bin/env bash
# Generates tests/fixtures/decoration_10k.org -- a synthetic ~10000-line
# org file exercising features the decoration providers care about
# (headlines, emphasis, lists, tables, src blocks, timestamps).
#
# Run from the repo root.

set -euo pipefail
out="tests/fixtures/decoration_10k.org"
mkdir -p tests/fixtures

{
  echo "#+TITLE: Decoration perf fixture"
  echo
  for i in $(seq 1 700); do
    echo "* TODO Heading $i :tag:"
    echo "Body of heading $i with *bold* and /italic/ and =verbatim= and [[https://example.com][link]]."
    echo "- item one"
    echo "- item two with *emphasis*"
    echo "- [ ] checkbox todo"
    echo "- [X] checkbox done"
    echo "#+begin_src python"
    echo "def f(): pass"
    echo "#+end_src"
    echo
  done
} > "$out"

wc -l "$out"
