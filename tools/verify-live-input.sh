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
# Run isolation (#523 item 2 / issue #528, claim 5069): private stacked
# disk + EFI vars + serial log under $RUN_DIR; DIPSHIT_GATE_SUFFIX/_KEEP_RUN
# supported.
#
# ---------------------------------------------------------------------------
# Claim 9588 phase (--via-virtio): the same proof WITHOUT synthesis and
# WITHOUT a window. GATE_VIRTIO selects the phases:
#
#   GATE_VIRTIO=0    (default) classic synthesized-NSEvent phase only —
#                    byte-identical to the pre-9588 gate;
#   GATE_VIRTIO=1    claim-9588 custom-virtio INPUT-queue phase ONLY;
#   GATE_VIRTIO=all  both phases back to back (PASS requires both).
#
# The virtio phase boots HEADLESS (no --display, no --input — no USB
# keyboard exists, `input: armed=0`) and injects "input\n" through the
# custom-virtio device's queue 3 as HID-shaped 16-byte messages (wire format
# normative in docs/hardware-contract.md). The guest decodes them through
# the SAME decode_keyboard_report path XHCI reports take. Assertions: the
# guest's own `input` report shows events=6 kb-usage=0x28 kb-byte=0xa WITH
# armed=0 (keys arrived, yet no USB keyboard was ever attached), plus the
# host enqueue evidence. This attacks BOTH open threads: #179 (synthesized
# seam reporting events=0 — here there is nothing synthesized to drop) and
# #151 (pointer focus class-C-only due to the activation wall — here no
# window or activation exists at all).
#
# Class B — Apple silicon + VZ only; boots a real VM. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-input.sh              # classic phase (as before)
#   GATE_VIRTIO=1 bash tools/verify-live-input.sh    # claim-9588 phase only
#   GATE_VIRTIO=all bash tools/verify-live-input.sh  # both phases
#
# Evidence: artifacts/live-input-gate.txt (full output),
# artifacts/live-input-report.txt (classic-phase detail),
# artifacts/live-input-virtio-report.txt (claim-9588 phase detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-input-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="artifacts/live-input-report.txt"
VREPORT="artifacts/live-input-virtio-report.txt"
GATE_VIRTIO="${GATE_VIRTIO:-0}"

echo "=== verify-live-input: claim 6050 — scripted key sequence types a real command into Road Pops, live on VZ (GATE_VIRTIO=$GATE_VIRTIO) ==="

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
if [ "$GATE_VIRTIO" != "1" ]; then
    # Classic phase: the BASE binary (no custom-virtio types referenced).
    swift build --package-path host/vm-runner --configuration release
    codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner
fi

CLASSIC_PASS=0
VIRTIO_PASS=0

# ===========================================================================
# Phase 1 (default): claim 6050 — synthesized NSEvents over XHCI
# ===========================================================================
if [ "$GATE_VIRTIO" != "1" ]; then

# --- per-run isolation -------------------------------------------------------
gate_begin live-input
echo "run dir: $RUN_DIR"

# --- scripted keystrokes ----------------------------------------------------
# The serial script only proves the shell stays responsive on serial; the
# REAL command ("input\n") is typed by the keyboard via --input-string.
cat > "$RUN_DIR/script.txt" <<'EOF'
echo i3-serial-ok
EOF

# --- per-run gate ------------------------------------------------------------
run_one() {
    local out="$1" serial="$2"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial.log" \
        --input --display \
        --script "$RUN_DIR/script.txt" \
        --input-string "input"$'\n' --input-string-after "userspace: el0=1" \
        --script-expect "input: armed=" \
        --timeout 70 \
        > "$(art live-input-run.txt)" 2>&1
    local RC=$?
    [ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-input-serial.log)" || true
    echo "$RC" > "$RUN_DIR/rc.txt"
}

set +e
run_one "$(art live-input-run.txt)" "$(art live-input-serial.log)"
RC="$(cat "$RUN_DIR/rc.txt")"
set -e
gate_end

