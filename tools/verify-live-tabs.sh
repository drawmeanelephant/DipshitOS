#!/usr/bin/env bash
#
# verify-live-tabs.sh -- milestone-twenty card U10 class-B gate (issue
# #315): tab stops in the terminal text layer.
#
# Mechanism: boots the production image and drives the walk over serial.
# `text putraw` feeds TAB bytes through the real putc path and skips the
# trailing newline, so a follow-up `text` report exposes the landing
# column exactly:
#   text putraw A<TAB>B     -> tab from col 1 lands B at col 8; cursor 9
#   text                    -> cur=0,9
#   text putraw <TAB><TAB>  -> two stops: cursor at column 16
#   text                    -> cur=0,16
#   echo m20-tabs-ok
#
# Class B — Apple silicon + VZ only.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-tabs-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-tabs-report.txt"
SCRIPT="artifacts/live-tabs-input.txt"

echo "=== verify-live-tabs: M20 U10 — tab stops on VZ, $BOOTS boot(s) ==="

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

printf 'text putraw A\tB\ntext\ntext putraw \t\t\ntext\necho m20-tabs-ok\n' > "$SCRIPT"
# NOTE: the second putraw CONTINUES the same line (cursor at col 9 after
# the first), so two more stops land the cursor at column 24.
# NOTE: the second putraw CONTINUES the same line (cursor at col 9 after
# the first), so two more stops land the cursor at column 24.

run_one() {
    local tag="$1"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" --script-expect "m20-tabs-ok" --timeout 30 \
        > "artifacts/live-tabs-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-tabs-serial-$tag.log" || true

    local SERIAL_BYTES BANNER=0 COL9=0 COL16=0 DONE=0
    SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log 2>/dev/null | tr -d ' ')
    if [ -f artifacts/vm-serial.log ]; then
        grep -qF "DipshitOS kernel" artifacts/vm-serial.log && BANNER=1
        # A(0) TAB→8 B(8): cursor rests at column 9.
        grep -qF "cur=0,9" artifacts/vm-serial.log && COL9=1
        # Two tabs continuing from column 9: stop at 16 then 24.
        grep -qF "cur=0,24" artifacts/vm-serial.log && COL16=1
        grep -qF "m20-tabs-ok" artifacts/vm-serial.log && DONE=1
    fi
    echo "$tag: rc=$RC bytes=$SERIAL_BYTES banner=$BANNER col9=$COL9 col16=$COL16 done=$DONE"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$COL9" = 1 ] && [ "$COL16" = 1 ] && [ "$DONE" = 1 ]
}

PASS=0
for n in $(seq 1 "$BOOTS"); do
    echo "=== live-tabs boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then PASS=$((PASS + 1)); fi
done

if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-tabs: PASS ($PASS/$BOOTS)"
    echo "PASS: $PASS/$BOOTS" > "$REPORT"
    exit 0
else
    echo "verify-live-tabs: FAIL ($PASS/$BOOTS)"
    echo "FAIL: $PASS/$BOOTS" > "$REPORT"
    exit 1
fi
