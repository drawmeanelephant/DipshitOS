#!/usr/bin/env bash
#
# verify-live-calc-prog.sh -- milestone-twenty-four card K1 class-B gate:
# programmer mode toggle on real VZ.
#
# Mechanism: boots the production image, execs CALC.BIN from the monitor,
# waits for the app to be ready, sends Ctrl+P to toggle programmer mode,
# and asserts the serial markers prove the toggle happened.
#
# The walk:
#   exec CALC.BIN                          -> launch calculator
#   (wait for calc: ready)                 -> app event loop running
#   Ctrl+P                                 -> toggle programmer mode ON
#   (assert calc: prog-on)                 -> mode switched
#   Ctrl+P                                 -> toggle programmer mode OFF
#   (assert calc: prog-off)                -> mode switched back
#   echo calc-prog-live-ok                 -> success marker
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-calc-prog.sh            # BOOTS boots (default 1)
#   BOOTS=3 bash tools/verify-live-calc-prog.sh
#
# Evidence saved under artifacts/: live-calc-prog-gate.txt,
# live-calc-prog-report.txt, live-calc-prog-run-<NN>.txt,
# live-calc-prog-serial-<NN>.log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-calc-prog-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-calc-prog-report.txt"
SCRIPT="artifacts/live-calc-prog-script.txt"

echo "=== verify-live-calc-prog: M24 K1 — programmer mode on VZ, $BOOTS boot(s) ==="

# Tool versions + revision
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- phase 1: launch CALC.BIN from the monitor ------------------------------
cat > "$SCRIPT" <<'EOF'
exec CALC.BIN
EOF

# --- phase 2: Ctrl+P x2 + success marker (after calc: ready) ----------------
# Ctrl+P = ctrl-p chord (the runner maps ctrl-a..ctrl-z to macOS keycodes)
CTRL_P=$'ctrl-p'
INPUT_CHORDS="${CTRL_P},${CTRL_P},echo calc-prog-live-ok"

run_one() {
    local tag="$1"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" \
        --input-chords "$INPUT_CHORDS" \
        --input-chords-after "calc: ready" \
        --script-expect "calc-prog-live-ok" \
        --timeout 45 \
        > "artifacts/live-calc-prog-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-calc-prog-serial-$tag.log" || true

    local SERIAL_BYTES=0 BANNER=0 CALC_READY=0 PROG_ON=0 PROG_OFF=0 DONE=0
    if [ -f artifacts/vm-serial.log ]; then
        SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log 2>/dev/null | tr -d ' ')
        grep -qF -- "DipshitOS kernel has seized control." artifacts/vm-serial.log && BANNER=1
        grep -qF -- "calc: ready" artifacts/vm-serial.log && CALC_READY=1
        grep -qF -- "calc: prog-on" artifacts/vm-serial.log && PROG_ON=1
        grep -qF -- "calc: prog-off" artifacts/vm-serial.log && PROG_OFF=1
        grep -qF -- "calc-prog-live-ok" artifacts/vm-serial.log && DONE=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER calc-ready=$CALC_READY prog-on=$PROG_ON prog-off=$PROG_OFF done=$DONE"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER calc-ready=$CALC_READY prog-on=$PROG_ON prog-off=$PROG_OFF done=$DONE"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$CALC_READY" = 1 ] && [ "$PROG_ON" = 1 ] && [ "$PROG_OFF" = 1 ] && [ "$DONE" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live-calc-prog gate (M24 K1) — programmer mode on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "phase 1: exec CALC.BIN from monitor"
    echo "phase 2: Ctrl+P toggle x2 (on/off), assert markers, final echo"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-calc-prog boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-calc-prog: PASS — programmer mode toggles via Ctrl+P, serial markers observed ($PASS/$BOOTS boot(s))."
    echo "PASS: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-calc-prog: FAILED — $PASS/$BOOTS boot(s) passed; see artifacts/live-calc-prog-report.txt"
    echo "FAIL: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
