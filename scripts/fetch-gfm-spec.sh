#!/usr/bin/env bash
# Regenerate tests/fixtures/gfm/spec.json from the canonical cmark-gfm spec --
# ONLY the GFM extension sections (Tables/Task list/Strikethrough/Autolinks/
# Disallowed Raw HTML).  Test data, regenerate with this script.
set -euo pipefail
URL="https://raw.githubusercontent.com/github/cmark-gfm/master/test/spec.txt"
OUT="tests/fixtures/gfm/spec.json"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
mkdir -p "$(dirname "$OUT")"
curl -fsSL "$URL" -o "$TMP"
python3 - "$TMP" "$OUT" <<'PY'
import sys, re, json
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
examples = []; section = ""; n = 0; i = 0
fence = re.compile(r"^`{3,}\s*example")
while i < len(lines):
    h = re.match(r"^#{1,6}\s+(.*)$", lines[i])
    if h: section = h.group(1).strip()
    if fence.match(lines[i]):
        i += 1; md = []
        while i < len(lines) and lines[i] != ".": md.append(lines[i]); i += 1
        i += 1; html = []
        while i < len(lines) and not re.match(r"^`{3,}\s*$", lines[i]): html.append(lines[i]); i += 1
        n += 1
        if "(extension)" in section:
            dec = lambda xs: "\n".join(xs).replace("→", "\t")
            examples.append({"markdown": dec(md) + ("\n" if md else ""),
                             "html": dec(html) + ("\n" if html else ""),
                             "example": n, "section": section})
    i += 1
json.dump(examples, open(sys.argv[2], "w"), ensure_ascii=False, indent=0)
print("wrote %d GFM extension examples to %s" % (len(examples), sys.argv[2]))
PY
