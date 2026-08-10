#!/usr/bin/env bash
#
# verify-live-svc.sh -- claim 3594 class-B gate: the numbered syscall table
# on the real claim-8215 EL0/SVC boundary.
#
# The EL0 payload performs two pings and a bounded console write, waits for a
# real timer preemption, then yields and exits without returning. The
# runner sends one script only after the shell reports that exit, so the reply
# proves the shell remained responsive after the real SVC sequence.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/m3-syscall-abi-live-svc.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-svc-report.txt"
SCRIPT="artifacts/live-svc-script.txt"
EXIT_LINE="tasks user-el0 exited status=7"

echo "=== verify-live-svc: claim 3594 — syscall table on EL0 SVC, $BOOTS boot(s) ==="
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

printf 'syscalls\necho rx-svc-ok\n' > "$SCRIPT"

run_one() {
    local tag="$1"
    local run_log="artifacts/live-svc-run-$tag.txt"
    local serial_copy="artifacts/live-svc-serial-$tag.log"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log

    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" --script-after "$EXIT_LINE" \
        --script-expect $'rx-svc-ok\n' --timeout 45 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "$serial_copy" || true

    local bytes=0 banner=0 write_ok=0 ping=0 write_count=0 yield_ok=0 exit_count=0 table=0 echo_ok=0 userspace_ok=0 fatal=0 ordered=0
    if [ -f artifacts/vm-serial.log ]; then
        bytes="$(wc -c < artifacts/vm-serial.log | tr -d ' ')"
        [ "$(grep -aFxc -- "DipshitOS kernel has seized control." artifacts/vm-serial.log || true)" = 1 ] && banner=1
        [ "$(grep -aFxc -- "dipshit> syscall: write ok n=23" artifacts/vm-serial.log || true)" = 1 ] && write_ok=1
        [ "$(grep -aFxc -- "  0 sys_ping calls=2" artifacts/vm-serial.log || true)" = 1 ] && ping=1
        [ "$(grep -aFxc -- "  1 sys_write calls=1" artifacts/vm-serial.log || true)" = 1 ] && write_count=1
        [ "$(grep -aFxc -- "  2 sys_yield calls=1" artifacts/vm-serial.log || true)" = 1 ] && yield_ok=1
        [ "$(grep -aFxc -- "$EXIT_LINE" artifacts/vm-serial.log || true)" = 1 ] && exit_count=1
        [ "$(grep -aFxc -- "  3 sys_exit calls=1" artifacts/vm-serial.log || true)" = 1 ] && table=1
        [ "$(grep -aFxc -- "rx-svc-ok" artifacts/vm-serial.log || true)" = 1 ] && echo_ok=1
        [ "$(grep -aFxc -- "userspace: el0=1 svc=2 roundtrips=1 arg=2 result=2 rejected=0" artifacts/vm-serial.log || true)" = 1 ] && userspace_ok=1
        grep -qF -- "[EXC] parking:" artifacts/vm-serial.log && fatal=1 || true
        local write_line timer_line exit_line
        write_line="$(grep -anF -- "dipshit> syscall: write ok n=23" artifacts/vm-serial.log | cut -d: -f1 | head -1)"
        timer_line="$(grep -anF -- "timer irq delivered ppi=0x1e irq_ticks=1" artifacts/vm-serial.log | cut -d: -f1 | head -1)"
        exit_line="$(grep -anF -- "$EXIT_LINE" artifacts/vm-serial.log | cut -d: -f1 | head -1)"
        if [ -n "$write_line" ] && [ -n "$timer_line" ] && [ -n "$exit_line" ] && \
            [ "$write_line" -lt "$timer_line" ] && [ "$timer_line" -lt "$exit_line" ]; then ordered=1; fi
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner write=$write_ok ping=$ping write-count=$write_count yield=$yield_ok exit=$exit_count table=$table echo=$echo_ok userspace=$userspace_ok ordered=$ordered fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$write_ok" = 1 ] && \
        [ "$ping" = 1 ] && [ "$write_count" = 1 ] && [ "$yield_ok" = 1 ] && \
        [ "$exit_count" = 1 ] && [ "$table" = 1 ] && [ "$echo_ok" = 1 ] && \
        [ "$userspace_ok" = 1 ] && [ "$ordered" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live SVC gate (claim 3594) — numbered syscall table on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

pass=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-svc boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-svc: PASS — write/yield/exit dispatched through real EL0 SVC, counters reported, and the post-SVC shell replied ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-svc: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
