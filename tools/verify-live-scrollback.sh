#!/usr/bin/env bash
#
# verify-live-scrollback.sh -- milestone-eighteen card T1 class-B gate (issue #404):
# the terminal scrollback ring on real VZ. Host scripted keystrokes fill the
# scrollback with 30 echo lines, then inject PageUp/PageDown CSI sequences
# via --input-string, and verify the shell remains responsive (no crash or
# hang from the scroll-key CSI interceptor).
#
# Mechanism: the production image is booted with the runner's scripted-input
# mode (--script / --input-string / --script-expect, claim-6684). Phase 1
# (--script) fills the scrollback with echo lines until a ready marker
# appears. Phase 2 (--input-string, gated on --input-string-after the marker)
# sends PageUp ×3 then PageDown ×3, then a final echo to prove the shell
# survived.
#
# The walk:
#   echo line-01 … echo line-30           -> fill scrollback
#   echo scrollback-fill-ready            -> phase-1 marker
#   \x1b[5~ ×3 (PageUp)                  -> scroll back 30 lines
#   \x1b[6~ ×3 (PageDown)                -> scroll forward 30 (back to live)
#   echo scrollback-live-done             -> proves shell survives scrolling
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-scrollback.sh            # BOOTS boots (default 1)
#   BOOTS=3 bash tools/verify-live-scrollback.sh
#
# Evidence saved under artifacts/: live-scrollback-gate.txt,
# live-scrollback-report.txt, live-scrollback-run-<NN>.txt,
# live-scrollback-serial-<NN>.log, live-scrollback-script.txt.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-scrollback-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-scrollback-report.txt"
SCRIPT="artifacts/live-scrollback-script.txt"

echo "=== verify-live-scrollback: M18 T1 — terminal scrollback on VZ, $BOOTS boot(s) ==="

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

# --- phase 1: fill scrollback with output (regular script) ------------------
cat > "$SCRIPT" <<'EOF'
echo line-01
echo line-02
echo line-03
echo line-04
echo line-05
echo line-06
echo line-07
echo line-08
echo line-09
echo line-10
echo line-11
echo line-12
echo line-13
echo line-14
echo line-15
echo line-16
echo line-17
echo line-18
echo line-19
echo line-20
echo line-21
echo line-22
echo line-23
echo line-24
echo line-25
echo line-26
echo line-27
echo line-28
echo line-29
echo line-30
echo scrollback-fill-ready
EOF

# --- phase 2: inject PageUp ×3 + PageDown ×3 + final echo -------------------
# The runner types these as keyDown+keyUp per character (claim 6050 semantics).
# PageUp = ESC [ 5 ~, PageDown = ESC [ 6 ~
PGUP=$'\x1b[5~'
PGDN=$'\x1b[6~'
INPUT_STRING="${PGUP}${PGUP}${PGUP}${PGDN}${PGDN}${PGDN}echo alive-after-scroll
echo scrollback-live-done
"

run_one() {
    local tag="$1"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" \
        --input-string "$INPUT_STRING" \
        --input-string-after "scrollback-fill-ready" \
        --script-expect "scrollback-live-done" \
        --timeout 40 \
        > "artifacts/live-scrollback-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-scrollback-serial-$tag.log" || true

    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log 2>/dev/null | tr -d ' ')
    local BANNER=0 FILL_READY=0 ALIVE=0 DONE=0
    if [ -f artifacts/vm-serial.log ]; then
        grep -qF -- "DipshitOS kernel has seized control." artifacts/vm-serial.log && BANNER=1
        grep -qF -- "scrollback-fill-ready" artifacts/vm-serial.log && FILL_READY=1
        grep -qF -- "alive-after-scroll" artifacts/vm-serial.log && ALIVE=1
        grep -qF -- "scrollback-live-done" artifacts/vm-serial.log && DONE=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER fill-ready=$FILL_READY alive=$ALIVE done=$DONE"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER fill-ready=$FILL_READY alive=$ALIVE done=$DONE"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$FILL_READY" = 1 ] && [ "$ALIVE" = 1 ] && [ "$DONE" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live-scrollback gate (M18 T1, issue #404) — terminal scrollback on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "phase 1: 30 echo lines + scrollback-fill-ready marker"
    echo "phase 2: PageUp×3 PageDown×3 + echo alive-after-scroll + scrollback-live-done"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-scrollback boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-scrollback: PASS — scrollback ring survives live VZ boot: scroll keys don't crash the shell, and follow-up commands run ($PASS/$BOOTS boot(s))."
    echo "PASS: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-scrollback: FAILED — $PASS/$BOOTS boot(s) passed; see artifacts/live-scrollback-report.txt and the per-boot serial logs."
    echo "FAIL: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 1
fi