# --- assertions --------------------------------------------------------------
SERIAL="$(art live-input-serial.log)"
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
grep -a -qF -- "input-string: ENABLED" "$(art live-input-run.txt)" && RUNNERFLAG=1

echo "input: rc=$RC serial-bytes=$SERIAL_BYTES armed=$ARMED report=$REPORTED events=$EVENTS no-drop=$NODROP enter=$ENTER obs-done=$OBSDONE runner-flag=$RUNNERFLAG"

PASS=0
if [ "$RC" = 0 ] && [ "$ARMED" = 1 ] && [ "$REPORTED" = 1 ] && [ "$EVENTS" = 1 ] && \
   [ "$NODROP" = 1 ] && [ "$ENTER" = 1 ] && [ "$OBSDONE" = 1 ] && [ "$RUNNERFLAG" = 1 ]; then
    PASS=1
    CLASSIC_PASS=1
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
echo "=== result (classic phase) ==="
if [ "$PASS" = 1 ]; then
    echo "verify-live-input: PASS — a scripted keyboard sequence (VZ has no keyboard API; the runner synthesizes one NSEvent per keyDown/keyUp into the VZVirtualMachineView) typed input\\n into the Road Pops terminal over the XHCI transport, and the guest's own input command reported events=6 (i, n, p, u, t, Enter) with dropped=0 and kb-byte=0xa (Enter) — the bounded BSS event FIFO + keycode decode + shell-idle drain carried the keystrokes end to end with no lost reports. The evidence shape is the guest's own accounting (byte-exact host capture does not apply to a memory-mapped controller). The default VM is untouched: without --input, config.keyboards/pointingDevices stay []."
    echo "PASS: $PASS" >> "$REPORT"
else
    echo "verify-live-input: FAILED — see artifacts/live-input-report.txt, the runner output (live-input-run.txt), and the serial log (live-input-serial.log)."
    echo "FAIL: $PASS" >> "$REPORT"
fi
fi # classic phase

# ===========================================================================
# Phase 2 (GATE_VIRTIO=1|all): claim 9588 — HID-shaped messages over the
# custom-virtio INPUT queue. Headless: no --display, no --input, no view,
# no window, no CGEvent/NSEvent anywhere.
# ===========================================================================
if [ "$GATE_VIRTIO" = "1" ] || [ "$GATE_VIRTIO" = "all" ]; then

# The SPIKE binary (macOS 27 SDK types; `zig build spike-virtio` drives the
# same shape). Rebuild + re-sign AFTER the classic phase so its run used the
# base binary exactly as before.
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-input-virtio
echo "run dir: $RUN_DIR"

# The serial script echoes the INJECTION TRIGGER marker: the runner forwards
# the script once (its own choreography), the guest echoes the line, and only
# THEN does the injection path start enqueueing — strictly ordered, not a
# sleep. The typed text ("input\n") is carried by the virtio channel itself.
cat > "$RUN_DIR/script-virtio.txt" <<'EOF'
echo i3-virtio-pre
EOF

run_virtio() {
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial.log" \
        --via-virtio \
        --script "$RUN_DIR/script-virtio.txt" \
        --input-string "input"$'\n' --input-string-after "i3-virtio-pre" \
        --script-expect "input: armed=" \
        --timeout 90 \
        > "$(art live-input-virtio-run.txt)" 2>&1
    local RC=$?
    [ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-input-virtio-serial.log)" || true
    echo "$RC" > "$RUN_DIR/rc.txt"
}

set +e
run_virtio
VRC="$(cat "$RUN_DIR/rc.txt")"
set -e
gate_end

