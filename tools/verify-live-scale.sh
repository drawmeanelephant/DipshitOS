#!/usr/bin/env bash
#
# verify-live-scale.sh -- claim 5795 (milestone-four follow-on 3, card 3g)
# class-B gate: the pool-scale capstone on real VZ hardware.
#
# Every prior card documented the 5-slot budget (3b/3c/3f: "5/5, NO spare";
# 3a/3e: one spare). Card 3g DELIBERATELY grew the scheduler pool
# max_tasks 5 -> 7 (shell + worker + FOUR EL0t user slots + idle).
# Milestone sixteen C3 (claim 0339) grew it again 7 -> 11 (shell + worker +
# EIGHT EL0t user slots + idle) because the demo apps exhausted the four
# user slots. This gate proves the grown budget's headline: EIGHT live user
# programs at once.
#
# Script (the claim-4613 multi-phase runner; phase 1 is forwarded after
# the boot payload exits + is reaped, freeing the user slots):
#   Phase 1:
#     ls | exec COUNTER.BIN | exec USER.BIN | exec USER.BIN | exec USER.BIN
#       | exec USER.BIN | exec USER.BIN | exec USER.BIN | exec USER.BIN
#       | procs | addrspaces | exec USER.BIN | echo rx-scale-ok
#
# All asserted in vm-serial.log:
#   1. All three ESP programs are listed; COUNTER.BIN loads once and
#      USER.BIN loads SEVEN times ("exec: loaded ... size=").
#   2. The procs snapshot shows EIGHT running user processes — one
#      COUNTER.BIN + seven USER.BINs — with EIGHT DISTINCT executor task
#      ids and EIGHT DISTINCT stack VAs (the 11-slot budget's headline:
#      shell + worker + 8 users + idle = 11/11).
#   3. All seven USER.BINs run their usual EL0 flow (hello markers) and
#      their markers + the counter's markers interleave with the worker's
#      advances across the whole log (8 live programs + worker + shell).
#   4. The pool is FULL at 11/11: the NINTH exec (an 8th USER.BIN) is
#      refused with "error: no free scheduler pool slot" — the capacity
#      gate at the grown budget, checked before any allocation (leak-free).
#   5. The addrspaces read shows tables=NN/512 with the kernel root + EIGHT
#      user roots live: NN stays inside the 512-page carve-out (headroom
#      assertion — the C3 measurement records the actual NN; the carve-out
#      grew 256 → 512 in C4, claim 2714).
#   6. The counter is STILL state=running at the final procs read (the
#      permanent occupant survives the seven short programs); the shell
#      stays responsive; no exception park.
#
# The runner runs WITHOUT --script-expect: the never-exiting counter needs
# the full window (the runner exits success on timeout when no expect is
# configured; the assertions below are the gate). Evidence saved under
# artifacts/: live-scale-gate.txt, live-scale-report.txt,
# live-scale-run-<NN>.txt, live-scale-serial-<NN>.log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-scale-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-scale-report.txt"
SCRIPT="artifacts/live-scale-script.txt"
# The static claim-8215 payload's exit line: the runner forwards the
# script only after it appears, so the boot payload's slot is free.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
# The refused ninth exec (11/11 pool at the grown budget).
POOL_FULL_LINE="error: no free scheduler pool slot"

echo "=== verify-live-scale: claim 5795 (C3 claim 0339) — EIGHT live user programs at the 11-slot budget, $BOOTS boot(s) ==="
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

# The counter (permanent occupant) + seven short programs fill the pool to
# 11/11; the procs + addrspaces snapshots catch all eight live; the NINTH
# exec is the capacity gate; then the shell check.
printf 'ls\nexec COUNTER.BIN\nexec USER.BIN\nexec USER.BIN\nexec USER.BIN\nexec USER.BIN\nexec USER.BIN\nexec USER.BIN\nexec USER.BIN\nprocs\naddrspaces\nexec USER.BIN\necho rx-scale-ok\n' > "$SCRIPT"

