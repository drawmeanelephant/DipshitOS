#!/usr/bin/env bash
#
# verify-live-m14-composition.sh -- claim 3289 (Milestone 14, Card S3)
# class-B gate: the composition capstone. NOTEPAD — the flagship text app —
# uses BOTH shared user services in ONE EL0 session:
#
#   S1 (claim 0169): the shared kernel clipboard. The gate pre-loads the
#   clipboard with the terminal's `clip` command, then NOTEPAD's `selfdemo`
#   mode pastes it (`sys_clipboard_get`, slot 39) and copies the result back
#   out (`sys_clipboard_set`, slot 38) — the paste AND copy directions, live.
#
#   S2 (claim 7323): the per-process app timer. NOTEPAD arms
#   `sys_timer_set` (slot 40) and toggles its cursor on every `TIMER` event
#   (kind 9 on the ADR 0009 queue), re-arming after each fire — the cursor
#   blinks on the kernel's scheduler tick, NOT a sys_sleep spin loop.
#
#   Together: the same app pastes (S1) and blinks (S2) — the "apps stop
#   spinning" promise of the M14 arc, realized in the real editor.
#
# Input-seam note (issue #179): the synthesized keyboard route currently
# reports `events=0` on this machine (reproduced on a fresh boot 2026-08-18;
# the runner's KEY-SEQ reports ok=true but the guest ring stays empty). The
# gate therefore drives the composition through NOTEPAD's argv "selfdemo"
# mode (claim 4636's entry contract — argc/argv arrive in x0/x1) instead of
# scripted Ctrl+C/V chords, and records the seam state in the report. The
# chord path itself is unchanged and host-tested; it regains live coverage
# when the seam recovers.
#
# Mechanism: the production image boots with the runner's scripted-input
# mode. Phase 1 forwards `clip hello world` (the S1 set side) then
# `exec NOTEPAD.BIN selfdemo` after the boot payload exits. NOTEPAD prints
# `selfdemo pasted` / `selfdemo copied` / `selfdemo armed blink` and one
# `notepad: cursor blink` per TIMER event. Phase 2 (after `selfdemo done`)
# runs `syscalls` (implemented=61 today — slots 47-60 landed post-M14;
# slots 38/39/40 counted in the same boot)
# and the success echo.
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-m14-composition.sh
#
# Run isolation (#523 item 2 / issue #528; fleet remainder claim 2259):
# private stacked disk (pristine-per-boot overlay), EFI var store, serial
# log, and scripts under $RUN_DIR. Set VIRELAI_GATE_SUFFIX=_alt for
# distinct canonical evidence names; VIRELAI_KEEP_RUN=1 keeps the scratch
# dir.
#
# Evidence saved under artifacts/: live-composition-gate.txt,
# live-composition-report.txt, live-composition-run.txt,
# live-composition-serial.log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-composition-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-composition-report.txt)"

echo "=== verify-live-m14-composition: claim 3289 — M14 S3 composition capstone on VZ ==="

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# Build all binaries and disk image
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-m14-composition
gate_seed_share
echo "run dir: $RUN_DIR"

# Phase 1: set the clipboard (S1 write side via the terminal half), then
# exec NOTEPAD in its selfdemo mode (argv "selfdemo", claim 4636 entry
# contract). The selfdemo pastes the pre-loaded clipboard (S1 read side),
# copies it back (S1 write side from EL0), and arms the blink timer (S2).
cat > "$RUN_DIR/script.txt" <<'EOF'
clip hello world
exec NOTEPAD.BIN selfdemo
EOF

# Phase 2: after the selfdemo completes, the syscalls report proves slots
# 38/39/40 were all called in this boot.
cat > "$RUN_DIR/script2.txt" <<'EOF'
syscalls
echo composition-live-ok
EOF

STATIC_EXIT_LINE="tasks user-el0 exited status=7"

# Exit condition (fleet remainder claim 2259, OBSERVED 2026-08-24): the
# kernel reaper is asynchronous — its `tasks user-exec exited status=43` /
# `procs NOTEPAD.BIN exited status=43` lines reliably TRAIL the sweep echo,
# so expecting `composition-live-ok` truncated the serial before the
# lifecycle proof landed. The runner now exits on the reap line instead,
# which also guarantees every earlier marker (syscalls report included) is
# inside the captured window.
REAP_EXPECT="procs NOTEPAD.BIN exited status=43"

echo "--- Phase 1: Running the M14 composition (clipboard + blink) on VZ ---"
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"

set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --display \
    --script "$RUN_DIR/script.txt" \
    --script-after "$STATIC_EXIT_LINE" \
    --script2 "$RUN_DIR/script2.txt" \
    --script2-after "notepad: selfdemo done" \
    --script-expect "$REAP_EXPECT" \
    --timeout 90 > "$(art live-composition-run.txt)" 2>&1
RC=$?
set -e

[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-composition-serial.log)" || true
SER="$(art live-composition-serial.log)"

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat "$(art live-composition-run.txt)"
    exit 1
fi

echo "--- Phase 2: Verifying the composition markers ---"

