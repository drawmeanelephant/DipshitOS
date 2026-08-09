#!/usr/bin/env bash
#
# verify-live-timer.sh -- claim 7948 class-B gate: live GIC + generic timer
# on real VZ hardware. The production image boots with the claim-9746
# vectors installed and the GIC + CNTP timer programmed (discovered
# pre-exit from the MADT/GTDT); IRQs are unmasked after the chain is
# armed. The timer's EL1 physical-timer comparator fires once a second.
#
# Honest mechanism on this platform: Apple VZ's GIC accepts distributor +
# CPU-interface configuration (read-back proven) but never presents an
# interrupt to the guest — its GICR is a RAZ/WI stub (measured: PPI 30,
# SGIs, and SPIs 32-39 all fail to reach the CPU interface with every
# guest-side lever tried; see claim 7948). The kernel therefore keeps the
# spec-correct ack/EOI IRQ path for real hardware AND consumes the fired
# comparator in the shell idle loop (`timer.poll`), which is what produces
# the heartbeat here: every 5 consumed ticks the loop prints a heartbeat
# line. The gate asserts the boot state line, the `dipshit> timer`
# command's `armed=1` report, a follow-up echo reply, and ≥5 consumed,
# re-armed ticks (`timer heartbeat ticks=5`).
#
# Mechanism: the runner's non-interactive scripted-input mode (claim 6684,
# --script / --script-expect) forwards keystrokes into the serial
# attachment; guest output is teed to vm-serial.log; the runner exits 0 iff
# the expected transcript appears. The script sends `timer` + `echo` at
# once; the runner keeps polling the log until the 5th heartbeat appears
# (the ticks=5 line is written ~5 s after boot, so --timeout must cover it).
#
# Per boot this reports:
#   rc              the runner's exit code (0 iff the heartbeat appeared)
#   serial-bytes    vm-serial.log size
#   banner / interrupts-armed / timer-cmd-armed / echo / heartbeat   flags
#
# Class B — Apple silicon + VZ only; boots a real VM. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-timer.sh          # BOOTS boots (default 1)
#   BOOTS=3 bash tools/verify-live-timer.sh
#
# Evidence saved under artifacts/: live-timer-gate.txt (full output),
# live-timer-report.txt (per-boot detail), live-timer-run-<NN>.txt (runner
# output), live-timer-serial-<NN>.log (vm-serial.log copy),
# live-timer-script.txt (the forwarded keystrokes).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-timer-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-timer-report.txt"
SCRIPT="artifacts/live-timer-script.txt"

echo "=== verify-live-timer: claim 7948 — live GIC + generic timer (CNTP programmed, comparator consumed + re-armed via the idle-loop poll — VZ delivers no interrupts), $BOOTS boot(s) ==="

# --- tool versions + revision -----------------------------------------------
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

# --- the scripted keystrokes ------------------------------------------------
cat > "$SCRIPT" <<'EOF'
timer
echo rx-timer-ok
EOF

# --- THE GATE: per-boot live run, fresh variable store each -----------------
run_one() {
    local tag="$1"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    # --script-expect watches the 5th heartbeat (written ~5 s after boot);
    # the runner exits 0 as soon as it appears in the serial log.
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" --script-expect "timer heartbeat ticks=5" --timeout 60 \
        > "artifacts/live-timer-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-timer-serial-$tag.log" || true

    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log 2>/dev/null | tr -d ' ')
    local BANNER=0 INTERRUPTS=0 CMD_ARMED=0 ECHO=0 HEARTBEAT=0
    [ -f artifacts/vm-serial.log ] || { SERIAL_BYTES=0; }
    if [ -f artifacts/vm-serial.log ]; then
        grep -qF -- "DipshitOS kernel has seized control." artifacts/vm-serial.log && BANNER=1
        grep -qF -- "interrupts: gic=" artifacts/vm-serial.log && INTERRUPTS=1
        grep -qF -- "timer: armed=1" artifacts/vm-serial.log && CMD_ARMED=1
        grep -qF -- "rx-timer-ok" artifacts/vm-serial.log && ECHO=1
        grep -qF -- "timer heartbeat ticks=5" artifacts/vm-serial.log && HEARTBEAT=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER interrupts=$INTERRUPTS cmd-armed=$CMD_ARMED echo=$ECHO heartbeat=$HEARTBEAT"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER interrupts=$INTERRUPTS cmd-armed=$CMD_ARMED echo=$ECHO heartbeat=$HEARTBEAT"
    # The gate passes iff the runner saw the 5th heartbeat AND every live
    # interrupt assertion held (GIC+CPU interface programmed, timer armed,
    # shell alive after the timer ran).
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$INTERRUPTS" = 1 ] && [ "$CMD_ARMED" = 1 ] && [ "$ECHO" = 1 ] && [ "$HEARTBEAT" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live-timer gate (claim 7948) — GIC + generic timer on real VZ hardware (poll-consumed heartbeat; VZ's GICR is a RAZ/WI stub, no IRQs delivered)"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $SCRIPT (timer / echo rx-timer-ok; expect heartbeat ticks=5)"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-timer boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-timer: PASS — the GIC + generic timer were programmed (read-back proven) and the CNTP comparator fired, was consumed, and was re-armed at least 5 times by the idle-loop poll, with the shell alive throughout on VZ ($PASS/$BOOTS boot(s)). IRQ delivery stays blocked: VZ never presents an interrupt (claim 7948 evidence)."
    echo "PASS: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-timer: FAILED — $PASS/$BOOTS boot(s) passed; see artifacts/live-timer-report.txt and the per-boot serial logs."
    echo "FAIL: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
