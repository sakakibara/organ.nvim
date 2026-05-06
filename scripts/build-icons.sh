#!/usr/bin/env bash
# build-icons.sh — generate all platform icon assets from assets/logo.svg
#
# Required tools (one SVG renderer + iconutil/ImageMagick for packing):
#
#   macOS (recommended):
#     brew install librsvg imagemagick
#     iconutil is built into macOS — no install needed.
#
#   Linux:
#     apt install librsvg2-bin imagemagick
#     .icns generation is skipped (iconutil is macOS-only) — run on a Mac
#     once to produce the macOS .icns file.
#
# Outputs (all under assets/icons/):
#   png/organ-{16,32,48,64,128,256,512,1024}.png    raster masters
#   linux/hicolor/<NxN>/apps/organ.png              freedesktop theme layout
#   Organ.ico                                       Windows
#   Organ.icns                                      macOS (only on macOS)
#
# Run from repo root or anywhere — script resolves paths from its own location.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_SVG="$REPO_ROOT/assets/logo.svg"
OUT_DIR="$REPO_ROOT/assets/icons"

[[ -f "$SRC_SVG" ]] || { echo "ERROR: source SVG not found at $SRC_SVG" >&2; exit 1; }

# Pick an SVG renderer. rsvg-convert handles gradients more accurately than
# ImageMagick's SVG path. Inkscape works but is slow for batch.
if command -v rsvg-convert >/dev/null 2>&1; then
  render() { rsvg-convert -w "$1" -h "$1" "$SRC_SVG" -o "$2"; }
elif command -v magick >/dev/null 2>&1; then
  render() { magick -background none -size "${1}x${1}" "$SRC_SVG" "$2"; }
elif command -v convert >/dev/null 2>&1; then
  render() { convert -background none -size "${1}x${1}" "$SRC_SVG" "$2"; }
elif command -v inkscape >/dev/null 2>&1; then
  render() { inkscape -w "$1" -h "$1" "$SRC_SVG" -o "$2" >/dev/null 2>&1; }
else
  echo "ERROR: no SVG renderer found. Install one of:" >&2
  echo "  rsvg-convert (recommended) — brew install librsvg / apt install librsvg2-bin" >&2
  echo "  imagemagick                — brew install imagemagick / apt install imagemagick" >&2
  echo "  inkscape                   — brew install inkscape / apt install inkscape" >&2
  exit 1
fi

# Pick an ICO packer.
if command -v magick >/dev/null 2>&1; then
  pack_ico() { magick "$@"; }
elif command -v convert >/dev/null 2>&1; then
  pack_ico() { convert "$@"; }
else
  echo "ERROR: ImageMagick required for .ico packing. Install via:" >&2
  echo "  brew install imagemagick / apt install imagemagick" >&2
  exit 1
fi

mkdir -p "$OUT_DIR/png" "$OUT_DIR/linux/hicolor"

echo "Rendering PNG masters from $SRC_SVG..."
for size in 16 32 48 64 128 256 512 1024; do
  out="$OUT_DIR/png/organ-${size}.png"
  render "$size" "$out"
  printf "  %4d px -> %s\n" "$size" "$out"
done

echo ""
echo "Building Linux freedesktop hicolor theme layout..."
for size in 16 32 48 64 128 256 512; do
  dir="$OUT_DIR/linux/hicolor/${size}x${size}/apps"
  mkdir -p "$dir"
  cp "$OUT_DIR/png/organ-${size}.png" "$dir/organ.png"
done
echo "  -> $OUT_DIR/linux/hicolor/"

echo ""
echo "Building Windows .ico (multi-resolution)..."
pack_ico \
  "$OUT_DIR/png/organ-16.png" \
  "$OUT_DIR/png/organ-32.png" \
  "$OUT_DIR/png/organ-48.png" \
  "$OUT_DIR/png/organ-64.png" \
  "$OUT_DIR/png/organ-256.png" \
  "$OUT_DIR/Organ.ico"
echo "  -> $OUT_DIR/Organ.ico"

# .icns requires macOS iconutil — gracefully skip on Linux.
if command -v iconutil >/dev/null 2>&1; then
  echo ""
  echo "Building macOS .icns..."
  iconset="$OUT_DIR/Organ.iconset"
  rm -rf "$iconset"
  mkdir -p "$iconset"

  # Apple iconset naming: icon_<size>x<size>[@2x].png
  cp "$OUT_DIR/png/organ-16.png"   "$iconset/icon_16x16.png"
  cp "$OUT_DIR/png/organ-32.png"   "$iconset/icon_16x16@2x.png"
  cp "$OUT_DIR/png/organ-32.png"   "$iconset/icon_32x32.png"
  cp "$OUT_DIR/png/organ-64.png"   "$iconset/icon_32x32@2x.png"
  cp "$OUT_DIR/png/organ-128.png"  "$iconset/icon_128x128.png"
  cp "$OUT_DIR/png/organ-256.png"  "$iconset/icon_128x128@2x.png"
  cp "$OUT_DIR/png/organ-256.png"  "$iconset/icon_256x256.png"
  cp "$OUT_DIR/png/organ-512.png"  "$iconset/icon_256x256@2x.png"
  cp "$OUT_DIR/png/organ-512.png"  "$iconset/icon_512x512.png"
  cp "$OUT_DIR/png/organ-1024.png" "$iconset/icon_512x512@2x.png"

  iconutil -c icns "$iconset" -o "$OUT_DIR/Organ.icns"
  rm -rf "$iconset"
  echo "  -> $OUT_DIR/Organ.icns"
else
  echo ""
  echo "NOTE: iconutil not found (only available on macOS) — .icns generation skipped."
  echo "      Run this script on a Mac once to produce the macOS .icns file."
fi

echo ""
echo "Done. Outputs in $OUT_DIR/"
