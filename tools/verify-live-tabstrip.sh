#!/usr/bin/env bash
#
# verify-live-tabstrip.sh — M37 DQ2 tab-strip chrome live proof (issue #840)
#
# Proves, in ONE headless VZ boot:
#   1. TABHOLD.BIN opens a window and attaches it as a tab of NOTEPAD
#      (`wnd: tab-attach child=3 parent=2`, kernel mirrors the grouping).
#   2. After two cycles (group resting on NOTEPAD visible+focused,
#      TABHOLD attached-but-hidden), the kind-4 snapshot shows the painted
#      strip below NOTEPAD's title bar: trough color, per-tab cells, the
#      accent underline on the active (NOTEPAD) cell, title text ink, and
#      a red per-tab close glyph.
#
# NOTEPAD opens deterministically at (56,56) 512x384; with 2 tabs each
# cell is 256px: strip rows 72..93, active underline rows 92..93.
#
# Class B -- Apple silicon + VZ, headless (custom-virtio, no view). CI=yes.
#
# Usage:  bash tools/verify-live-tabstrip.sh
# Evidence: artifacts/live-tabstrip-{run.txt,serial.log,snap-A.raw},
#           artifacts/live-tabstrip-report.txt

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/tools/lib/gate-run.sh"

art() { echo "$ROOT/artifacts/$1"; }

GATE_LOG="$(art live-tabstrip-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT
REPORT="$(art live-tabstrip-report.txt)"

echo "=== verify-live-tabstrip: M37 DQ2 tab-strip chrome (issue #840) ==="

# --- tool versions + revision ------------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's|agent/||;s|/|-|g' || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates -------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig user/src/wnd.zig user/src/tabhold.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-tabstrip
gate_seed_share
echo "run dir: $RUN_DIR"

run_boot() {
    local tag="$1"; shift
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log" "$RUN_DIR"/snap-$tag-*.raw
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --screen "$RUN_DIR/screen" \
        --via-virtio --cvc-snap \
        --snapshot-out "$RUN_DIR/snap-$tag" \
        "$@" \
        > "$(art live-tabstrip-run-$tag.txt)" 2>&1
    local RC=$?
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-tabstrip-serial-$tag.log)" || true
    echo "$tag: runner rc=$RC"
    return "$RC"
}

snap_file() {
    local f
    f="$(ls "$RUN_DIR"/snap-$1-*.raw 2>/dev/null | head -1 || true)"
    [ -n "$f" ] || { echo "FAIL: no snapshot streamed in boot $1"; return 1; }
    cp "$f" "$(art live-tabstrip-snap-$1.raw)"
    printf '%s' "$f"
}

# --- boot A: NOTEPAD + self-driving TABHOLD, snapshot the held strip -------
# TABHOLD attaches/retries/cycles/holds/dones autonomously, so the boot is
# a single script burst — no phase-2/3 triggers (issue #843 flake dodge).
echo "--- boot A: attach + hold + snapshot ---"
printf 'wnd start\nexec NOTEPAD.BIN\nexec TABHOLD.BIN\n' > "$RUN_DIR/script-A.txt"

set +e
run_boot A \
    --script "$RUN_DIR/script-A.txt" \
    --snapshot-after "tabhold: cycled" \
    --script-expect "tabhold: done" --timeout 240
RC_A=$?
set -e

SER_A="$(art live-tabstrip-serial-A.log)"
A_ATTACH=0
A_CYCLED=0
A_PIX=0
if [ "$RC_A" = 0 ] && [ -f "$SER_A" ]; then
    grep -a -qF -- "wnd: tab-attach child=3 parent=2" "$SER_A" && A_ATTACH=1
    grep -a -qF -- "tabhold: cycled" "$SER_A" && A_CYCLED=1
    SNAP_A="$(snap_file A || true)"
    if [ -n "$SNAP_A" ] && python3 - "$SNAP_A" <<'PYEOF'
import sys
data = open(sys.argv[1], "rb").read()
W, H = 1280, 720
assert len(data) == W * H * 4, f"snapshot size {len(data)}"
def px(x, y):
    k = (y * W + x) * 4
    return (data[k + 2], data[k + 1], data[k])  # R,G,B
# NOTEPAD at (56,56) 512x384; strip rows 72..93; cells 256px wide.
X, SY, SW = 56, 72, 512
TROUGH = (0x47, 0x55, 0x69)   # border_unfocus (dividers)
CELLBG = (0x1a, 0x2b, 0x3c)   # title_bg
ACCENT = (0x3b, 0x82, 0xf6)   # ring (active underline)
ok = True
# Trough divider between cells (x=312; the strip-left divider sits under
# the focus ring, so only the inter-cell divider is asserted).
divs = sum(1 for y in range(SY, SY + 22, 2) if px(X + 256, y) == TROUGH)
print(f"dividers={divs}")
ok &= divs >= 8
# Cell band: title_bg across both cells (sample clear of text/underline rows
# and the focus-ring columns).
band = sum(1 for x in range(X + 4, X + SW, 4) if px(x, SY + 1) == CELLBG)
print(f"band={band}")
ok &= band >= (SW // 4) - 8
# Active underline (cell 0 bottom rows): long accent run.
under = sum(1 for x in range(X + 4, X + 240, 2) if px(x, SY + 20) == ACCENT or px(x, SY + 21) == ACCENT)
print(f"underline={under}")
ok &= under >= 80
# Title text ink: bright pixels inside cell 0 text rows.
ink = sum(1 for x in range(X + 4, X + 220, 2) for y in range(SY + 3, SY + 19, 2)
          if px(x, y)[0] > 200 and px(x, y)[1] > 200 and px(x, y)[2] > 200)
print(f"ink={ink}")
ok &= ink >= 20
# Per-tab close glyph: red pixels at cell 0 right end (box x 300..311, y 79..90).
red = sum(1 for x in range(X + 244, X + 256) for y in range(SY + 7, SY + 18)
          if px(x, y)[0] > 170 and px(x, y)[1] < 120 and px(x, y)[2] < 120)
print(f"close_red={red}")
ok &= red >= 3
print("STRIP_OK" if ok else "STRIP_MISSING")
sys.exit(0 if ok else 1)
PYEOF
    then A_PIX=1
    fi
fi

# --- report ------------------------------------------------------------------
{
    echo "--- M37 DQ2 tab-strip report ---"
    echo "  runner rc=$RC_A"
    echo "  attach=$A_ATTACH  held_cycled=$A_CYCLED  strip_pixels=$A_PIX"
    if [ "$A_ATTACH" = 1 ] && [ "$A_CYCLED" = 1 ] && [ "$A_PIX" = 1 ]; then
        echo "  RESULT: PASS"
    else
        echo "  RESULT: FAIL"
    fi
    echo "---"
} | tee "$REPORT"

if [ "$A_ATTACH" = 1 ] && [ "$A_CYCLED" = 1 ] && [ "$A_PIX" = 1 ]; then
    echo "verify-live-tabstrip: PASS — attached tabs paint a visible strip (trough + cells + active underline + titles + close) live on VZ"
    exit 0
else
    echo "verify-live-tabstrip: FAIL"
    exit 1
fi