# --- assertions --------------------------------------------------------------
VSERIAL="$(art live-input-virtio-serial.log)"
VRUN="$(art live-input-virtio-run.txt)"
VSERIAL_BYTES=0 G_DEVICE=0 G_Q3ARMED=0 G_REPORT=0 G_EVENTS=0 G_ENTER=0 G_Q2=0 G_MARKER=0
H_ENABLED=0 H_DRIVER_OK=0 H_ENQUEUE_I=0 H_ENQUEUE_ENTER=0 H_KEYSEQ=0 H_NOSYNTH=0 H_NOVIEW=0
if [ -f "$VSERIAL" ]; then
    VSERIAL_BYTES=$(wc -c < "$VSERIAL" | tr -d ' ')
    # The custom device came up and the input pool armed (queue 3 present).
    grep -a -qF -- "cvspike: init ok" "$VSERIAL" && G_DEVICE=1
    grep -a -qF -- "cvspike: q3 armed bufs=" "$VSERIAL" && G_Q3ARMED=1
    # THE deterministic proof: the guest's OWN input report shows SIX decoded
    # key-down events with armed=0 — no USB keyboard existed, yet keys
    # arrived (over the custom-virtio input channel).
    grep -a -qF -- "input: armed=0 fifo=0/64 dropped=0 events=6 kb-mods=0x0 kb-usage=0x28 kb-byte=0xa ptr-btns=0 ptr-x=0 ptr-y=0 ptr-reports=0" "$VSERIAL" && G_REPORT=1
    grep -a -qF -- "events=6" "$VSERIAL" && G_EVENTS=1
    grep -a -qF -- "kb-usage=0x28 kb-byte=0xa" "$VSERIAL" && G_ENTER=1
    # Coexistence: the claim-3141 push echo stayed green in the same boot
    # (--via-virtio implies the four-queue shape).
    grep -a -qF -- "cvspike: q2 ok=1" "$VSERIAL" && G_Q2=1
    # The serial path stayed alive (the trigger marker echoed by the shell).
    grep -a -qF -- "i3-virtio-pre" "$VSERIAL" && G_MARKER=1
fi
if [ -f "$VRUN" ]; then
    # The runner attached the four-queue device incl. the input queue.
    grep -a -qF -- "claim-9588 INPUT queue (--via-virtio)" "$VRUN" && H_ENABLED=1
    grep -a -qF -- "CUSTOM-VIRTIO: guest set DRIVER_OK" "$VRUN" && H_DRIVER_OK=1
    # The first keystroke ('i', HID usage 0x0c) went out as an input message.
    grep -a -qF -- "CUSTOM-VIRTIO-INPUT: enqueued key-seq down usage=0xc mods=0x0" "$VRUN" && H_ENQUEUE_I=1
    # The LAST keystroke (Enter down, usage 0x28) was enqueued too — the
    # runner cannot have exited before it: the exit marker IS the guest's
    # decode of this very message. (The trailing keyUp/summary lines are
    # printed for the log but not gated — the runner may legitimately exit
    # once the report lands.)
    grep -a -qF -- "CUSTOM-VIRTIO-INPUT: enqueued key-seq down usage=0x28 mods=0x0" "$VRUN" && H_ENQUEUE_ENTER=1
    # The KEY-SEQ path ran in virtio mode (never touched a view).
    grep -a -qF -- "over the custom-virtio INPUT queue after \"i3-virtio-pre\" transport=cv-input" "$VRUN" && H_KEYSEQ=1
    # NEGATIVE proofs: no NSEvent synthesis line and no window-state report
    # can exist on this path (headless — there is no view to synthesize into).
    if ! grep -a -qF -- "dispatched to the VZVirtualMachineView" "$VRUN" &&
       ! grep -a -qF -- "window key=" "$VRUN"; then
        H_NOSYNTH=1
    fi
    # Structural headless proof: the attach line lists FOUR queues (no
    # --display flag was passed; the display line never claims a window).
    grep -a -qF -- ", 4 queue(s) incl. the claim-3141 push-echo queue and the claim-9588 INPUT queue" "$VRUN" && H_NOVIEW=1
fi

