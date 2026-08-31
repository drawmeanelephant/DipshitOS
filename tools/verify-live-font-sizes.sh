#!/usr/bin/env bash
#
# verify-live-font-sizes.sh -- milestone-twenty card U1 class-B gate
# (issue #306): three font sizes on the terminal text layer.
#
# Mechanism: boots the production image and drives the walk over serial.
# The monitor `text` report prints rows/cols and the cell size, so the
# size switch is observable WITHOUT reading the framebuffer:
#   text            -> cell=8x8, cols=160, rows=90 (small baseline)
#   font medium     -> switches to 16x16
#   text            -> cell=16x16, cols=80, rows=45
#   font large      -> 24x24
#   text            -> cell=24x24, cols=53, rows=30
#   font small      -> back to 8x8
#   text putraw AB  -> putraw lands at col 2 (geometry sane after restore)
#   text            -> cur=0,2
#   echo m20-font-ok
#
# Run isolation (#523 item 2 / issue #528, claim 5069): every boot attaches
# a private DiskImageKit stacked disk (read-only base + throwaway ASIF
# overlay), a private EFI var store (recreated fresh per boot, as the
# pre-isolation gate did), and a private serial log under $RUN_DIR — two
# concurrent instances cannot clobber each other's disks, NVRAM, or
# evidence. Set VIRELAI_GATE_SUFFIX=_alt to give this instance its own
# canonical evidence names (two simultaneous instances MUST differ), and
# VIRELAI_KEEP_RUN=1 to keep the scratch dir.
#
# Class B — Apple silicon + VZ only.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-font-sizes-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-font-sizes-report.txt)"
SCRIPT="artifacts/live-font-sizes-input.txt"

echo "=== verify-live-font-sizes: M20 U1 — font sizes on VZ, $BOOTS boot(s) ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------------
# Private scratch dir + pristine-boot overlay for EVERY boot.
# See tools/lib/gate-run.sh.
gate_begin live-font-sizes
echo "run dir: $RUN_DIR"


printf 'text\nfont medium\ntext\nfont large\ntext\nfont small\ntext\necho m20-font-ok\n' > "$SCRIPT"

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --screen artifacts/gpu-screen --script "$SCRIPT" --script-expect "m20-font-ok" --timeout 30 \
        > "$(art live-font-sizes-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-font-sizes-serial-$tag.log)" || true
    local SER="$(art live-font-sizes-serial-$tag.log)"

    local SERIAL_BYTES BANNER=0 S8=0 M16=0 L24=0 BACK8=0 DONE=0
    SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
    if [ -f "$SER" ]; then
        grep -qF "VirelaiOS kernel" "$SER" && BANNER=1
        # Baseline small: 160x90 at 8x8.
        grep -qF "rows=90 cols=160 cell=8x8" "$SER" && S8=1
        # Medium: exactly halved geometry.
        grep -qF "rows=45 cols=80 cell=16x16" "$SER" && M16=1
        # Large: 1280/24 = 53 columns, 720/24 = 30 rows.
        grep -qF "rows=30 cols=53 cell=24x24" "$SER" && L24=1
        # Restored small after large.
        grep -qF "rows=90 cols=160 cell=8x8" "$SER" && BACK8=1
        grep -qF "m20-font-ok" "$SER" && DONE=1
    fi
    echo "$tag: rc=$RC bytes=$SERIAL_BYTES banner=$BANNER s8=$S8 m16=$M16 l24=$L24 back8=$BACK8 done=$DONE"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$S8" = 1 ] && [ "$M16" = 1 ] \
        && [ "$L24" = 1 ] && [ "$BACK8" = 1 ] && [ "$DONE" = 1 ]
}

PASS=0
for n in $(seq 1 "$BOOTS"); do
    echo "=== live-font-sizes boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then PASS=$((PASS + 1)); fi
done

if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-font-sizes: PASS ($PASS/$BOOTS)"
    echo "PASS: $PASS/$BOOTS" > "$REPORT"
    exit 0
else
    echo "verify-live-font-sizes: FAIL ($PASS/$BOOTS)"
    echo "FAIL: $PASS/$BOOTS" > "$REPORT"
    exit 1
fi
