#!/usr/bin/env bash
#
# verify-live-editing.sh -- milestone-eight card U2 class-B gate (claim 1809):
# the ADR 0008 D2 line editor on real VZ hardware. A scripted CHORD sequence
# (printable chars + Up arrow + Left arrow, typed by a real keyboard) drives
# history recall and mid-line cursor editing through the I3 input path, and
# the gate asserts the edited commands actually ran in vm-serial.log.
#
# Mechanism: the runner's --input flag attaches the keyboard (claim 4272);
# the guest drives it through the XHCI transport (I1) + USB enumeration (I2)
# and I3's keymap decodes the HID reports. The new --input-chords seam (this
# card) synthesizes one NSEvent per chord (keyDown + keyUp) into the
# VZVirtualMachineView after a marker, so arrows/Ctrl chords reach the I3
# keymap over a real VZ keyboard (VZ has no programmatic keyboard API).
#
# The chord sequence (typed by the KEYBOARD, not the serial script):
#   echo ab <Left> c <Enter> -> mid-line insert -> "echo acb", prints "acb"
#   <Up> <Enter>             -> recalls "echo acb", re-runs it, prints "acb"
#   echo u2done <Enter>      -> the runner's --script-expect exit marker
#
# Assertions (grep -Fx = exact full lines, so the echo OUTPUT is counted and
# the echoed command text is not):
#   "acb" appears exactly twice (mid-line insert + the Up recall re-ran it);
#   "u2done" appears exactly once (the runner's exit marker);
#   the boot-time input arming, the serial marker, and the runner's
#   input-chords flag line all appear.
#
# The default VM is untouched: without --input config.keyboards/pointing
# Devices stay [] and every existing gate stays byte-identical.
#
# Class B -- Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-editing.sh
#
# Evidence: artifacts/live-editing-gate.txt (full output),
# artifacts/live-editing-report.txt (per-phase detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-editing-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-editing-report.txt"

echo "=== verify-live-editing: claim 1809 — scripted chords drive history recall + cursor editing, live on VZ ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- the serial script + the keyboard chord sequence ------------------------
# The serial script only proves the shell stays responsive on serial; the
# REAL editing is typed by the keyboard via --input-chords. The chords start
# AFTER the boot self-test settles ("userspace: el0=1", the same marker the
# I3 gate uses) — typing during the settling boot drops reports (the XHCI
# interrupt-IN endpoint holds one pending report and VZ's delivery tracks the
# Road Pops present cadence). The serial marker "u2-serial-ok" appears BEFORE
# that point, so the two input paths never interleave.
#
# The sequence:
#   echo ab <Left> c <Enter>  -> mid-line insert -> "echo acb", prints "acb"
#   <Up> <Enter>              -> history recall -> re-runs it, prints "acb"
#   echo u2done <Enter>       -> final marker (the runner's exit condition)
cat > artifacts/live-editing-script.txt <<'EOF'
echo u2-serial-ok
EOF

CHORDS="e,c,h,o,space,a,b,left,c,return,up,return,e,c,h,o,space,u,2,d,o,n,e,return"

run_one() {
    local out="$1" serial="$2"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --input --display \
        --script artifacts/live-editing-script.txt \
        --input-chords "$CHORDS" --input-chords-after "userspace: el0=1" \
        --script-expect "u2done" \
        --timeout 160 \
        > "$out" 2>&1
    local RC=$?
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "$serial" || true
    echo "$RC" > /tmp/live-editing-rc.txt
}

rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
set +e
run_one "artifacts/live-editing-run.txt" "artifacts/live-editing-serial.log"
RC="$(cat /tmp/live-editing-rc.txt)"
set -e

SERIAL="artifacts/live-editing-serial.log"
SERIAL_BYTES=0 ARMED=0 ACB2=0 DONE=0 SERIALOK=0 RUNNERFLAG=0
if [ -f "$SERIAL" ]; then
    SERIAL_BYTES=$(wc -c < "$SERIAL" | tr -d ' ')
    # Boot-time input arming: the keyboard path is up after enumeration.
    grep -a -qF -- "input: armed" "$SERIAL" && ARMED=1
    # "acb" appears exactly twice: once for the typed 'echo acb' (mid-line
    # insert: 'echo ab' + Left + 'c'), once for the Up-arrow recall re-run.
    if [ "$(grep -a -cFx 'acb' "$SERIAL" | tr -d ' ')" = "2" ]; then ACB2=1; fi
    # The final marker command ran (the runner's exit condition).
    if [ "$(grep -a -cFx 'u2done' "$SERIAL" | tr -d ' ')" = "1" ]; then DONE=1; fi
    # The serial marker (the shell stayed responsive on serial).
    grep -a -qF -- "u2-serial-ok" "$SERIAL" && SERIALOK=1
fi
# The runner attached the chord seam (its own report line).
grep -a -qF -- "input-chords: ENABLED" artifacts/live-editing-run.txt && RUNNERFLAG=1

echo "editing: rc=$RC serial-bytes=$SERIAL_BYTES armed=$ARMED acb-x2=$ACB2 done=$DONE serial-ok=$SERIALOK runner-flag=$RUNNERFLAG"

PASS=0
if [ "$RC" = 0 ] && [ "$ARMED" = 1 ] && [ "$ACB2" = 1 ] && [ "$DONE" = 1 ] && \
   [ "$SERIALOK" = 1 ] && [ "$RUNNERFLAG" = 1 ]; then
    PASS=1
fi

{
    echo "DIPSHITOS live editing gate (claim 1809, milestone eight card U2) — scripted chords drive history recall + cursor editing, on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "phase: keyboard types 'echo ab <Left> c <Enter> <Up> <Enter> echo u2done <Enter>' after the boot self-test"
    echo "assertions: input arming, the mid-line insert produced 'echo acb' and the Up recall re-ran it (acb x2), the final marker (u2done x1), the serial marker, the runner's input-chords flag line"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} > "$REPORT"

echo
echo "=== result ==="
if [ "$PASS" = 1 ]; then
    echo "verify-live-editing: PASS — a scripted keyboard chord sequence (VZ has no keyboard API; the runner synthesizes one NSEvent per keyDown/keyUp into the VZVirtualMachineView) drove mid-line cursor editing (Left + 'c' turned 'echo ab' into 'echo acb') and history recall (Up re-ran it) over the XHCI transport end to end, and the guest's own output is the proof. The default VM is untouched: without --input, config.keyboards/pointingDevices stay []."
    echo "PASS: $PASS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-editing: FAILED — see artifacts/live-editing-report.txt, the runner output (live-editing-run.txt), and the serial log (live-editing-serial.log)."
    echo "FAIL: $PASS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
