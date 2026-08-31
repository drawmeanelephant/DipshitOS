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

GATE_LOG="$(art live-pipe-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-pipe-report.txt)"
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

# --- per-run isolation -------------------------------------------------------------
# Private scratch dir + pristine-boot overlay for EVERY boot.
# See tools/lib/gate-run.sh.
gate_begin live-pipe
echo "run dir: $RUN_DIR"


cat > "$SCRIPT" <<'EOF'
echo pipe-left-marker | type
ls | type
echo a | echo b | echo c
echo pipe-ok
EOF

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-expect "pipe-ok" --timeout 30 \
        > "$(art live-pipe-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-pipe-serial-$tag.log)" || true
    local SER="$(art live-pipe-serial-$tag.log)"

    local SERIAL_BYTES BANNER=0 PIPE=0 LS=0 CHAIN=0 DONE=0
    SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
    if [ -f "$SER" ]; then
        grep -qF "VirelaiOS kernel" "$SER" && BANNER=1
        # The pipe proof: a line that is EXACTLY "pipe-left-marker" can
        # only come from `type` echoing the pipe content (the typed line
        # is "echo pipe-left-marker | type", not an exact match).
        [ "$(grep -x -c "pipe-left-marker" "$SER" | tr -d ' ')" = 1 ] && PIPE=1
        # `ls | type` — the listing header only appears if ls ran and its
        # output travelled through the pipe to type.
        grep -qF "ls: esp=" "$SER" && LS=1
        grep -qF "pipes: only one pipe per line (no chaining)" "$SER" && CHAIN=1
        grep -qF "pipe-ok" "$SER" && DONE=1
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