run_one() {
    local tag="$1"
    local run_log="artifacts/live-scale-run-$tag.txt"
    local serial_copy="artifacts/live-scale-serial-$tag.log"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log

    set +e
    # No --script-expect: capture the full window (the runner exits 0 on
    # timeout when no expect is configured).
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" --script-after "$STATIC_EXIT_LINE" \
        --timeout 60 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "$serial_copy" || true

    local bytes=0 banner=0 listed_counter=0 listed_user=0 loaded_counter=0 \
        loaded_user=0 eight_running=0 distinct_tasks=0 distinct_stacks=0 \
        hello=0 markers=0 interleave=0 pool_full=0 tables_headroom=0 \
        final_counter_running=0 echo_ok=0 fatal=0
    if [ -f artifacts/vm-serial.log ]; then
        bytes="$(wc -c < artifacts/vm-serial.log | tr -d ' ')"
        [ "$(grep -aFxc -- "DipshitOS kernel has seized control." artifacts/vm-serial.log || true)" = 1 ] && banner=1
        grep -a -qE -- "^  COUNTER.BIN " artifacts/vm-serial.log && listed_counter=1
        grep -a -qE -- "^  USER.BIN " artifacts/vm-serial.log && listed_user=1
        loaded_counter="$(grep -aFc -- "exec: loaded COUNTER.BIN size=" artifacts/vm-serial.log || true)"
        loaded_user="$(grep -aFc -- "exec: loaded USER.BIN size=" artifacts/vm-serial.log || true)"

        # The procs snapshot: EIGHT running user processes (one counter +
        # seven USER.BINs) with EIGHT distinct executor task ids + stack VAs.
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

        # All seven USER.BINs ran their usual flow, and the counter's
        # markers span the whole log. Interleaving: the worker's advances
        # land BETWEEN the counter's markers (the counter runs forever, so
        # its markers + the worker's advances alternate across the log —
        # with 8 user programs + shell + worker all in the ring).
        hello="$(grep -aFc -- "user: hello from the ESP" artifacts/vm-serial.log || true)"
        markers="$(grep -aFc -- "counter: alive" artifacts/vm-serial.log || true)"
        local first_marker last_marker mid
        first_marker="$(grep -anF -- "counter: alive" artifacts/vm-serial.log | head -1 | cut -d: -f1 || true)"
        last_marker="$(grep -anF -- "counter: alive" artifacts/vm-serial.log | tail -1 | cut -d: -f1 || true)"
        if [ -n "$first_marker" ] && [ -n "$last_marker" ] && [ "$first_marker" -lt "$last_marker" ]; then
            mid="$(sed -n "$((first_marker + 1)),$((last_marker - 1))p" artifacts/vm-serial.log)"
            [ "$(echo "$mid" | grep -cF -- "tasks worker advances=" || true)" -ge 1 ] && interleave=1 || interleave=0
        fi

        # 11/11 budget: the NINTH exec is refused.
        [ "$(grep -aFc -- "$POOL_FULL_LINE" artifacts/vm-serial.log || true)" -ge 1 ] && pool_full=1 || true

        # The tables budget with the kernel root + EIGHT user roots live:
        # the C3 measurement records NN/512. It must stay inside the
        # 512-page carve-out (headroom > 0), and the actual NN is echoed
        # in the report line for the claim's before/after record.
        local tables
        tables="$(grep -aoE -- "addrspaces: tables=[0-9]+/512" artifacts/vm-serial.log | tail -1 || true)"
        if [ -n "$tables" ]; then
            local used cap
            used="$(printf '%s\n' "$tables" | sed -E 's/.*tables=([0-9]+)\/512.*/\1/')"
            cap=512
            [ -n "$used" ] && [ "$used" -gt 0 ] && [ "$used" -lt "$cap" ] && tables_headroom=1 || true
        fi

        # The counter is STILL running at the final procs read.
        local last_counter_row
        last_counter_row="$(grep -aE -- "procs: id=[0-9]+ name=COUNTER.BIN" artifacts/vm-serial.log | tail -1 || true)"
        if [ -n "$last_counter_row" ]; then
            printf '%s\n' "$last_counter_row" | grep -qF -- "state=running" && final_counter_running=1
        fi
        [ "$(grep -aFxc -- "rx-scale-ok" artifacts/vm-serial.log || true)" = 1 ] && echo_ok=1
        grep -qF -- "[EXC] parking:" artifacts/vm-serial.log && fatal=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner listed-counter=$listed_counter listed-user=$listed_user loaded-counter=$loaded_counter loaded-user=$loaded_user eight-running=$eight_running tasks-distinct=$distinct_tasks stacks-distinct=$distinct_stacks hello=$hello markers=$markers interleave=$interleave pool-full=$pool_full tables=$tables tables-headroom=$tables_headroom final-counter-running=$final_counter_running echo=$echo_ok fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$listed_counter" = 1 ] && [ "$listed_user" = 1 ] && \
        [ "$loaded_counter" = 1 ] && [ "$loaded_user" = 7 ] && \
        [ "$eight_running" = 1 ] && [ "$distinct_tasks" = 1 ] && [ "$distinct_stacks" = 1 ] && \
        [ "$hello" = 7 ] && [ "$markers" -ge 3 ] && [ "$interleave" = 1 ] && \
        [ "$pool_full" = 1 ] && [ "$tables_headroom" = 1 ] && \
        [ "$final_counter_running" = 1 ] && [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live pool-scale gate (claim 5795 + C3 claim 0339) — EIGHT live user programs at the 11-slot budget on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $(cat "$SCRIPT" | tr '\n' '|')"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
    echo "COUNTER.BIN (never exits) + seven USER.BINs fill the pool to 11/11"
    echo "(shell + worker + 8 users + idle); the procs snapshot shows EIGHT"
    echo "running user processes with distinct tasks + stack VAs; a NINTH exec"
    echo "is pool_full; addrspaces tables=NN/512 records the C3 measurement."
    echo
} >> "$REPORT"

pass=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-scale boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-scale: PASS — EIGHT live user programs (counter + 7 USER.BINs) ran simultaneously with distinct tasks and stacks, the pool filled to 11/11, a ninth exec was pool_full, and the tables budget stayed inside the carve-out ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-scale: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
