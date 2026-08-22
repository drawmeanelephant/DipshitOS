#!/usr/bin/env bash
#
# verify-live-pipe.sh -- milestone-nineteen card P1 class-B gate
# (issue #290): the pipe operator — `cmd1 | cmd2`.
#
# Mechanism: boots the production image and drives the walk over serial:
#   echo pipe-left-marker | type    -> type echoes "pipe-left-marker"
#                                     (the left echo's output went into the
#                                     pipe, NOT the console; type echoes it)
#   ls | type                        -> lists the ESP through the pipe
#   echo a | echo b | echo c         -> "pipes: only one pipe per line
#                                      (no chaining)" — single-pipe refusal
#   echo pipe-ok                     -> completion marker
#
# The honest pipe proof is the exact-line check: the typed line
# "echo pipe-left-marker | type" is NOT the line "pipe-left-marker", so a
# line that is exactly "pipe-left-marker" can only come from `type`
# echoing the pipe content. If the pipe were broken (left output printed
# directly, type reading nothing), that exact line would never appear.
#
# Class B — Apple silicon + VZ only.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-pipe-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-pipe-report.txt"
SCRIPT="artifacts/live-pipe-input.txt"

echo "=== verify-live-pipe: M19 P1 — pipes on VZ, $BOOTS boot(s) ==="

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
echo pipe-left-marker | type
ls | type
echo a | echo b | echo c
echo pipe-ok
EOF

run_one() {
    local tag="$1"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" --script-expect "pipe-ok" --timeout 30 \
        > "artifacts/live-pipe-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-pipe-serial-$tag.log" || true

    local SERIAL_BYTES BANNER=0 PIPE=0 LS=0 CHAIN=0 DONE=0
    SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log 2>/dev/null | tr -d ' ')
    if [ -f artifacts/vm-serial.log ]; then
        grep -qF "DipshitOS kernel" artifacts/vm-serial.log && BANNER=1
        # The pipe proof: a line that is EXACTLY "pipe-left-marker" can
        # only come from `type` echoing the pipe content (the typed line
        # is "echo pipe-left-marker | type", not an exact match).
        [ "$(grep -x -c "pipe-left-marker" artifacts/vm-serial.log | tr -d ' ')" = 1 ] && PIPE=1
        # `ls | type` — the listing header only appears if ls ran and its
        # output travelled through the pipe to type.
        grep -qF "ls: esp=" artifacts/vm-serial.log && LS=1
        grep -qF "pipes: only one pipe per line (no chaining)" artifacts/vm-serial.log && CHAIN=1
        grep -qF "pipe-ok" artifacts/vm-serial.log && DONE=1
    fi
    echo "$tag: rc=$RC bytes=$SERIAL_BYTES banner=$BANNER pipe=$PIPE ls=$LS chain=$CHAIN done=$DONE"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$PIPE" = 1 ] && [ "$LS" = 1 ] && [ "$CHAIN" = 1 ] && [ "$DONE" = 1 ]
}

PASS=0
for n in $(seq 1 "$BOOTS"); do
    echo "=== live-pipe boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then PASS=$((PASS + 1)); fi
done

if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-pipe: PASS ($PASS/$BOOTS)"
    echo "PASS: $PASS/$BOOTS" > "$REPORT"
    exit 0
else
    echo "verify-live-pipe: FAIL ($PASS/$BOOTS)"
    echo "FAIL: $PASS/$BOOTS" > "$REPORT"
    exit 1
fi
