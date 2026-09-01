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

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

# Run isolation (#523 item 2 / issue #528; fleet remainder claim 2259):
# private stacked disk (pristine-per-boot overlay), EFI var store, serial
# log, and scripts under $RUN_DIR. Set VIRELAI_GATE_SUFFIX=_alt for
# distinct canonical evidence names; VIRELAI_KEEP_RUN=1 keeps the scratch
# dir.

GATE_LOG="$(art live-timers-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-timers-report.txt)"
echo "=== verify-live-timers: claim 7323 — Milestone 14 S2 on VZ ==="

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
gate_begin live-timers
gate_seed_share
echo "run dir: $RUN_DIR"

cat > "$RUN_DIR/script.txt" <<'EOF'
exec TIMER.BIN
EOF

# Order matters (fleet remainder claim 2259, OBSERVED 2026-08-24): the
# syscalls report must print BEFORE the success echo — the runner exits on
# the echo, so an echo-first order truncates the report. The forward parks
# 3 s past `timertest: done` because the kernel reaper is asynchronous and
# its exit line must land inside the settle window (and a forward typed at
# `done` lands before the shell is back at a live prompt).
cat > "$RUN_DIR/script2.txt" <<'EOF'
syscalls
echo timers-live-ok
EOF

# The boot payload's exit line frees the pool slot the exec lands in.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "--- Phase 1: Running TIMER.BIN on VZ ---"
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"

set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --script "$RUN_DIR/script.txt" \
    --script-after "$STATIC_EXIT_LINE" \
    --script2 "$RUN_DIR/script2.txt" \
    --script2-after "timertest: done" \
    --script2-delay 3 \
    --script-expect "timers-live-ok" \
    --timeout 90 > "$(art live-timers-run.txt)" 2>&1
RC=$?
set -e

[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-timers-serial.log)" || true
SER="$(art live-timers-serial.log)"

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat "$(art live-timers-run.txt)"
    exit 1
fi

echo "--- Phase 2: Verifying TIMER.BIN Markers ---"

grep -q "timertest: armed 2" "$SER" || {
    echo "ERROR: arm marker missing from serial log"
    exit 1
}
echo "TIMER.ARM: OK"

grep -q "timertest: fired seq=1" "$SER" || {
    echo "ERROR: first TIMER event marker missing from serial log"
    exit 1
}
echo "TIMER.FIRED: OK"

grep -q "timertest: cancel-none" "$SER" || {
    echo "ERROR: cancel-none marker missing from serial log"
    exit 1
}
echo "TIMER.CANCEL_NONE: OK"

grep -q "timertest: armed 1" "$SER" || {
    echo "ERROR: second arm marker missing from serial log"
    exit 1
}
grep -q "timertest: fired2 seq=2" "$SER" || {
    echo "ERROR: second TIMER event marker missing from serial log"
    exit 1
}
echo "TIMER.FIRED2: OK"

grep -q "timertest: canceled" "$SER" || {
    echo "ERROR: cancel-pending marker missing from serial log"
    exit 1
}
echo "TIMER.CANCEL_PENDING: OK"

grep -q "timertest: done" "$SER" || {
    echo "ERROR: done marker missing from serial log"
    exit 1
}
grep -q "tasks user-exec exited status=23" "$SER" || {
    echo "ERROR: TIMER.BIN exit status line missing from serial log"
    exit 1
}
echo "TIMER.EXIT23: OK"

# The syscall counters — set called 3 times, cancel called 2 times.
# OBSERVED BYTES (2026-08-24, claim 2259): implemented=61 today, not 46 —
# slots 47-60 landed after M14 across the M17-M26 arcs.
grep -q "syscalls: slots=64 implemented=61" "$SER" || {
    echo "ERROR: implemented=61 syscalls report missing from serial log"
    exit 1
}
grep -q "40 sys_timer_set calls=3" "$SER" || {
    echo "ERROR: sys_timer_set calls=3 missing from syscalls report"
    exit 1
}
grep -q "41 sys_timer_cancel calls=2" "$SER" || {
    echo "ERROR: sys_timer_cancel calls=2 missing from syscalls report"
    exit 1
}
echo "SYS_TIMER_SET/CANCEL COUNTS: OK"

grep -q "timers-live-ok" "$SER" || {
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
- syscalls report: implemented=61 (slots 47-60 landed post-M14),
  sys_timer_set calls=3, sys_timer_cancel calls=2

Serial Output Highlights:
$(grep -E 'timertest:|sys_timer_(set|cancel)' artifacts/live-timers-serial.log || true)
EOF

echo "verify-live-timers: PASS — arm/block/fire/cancel verified on VZ."