echo "input-virtio: rc=$VRC serial-bytes=$VSERIAL_BYTES guest-device=$G_DEVICE guest-q3=$G_Q3ARMED guest-report=$G_REPORT guest-events=$G_EVENTS guest-enter=$G_ENTER guest-q2=$G_Q2 guest-marker=$G_MARKER host-enabled=$H_ENABLED host-driver-ok=$H_DRIVER_OK host-enqueue-i=$H_ENQUEUE_I host-enqueue-enter=$H_ENQUEUE_ENTER host-keyseq=$H_KEYSEQ host-no-synthesis=$H_NOSYNTH host-four-queues=$H_NOVIEW"

VPASS=0
if [ "$VRC" = 0 ] && [ "$G_DEVICE" = 1 ] && [ "$G_Q3ARMED" = 1 ] && [ "$G_REPORT" = 1 ] && \
   [ "$G_EVENTS" = 1 ] && [ "$G_ENTER" = 1 ] && [ "$G_Q2" = 1 ] && [ "$G_MARKER" = 1 ] && \
   [ "$H_ENABLED" = 1 ] && [ "$H_DRIVER_OK" = 1 ] && [ "$H_ENQUEUE_I" = 1 ] && \
   [ "$H_ENQUEUE_ENTER" = 1 ] && [ "$H_KEYSEQ" = 1 ] && [ "$H_NOSYNTH" = 1 ] && [ "$H_NOVIEW" = 1 ]; then
    VPASS=1
    VIRTIO_PASS=1
fi

{
    echo "DIPSHITOS live input gate — claim 9588 phase: injected keys arrive over the custom-virtio INPUT queue, HEADLESS, on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "phase: --via-virtio injects input\\n as HID-shaped 16-byte messages (queue 3); no --display, no --input, no window"
    echo "assertions: guest q3 pool armed; input report events=6 kb-usage=0x28 kb-byte=0xa WITH armed=0 (no USB keyboard attached); q2 push-echo coexistence; serial marker; host DRIVER_OK + enqueues + transport=cv-input; negative: no synthesis/window lines"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} > "$VREPORT"

echo
echo "=== result (claim-9588 virtio phase) ==="
if [ "$VPASS" = 1 ]; then
    echo "verify-live-input[virtio]: PASS — an injected key arrived with events>0 WITHOUT CGEvent/NSEvent synthesis and WITHOUT window activation: the runner wrote six HID-shaped 16-byte messages into the custom-virtio device's pre-armed queue-3 receive buffers (no view existed — the boot was headless), the guest replenished the pool from its idle loop and decoded every report through the same decode_keyboard_report path USB keyboards use, and the guest's own input command reported events=6 (i, n, p, u, t, Enter; kb-usage=0x28 kb-byte=0xa) WITH armed=0 — proving no USB keyboard was ever attached. The claim-4769 activation wall and the claim-8844 synthesized-drop failure mode (#179) cannot apply on this channel: there is no window to activate and nothing synthesized to drop."
    echo "PASS: $VPASS" >> "$VREPORT"
else
    echo "verify-live-input[virtio]: FAILED — see artifacts/live-input-virtio-report.txt, the runner output (live-input-virtio-run.txt), and the serial log (live-input-virtio-serial.log)."
    echo "FAIL: $VPASS" >> "$VREPORT"
fi
fi # virtio phase

# --- overall result ----------------------------------------------------------
echo
echo "=== overall (GATE_VIRTIO=$GATE_VIRTIO) ==="
OVERALL=1
if [ "$GATE_VIRTIO" != "1" ] && [ "$CLASSIC_PASS" != 1 ]; then OVERALL=0; fi
if [ "$GATE_VIRTIO" = "1" ] || [ "$GATE_VIRTIO" = "all" ]; then
    if [ "$VIRTIO_PASS" != 1 ]; then OVERALL=0; fi
fi
if [ "$OVERALL" = 1 ]; then
    echo "verify-live-input: PASS (requested phase(s) green)"
    sleep 0.5
    exit 0
else
    echo "verify-live-input: FAILED (requested phase(s)) — see the per-phase reports under artifacts/."
    sleep 0.5
    exit 1
fi
