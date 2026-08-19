#!/usr/bin/env bash
#
# verify-live-timers.sh -- claim 5390 (Milestone 14, Card S2) class-B
# gate: the per-process application timer seam (ADR 0007 slots 40/41)
# verified on real Apple silicon Virtualization.framework hardware.
#
# TMRTEST.BIN drives the seam from EL0:
#   one-shot timer (ticks=2) fires exactly once -> periodic timer (ticks=1)
#   delivers three expiries -> cancel stops it (no leaked event) -> a stale
#   cancel id is refused (EINVAL).
# The syscalls report proves slots 40/41 were each called the exact number
# of times.
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

echo "=== verify-live-timers: claim 5390 — Milestone 14 S2 on VZ ==="

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
exec TMRTEST.BIN
EOF

cat > artifacts/live-timers-script2.txt <<'EOF'
echo done-timers
syscalls
EOF

STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "--- Phase 1: Running TMRTEST.BIN on VZ ---"
rm -f artifacts/efi-vars.bin
rm -f artifacts/vm-serial.log artifacts/gpu-screen-*

set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --script artifacts/live-timers-script.txt \
    --script-after "$STATIC_EXIT_LINE" \
    --script2 artifacts/live-timers-script2.txt \
    --script2-after "timer: done" \
    --script-expect "done-timers" \
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

echo "--- Phase 2: Verifying TMRTEST.BIN Markers ---"

grep -q "timer: armed oneshot" artifacts/live-timers-serial.log || {
    echo "ERROR: timer: armed oneshot marker missing from serial log"
    exit 1
}
echo "TIMER.ARM.ONESHOT: OK"

grep -q "timer: oneshot fired" artifacts/live-timers-serial.log || {
    echo "ERROR: timer: oneshot fired marker missing from serial log"
    exit 1
}
echo "TIMER.ONESHOT.FIRE: OK"

grep -q "timer: oneshot spent" artifacts/live-timers-serial.log || {
    echo "ERROR: timer: oneshot spent marker missing from serial log"
    exit 1
}
echo "TIMER.ONESHOT.SPENT: OK"

grep -q "timer: armed periodic" artifacts/live-timers-serial.log || {
    echo "ERROR: timer: armed periodic marker missing from serial log"
    exit 1
}
grep -q "timer: periodic x3" artifacts/live-timers-serial.log || {
    echo "ERROR: timer: periodic x3 marker missing from serial log"
    exit 1
}
echo "TIMER.PERIODIC: OK"

grep -q "timer: cancelled" artifacts/live-timers-serial.log || {
    echo "ERROR: timer: cancelled marker missing from serial log"
    exit 1
}
grep -q "timer: cancel clean" artifacts/live-timers-serial.log || {
    echo "ERROR: timer: cancel clean marker missing from serial log"
    exit 1
}
echo "TIMER.CANCEL: OK"

grep -q "timer: stale refused" artifacts/live-timers-serial.log || {
    echo "ERROR: timer: stale refused marker missing from serial log"
    exit 1
}
echo "TIMER.STALE: OK"

# The two new slots were called the exact number of times (set x2: one-shot +
# periodic; cancel x2: the live cancel + the stale-id refusal).
grep -q "40 sys_timer_set calls=2" artifacts/live-timers-serial.log || {
    echo "ERROR: sys_timer_set call count missing from syscalls report"
    exit 1
}
grep -q "41 sys_timer_cancel calls=2" artifacts/live-timers-serial.log || {
    echo "ERROR: sys_timer_cancel call count missing from syscalls report"
    exit 1
}
echo "SYS_TIMER_SET/CANCEL: OK"

grep -q "tasks user-exec exited status=0" artifacts/live-timers-serial.log || {
    echo "ERROR: TMRTEST.BIN exit status 0 missing from serial log"
    exit 1
}
grep -q "tasks user-exec reaped" artifacts/live-timers-serial.log || {
    echo "ERROR: TMRTEST.BIN reap missing from serial log"
    exit 1
}
echo "TIMER.LIFECYCLE: OK"

grep -q "done-timers" artifacts/live-timers-serial.log || {
    echo "ERROR: final sweep marker missing from serial log"
    exit 1
}

cat > "$REPORT" <<EOF
=== Milestone 14 S2 Live Gate Report ===
Revision: $REVISION ($BRANCH)
Status: PASS (1/1 on Apple Virtualization.framework)

Verified Components:
- sys_timer_set (slot 40): one-shot arm + periodic arm
- sys_timer_cancel (slot 41): live cancel + stale-id refusal
- The bounded 8-entry BSS timer table posting TIMER events on the ADR 0009 queue
- TMRTEST.BIN exit status 0 through the real lifecycle

Serial Output Highlights:
$(grep -E 'timer:|sys_timer_(set|cancel)|user-exec' artifacts/live-timers-serial.log || true)
EOF

echo "verify-live-timers: PASS — application timers verified on VZ."
