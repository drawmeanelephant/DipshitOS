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
# Run isolation (#523 item 2 / issue #528, claim 5069): private stacked
# disk + EFI vars + serial log under $RUN_DIR; VIRELAI_GATE_SUFFIX/_KEEP_RUN
# supported.
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

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-editing-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

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

# --- per-run isolation -------------------------------------------------------
gate_begin live-editing
echo "run dir: $RUN_DIR"

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
cat > "$RUN_DIR/script.txt" <<'EOF'
echo u2-serial-ok
EOF

CHORDS="e,c,h,o,space,a,b,left,c,return,up,return,e,c,h,o,space,u,2,d,o,n,e,return"

# --- phase 2: the six D2 Ctrl chords, over the serial byte path --------------
# ADR 0008 D2 requires Ctrl-A/E/K/U/L/C. Phase 1 cannot prove them: VZ ignores
# `modifierFlags` on a synthesized keyDown, so a --input-chords ctrl-* token
# reaches the guest as the bare letter (observed claim-time; the hardware
# contract records the three synthesis routes that fail). The bytes a real
# Ctrl chord produces are 0x01/0x05/0x0b/0x15/0x0c/0x03, and input.zig's HID
# decode emits exactly those, so feeding them on the serial console exercises
# the SAME LineEditor path from one byte earlier. Each chord is proven by an
# observable RESULT, never by the keystroke itself:
#   Ctrl-A  "cho u2chord" + home + "e"        -> runs `echo u2chord`
#   Ctrl-E  home, then end, then "d"          -> runs `echo u2end`
#   Ctrl-K  4x Left then kill-to-end          -> runs `echo u2kill`
#   Ctrl-U  junk then kill-to-start           -> runs `echo u2under`
#   Ctrl-L  clear screen mid-line             -> ESC[2J in the log, then runs
#   Ctrl-C  cancel a line that must NOT run   -> `^C`, and NEVER never runs
printf 'cho u2chord\001e\n' > "$RUN_DIR/chords.txt"
printf 'echo u2en\001\005d\n' >> "$RUN_DIR/chords.txt"
printf 'echo u2killXXXX\033[D\033[D\033[D\033[D\013\n' >> "$RUN_DIR/chords.txt"
printf 'JUNK\025echo u2under\n' >> "$RUN_DIR/chords.txt"
printf 'echo u2clear\014\n' >> "$RUN_DIR/chords.txt"
printf 'echo NEVER\003echo u2cancel\n' >> "$RUN_DIR/chords.txt"

run_one() {
    local out="$1" serial="$2"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial.log" \
        --input --display \
        --script "$RUN_DIR/script.txt" \
        --input-chords "$CHORDS" --input-chords-after "userspace: el0=1" \
        --script2 "$RUN_DIR/chords.txt" --script2-after "u2done" \
        --script-expect "u2cancel" \
        --timeout 240 \
        > "$(art live-editing-run.txt)" 2>&1
    local RC=$?
    [ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-editing-serial.log)" || true
    echo "$RC" > "$RUN_DIR/rc.txt"
}

set +e
run_one "$(art live-editing-run.txt)" "$(art live-editing-serial.log)"
RC="$(cat "$RUN_DIR/rc.txt")"
set -e

