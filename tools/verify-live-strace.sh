#!/usr/bin/env bash
#
# verify-live-strace.sh -- M22 D5 class-B gate (issue #328, claim 9815):
# the syscall tracer prints one line per syscall for a traced program.
#
# The chain, all asserted in vm-serial.log:
#   1. `strace exec HELLO.ELF` arms the tracer around the exec — the
#      loader records the new pid at the success point so every subsequent
#      syscall from that process is printed synchronously by dispatch().
#   2. The traced program's syscalls appear with names + args + results:
#      "[strace 1] sys_write(0x1, 0x400024, 0x1a) = 0x1a" (the marker
#      line) and "[strace 1] sys_exit(0x2a, ...) = 0" before the exit.
#   3. The program itself still runs normally: its sys_write marker lands,
#      it exits status 42 and is reaped.
#   4. `strace off` disarms cleanly.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/m22-strace-live.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-strace-report.txt"
SCRIPT="artifacts/live-strace-script.txt"
SCRIPT2="artifacts/live-strace-script2.txt"
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
EXIT_LINE="tasks user-exec exited status=42"

echo "=== verify-live-strace: M22 D5 (issue #328) — per-syscall tracing, $BOOTS boot(s) ==="
zig version
swift --version 2>&1 | head -1
sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

printf 'strace exec HELLO.ELF\necho strace-mid\n' > "$SCRIPT"
printf 'crash\nsym\nstrace off\necho rx-strace-ok\n' > "$SCRIPT2"

run_one() {
    local tag="$1"
    local run_log="artifacts/live-strace-run-$tag.txt"
    local serial_copy="artifacts/live-strace-serial-$tag.log"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log

    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" --script-after "$STATIC_EXIT_LINE" \
        --script2 "$SCRIPT2" --script2-after "$EXIT_LINE" \
        --script-expect "rx-strace-ok" --timeout 90 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "$serial_copy" || true

    local bytes=0 banner=0 armed=0 trace_write=0 trace_exit=0 hello=0 exited=0 off=0 echo_ok=0 fatal=0
    if [ -f artifacts/vm-serial.log ]; then
        bytes="$(wc -c < artifacts/vm-serial.log | tr -d ' ')"
        [ "$(grep -aFxc -- "DipshitOS kernel has seized control." artifacts/vm-serial.log || true)" = 1 ] && banner=1
        [ "$(grep -aFxc -- "strace: armed" artifacts/vm-serial.log || true)" = 1 ] && armed=1
        [ "$(grep -aFc -- "] sys_write(" artifacts/vm-serial.log || true)" -ge 1 ] && trace_write=1
        [ "$(grep -aFc -- "] sys_exit(" artifacts/vm-serial.log || true)" -ge 1 ] && trace_exit=1
        [ "$(grep -aFxc -- "elf: hello from HELLO.ELF" artifacts/vm-serial.log || true)" = 1 ] && hello=1
        [ "$(grep -aFxc -- "$EXIT_LINE" artifacts/vm-serial.log || true)" = 1 ] && exited=1
        [ "$(grep -aFxc -- "strace: off" artifacts/vm-serial.log || true)" = 1 ] && off=1
        [ "$(grep -aFxc -- "rx-strace-ok" artifacts/vm-serial.log || true)" = 1 ] && echo_ok=1
        grep -qF -- "[EXC] parking:" artifacts/vm-serial.log && fatal=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner armed=$armed trace_write=$trace_write trace_exit=$trace_exit hello=$hello exited=$exited off=$off echo=$echo_ok fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$armed" = 1 ] && [ "$trace_write" = 1 ] && \
        [ "$trace_exit" = 1 ] && [ "$hello" = 1 ] && [ "$exited" = 1 ] && \
        [ "$off" = 1 ] && [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live strace gate (M22 D5, issue #328, claim 9815)"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $(cat "$SCRIPT" | tr '\n' '|')"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

pass=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-strace boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-strace: PASS — the tracer printed named syscall lines (args + result) for the exec'd program, which ran normally to exit 42; 'strace off' disarmed ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-strace: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