# S1 read side: NOTEPAD pasted the clipboard the terminal set.
grep -q "notepad: selfdemo pasted" "$SER" || {
    echo "ERROR: NOTEPAD paste marker missing from serial log"
    exit 1
}
echo "S1.PASTE: OK"

# S1 write side: NOTEPAD copied the buffer back into the shared clipboard.
grep -q "notepad: selfdemo copied" "$SER" || {
    echo "ERROR: NOTEPAD copy marker missing from serial log"
    exit 1
}
echo "S1.COPY: OK"

# S2: the timer-driven blink — at least two TIMER events (two cursor
# toggles) observed, and the demo ran to completion.
BLINK_COUNT=$(grep -c "notepad: cursor blink" "$SER" || true)
if [ "${BLINK_COUNT:-0}" -lt 2 ]; then
    echo "ERROR: expected at least 2 cursor blink markers, saw ${BLINK_COUNT:-0}"
    exit 1
fi
echo "S2.BLINK: OK ($BLINK_COUNT TIMER events observed)"

grep -q "notepad: selfdemo armed blink" "$SER" || {
    echo "ERROR: blink arm marker missing from serial log"
    exit 1
}
grep -q "notepad: selfdemo done" "$SER" || {
    echo "ERROR: selfdemo done marker missing from serial log"
    exit 1
}
echo "S2.ARM+DONE: OK"

# NOTEPAD exits through the real lifecycle.
grep -q "notepad: exiting 43" "$SER" || {
    echo "ERROR: NOTEPAD exit marker missing from serial log"
    exit 1
}
grep -q "tasks user-exec exited status=43" "$SER" || {
    echo "ERROR: NOTEPAD exit status line missing from serial log"
    exit 1
}
echo "LIFECYCLE: OK"

# The syscalls report — OBSERVED BYTES (2026-08-24, claim 2259):
# `implemented=61` today, not 46: slots 47–60 landed after M14 across the
# M17–M26 arcs (win_resize, drag, notify, workspaces, setrlimit, pipes,
# font_size, ping, ...). Slots 38/39/40 all counted in the same boot —
# sys_clipboard_set calls=1 (the selfdemo copy; the terminal `clip`
# command is the EL1h half and does NOT ride the syscall counter),
# sys_clipboard_get calls=1 (the selfdemo paste), sys_timer_set calls=7
# (the arm + one re-arm per TIMER event, six blinks).
grep -q "syscalls: slots=64 implemented=61" "$SER" || {
    echo "ERROR: implemented=61 syscalls report missing from serial log"
    exit 1
}
grep -q "38 sys_clipboard_set calls=1" "$SER" || {
    echo "ERROR: sys_clipboard_set calls=1 missing from syscalls report"
    exit 1
}
grep -q "39 sys_clipboard_get calls=1" "$SER" || {
    echo "ERROR: sys_clipboard_get calls=1 missing from syscalls report"
    exit 1
}
grep -q "40 sys_timer_set calls=7" "$SER" || {
    echo "ERROR: sys_timer_set calls=7 missing from syscalls report"
    exit 1
}
echo "SYSCALL COUNTS: OK"

grep -q "composition-live-ok" "$SER" || {
    echo "ERROR: final sweep marker missing from serial log"
    exit 1
}

# Input-seam state (issue #179): recorded for the report, never gates.
KB_STATE="not-checked"
if grep -q "input: armed" "$SER"; then
    KB_STATE="keyboard-armed-events-unobserved"
fi

cat > "$REPORT" <<EOF
=== Milestone 14 S3 Composition Live Gate Report ===
Revision: $REVISION ($BRANCH)
Status: PASS (1/1 on Apple Virtualization.framework)

Verified Components:
- S1 (claim 0169): shared kernel clipboard in a real app — the terminal
  'clip' set the clipboard (the EL1h half), NOTEPAD's selfdemo pasted it
  (sys_clipboard_get calls=1) and copied it back (sys_clipboard_set
  calls=1 — the EL0 write path)
- S2 (claim 7323): timer-driven cursor blink in a real app — NOTEPAD armed
  sys_timer_set and toggled its cursor on $BLINK_COUNT TIMER events
  (kind 9, ADR 0009 queue), re-arming after every fire; no spin loop
- Composition: the SAME EL0 program (NOTEPAD.BIN) used both facilities,
  then exited status 43 through the real lifecycle
- syscalls report: implemented=61 (slots 47-60 landed post-M14) with slots 38/39/40 all counted live
- Input seam (issue #179): $KB_STATE — the gate drives the composition via
  NOTEPAD's argv selfdemo mode because the synthesized keyboard route
  reports events=0 on this machine; the chord path is host-tested and
  regains live coverage when the seam recovers

Serial Output Highlights:
$(grep -E 'notepad: (ready|selfdemo|cursor blink|exiting)|sys_clipboard|sys_timer|syscalls:' "$SER" || true)
EOF

echo "verify-live-m14-composition: PASS — NOTEPAD pastes (S1) and blinks (S2) in one session on VZ."
