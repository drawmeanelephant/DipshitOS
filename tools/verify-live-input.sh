#!/usr/bin/env bash
#
# verify-live-input.sh -- claim 6050 (milestone seven, card I3) class-B
# gate: a scripted keyboard sequence types a real command into the Road Pops
# terminal on real VZ hardware.
#
# Mechanism: the runner's --input flag attaches the keyboard + pointing
# devices (VZUSBKeyboardConfiguration + VZUSBScreenCoordinatePointingDevice
# Configuration, claim 4272). The guest drives them through the XHCI
# transport (I1) + USB enumeration (I2) and, in I3, drains the interrupt-IN
# reports into a bounded BSS event FIFO, decodes HID boot-protocol keycodes
# to ASCII through the keymap, and feeds the Road Pops tee's read path so
# the decoded bytes reach the line editor — the FIRST keystrokes drive the
# on-screen terminal.
#
# VZ has no programmatic keyboard API, so the runner synthesizes one NSEvent
# per keystroke (keyDown + keyUp, shift for uppercase, `\n` = Enter) and
# dispatches it to the VZVirtualMachineView via --input-string + 
# --input-string-after. The typed text is "input\n" (the I3 monitor command),
# so the gate's evidence is the guest's OWN `input` report — typed by the
# keyboard, not the serial script.
#
# Claim-time observations (pinned in docs/hardware-contract.md, saved logs
# under artifacts/live-input-*):
#   * VZ delivers one interrupt-IN report per key state change, but the
#     delivery rate tracks the guest's Road Pops present cadence: a full-
#     frame virtio-gpu present per output batch is the slow step, and typing
#     faster than ~2 s per keystroke drops reports (the endpoint holds one
#     pending report). The runner's --input-string therefore types at 2 s
#     per keyDown/keyUp. Single-TRB arming (one armed report TRB, re-armed
#     on every completion) is the correct shape; the earlier multi-TRB
#     depth experiment wrapped the transfer ring at the 8th report and
#     dropped everything after, so I3 arms exactly one TRB and re-arms per
#     completion.
#   * The drain runs BEFORE the Road Pops present in the shell idle loop so
#     a report is never starved behind a slow full-frame present.
#   * The keymap covers the usable ASCII subset (letters, digits, Enter,
#     Backspace, Tab, Space, common punctuation) and refuses anything else
#     (no invented bytes).
#
# The gate: ONE run on VZ with --input --display. The serial script only
# echoes a marker (the shell stays responsive); the KEYBOARD types "input\n"
# after the boot self-test (`userspace: el0=1`) settles. The assertions:
# the boot-time input arming, the typed `input` command's report (events=6 =
# i,n,p,u,t,Enter with zero drops, kb-byte=0xa = Enter), the serial marker,
# and the runner's --input-string flag line.
#
# The default VM is untouched: without --input config.keyboards/pointing
# Devices stay [] and every existing gate stays byte-identical (the full
# verify-vz aggregate is re-run separately as proof).
#
# Class B — Apple silicon + VZ only; boots a real VM. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-input.sh
#
# Evidence: artifacts/live-input-gate.txt (full output),
# artifacts/live-input-report.txt (per-phase detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-input-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-input-report.txt"

echo "=== verify-live-input: claim 6050 — scripted key sequence types a real command into Road Pops, live on VZ ==="

# --- tool versions + revision -----------------------------------------------
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

# --- scripted keystrokes ----------------------------------------------------
# The serial script only proves the shell stays responsive on serial; the
# REAL command ("input\n") is typed by the keyboard via --input-string.
cat > artifacts/live-input-script.txt <<'EOF'
echo i3-serial-ok
EOF

# --- per-run gate ------------------------------------------------------------
run_one() {
    local out="$1" serial="$2"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --input --display \
        --script artifacts/live-input-script.txt \
        --input-string "input"$'\n' --input-string-after "userspace: el0=1" \
        --script-expect $'input: armed=1 fifo=0/64 dropped=0 events=6 kb-mods=0x0 kb-usage=0x28 kb-byte=0xa ptr-btns=0 ptr-x=0 ptr-y=0 ptr-reports=0' \
        --timeout 50 \
        > "$out" 2>&1
    local RC=$?
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "$serial" || true
    echo "$RC" > /tmp/live-input-rc.txt
}

rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
set +e
run_one "artifacts/live-input-run.txt" "artifacts/live-input-serial.log"
RC="$(cat /tmp/live-input-rc.txt)"
set -e

# --- assertions --------------------------------------------------------------
SERIAL="artifacts/live-input-serial.log"
SERIAL_BYTES=0 ARMED=0 REPORTED=0 EVENTS=0 NODROP=0 ENTER=0 OBSDONE=0 RUNNERFLAG=0
if [ -f "$SERIAL" ]; then
    SERIAL_BYTES=$(wc -c < "$SERIAL" | tr -d ' ')
    # Boot-time arming: the input path is armed after enumeration.
    grep -a -qF -- "input: armed" "$SERIAL" && ARMED=1
    # THE deterministic proof: the keyboard-typed `input` command printed
    # its report — the guest's own accounting of the typed sequence.
    grep -a -qF -- "input: armed=1 fifo=0/64 dropped=0 events=6 kb-mods=0x0 kb-usage=0x28 kb-byte=0xa ptr-btns=0 ptr-x=0 ptr-y=0 ptr-reports=0" "$SERIAL" && REPORTED=1
    # Six decoded key-down events (i, n, p, u, t, Enter).
    grep -a -qF -- "events=6" "$SERIAL" && EVENTS=1
    # Zero dropped reports (the bounded FIFO + per-completion re-arm held).
    grep -a -qF -- "dropped=0" "$SERIAL" && NODROP=1
    # The last decoded byte is Enter (HID usage 0x28 -> ASCII 0x0a).
    grep -a -qF -- "kb-usage=0x28 kb-byte=0xa" "$SERIAL" && ENTER=1
    # A responsive shell (the serial marker).
    grep -a -qF -- "i3-serial-ok" "$SERIAL" && OBSDONE=1
fi
# The runner attached the keyboard seam (its own report line).
grep -a -qF -- "input-string: ENABLED" artifacts/live-input-run.txt && RUNNERFLAG=1

echo "input: rc=$RC serial-bytes=$SERIAL_BYTES armed=$ARMED report=$REPORTED events=$EVENTS no-drop=$NODROP enter=$ENTER obs-done=$OBSDONE runner-flag=$RUNNERFLAG"

PASS=0
if [ "$RC" = 0 ] && [ "$ARMED" = 1 ] && [ "$REPORTED" = 1 ] && [ "$EVENTS" = 1 ] && \
   [ "$NODROP" = 1 ] && [ "$ENTER" = 1 ] && [ "$OBSDONE" = 1 ] && [ "$RUNNERFLAG" = 1 ]; then
    PASS=1
fi

{
    echo "DIPSHITOS live input gate (claim 6050, milestone seven card I3) — scripted keystrokes drive Road Pops, on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "phase: keyboard types input\\n (the I3 monitor command) after the boot self-test"
    echo "assertions: boot-time input arming, the typed input command's report (events=6 = i,n,p,u,t,Enter; dropped=0; kb-usage=0x28 kb-byte=0xa = Enter), the serial marker, the runner's input-string flag line"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} > "$REPORT"

echo
echo "=== result ==="
if [ "$PASS" = 1 ]; then
    echo "verify-live-input: PASS — a scripted keyboard sequence (VZ has no keyboard API; the runner synthesizes one NSEvent per keyDown/keyUp into the VZVirtualMachineView) typed input\\n into the Road Pops terminal over the XHCI transport, and the guest's own input command reported events=6 (i, n, p, u, t, Enter) with dropped=0 and kb-byte=0xa (Enter) — the bounded BSS event FIFO + keycode decode + shell-idle drain carried the keystrokes end to end with no lost reports. The evidence shape is the guest's own accounting (byte-exact host capture does not apply to a memory-mapped controller). The default VM is untouched: without --input, config.keyboards/pointingDevices stay []."
    echo "PASS: $PASS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-input: FAILED — see artifacts/live-input-report.txt, the runner output (live-input-run.txt), and the serial log (live-input-serial.log)."
    echo "FAIL: $PASS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
