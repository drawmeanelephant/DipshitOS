#!/usr/bin/env bash
#
# verify-live-glob.sh -- milestone-nineteen card P6 class-B gate
# (issue #295): wildcard expansion against the ESP listing.
#
# Mechanism: boots the production image and drives the walk over serial:
#   write ga.bin alpha       -> two files land on the ESP
#   write gb.bin beta
#   echo *.bin               -> sorted expansion: "ga.bin gb.bin"
#   echo g?.bin              -> question mark: "ga.bin gb.bin"
#   echo g[a-b].bin          -> character class: "ga.bin gb.bin"
#   echo zz*.nomatch         -> no match: literal pattern passes through
#   echo glob-done           -> completion marker
#
# Exact-line discipline (verify-live-pipe.sh rule): the typed lines are
# echoed but none of them is an EXACT "ga.bin gb.bin" line, so that line
# can only come from a real expansion. The literal passthrough is checked
# as an exact "zz*.nomatch" line — the typed echo has the "echo " prefix,
# so only the unmatched wildcard's output matches exactly.
#
# Class B — Apple silicon + VZ only.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-glob-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-glob-report.txt"
SCRIPT="artifacts/live-glob-input.txt"

echo "=== verify-live-glob: M19 P6 — wildcard expansion on VZ, $BOOTS boot(s) ==="

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
write ga.bin alpha
write gb.bin beta
echo *.bin
echo g?.bin
echo g[a-b].bin
echo zz*.nomatch
echo glob-done
EOF

run_one() {
    local tag="$1"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" --script-expect "glob-done" --timeout 30 \
        > "artifacts/live-glob-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-glob-serial-$tag.log" || true

    local SERIAL_BYTES BANNER=0 FILES=0 STAR=0 QMARK=0 CLASS=0 LITERAL=0 DONE=0
    SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log 2>/dev/null | tr -d ' ')
    if [ -f artifacts/vm-serial.log ]; then
        grep -qF "DipshitOS kernel" artifacts/vm-serial.log && BANNER=1
        # Both writes landed (the write builtin confirms each file).
        grep -qF "ga.bin" artifacts/vm-serial.log && grep -qF "gb.bin" artifacts/vm-serial.log && FILES=1
        # Star, ?, and class all expand to BOTH names in sorted order.
        local EXPANDS=0
        [ "$(grep -x -c "ga.bin gb.bin" artifacts/vm-serial.log | tr -d ' ')" = 3 ] && EXPANDS=1
        STAR=$EXPANDS; QMARK=$EXPANDS; CLASS=$EXPANDS
        # No match: exact literal line (typed echo carries the command).
        [ "$(grep -x -c 'zz\*.nomatch' artifacts/vm-serial.log | tr -d ' ')" = 1 ] && LITERAL=1
        grep -qF "glob-done" artifacts/vm-serial.log && DONE=1
    fi
    echo "$tag: rc=$RC bytes=$SERIAL_BYTES banner=$BANNER files=$FILES star=$STAR qmark=$QMARK class=$CLASS literal=$LITERAL done=$DONE"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$FILES" = 1 ] && [ "$STAR" = 1 ] \
        && [ "$QMARK" = 1 ] && [ "$CLASS" = 1 ] && [ "$LITERAL" = 1 ] && [ "$DONE" = 1 ]
}

PASS=0
for n in $(seq 1 "$BOOTS"); do
    echo "=== live-glob boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then PASS=$((PASS + 1)); fi
done

if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-glob: PASS ($PASS/$BOOTS)"
    echo "PASS: $PASS/$BOOTS" > "$REPORT"
    exit 0
else
    echo "verify-live-glob: FAIL ($PASS/$BOOTS)"
    echo "FAIL: $PASS/$BOOTS" > "$REPORT"
    exit 1
fi
