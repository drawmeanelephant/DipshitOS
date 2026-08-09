#!/usr/bin/env bash
#
# verify-live-timer.sh -- claim 9187 class-B gate: real timer IRQ delivery
# on real VZ hardware. The production image boots with the claim-9746
# vectors installed and the GIC + CNTP timer programmed (discovered
# pre-exit from the MADT/GTDT); IRQs are unmasked after the chain is
# armed. The timer's EL1 physical-timer comparator fires once a second.
#
# Claim 9187 corrected claim 7948's guest driver: the old MADT structure
# IDs were shifted, SGI/PPI MMIO targeted the redistributor RD frame instead
# of its +0x10000 SGI frame, and ICFGR wrote the RES0 bit rather than the
# trigger bit. This gate distinguishes the IRQ path from the diagnostic
# poll counter. It requires the first-IRQ report and the fifth
# heartbeat to say all five ticks came through the IRQ vector with zero
# poll-consumed ticks.
#
# Mechanism: the runner's non-interactive scripted-input mode (claim 6684,
# --script / --script-expect) forwards keystrokes into the serial
# attachment; guest output is teed to vm-serial.log; the runner exits 0 iff
# the expected transcript appears. The script sends `timer` + `echo` at
# once; the runner keeps polling the log until the fifth IRQ heartbeat
# appears (about 5 s after boot, so --timeout must cover it).
#
# Per boot this reports:
#   rc              the runner's exit code (0 iff the heartbeat appeared)
#   serial-bytes    vm-serial.log size
#   banner / interrupts-armed / timer-cmd-armed / echo / irq / heartbeat
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

echo "=== verify-live-timer: claim 9187 — live CNTP PPI through the EL1 IRQ vector, $BOOTS boot(s) ==="

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
    # --script-expect watches the fifth IRQ heartbeat (written ~5 s after boot);
    # the runner exits 0 as soon as it appears in the serial log.
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" --script-expect "timer heartbeat ticks=5 irq=5 poll=0" --timeout 60 \
        > "artifacts/live-timer-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-timer-serial-$tag.log" || true

    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log 2>/dev/null | tr -d ' ')
    local BANNER=0 INTERRUPTS=0 CMD_ARMED=0 ECHO=0 IRQ=0 HEARTBEAT=0
    [ -f artifacts/vm-serial.log ] || { SERIAL_BYTES=0; }
    if [ -f artifacts/vm-serial.log ]; then
        grep -qF -- "DipshitOS kernel has seized control." artifacts/vm-serial.log && BANNER=1
        grep -qF -- "interrupts: gic=" artifacts/vm-serial.log && INTERRUPTS=1
        grep -qF -- "timer: armed=1" artifacts/vm-serial.log && CMD_ARMED=1
        grep -qF -- "rx-timer-ok" artifacts/vm-serial.log && ECHO=1
        grep -qF -- "timer irq delivered ppi=0x1e irq_ticks=1" artifacts/vm-serial.log && IRQ=1
        grep -qF -- "timer heartbeat ticks=5 irq=5 poll=0" artifacts/vm-serial.log && HEARTBEAT=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER interrupts=$INTERRUPTS cmd-armed=$CMD_ARMED echo=$ECHO irq=$IRQ heartbeat=$HEARTBEAT"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER interrupts=$INTERRUPTS cmd-armed=$CMD_ARMED echo=$ECHO irq=$IRQ heartbeat=$HEARTBEAT"
    # The gate passes iff the runner saw five IRQ-serviced timer ticks with
    # no fallback poll ticks and the shell remained alive throughout.
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$INTERRUPTS" = 1 ] && [ "$CMD_ARMED" = 1 ] && [ "$ECHO" = 1 ] && [ "$IRQ" = 1 ] && [ "$HEARTBEAT" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live-timer gate (claim 9187) — real CNTP PPI delivery through the EL1 IRQ vector on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $SCRIPT (timer / echo rx-timer-ok; expect heartbeat ticks=5 irq=5 poll=0)"
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
    echo "verify-live-timer: PASS — the CNTP PPI entered the EL1 IRQ vector, was acknowledged/handled/EOI'd and re-armed 5 times, with irq=5, poll=0, and the shell alive throughout on VZ ($PASS/$BOOTS boot(s))."
    echo "PASS: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-timer: FAILED — $PASS/$BOOTS boot(s) passed; see artifacts/live-timer-report.txt and the per-boot serial logs."
    echo "FAIL: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
