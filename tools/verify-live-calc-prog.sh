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
# Run isolation (#523 item 2 / issue #528, claim 5069): every boot attaches
# a private DiskImageKit stacked disk (read-only base + throwaway ASIF
# overlay), a private EFI var store (recreated fresh per boot, as the
# pre-isolation gate did), and a private serial log under $RUN_DIR — two
# concurrent instances cannot clobber each other's disks, NVRAM, or
# evidence. Set DIPSHIT_GATE_SUFFIX=_alt to give this instance its own
# canonical evidence names (two simultaneous instances MUST differ), and
# DIPSHIT_KEEP_RUN=1 to keep the scratch dir.
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

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-calc-prog-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-calc-prog-report.txt)"

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

# --- per-run isolation -------------------------------------------------------------
# Private scratch dir + pristine-boot overlay for EVERY boot.
# See tools/lib/gate-run.sh.
gate_begin live-calc-prog
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"
SCRIPT2="$RUN_DIR/script2.txt"

# GUI apps are launched BY the desktop (the window server); a bare monitor
# `exec CALC.BIN` fails with `calc: failed to open window`. The desktop owns
# synthesized keyboard input (focused window); the monitor shell stays on the
# serial console, which is what scripts talk to.
cat > "$SCRIPT" <<'EOF'
exec DESKTOP.BIN
EOF
cat > "$SCRIPT2" <<'EOF'
echo calc-prog-live-ok
EOF

# Chord stage (sent once `desktop: menu ready` appears, one chord per
# --input-chords-delay): Return launches manifest index 0 = CALC.BIN, then
# Ctrl+P x2 toggles programmer mode on and off once `calc: ready` has printed.
CHORDS="return,ctrl-p,ctrl-p"

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --display --input --screen "$RUN_DIR/gpu-screen-$tag" \
        --script "$SCRIPT" \
        --script2 "$SCRIPT2" \
        --script2-after "calc: prog-off" \
        --input-chords "$CHORDS" \
        --input-chords-after "desktop: menu ready" \
        --input-chords-delay 3.0 \
        --script-expect "calc-prog-live-ok" \
        --timeout 60 \
        > "$(art live-calc-prog-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-calc-prog-serial-$tag.log)" || true
    local SER="$(art live-calc-prog-serial-$tag.log)"

    local SERIAL_BYTES=0 BANNER=0 CALC_READY=0 PROG_ON=0 PROG_OFF=0 DONE=0
    if [ -f "$SER" ]; then
        SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
        grep -qF -- "DipshitOS kernel has seized control." "$SER" && BANNER=1
        grep -qF -- "calc: ready" "$SER" && CALC_READY=1
        grep -qF -- "calc: prog-on" "$SER" && PROG_ON=1
        grep -qF -- "calc: prog-off" "$SER" && PROG_OFF=1
        grep -qF -- "calc-prog-live-ok" "$SER" && DONE=1
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
