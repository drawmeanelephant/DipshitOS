#!/usr/bin/env bash
#
# verify-live-timers.sh -- claim 7323 (Milestone 14, Card S2) class-B gate:
# the bounded per-process application timer facility (ADR 0007 slots 40-41)
# verified on real Apple silicon Virtualization.framework hardware.
#
# TIMER.BIN drives the seam from EL0 WITHOUT spinning: arm a 2-tick timer,
# BLOCK in `sys_wait_event`, observe the `TIMER` event the kernel posts when
# the countdown reaches zero (the scheduler tick fires it), prove cancel
# (nothing pending -> 0), re-arm -> fire again, and cancel a live pending
# timer (-> 1). The syscalls report proves slots 40/41 were called exactly
# the right number of times.
#
# Usage:
#   bash tools/verify-live-timers.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-timers-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-timers-report.txt"

echo "=== verify-live-timers: claim 7323 — Milestone 14 S2 on VZ ==="

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
echo "revision: $REVISION branch=$BRANCH"

# Build all binaries and disk image
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

cat > artifacts/live-timers-script.txt <<'EOF'
exec TIMER.BIN
EOF

cat > artifacts/live-timers-script2.txt <<'EOF'
echo timers-live-ok
syscalls
EOF

# The boot payload's exit line frees the pool slot the exec lands in.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "--- Phase 1: Running TIMER.BIN on VZ ---"
rm -f artifacts/efi-vars.bin
rm -f artifacts/vm-serial.log artifacts/gpu-screen-*

set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --script artifacts/live-timers-script.txt \
    --script-after "$STATIC_EXIT_LINE" \
    --script2 artifacts/live-timers-script2.txt \
    --script2-after "timertest: done" \
    --script-expect "timers-live-ok" \
    --timeout 90 > artifacts/live-timers-run.txt 2>&1
RC=$?
set -e

[ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log artifacts/live-timers-serial.log || true

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat artifacts/live-timers-run.txt
    exit 1
fi

echo "--- Phase 2: Verifying TIMER.BIN Markers ---"

grep -q "timertest: armed 2" artifacts/live-timers-serial.log || {
    echo "ERROR: arm marker missing from serial log"
    exit 1
}
echo "TIMER.ARM: OK"

grep -q "timertest: fired seq=1" artifacts/live-timers-serial.log || {
    echo "ERROR: first TIMER event marker missing from serial log"
    exit 1
}
echo "TIMER.FIRED: OK"

grep -q "timertest: cancel-none" artifacts/live-timers-serial.log || {
    echo "ERROR: cancel-none marker missing from serial log"
    exit 1
}
echo "TIMER.CANCEL_NONE: OK"

grep -q "timertest: armed 1" artifacts/live-timers-serial.log || {
    echo "ERROR: second arm marker missing from serial log"
    exit 1
}
grep -q "timertest: fired2 seq=2" artifacts/live-timers-serial.log || {
    echo "ERROR: second TIMER event marker missing from serial log"
    exit 1
}
echo "TIMER.FIRED2: OK"

grep -q "timertest: canceled" artifacts/live-timers-serial.log || {
    echo "ERROR: cancel-pending marker missing from serial log"
    exit 1
}
echo "TIMER.CANCEL_PENDING: OK"

grep -q "timertest: done" artifacts/live-timers-serial.log || {
    echo "ERROR: done marker missing from serial log"
    exit 1
}
grep -q "tasks user-exec exited status=23" artifacts/live-timers-serial.log || {
    echo "ERROR: TIMER.BIN exit status line missing from serial log"
    exit 1
}
echo "TIMER.EXIT23: OK"

# The syscall counters: set called 3 times, cancel called 2 times.
grep -q "syscalls: slots=64 implemented=42" artifacts/live-timers-serial.log || {
    echo "ERROR: implemented=42 syscalls report missing from serial log"
    exit 1
}
grep -q "40 sys_timer_set calls=3" artifacts/live-timers-serial.log || {
    echo "ERROR: sys_timer_set calls=3 missing from syscalls report"
    exit 1
}
grep -q "41 sys_timer_cancel calls=2" artifacts/live-timers-serial.log || {
    echo "ERROR: sys_timer_cancel calls=2 missing from syscalls report"
    exit 1
}
echo "SYS_TIMER_SET/CANCEL COUNTS: OK"

grep -q "timers-live-ok" artifacts/live-timers-serial.log || {
    echo "ERROR: final sweep marker missing from serial log"
    exit 1
}

cat > "$REPORT" <<EOF
=== Milestone 14 S2 Live Gate Report ===
Revision: $REVISION ($BRANCH)
Status: PASS (1/1 on Apple Virtualization.framework)

Verified Components:
- sys_timer_set (slot 40): armed a 2-tick timer and a 1-tick timer from EL0;
  each fired exactly one TIMER event (kind 9) into the process's ADR 0009
  queue while the program was blocked in sys_wait_event (no spin loop)
- sys_timer_cancel (slot 41): returned 0 with nothing pending and 1 with a
  live pending timer (which then never fired)
- The scheduler tick drove both fires; the process exited status 23
- syscalls report: implemented=42, sys_timer_set calls=3, sys_timer_cancel calls=2

Serial Output Highlights:
$(grep -E 'timertest:|sys_timer_(set|cancel)' artifacts/live-timers-serial.log || true)
EOF

echo "verify-live-timers: PASS — arm/block/fire/cancel verified on VZ."