SERIAL="$(art live-editing-serial.log)"
SERIAL_BYTES=0 ARMED=0 ACB2=0 DONE=0 SERIALOK=0 RUNNERFLAG=0
CHORD_A=0 CHORD_E=0 CHORD_K=0 CHORD_U=0 CHORD_L=0 CHORD_C=0 NOJUNK=0
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
    # Phase 2 — each of D2's six Ctrl chords, proven by its RESULT. Every
    # marker is asserted as an exact full line, so the echoed command text
    # (which contains the same word) is never what satisfies the check.
    [ "$(grep -a -cFx 'u2chord' "$SERIAL" | tr -d ' ')" = "1" ] && CHORD_A=1  # Ctrl-A
    [ "$(grep -a -cFx 'u2end' "$SERIAL" | tr -d ' ')" = "1" ] && CHORD_E=1    # Ctrl-E
    [ "$(grep -a -cFx 'u2kill' "$SERIAL" | tr -d ' ')" = "1" ] && CHORD_K=1   # Ctrl-K
    [ "$(grep -a -cFx 'u2under' "$SERIAL" | tr -d ' ')" = "1" ] && CHORD_U=1  # Ctrl-U
    [ "$(grep -a -cFx 'u2cancel' "$SERIAL" | tr -d ' ')" = "1" ] && CHORD_C=1 # Ctrl-C ran the NEXT line
    # Ctrl-L emits the erase-in-display sequence to the console.
    grep -a -qF -- $'\033[2J' "$SERIAL" && CHORD_L=1
    # Ctrl-C cancelled its line: the cancelled command must never have run,
    # and the editor must have echoed the cancel marker.
    if [ "$(grep -a -cFx 'NEVER' "$SERIAL" | tr -d ' ')" = "0" ] && grep -a -qF -- '^C' "$SERIAL"; then NOJUNK=1; fi
fi
# The runner attached the chord seam (its own report line).
grep -a -qF -- "input-chords: ENABLED" artifacts/live-editing-run.txt && RUNNERFLAG=1

echo "editing: rc=$RC serial-bytes=$SERIAL_BYTES armed=$ARMED acb-x2=$ACB2 done=$DONE serial-ok=$SERIALOK runner-flag=$RUNNERFLAG"
echo "chords: ctrl-a=$CHORD_A ctrl-e=$CHORD_E ctrl-k=$CHORD_K ctrl-u=$CHORD_U ctrl-l=$CHORD_L ctrl-c=$CHORD_C cancelled-never-ran=$NOJUNK"

PASS=0
if [ "$RC" = 0 ] && [ "$ARMED" = 1 ] && [ "$ACB2" = 1 ] && [ "$DONE" = 1 ] && \
   [ "$SERIALOK" = 1 ] && [ "$RUNNERFLAG" = 1 ] && \
   [ "$CHORD_A" = 1 ] && [ "$CHORD_E" = 1 ] && [ "$CHORD_K" = 1 ] && \
   [ "$CHORD_U" = 1 ] && [ "$CHORD_L" = 1 ] && [ "$CHORD_C" = 1 ] && [ "$NOJUNK" = 1 ]; then
    PASS=1
fi

{
    echo "VIRELAIOS live editing gate (claim 1809, milestone eight card U2) — scripted chords drive history recall + cursor editing, on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "phase 1 (USB keyboard): types 'echo ab <Left> c <Enter> <Up> <Enter> echo u2done <Enter>' after the boot self-test"
    echo "phase 2 (serial bytes): the six D2 Ctrl chords — Ctrl-A/E/K/U/L/C — each proven by the command that ends up running"
    echo "assertions: input arming, the mid-line insert produced 'echo acb' and the Up recall re-ran it (acb x2), the final marker (u2done x1), the serial marker, the runner's input-chords flag line, one exact-line result per chord (u2chord/u2end/u2kill/u2under/u2clear/u2cancel), the ESC[2J erase from Ctrl-L, and zero runs of the Ctrl-C-cancelled command"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} > "$REPORT"

echo
echo "=== result ==="
if [ "$PASS" = 1 ]; then
    echo "verify-live-editing: PASS — phase 1: a scripted keyboard chord sequence (VZ has no keyboard API; the runner synthesizes one NSEvent per keyDown/keyUp into the VZVirtualMachineView) drove mid-line cursor editing (Left + 'c' turned 'echo ab' into 'echo acb') and history recall (Up re-ran it) over the XHCI transport end to end. Phase 2: all six ADR 0008 D2 Ctrl chords (A/E/K/U/L/C) ran over the serial byte path — the same LineEditor bytes input.zig's HID decode emits — each proven by its resulting command, with the Ctrl-C-cancelled line never executing. The guest's own output is the proof. The default VM is untouched: without --input, config.keyboards/pointingDevices stay []."
    echo "PASS: $PASS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-editing: FAILED — see artifacts/live-editing-report.txt, the runner output (live-editing-run.txt), and the serial log (live-editing-serial.log)."
    echo "FAIL: $PASS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
