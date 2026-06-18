#!/usr/bin/env bash
# Regenerate tests/fixtures/commonmark/spec.json from the pinned CommonMark
# spec.  Example blocks in spec.txt look like:
#   ```````````````````````````````` example
#   <markdown>
#   .
#   <html>
#   ````````````````````````````````
# In spec.txt, U+2192 (->) marks tabs and the middle dot marks spaces in some
# examples; the canonical fixtures use real tab/space, so we substitute back.
set -euo pipefail
VER=0.31.2
URL="https://raw.githubusercontent.com/commonmark/commonmark-spec/${VER}/spec.txt"
OUT="tests/fixtures/commonmark/spec.json"
mkdir -p "$(dirname "$OUT")"
SPEC_TMP=$(mktemp)
trap "rm -f $SPEC_TMP" EXIT
curl -fsSL "$URL" > "$SPEC_TMP"

python3 - "$SPEC_TMP" "$OUT" << 'PY'
import sys, re, json
spec_file = sys.argv[1]
out_file = sys.argv[2]
with open(spec_file) as f:
    src = f.read()
# Spec uses U+2192 for tab inside examples.
examples = []
section = ""
example_no = 0
lines = src.split("\n")
i = 0
fence = re.compile(r"^`{32,} example")
while i < len(lines):
    line = lines[i]
    h = re.match(r"^#{1,6} +(.*)$", line)
    if h:
        section = h.group(1).strip()
    if fence.match(line):
        i += 1
        md = []
        while i < len(lines) and lines[i] != ".":
            md.append(lines[i]); i += 1
        i += 1  # skip "."
        html = []
        while i < len(lines) and not lines[i].startswith("`" * 32):
            html.append(lines[i]); i += 1
        example_no += 1
        def dec(xs):
            return "\n".join(xs).replace("→", "\t")
        examples.append({
            "markdown": dec(md) + ("\n" if md else ""),
            "html": dec(html) + ("\n" if html else ""),
            "example": example_no,
            "section": section,
        })
    i += 1
with open(out_file, "w") as f:
    json.dump(examples, f, ensure_ascii=False, indent=0)
print(f"wrote {len(examples)} examples to {out_file}")
PY
