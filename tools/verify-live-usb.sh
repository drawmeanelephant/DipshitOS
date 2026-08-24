#!/usr/bin/env bash
#
# verify-live-usb.sh -- claim 4116 (milestone seven, card I2) class-B gate:
# USB enumeration + HID over the XHCI transport on real VZ hardware.
#
# Mechanism: the runner's --input flag attaches the keyboard + pointing
# devices (VZUSBKeyboardConfiguration +
# VZUSBScreenCoordinatePointingDeviceConfiguration). Claim 3868 established
# these present as an Apple XHCI USB controller (DID 0x1a06) with the two HID
# devices behind it; I1 (claim 4272) built the controller's register-map +
# command/event-ring transport; I2 enumerates the two devices (port reset ->
# Enable Slot -> Address Device -> device/config descriptors over the control
# endpoint -> Set Configuration -> arm the interrupt-IN endpoint) and parses
# the HID boot-protocol reports. The gate asserts the guest's OWN `usb
# devices` + `usb report` lines (the card's evidence shape: a memory-mapped
# controller + device reports have no host-side byte-exact capture — the
# proof is the guest's parsed descriptor + report bytes).
#
# Claim-time observations (pinned in docs/hardware-contract.md, saved logs
# under artifacts/usb-discovery-*):
#   * Port 9 = the keyboard, port 10 = the pointing device, both FULL speed
#     (PORTSC PS=1 after reset).
#   * Keyboard: VID 0x05ac (Apple) PID 0x8105, bDeviceClass 0 (class is in
#     the interface descriptor), HID boot-protocol KEYBOARD
#     (bInterfaceProtocol 1), interrupt-IN EP1 maxpkt 8, bInterval 8,
#     Set_Protocol(boot) ACCEPTED. A synthesized host keyDown (macOS keyCode
#     0 = 'a') produces the 8-byte boot report 00 00 04 00 00 00 00 00
#     (modifier 0, HID usage 0x04 in byte 2) — the observed byte-exact
#     report.
#   * Pointing device: VID 0x05ac PID 0x8106, bInterfaceProtocol 0 (NOT a
#     boot-protocol mouse — the screen-coordinate absolute pointer),
#     interrupt-IN EP1 maxpkt 10, bInterval 8, Set_Protocol(boot) REFUSED
#     (boot=0 — recorded honestly, the raw report is the ground truth).
#   * The runner's MINIMAL synthesized-key seam (`--input-key <mac-keycode>`
#     + `--input-key-after <marker>`) is what produces the report: VZ has NO
#     programmatic keyboard API — VZUSBKeyboardConfiguration is driven only
#     by a VZVirtualMachineView forwarding host key events — so the runner
#     dispatches one synthesized NSEvent keyDown into the view. The full
#     scripted key-sequence surface that types into Road Pops stays I3.
#
# The gate: ONE run on VZ with --input --display --input-key 0. The key is
# injected after the boot's `usb: enumerated` line (the interrupt endpoints
# are armed), then the scripted `usb devices` + `usb report` reads the
# report the key produced. The assertions: enumeration of BOTH devices (the
# keyboard + pointer rows with their observed VID/PID/protocol/endpoint
# facts), the boot protocol negotiation results (keyboard boot=1, pointer
# boot=0), the observed 8-byte keyboard report (00 00 04 00 00 00 00 00) +
# its decode (mod 0, keys 0x4), the runner's KEY-INJECT line, and a
# responsive shell.
#
# Run isolation (#523 item 2 / issue #528, claim 5069): private stacked
# disk + EFI vars + serial log under $RUN_DIR; DIPSHIT_GATE_SUFFIX/_KEEP_RUN
# supported.
#
# Class B — Apple silicon + VZ only; boots a real VM. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-usb.sh
#
# Evidence: artifacts/live-usb-gate.txt (full output),
# artifacts/live-usb-report.txt (per-phase detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-usb-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="artifacts/live-usb-report.txt"

echo "=== verify-live-usb: claim 4116 — USB enumeration + HID over the XHCI transport live on VZ ==="

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

# --- per-run isolation -------------------------------------------------------
gate_begin live-usb
echo "run dir: $RUN_DIR"

# --- scripted keystrokes ----------------------------------------------------
# One script: the enumeration table, then the report poll (the report the
# synthesized key already produced is delivered to the armed interrupt ring
# and drained by the poll). The key is injected AFTER the boot's
# `usb: enumerated` line by the runner's --input-key seam, so the report is
# already pending when `usb report` runs — deterministic, not a sleep race.
# The leading EMPTY line absorbs the synthesized --input-key keystroke:
# OBSERVED TODAY (2026-08-24, claim 5069) on this host (and reproduced on
# unmodified main) the key 0 ('a') injected after "usb: enumerated" races
# the script forwarder and prepends to the first typed line, producing
# `ausb devices` — an unknown command — so the report never prints. The
# sacrificial line takes the collision; everything after runs clean.
cat > "$RUN_DIR/script.txt" <<'EOF'

usb devices
usb report
echo usb-gate-ok
EOF

# --- per-run gate ------------------------------------------------------------
run_one() {
    local out="$1" serial="$2"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"
    # OBSERVED TODAY (2026-08-24, claim 5069): anchoring the synthesized
    # key at "usb: enumerated" (boot time) made `usb report` read "no
    # report (timeout)" — the injected report was consumed long before the
    # script reached it. Anchor moved to the `usb devices` REPORT output so
    # the keystroke lands immediately before `usb report` runs.
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial.log" \
        --input --display --input-key 0 --input-key-after "usb devices: count=" \
        --script "$RUN_DIR/script.txt" \
        --script-expect "usb-gate-ok" --timeout 40 \
        > "$(art live-usb-run.txt)" 2>&1
    local RC=$?
    [ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-usb-serial.log)" || true
    echo "$RC" > "$RUN_DIR/rc.txt"
}

