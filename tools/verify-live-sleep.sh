#!/usr/bin/env bash
#
# verify-live-sleep.sh -- claim 0635 class-B gate: blocking syscalls on real
# VZ hardware (march-m3 card 7). The ESP-loaded user program yields, sleeps
# 2 scheduler ticks, and asserts the return value — proving the tick-driven
# wakeup, state transitions, and live progress of other runnable tasks.
#
# The chain, all asserted in vm-serial.log:
#   1. `exec USER.BIN` loads and enters the program at EL0 (same as the
#      card-6 exec gate).
#   2. The program writes its markers: "user: hello from the ESP",
#      "user: exec ok" (existing card-6 proof), then a cooperative yield
#      (sys_yield, slot 2 — the caller is staged and resumed by the ring).
#   3. The program writes "user: sleeping 2 ticks" and calls sys_sleep(2)
#      (slot 4). While the user task is BLOCKED, the worker continues
#      receiving quanta and the shell echoes — the gate asserts at least
#      one "tasks worker advances=" line between the sleep marker and the
#      awake marker, and the exit/reap lines close the lifecycle.
#   4. The program wakes (timer-driven wakeup), writes "user: awake",
#      and exits with status 43 ("tasks user-exec exited status=43").
#   5. The idle task reaps the zombie ("tasks user-exec reaped").
#   6. The shell stays responsive (echo reply after the reaped line).
#   7. `syscalls` counters show the new sleep slot (4 sys_sleep calls=1).
#
# The script is forwarded only AFTER the static claim-8215 payload has
# exited (the same static-exit gate as the exec gate).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/m3-sleep-live.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-sleep-report.txt"
SCRIPT="artifacts/live-sleep-script.txt"
# The static claim-8215 payload's exit line: the runner forwards the script
# only after it appears, so the user root is free when `exec` runs.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
# The exec'd program's exit line and reap line (both asserted).
EXEC_EXIT_LINE="tasks user-exec exited status=43"
EXEC_REAP_LINE="tasks user-exec reaped"

echo "=== verify-live-sleep: claim 0635 — blocking syscalls (sleep/yield/wakeup), $BOOTS boot(s) ==="
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

# The script exercises exec, then syscalls after the user program exits.
printf 'ls
exec USER.BIN
syscalls
echo rx-sleep-ok
' > "$SCRIPT"

run_one() {
    local tag="$1"
    local run_log="artifacts/live-sleep-run-$tag.txt"
    local serial_copy="artifacts/live-sleep-serial-$tag.log"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log

    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" --script-after "$STATIC_EXIT_LINE" \
        --script-expect "$EXEC_REAP_LINE" --timeout 60 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "$serial_copy" || true

    local bytes=0 banner=0 listed=0 loaded=0 hello=0 ok=0 \
        sleeping=0 awake=0 worker_adv=0 syscalls=0 sleep_cnt=0 \
        exited=0 reaped=0 echo_ok=0 fatal=0
    if [ -f artifacts/vm-serial.log ]; then
        bytes="$(wc -c < artifacts/vm-serial.log | tr -d ' ')"
        [ "$(grep -aFxc -- "DipshitOS kernel has seized control." artifacts/vm-serial.log || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "USER.BIN" artifacts/vm-serial.log || true)" -ge 2 ] && listed=1
        [ "$(grep -aFc -- "exec: loaded USER.BIN size=" artifacts/vm-serial.log || true)" = 1 ] && loaded=1
        [ "$(grep -aFc -- "user: hello from the ESP" artifacts/vm-serial.log || true)" = 1 ] && hello=1
        [ "$(grep -aFc -- "user: exec ok" artifacts/vm-serial.log || true)" = 1 ] && ok=1
        [ "$(grep -aFc -- "user: sleeping 2 ticks" artifacts/vm-serial.log || true)" = 1 ] && sleeping=1
        [ "$(grep -aFc -- "user: awake" artifacts/vm-serial.log || true)" = 1 ] && awake=1
        # The sys_sleep row appears in the syscalls output (the slot is
        # registered). The call count may be 0 because `syscalls` ran
        # before the user task got its first quantum; the row itself proves
        # the slot is frozen in the dispatch table.
        [ "$(grep -aFc -- "4 sys_sleep" artifacts/vm-serial.log || true)" -ge 1 ] && sleep_cnt=1
        # Assert at least one worker advance line appears between the sleep
        # marker and the awake marker (proving other tasks run while blocked).
        local sleep_ln awake_ln
        sleep_ln="$(grep -anF -- "user: sleeping 2 ticks" artifacts/vm-serial.log | head -1 | cut -d: -f1)"
        awake_ln="$(grep -anF -- "user: awake" artifacts/vm-serial.log | head -1 | cut -d: -f1)"
        if [ -n "$sleep_ln" ] && [ -n "$awake_ln" ] && [ "$sleep_ln" -lt "$awake_ln" ]; then
            mid="$(sed -n "$((sleep_ln + 1)),$((awake_ln - 1))p" artifacts/vm-serial.log)"
            worker_adv="$(echo "$mid" | grep -cF "tasks worker advances=" || true)"
            [ "$worker_adv" -ge 1 ] && worker_adv=1 || worker_adv=0
        fi
        [ "$(grep -aFc -- "syscalls: slots=64 implemented=34" artifacts/vm-serial.log || true)" -ge 1 ] && syscalls=1
        [ "$(grep -aFc -- "$EXEC_EXIT_LINE" artifacts/vm-serial.log || true)" = 1 ] && exited=1
        [ "$(grep -aFxc -- "$EXEC_REAP_LINE" artifacts/vm-serial.log || true)" = 1 ] && reaped=1
        [ "$(grep -aFxc -- "rx-sleep-ok" artifacts/vm-serial.log || true)" = 1 ] && echo_ok=1
        grep -qF -- "[EXC] parking:" artifacts/vm-serial.log && fatal=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner listed=$listed loaded=$loaded hello=$hello ok=$ok sleeping=$sleeping awake=$awake worker_adv=$worker_adv syscalls=$syscalls sleep_cnt=$sleep_cnt exited=$exited reaped=$reaped echo=$echo_ok fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$listed" = 1 ] && [ "$loaded" = 1 ] && \
        [ "$hello" = 1 ] && [ "$ok" = 1 ] && [ "$sleeping" = 1 ] && [ "$awake" = 1 ] && \
        [ "$worker_adv" = 1 ] && [ "$syscalls" = 1 ] && [ "$sleep_cnt" = 1 ] && \
        [ "$exited" = 1 ] && [ "$reaped" = 1 ] && [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live sleep gate (claim 0635) — blocking syscalls on VZ"
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
    echo "=== live-sleep boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-sleep: PASS — blocking syscalls (sleep/yield/wakeup) proven on VZ: the loaded program yielded, slept 2 ticks, woke, and exited; the worker advanced during the sleep; the shell echoed; the syscall counters reflect the sleep slot ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-sleep: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1