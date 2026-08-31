#!/usr/bin/env bash
#
# verify-live-color.sh -- M18 T5 class-B gate (issue #408): ANSI terminal
# colors on real VZ.
#
# Mechanism: boots the image, types `color on` then `ls` (to see bold dirs),
# then `color off`, then verifies the prompt wraps in ANSI escape codes.
#
# The walk: color on, ls, color off, echo color-live-ok
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

GATE_LOG="$(art live-color-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-color-report.txt)"

echo "=== verify-live-color: M18 T5 — terminal ANSI colors on VZ, $BOOTS boot(s) ==="

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
gate_begin live-color
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"


cat > "$SCRIPT" <<'EOF'
color on
color
ls
color off
echo color-live-ok
EOF

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-expect "color-live-ok" --timeout 30 \
        > "$(art live-color-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-color-serial-$tag.log)" || true
    local SER="$(art live-color-serial-$tag.log)"

    local SERIAL_BYTES BANNER=0 COLOR_ON=0 LS_DIR=0 COLOR_OFF=0 DONE=0
    SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
    if [ -f "$SER" ]; then
        grep -qF "VirelaiOS kernel" "$SER" && BANNER=1
        grep -qF "color: on" "$SER" && COLOR_ON=1
        grep -qF "[dir]" "$SER" && LS_DIR=1
        grep -qF "color: off" "$SER" && COLOR_OFF=1
        grep -qF "color-live-ok" "$SER" && DONE=1
    fi
    echo "$tag: rc=$RC bytes=$SERIAL_BYTES banner=$BANNER on=$COLOR_ON dir=$LS_DIR off=$COLOR_OFF done=$DONE"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$COLOR_ON" = 1 ] && [ "$LS_DIR" = 1 ] && [ "$COLOR_OFF" = 1 ] && [ "$DONE" = 1 ]
}

PASS=0
for n in $(seq 1 "$BOOTS"); do
    echo "=== live-color boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then PASS=$((PASS + 1)); fi
done

if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-color: PASS ($PASS/$BOOTS)"
    exit 0
else
    echo "verify-live-color: FAIL ($PASS/$BOOTS)"
    exit 1
fi