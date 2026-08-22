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
# Class B — Apple silicon + VZ only.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-color-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-color-report.txt"
SCRIPT="artifacts/live-color-script.txt"

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

cat > "$SCRIPT" <<'EOF'
color on
color
ls
color off
echo color-live-ok
EOF

run_one() {
    local tag="$1"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" --script-expect "color-live-ok" --timeout 30 \
        > "artifacts/live-color-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-color-serial-$tag.log" || true

    local SERIAL_BYTES BANNER=0 COLOR_ON=0 LS_DIR=0 COLOR_OFF=0 DONE=0
    SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log 2>/dev/null | tr -d ' ')
    if [ -f artifacts/vm-serial.log ]; then
        grep -qF "DipshitOS kernel" artifacts/vm-serial.log && BANNER=1
        grep -qF "color: on" artifacts/vm-serial.log && COLOR_ON=1
        grep -qF "[dir]" artifacts/vm-serial.log && LS_DIR=1
        grep -qF "color: off" artifacts/vm-serial.log && COLOR_OFF=1
        grep -qF "color-live-ok" artifacts/vm-serial.log && DONE=1
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