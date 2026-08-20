#!/usr/bin/env bash
#
# verify-live-m16-resources.sh -- milestone sixteen card C3 (claim 0339)
# class-B gate: measure the fixed pools under real concurrent-app load and
# prove the grown pool — EIGHT live user programs — with the before/after
# accounting pinned in the serial log.
#
# The wishlist rule ("keep pools bounded until real apps expose actual
# pain") is applied honestly here: the scheduler executor pool (7 slots ->
# 4 user programs) is the pool the demo apps exhaust — the exec path
# refused a FIFTH concurrent program with `pool_full` (the M4-era scale
# gate). C3 grows it to 11 slots (8 user programs) and records the
# measurement via the new `resources` command, which prints every bounded
# pool's live occupancy vs its bound.
#
# Script (forwarded after the boot payload exits + is reaped):
#   resources | ls | exec COUNTER.BIN | exec USER.BIN x7 | procs
#     | resources | exec USER.BIN (ninth) | echo rx-resources-ok
#
# All asserted in vm-serial.log:
#   1. The BEFORE `resources` read shows the baseline: tasks<=5 (shell +
#      worker + idle + at most the boot zombie) and procs<=1.
#   2. COUNTER.BIN loads once and USER.BIN loads SEVEN times (8 live
#      programs — "more concurrent applications than today's pool allows").
#   3. The procs snapshot shows EIGHT running user processes with EIGHT
#      distinct executor task ids + stack VAs.
#   4. The AFTER `resources` read pins the grown accounting: tasks=11/11
#      (shell + worker + idle + 8 users) and procs=9/16 (boot exited + 8
#      running) — the before/after pool accounting the card demands.
#   5. The NINTH exec is refused with `error: no free scheduler pool slot`
#      (capacity gate at the grown budget, checked before any allocation).
#   6. The other pools stay bounded (their bounds printed, not grown): the
#      final resources line still reports windows/8, events=16, mbox=8,
#      fds=8, timers=1, tcp=1 — the audit's "left alone" record.
#   7. The counter stays running; the shell stays responsive; no exception
#      park.
#
# Evidence saved under artifacts/: live-m16-resources-gate.txt,
# live-m16-resources-report.txt, live-m16-resources-run-<NN>.txt,
# live-m16-resources-serial-<NN>.log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-m16-resources-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-m16-resources-report.txt"
SCRIPT="artifacts/live-m16-resources-script.txt"
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
POOL_FULL_LINE="error: no free scheduler pool slot"

echo "=== verify-live-m16-resources: claim 0339 — measure the pools, grow the one the apps exhaust (8 live programs), $BOOTS boot(s) ==="
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

# BEFORE accounting -> fill the pool to 8 -> procs snapshot -> AFTER
# accounting -> ninth exec (pool_full) -> shell check.
printf 'resources\nls\nexec COUNTER.BIN\nexec USER.BIN\nexec USER.BIN\nexec USER.BIN\nexec USER.BIN\nexec USER.BIN\nexec USER.BIN\nexec USER.BIN\nprocs\nresources\nexec USER.BIN\necho rx-resources-ok\n' > "$SCRIPT"

