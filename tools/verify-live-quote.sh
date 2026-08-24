#!/usr/bin/env bash
#
# verify-live-quote.sh -- milestone-nineteen card P5 class-B gate
# (issue #294): quoting & escaping.
#
# Mechanism: boots the production image and drives the walk over serial:
#   echo 'hello world'     -> one argument, exact line "hello world"
#   set FOO bar
#   echo "value $FOO"      -> double quotes expand: "value bar"
#   echo '$FOO'            -> single quotes block expansion: "$FOO"
#   echo \$FOO             -> backslash blocks expansion: "$FOO"
#   echo a\;b              -> escaped operator does not split: "a;b"
#   echo 'q;b'             -> quoted operator does not split: "q;b"
#   echo quote-done        -> completion marker
#
# Exact-line discipline (verify-live-pipe.sh rule): the typed line is
# echoed but is never an EXACT output line, so each assertion below can
# only be satisfied by the command's real output.
#
# Class B — Apple silicon + VZ only.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-quote-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-quote-report.txt"
SCRIPT="artifacts/live-quote-input.txt"

echo "=== verify-live-quote: M19 P5 — quoting & escaping on VZ, $BOOTS boot(s) ==="

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
echo 'hello world'
set FOO=bar
echo "value $FOO"
echo '$FOO'
echo \$FOO
echo a\;b
echo 'q;b'
echo quote-done
EOF

run_one() {
    local tag="$1"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" --script-expect "quote-done" --timeout 30 \
        > "artifacts/live-quote-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-quote-serial-$tag.log" || true

    local SERIAL_BYTES BANNER=0 SINGLE=0 EXPAND=0 SQBLOCK=0 ESCBLOCK=0 ESCOP=0 QOP=0 DONE=0
    SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log 2>/dev/null | tr -d ' ')
    if [ -f artifacts/vm-serial.log ]; then
        grep -qF "DipshitOS kernel" artifacts/vm-serial.log && BANNER=1
        [ "$(grep -x -c "hello world" artifacts/vm-serial.log | tr -d ' ')" = 1 ] && SINGLE=1
        grep -x -q "value bar" artifacts/vm-serial.log && EXPAND=1
        # Both protection paths print the same literal line — expect two.
        [ "$(grep -x -c '\$FOO' artifacts/vm-serial.log | tr -d ' ')" = 2 ] && { SQBLOCK=1; ESCBLOCK=1; }
        [ "$(grep -x -c "a;b" artifacts/vm-serial.log | tr -d ' ')" = 1 ] && ESCOP=1
        [ "$(grep -x -c "q;b" artifacts/vm-serial.log | tr -d ' ')" = 1 ] && QOP=1
        grep -qF "quote-done" artifacts/vm-serial.log && DONE=1
    fi
    echo "$tag: rc=$RC bytes=$SERIAL_BYTES banner=$BANNER single=$SINGLE expand=$EXPAND sqblock=$SQBLOCK escblock=$ESCBLOCK escop=$ESCOP qop=$QOP done=$DONE"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$SINGLE" = 1 ] && [ "$EXPAND" = 1 ] \
        && [ "$SQBLOCK" = 1 ] && [ "$ESCBLOCK" = 1 ] && [ "$ESCOP" = 1 ] && [ "$QOP" = 1 ] && [ "$DONE" = 1 ]
}

PASS=0
for n in $(seq 1 "$BOOTS"); do
    echo "=== live-quote boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then PASS=$((PASS + 1)); fi
done

if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-quote: PASS ($PASS/$BOOTS)"
    echo "PASS: $PASS/$BOOTS" > "$REPORT"
    exit 0
else
    echo "verify-live-quote: FAIL ($PASS/$BOOTS)"
    echo "FAIL: $PASS/$BOOTS" > "$REPORT"
    exit 1
fi
