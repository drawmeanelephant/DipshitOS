#!/usr/bin/env bash
#
# verify-live-userspace.sh -- claim 8215 class-B gate: a real EL0t task,
# synchronous SVC boundary, and timer-preempted return to the EL1h shell.
#
# The success line is emitted only after the lower-EL synchronous vector has
# accepted TWO correctly sequenced SVCs. The second entry proves the first SVC
# returned to EL0 with x0 restored. The shell prints the deferred line only
# after the timer preempts the EL0 task and schedules EL1h again.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-userspace-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-userspace-report.txt"
SCRIPT="artifacts/live-userspace-script.txt"
EXPECT="userspace: el0=1 svc=2 roundtrips=1 arg=2 result=2 rejected=0"

echo "=== verify-live-userspace: claim 8215 — EL0t + SVC round-trip + timer preemption, $BOOTS boot(s) ==="
zig version
swift --version 2>&1 | head -1
sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

printf 'tasks\necho rx-el0-ok\n' > "$SCRIPT"

run_one() {
    local tag="$1"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" --script-expect "$EXPECT" --timeout 60 \
        > "artifacts/live-userspace-run-$tag.txt" 2>&1
    local rc=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-userspace-serial-$tag.log" || true

    local bytes=0 banner=0 tasks=0 user_row=0 worker=0 svc=0 echo_ok=0 fatal=0
    if [ -f artifacts/vm-serial.log ]; then
        bytes="$(wc -c < artifacts/vm-serial.log | tr -d ' ')"
        grep -qF -- "DipshitOS kernel has seized control." artifacts/vm-serial.log && banner=1
        grep -qF -- "tasks: enabled=1" artifacts/vm-serial.log && tasks=1
        grep -qE -- "user-el0 +saves=[0-9]+ resumes=[0-9]+ advances=0" artifacts/vm-serial.log && user_row=1
        grep -qE -- "tasks worker advances=[1-9][0-9]*" artifacts/vm-serial.log && worker=1
        grep -qF -- "$EXPECT" artifacts/vm-serial.log && svc=1
        grep -qF -- "rx-el0-ok" artifacts/vm-serial.log && echo_ok=1
        grep -qF -- "[EXC] parking:" artifacts/vm-serial.log && fatal=1 || true
    fi
    echo "$tag: rc=$rc serial-bytes=$bytes banner=$banner tasks=$tasks user-row=$user_row worker=$worker svc=$svc echo=$echo_ok fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$tasks" = 1 ] && \
        [ "$user_row" = 1 ] && [ "$worker" = 1 ] && [ "$svc" = 1 ] && \
        [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live-userspace gate (claim 8215) — EL0t/SVC/timer round-trip on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "expect: $EXPECT"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

pass=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-userspace boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-userspace: PASS — EL0 executed, completed an SVC return round-trip, and was timer-preempted back to the responsive EL1h shell ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-userspace: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot serial logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
