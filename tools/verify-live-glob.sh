#!/usr/bin/env bash
#
# verify-live-glob.sh -- milestone-nineteen card P6 class-B gate
# (issue #295): wildcard expansion against the ESP listing.
#
# Mechanism: boots the production image and drives the walk over serial:
#   write ga.bin alpha       -> two files land on the host share
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

GATE_LOG="$(art live-glob-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-glob-report.txt)"
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
# M34 HF6 (issue #740): glob walks the host share — `write` stages the
# probe files there, so the gate arms the channel (SPIKE runner build).
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------------
# Private scratch dir + pristine-boot overlay for EVERY boot.
# See tools/lib/gate-run.sh.
gate_begin live-glob
gate_arm_share
echo "run dir: $RUN_DIR"


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
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-expect "glob-done" --timeout 30 \
        > "$(art live-glob-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-glob-serial-$tag.log)" || true
    local SER="$(art live-glob-serial-$tag.log)"

    local SERIAL_BYTES BANNER=0 FILES=0 STAR=0 QMARK=0 CLASS=0 LITERAL=0 DONE=0
    SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
    if [ -f "$SER" ]; then
        grep -qF "VirelaiOS kernel" "$SER" && BANNER=1
        # Both writes landed (the write builtin confirms each file).
        grep -qF "ga.bin" "$SER" && grep -qF "gb.bin" "$SER" && FILES=1
        # Star, ?, and class all expand to BOTH names in sorted order.
        local EXPANDS=0
        [ "$(grep -x -c "ga.bin gb.bin" "$SER" | tr -d ' ')" = 3 ] && EXPANDS=1
        STAR=$EXPANDS; QMARK=$EXPANDS; CLASS=$EXPANDS
        # No match: exact literal line (typed echo carries the command).
        [ "$(grep -x -c 'zz\*.nomatch' "$SER" | tr -d ' ')" = 1 ] && LITERAL=1
        grep -qF "glob-done" "$SER" && DONE=1
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