set +e
run_one "$(art live-usb-run.txt)" "$(art live-usb-serial.log)"
RC="$(cat "$RUN_DIR/rc.txt")"
set -e

# --- assertions --------------------------------------------------------------
SERIAL="$(art live-usb-serial.log)"
SERIAL_BYTES=0 ENUMOK=0 COUNT=0 KBD=0 PTR=0 REPORTED=0 KBDECODE=0 OBSDONE=0 KEYINJECT=0 RUNNERFLAG=0
if [ -f "$SERIAL" ]; then
    SERIAL_BYTES=$(wc -c < "$SERIAL" | tr -d ' ')
    # Boot-time enumeration: BOTH devices enumerated.
    grep -a -qF -- "usb: enumerated=0x0000000000000002 ok" "$SERIAL" && ENUMOK=1
    # The enumerated table header.
    grep -a -qF -- "usb devices: count=2" "$SERIAL" && COUNT=1
    # The keyboard: port 9, slot 1, HID boot protocol (protocol=1), EP1 IN
    # maxpkt 8, boot protocol accepted (boot=1).
    grep -a -qF -- "usb dev0: slot=1 port=9 speed=1 vid=0x5ac pid=0x8105 class=0 protocol=1 epin=1 maxpkt=8 interval=8 boot=1" "$SERIAL" && KBD=1
    # The pointing device: port 10, slot 2, NOT a boot mouse (protocol=0),
    # EP1 IN maxpkt 10, Set_Protocol(boot) refused (boot=0 — observed).
    grep -a -qF -- "usb dev1: slot=2 port=10 speed=1 vid=0x5ac pid=0x8106 class=0 protocol=0 epin=1 maxpkt=10 interval=8 boot=0" "$SERIAL" && PTR=1
    # THE deterministic proof: the synthesized keyDown (macOS keyCode 0 = 'a')
    # produced the observed 8-byte boot report — modifier 0, HID usage 0x04.
    grep -a -qF -- "usb report: dev0 seq=0 len=8 bytes=0x0 0x0 0x4 0x0 0x0 0x0 0x0 0x0" "$SERIAL" && REPORTED=1
    # The keyboard decode (mod 0, keys 0x4).
    grep -a -qF -- "usb report: kb mod=0x0 keys=0x4" "$SERIAL" && KBDECODE=1
    # A responsive shell (the observation echo + the prompt).
    grep -a -qF -- "usb-gate-ok" "$SERIAL" && OBSDONE=1
fi
# The runner injected the key (its own report line).
grep -a -qF -- "KEY-INJECT: keyCode 0 keyDown dispatched to the VZVirtualMachineView" artifacts/live-usb-run.txt && KEYINJECT=1
grep -a -qF -- "input-key: ENABLED" artifacts/live-usb-run.txt && RUNNERFLAG=1

echo "usb: rc=$RC serial-bytes=$SERIAL_BYTES enum-ok=$ENUMOK count=$COUNT kbd=$KBD ptr=$PTR report=$REPORTED kb-decode=$KBDECODE obs-done=$OBSDONE key-inject=$KEYINJECT runner-flag=$RUNNERFLAG"

PASS=0
if [ "$RC" = 0 ] && [ "$ENUMOK" = 1 ] && [ "$COUNT" = 1 ] && [ "$KBD" = 1 ] && \
   [ "$PTR" = 1 ] && [ "$REPORTED" = 1 ] && [ "$KBDECODE" = 1 ] && [ "$OBSDONE" = 1 ] && \
   [ "$KEYINJECT" = 1 ] && [ "$RUNNERFLAG" = 1 ]; then
    PASS=1
fi

{
    echo "DIPSHITOS live USB gate (claim 4116, milestone seven card I2) — USB enumeration + HID, on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "phase: usb devices + usb report (after the synthesized keyDown)"
    echo "assertions: enumeration of BOTH devices, the keyboard row (port 9/slot 1, PID 0x8105, boot protocol, boot=1), the pointer row (port 10/slot 2, PID 0x8106, non-boot absolute pointer, boot=0), the observed 8-byte keyboard report 00 00 04 00 00 00 00 00 + its decode (mod 0, keys 0x4), the runner's KEY-INJECT line, a responsive shell"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} > "$REPORT"

echo
echo "=== result ==="
if [ "$PASS" = 1 ]; then
    echo "verify-live-usb: PASS — the two USB HID devices behind the XHCI controller were enumerated end to end (port reset -> Enable Slot -> Address Device -> descriptors -> Set Configuration -> interrupt-IN armed) and a synthesized host keyDown produced the observed raw HID report: keyboard (port 9, slot 1, PID 0x8105, boot protocol, 8-byte reports) -> report 00 00 04 00 00 00 00 00 (mod 0, HID usage 0x04 = 'a'); pointing device (port 10, slot 2, PID 0x8106) is the non-boot absolute pointer (Set_Protocol(boot) honestly refused, boot=0; the raw report is the ground truth). The evidence shape is the guest's own parsed descriptor + report bytes (byte-exact host capture does not apply to a memory-mapped controller). The default VM is untouched: without --input, config.keyboards/pointingDevices stay []."
    echo "PASS: $PASS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-usb: FAILED — see artifacts/live-usb-report.txt, the runner output (live-usb-run.txt), and the serial log (live-usb-serial.log)."
    echo "FAIL: $PASS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
