#!/usr/bin/env bash
#
# verify-live-scrollback.sh -- milestone-eighteen card T1 class-B gate (issue #404):
# the terminal scrollback ring on real VZ. Scripted input fills the
# scrollback with 30 echo lines, then the scroll keys (PageUp/PageDown/
# Escape) are typed through the SYNTHESIZED KEYBOARD as NSEvents
# (--input-chords, claim 1809 + claim 5093), and the shell's own `input`
# report proves every chord reached the guest keymap with dropped=0.
#
# Mechanism: the production image is booted with the runner's scripted-input
# mode (--script / --script-expect, claim-6684). Phase 1 (--script) fills
# the scrollback with echo lines until a ready marker appears. Phase 2
# (--input-chords, claim 5093) types the scroll keys then two shell
# commands, all through the VZ keyboard: PageUp x3, PageDown x3, Escape,
# then `echo scroll keys ok` and `input`. The typed echo proves the shell
# stayed live through the scroll keys; the input report proves the 33
# chord events all decoded (events=33 dropped=0).
#
# The walk:
#   echo line-01 … echo line-30           -> fill scrollback
#   echo scrollback-fill-ready            -> phase-1 marker
#   PageUp x3 (keyboard chord)            -> scroll back 30 lines
#   PageDown x3 (keyboard chord)          -> scroll forward 30 (back to live)
#   Escape (keyboard chord)               -> lone ESC key: no-op at the prompt
#   echo scroll keys ok                   -> typed by keyboard: shell survived
#   input                                 -> report: events=33 dropped=0
#                                            (all 33 chord events decoded)
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-scrollback.sh            # BOOTS boots (default 1)
#   BOOTS=3 bash tools/verify-live-scrollback.sh
#
# Evidence saved under artifacts/: live-scrollback-gate.txt,
# live-scrollback-report.txt, live-scrollback-run-<NN>.txt,
# live-scrollback-serial-<NN>.log.

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

# --- phase 2: type the scroll keys through the synthesized keyboard ---------
# Claim 5093: VMRunner macChord gained pageup/pagedown/escape, and the
# guest keymap decodes usages 0x4b/0x4e/0x29 (ESC [ 5 ~ / ESC [ 6 ~ / lone
# ESC). The shell's scroll interceptor consumes the CSI sequences; a lone
# ESC is a no-op at the prompt (lineedit: "a lone ESC does not eat the
# next keystroke"). The typed `echo scroll keys ok` proves the shell
# survived scrolling, and the `input` report proves all 33 chord events
# (7 nav/esc + 19 chars + 2 returns) reached the guest keymap.
# 33 chords x keyDown+keyUp at 2.0s/event ≈ 132s of typing after boot.
CHORDS="pageup,pageup,pageup,pagedown,pagedown,pagedown,escape,e,c,h,o,space,s,c,r,o,l,l,space,k,e,y,s,space,o,k,return,i,n,p,u,t,return"

run_one() {
    local tag="$1"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --input --display \
        --script "$SCRIPT" \
        --input-chords "$CHORDS" --input-chords-after "scrollback-fill-ready" \
        --input-chords-delay 2.0 \
        --script-expect "input: armed=1 fifo=0/64 dropped=0 events=33" \
        --timeout 240 \
        > "artifacts/live-scrollback-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-scrollback-serial-$tag.log" || true

    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log 2>/dev/null | tr -d ' ')
    local BANNER=0 FILL_READY=0 TYPED=0 INREPORT=0 RUNNERFLAG=0
    if [ -f artifacts/vm-serial.log ]; then
        grep -qF -- "DipshitOS kernel has seized control." artifacts/vm-serial.log && BANNER=1
        grep -qF -- "scrollback-fill-ready" artifacts/vm-serial.log && FILL_READY=1
        grep -qF -- "scroll keys ok" artifacts/vm-serial.log && TYPED=1
        grep -qF -- "input: armed=1 fifo=0/64 dropped=0 events=33" artifacts/vm-serial.log && INREPORT=1
    fi
    grep -a -qF -- "input-chords: ENABLED" "artifacts/live-scrollback-run-$tag.txt" && RUNNERFLAG=1
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER fill-ready=$FILL_READY typed=$TYPED report=$INREPORT runner-flag=$RUNNERFLAG"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER fill-ready=$FILL_READY typed=$TYPED report=$INREPORT runner-flag=$RUNNERFLAG"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$FILL_READY" = 1 ] && [ "$TYPED" = 1 ] && [ "$INREPORT" = 1 ] && [ "$RUNNERFLAG" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live-scrollback gate (M18 T1, issue #404) — terminal scrollback on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "phase 1: 30 echo lines + scrollback-fill-ready marker"
    echo "phase 2: keyboard chords pageup x3 + pagedown x3 + escape, then typed 'echo scroll keys ok' + 'input'"
    echo "assertions: banner, fill marker, typed echo, input report events=33 dropped=0, runner input-chords flag"
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
    echo "verify-live-scrollback: PASS — scroll keys typed through the synthesized keyboard don't crash the shell, the typed echo lands, and all 33 chord events decode with dropped=0 ($PASS/$BOOTS boot(s))."
    echo "PASS: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-scrollback: FAILED — $PASS/$BOOTS boot(s) passed; see artifacts/live-scrollback-report.txt and the per-boot serial logs."
    echo "FAIL: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
