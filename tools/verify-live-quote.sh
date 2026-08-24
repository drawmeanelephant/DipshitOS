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
# Run isolation (#523 item 2 / issue #528, claim 5069): every boot attaches
# a private DiskImageKit stacked disk (read-only base + throwaway ASIF
# overlay), a private EFI var store (recreated fresh per boot, as the
# pre-isolation gate did), and a private serial log under $RUN_DIR — two
# concurrent instances cannot clobber each other's disks, NVRAM, or
# evidence. Set DIPSHIT_GATE_SUFFIX=_alt to give this instance its own
# canonical evidence names (two simultaneous instances MUST differ), and
# DIPSHIT_KEEP_RUN=1 to keep the scratch dir.
#
# Class B — Apple silicon + VZ only.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-quote-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-quote-report.txt)"
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

# --- per-run isolation -------------------------------------------------------------
# Private scratch dir + pristine-boot overlay for EVERY boot.
# See tools/lib/gate-run.sh.
gate_begin live-quote
echo "run dir: $RUN_DIR"


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
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-expect "quote-done" --timeout 30 \
        > "$(art live-quote-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-quote-serial-$tag.log)" || true
    local SER="$(art live-quote-serial-$tag.log)"

    local SERIAL_BYTES BANNER=0 SINGLE=0 EXPAND=0 SQBLOCK=0 ESCBLOCK=0 ESCOP=0 QOP=0 DONE=0
    SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
    if [ -f "$SER" ]; then
        grep -qF "DipshitOS kernel" "$SER" && BANNER=1
        [ "$(grep -x -c "hello world" "$SER" | tr -d ' ')" = 1 ] && SINGLE=1
        grep -x -q "value bar" "$SER" && EXPAND=1
        # Both protection paths print the same literal line — expect two.
        [ "$(grep -x -c '\$FOO' "$SER" | tr -d ' ')" = 2 ] && { SQBLOCK=1; ESCBLOCK=1; }
        [ "$(grep -x -c "a;b" "$SER" | tr -d ' ')" = 1 ] && ESCOP=1
        [ "$(grep -x -c "q;b" "$SER" | tr -d ' ')" = 1 ] && QOP=1
        grep -qF "quote-done" "$SER" && DONE=1
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
