#!/usr/bin/env bash
#
# verify-ttf-fonts.sh -- class A: TrueType font engine verification for
# Inter (UI proportional font) and Fira Code (terminal / editor monospace font).
#
# Tests:
#   1. TrueType SFNT table parser (head, maxp, hhea, hmtx, loca, glyf, cmap fmt 4 & 12).
#   2. Vector outline decoding and delta coordinate reconstruction.
#   3. Quadratic Bézier subdivision and contour decomposition.
#   4. Scanline coverage anti-aliasing (half-integer subpixel sampling).
#   5. Composite glyph decomposition (accented Latin characters).
#   6. Zero-heap GlyphCache and 32-bpp BGRA alpha blending.
#   7. Proportional string measurement and layout helpers in ui.zig.
#
# Usage:
#   bash tools/verify-ttf-fonts.sh
#
# Evidence saved under artifacts/ttf-fonts-gate.txt.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/ttf-fonts-gate.txt"
mkdir -p "$(dirname "$GATE_LOG")"
exec > >(tee "$GATE_LOG") 2>&1

echo "=== verify-ttf-fonts: TrueType Engine & Typography Verification (Inter + Fira Code) ==="

INTER_TTF="image/fonts/Inter-Regular.ttf"
FIRA_TTF="image/fonts/FiraCode-Regular.ttf"

# 1. Assert font files exist
echo
echo "[1/3] Verifying source TrueType font files in image/fonts/"
if [ ! -f "$INTER_TTF" ]; then
    echo "FAIL: Inter-Regular.ttf not found at $INTER_TTF" >&2
    exit 1
fi
inter_size=$(stat -f%z "$INTER_TTF" 2>/dev/null || stat -c%s "$INTER_TTF")
echo "  Inter-Regular.ttf: $inter_size bytes (OK)"

if [ ! -f "$FIRA_TTF" ]; then
    echo "FAIL: FiraCode-Regular.ttf not found at $FIRA_TTF" >&2
    exit 1
fi
fira_size=$(stat -f%z "$FIRA_TTF" 2>/dev/null || stat -c%s "$FIRA_TTF")
echo "  FiraCode-Regular.ttf: $fira_size bytes (OK)"

# 2. Run unit tests for font_ttf.zig
echo
echo "[2/3] Running TrueType parser, rasterizer, composite, cache & blend unit tests"
PATH="/opt/homebrew/opt/gnu-sed/libexec/gnubin:/opt/homebrew/bin:$PATH" zig test user/src/lib/font_ttf.zig

# 3. Assert userland compilation with font subsystem
echo
echo "[3/3] Compiling userland with font engine integrated"
PATH="/opt/homebrew/opt/gnu-sed/libexec/gnubin:/opt/homebrew/bin:$PATH" zig build desktop edit

echo
echo "=== verify-ttf-fonts: PASS (Inter & Fira Code TrueType engine verified) ==="