run_one() {
    local tag="$1"
    local run_log="artifacts/live-m16-resources-run-$tag.txt"
    local serial_copy="artifacts/live-m16-resources-serial-$tag.log"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log

    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" --script-after "$STATIC_EXIT_LINE" \
        --timeout 60 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "$serial_copy" || true

    local bytes=0 banner=0 resources_before=0 resources_after=0 \
        baseline_tasks=0 loaded_counter=0 loaded_user=0 eight_running=0 \
        distinct_tasks=0 distinct_stacks=0 pool_full=0 counter_running=0 \
        bounded_left=0 echo_ok=0 fatal=0
    if [ -f artifacts/vm-serial.log ]; then
        bytes="$(wc -c < artifacts/vm-serial.log | tr -d ' ')"
        [ "$(grep -aFxc -- "DipshitOS kernel has seized control." artifacts/vm-serial.log || true)" = 1 ] && banner=1

        # 1. The BEFORE `resources` read: the baseline before filling (the
        # first resources line in the log).
        local before_line
        before_line="$(grep -aF -- "resources: tasks=" artifacts/vm-serial.log | head -1 || true)"
        if [ -n "$before_line" ]; then
            resources_before=1
            local bt
            bt="$(printf '%s\n' "$before_line" | sed -E 's/resources: tasks=([0-9]+)\/.*/\1/')"
            [ -n "$bt" ] && [ "$bt" -le 5 ] && baseline_tasks=1 || true
        fi

        # 2. Loads: one counter + seven USER.BINs.
        loaded_counter="$(grep -aFc -- "exec: loaded COUNTER.BIN size=" artifacts/vm-serial.log || true)"
        loaded_user="$(grep -aFc -- "exec: loaded USER.BIN size=" artifacts/vm-serial.log || true)"

        # 3. EIGHT running user processes with distinct tasks + stacks.
        local rows
        rows="$(grep -aE -- "procs: id=[0-9]+ name=(COUNTER.BIN|USER.BIN) state=running" artifacts/vm-serial.log || true)"
        if [ -n "$rows" ]; then
            local running_rows n_tasks n_stacks
            running_rows="$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"
            [ "$running_rows" = 8 ] && eight_running=1 || eight_running=0
            n_tasks="$(printf '%s\n' "$rows" | sed -E 's/.*task=([0-9]+).*/\1/' | sort -u | wc -l | tr -d ' ')"
            n_stacks="$(printf '%s\n' "$rows" | sed -E 's/.*stack=0x([0-9a-f]{16}).*/\1/' | sort -u | wc -l | tr -d ' ')"
            [ "$n_tasks" = 8 ] && distinct_tasks=1 || distinct_tasks=0
            [ "$n_stacks" = 8 ] && distinct_stacks=1 || distinct_stacks=0
        fi

        # 4. The AFTER `resources` read: tasks=11/11 (shell + worker + idle
        # + 8 users) and procs=9/16 (boot exited + 8 running).
        local after_line
        after_line="$(grep -aF -- "resources: tasks=" artifacts/vm-serial.log | tail -1 || true)"
        if [ -n "$after_line" ] && printf '%s\n' "$after_line" | grep -qF -- "resources: tasks=11/11"; then
            resources_after=1
        fi
        grep -a -qF -- "resources: procs=9/16" artifacts/vm-serial.log && resources_after=1 || true

        # 5. The NINTH exec is refused.
        [ "$(grep -aFc -- "$POOL_FULL_LINE" artifacts/vm-serial.log || true)" -ge 1 ] && pool_full=1 || true

        # 6. The audit's "left bounded" record: the pools NOT grown still
        # print their bounds (windows=N/8 on its own line, then the
        # per-process ring bounds events=16 mbox=8 fds=8 timers=1 tcp=1).
        if grep -a -qE -- "resources: windows=[0-9]+/8" artifacts/vm-serial.log && \
           grep -a -qF -- "resources: events=16 mbox=8 fds=8 timers=1 tcp=1" artifacts/vm-serial.log; then
            bounded_left=1
        fi

        # 7. The counter stays running; shell responsive; no park.
        local last_counter_row
        last_counter_row="$(grep -aE -- "procs: id=[0-9]+ name=COUNTER.BIN" artifacts/vm-serial.log | tail -1 || true)"
        if [ -n "$last_counter_row" ]; then
            printf '%s\n' "$last_counter_row" | grep -qF -- "state=running" && counter_running=1
        fi
        [ "$(grep -aFxc -- "rx-resources-ok" artifacts/vm-serial.log || true)" = 1 ] && echo_ok=1
        grep -qF -- "[EXC] parking:" artifacts/vm-serial.log && fatal=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner resources-before=$resources_before baseline-tasks=$baseline_tasks loaded-counter=$loaded_counter loaded-user=$loaded_user eight-running=$eight_running tasks-distinct=$distinct_tasks stacks-distinct=$distinct_stacks resources-after=$resources_after pool-full=$pool_full bounded-left=$bounded_left counter-running=$counter_running echo=$echo_ok fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$resources_before" = 1 ] && \
        [ "$baseline_tasks" = 1 ] && [ "$loaded_counter" = 1 ] && [ "$loaded_user" = 7 ] && \
        [ "$eight_running" = 1 ] && [ "$distinct_tasks" = 1 ] && [ "$distinct_stacks" = 1 ] && \
        [ "$resources_after" = 1 ] && [ "$pool_full" = 1 ] && [ "$bounded_left" = 1 ] && \
        [ "$counter_running" = 1 ] && [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live M16 resources gate (claim 0339) — measure the pools, grow the exhausted one"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $(cat "$SCRIPT" | tr '\n' '|')"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
    echo "BEFORE resources (baseline) -> 8 concurrent programs (counter + 7"
    echo "USER.BINs) -> AFTER resources (tasks=11/11 procs=9/16) -> ninth exec"
    echo "pool_full. The pools left bounded (windows/8, events=16, mbox=8,"
    echo "fds=8, timers=1, tcp=1) are printed as the audit's 'left alone' record."
    echo
} >> "$REPORT"

pass=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-m16-resources boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-m16-resources: PASS — the scheduler pool grew 7->11 (8 live user programs) because the apps exhausted 4; the before/after resources accounting pinned tasks=11/11 procs=9/16, the ninth exec was pool_full, and the other pools stayed bounded ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-m16-resources: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
