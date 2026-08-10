#!/usr/bin/env bash
#
# verify-live-uaccess.sh -- claim 6120 class-B gate: the fault-safe uaccess
# layer on real VZ hardware.
#
# Two independent proofs, both asserted in vm-serial.log:
#   1. The EL0 payload passes an unmapped bad pointer (0x1_2000_0000, above
#      the 4 GiB identity blanket) to sys_write, receives -3 (EFAULT) in x0,
#      and survives to write the marker line "uaccess: efault ok n=8" —
#      the EFAULT contract end to end, without crashing EL1.
#   2. The `uaccess` monitor command runs a validated copy from the user
#      text aperture (valid=1) and a RAW copy from an unmapped address
#      (recovered=1) — a real EL1 data abort consumed by the exception path
#      and converted to EFAULT, with the shell still responsive after.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/m3-uaccess-live.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-uaccess-report.txt"
SCRIPT="artifacts/live-uaccess-script.txt"
EXIT_LINE="tasks user-el0 exited status=7"
MON_LINE="uaccess: valid=1 fault=1 recovered=1 copies=4 validation_faults=1"

echo "=== verify-live-uaccess: claim 6120 — EFAULT contract + fault recovery on EL0 SVC, $BOOTS boot(s) ==="
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

printf 'syscalls\nuaccess\necho rx-uaccess-ok\n' > "$SCRIPT"

run_one() {
    local tag="$1"
    local run_log="artifacts/live-uaccess-run-$tag.txt"
    local serial_copy="artifacts/live-uaccess-serial-$tag.log"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log

    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" --script-after "$EXIT_LINE" \
        --script-expect $'rx-uaccess-ok\n' --timeout 45 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "$serial_copy" || true

    local bytes=0 banner=0 write_ok=0 marker=0 ping=0 write_count=0 mon=0 echo_ok=0 userspace_ok=0 fatal=0
    if [ -f artifacts/vm-serial.log ]; then
        bytes="$(wc -c < artifacts/vm-serial.log | tr -d ' ')"
        [ "$(grep -aFxc -- "DipshitOS kernel has seized control." artifacts/vm-serial.log || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "syscall: write ok n=23" artifacts/vm-serial.log || true)" -ge 1 ] && write_ok=1
        [ "$(grep -aFc -- "uaccess: efault ok n=8" artifacts/vm-serial.log || true)" -ge 1 ] && marker=1
        [ "$(grep -aFxc -- "  0 sys_ping calls=2" artifacts/vm-serial.log || true)" = 1 ] && ping=1
        [ "$(grep -aFxc -- "  1 sys_write calls=3" artifacts/vm-serial.log || true)" = 1 ] && write_count=1
        [ "$(grep -aFxc -- "$MON_LINE" artifacts/vm-serial.log || true)" = 1 ] && mon=1
        [ "$(grep -aFxc -- "rx-uaccess-ok" artifacts/vm-serial.log || true)" = 1 ] && echo_ok=1
        [ "$(grep -aFxc -- "userspace: el0=1 svc=2 roundtrips=1 arg=2 result=2 rejected=0" artifacts/vm-serial.log || true)" = 1 ] && userspace_ok=1
        grep -qF -- "[EXC] parking:" artifacts/vm-serial.log && fatal=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner write=$write_ok marker=$marker ping=$ping write-count=$write_count mon=$mon echo=$echo_ok userspace=$userspace_ok fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$write_ok" = 1 ] && \
        [ "$marker" = 1 ] && [ "$ping" = 1 ] && [ "$write_count" = 1 ] && \
        [ "$mon" = 1 ] && [ "$echo_ok" = 1 ] && \
        [ "$userspace_ok" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live uaccess gate (claim 6120) — EFAULT contract + fault recovery on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "monitor line: $MON_LINE"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

pass=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-uaccess boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-uaccess: PASS — EL0 observed EFAULT for a bad pointer and survived; the monitor command recovered a real data abort (valid=1 fault=1 recovered=1) and the shell replied ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-uaccess: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
