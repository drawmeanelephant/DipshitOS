#!/usr/bin/env bash
#
# verify-live-chain.sh -- milestone-nineteen cards P3+P4 class-B gate
# (issues #292, #293): command chaining (`;`, `&&`, `||`) and `$?` exit
# status propagation.
#
# Mechanism: boots the production image and drives the walk over serial:
#   echo chain-a && echo chain-b        -> both lines printed
#   false && echo chain-skip ; echo chain-seq
#                                        -> "chain-seq" printed,
#                                           "chain-skip" NEVER printed
#   exec NOTEXIST.BIN ; echo exit=$?    -> honest exec refusal, exit=1
#   true ; echo ok=$?                   -> ok=0
#   echo chain-done                     -> completion marker
#
# Exact-line discipline (same trick as verify-live-pipe.sh): the typed
# line "…&& echo chain-skip…" is echoed by the console but is never a
# LINE that is exactly "chain-skip", so an exact "chain-skip" line could
# only come from an echo that must not have run. Likewise "chain-b" /
# "chain-seq" as exact lines can only come from the echoes that ran.
# "ok=$?" appears literally in the typed echo; only expansion produces
# the bytes "ok=0".
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

GATE_LOG="$(art live-chain-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-chain-report.txt)"
SCRIPT="artifacts/live-chain-input.txt"

echo "=== verify-live-chain: M19 P3+P4 — chaining + exit status on VZ, $BOOTS boot(s) ==="

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
gate_begin live-chain
echo "run dir: $RUN_DIR"


cat > "$SCRIPT" <<'EOF'
echo chain-a && echo chain-b
false && echo chain-skip ; echo chain-seq
exec NOTEXIST.BIN ; echo exit=$?
true ; echo ok=$?
echo chain-done
EOF

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-expect "chain-done" --timeout 30 \
        > "$(art live-chain-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-chain-serial-$tag.log)" || true
    local SER="$(art live-chain-serial-$tag.log)"

    local SERIAL_BYTES BANNER=0 AND=0 SKIP=0 SEQ=0 EXECFAIL=0 STATUS=0 DONE=0
    SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
    if [ -f "$SER" ]; then
        grep -qF "VirelaiOS kernel" "$SER" && BANNER=1
        # P3: `&&` ran the right half on success — exact output lines.
        [ "$(grep -x -c "chain-a" "$SER" | tr -d ' ')" = 1 ] && AND=1
        [ "$(grep -x -c "chain-b" "$SER" | tr -d ' ')" = 1 ] || AND=0
        # P3: the skipped segment's output never appeared…
        [ "$(grep -x -c "chain-skip" "$SER" | tr -d ' ')" = 0 ] && SKIP=1
        # …while the `;` tail always ran.
        [ "$(grep -x -c "chain-seq" "$SER" | tr -d ' ')" = 1 ] && SEQ=1
        # P4: dispatch-level failure propagates a nonzero status through $?.
        grep -qF "not found on the ESP" "$SER" && grep -qF "exit=1" "$SER" && EXECFAIL=1
        # P4: success reads back as 0.
        grep -qF "ok=0" "$SER" && STATUS=1
        grep -qF "chain-done" "$SER" && DONE=1
    fi
    echo "$tag: rc=$RC bytes=$SERIAL_BYTES banner=$BANNER and=$AND skip=$SKIP seq=$SEQ execfail=$EXECFAIL status=$STATUS done=$DONE"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$AND" = 1 ] && [ "$SKIP" = 1 ] \
        && [ "$SEQ" = 1 ] && [ "$EXECFAIL" = 1 ] && [ "$STATUS" = 1 ] && [ "$DONE" = 1 ]
}

PASS=0
for n in $(seq 1 "$BOOTS"); do
    echo "=== live-chain boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then PASS=$((PASS + 1)); fi
done

if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-chain: PASS ($PASS/$BOOTS)"
    echo "PASS: $PASS/$BOOTS" > "$REPORT"
    exit 0
else
    echo "verify-live-chain: FAIL ($PASS/$BOOTS)"
    echo "FAIL: $PASS/$BOOTS" > "$REPORT"
    exit 1
fi
