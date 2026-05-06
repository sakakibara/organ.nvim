#!/usr/bin/env bash
# Regenerate lua/organ/todo/timezone_table.lua from IANA zone1970.tab.
# Run manually when IANA publishes a new tzdata release (typically 2-4× yearly).
# Usage: scripts/fetch-tz-table.sh
set -euo pipefail

cd "$(dirname "$0")/.."

URL="https://raw.githubusercontent.com/eggert/tz/main/zone1970.tab"
OUT="lua/organ/todo/timezone_table.lua"

echo "Fetching $URL..."
curl -fsSL "$URL" -o /tmp/zone1970.tab

{
  echo "-- Generated from IANA zone1970.tab by scripts/fetch-tz-table.sh."
  echo "-- IANA zone name -> ISO 3166-1 alpha-2 country code (primary country)."
  echo "return {"
  awk -F '\t' '
    /^#/ { next }
    NF >= 3 {
      split($1, countries, ",")
      printf "  [\"%s\"] = \"%s\",\n", $3, countries[1]
    }
  ' /tmp/zone1970.tab | sort
  echo "}"
} > "$OUT"

echo "Wrote $OUT ($(wc -l < "$OUT") lines)."
