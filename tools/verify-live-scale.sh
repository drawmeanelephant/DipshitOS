#!/usr/bin/env bash
#
# verify-live-scale.sh -- claim 5795 (milestone-four follow-on 3, card 3g)
# class-B gate: the pool-scale capstone on real VZ hardware.
#
# Every prior card documented the 5-slot budget (3b/3c/3f: "5/5, NO spare";
# 3a/3e: one spare). Card 3g DELIBERATELY grows the scheduler pool
# max_tasks 5 -> 7 (shell + worker + FOUR EL0t user slots + idle) and
# re-derives the gates. This gate proves the new budget's headline: FOUR
# live user programs at once — the strongest simultaneous-marker proof on
# the OS so far.
#
# Script (the claim-4613 multi-phase runner; phase 1 is forwarded after
# the boot payload exits + is reaped, freeing slots 2-5):
#   Phase 1:
#     ls | exec COUNTER.BIN | exec USER.BIN | exec USER.BIN | exec USER.BIN
#       | procs | addrspaces | exec USER.BIN | echo rx-scale-ok
#
# All asserted in vm-serial.log:
#   1. All three ESP programs are listed; COUNTER.BIN loads once and
#      USER.BIN loads THREE times ("exec: loaded ... size=").
#   2. The procs snapshot shows FOUR running user processes — one
#      COUNTER.BIN + three USER.BINs — with FOUR DISTINCT executor task
#      ids and FOUR DISTINCT stack VAs (the 7-slot budget's headline:
#      shell + worker + 4 users + idle = 7/7).
#   3. All three USER.BINs run their usual EL0 flow (hello markers) and
#      their markers + the counter's markers interleave with the worker's
#      advances across the whole log (4 live programs + worker + shell).
#   4. The pool is FULL at 7/7: the FIFTH exec (a 4th USER.BIN) is
#      refused with "error: no free scheduler pool slot" — the capacity
#      gate at the new budget, checked before any allocation (leak-free).
#   5. The addrspaces read shows tables=NN/256 with the kernel root + FOUR
#      user roots live: NN stays well inside the 256-page carve-out
#      (headroom assertion — the 0826 budget survey re-derived).
#   6. The counter is STILL state=running at the final procs read (the
#      permanent occupant survives the three short programs); the shell
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
# The refused fifth exec (7/7 pool at the new budget).
POOL_FULL_LINE="error: no free scheduler pool slot"

echo "=== verify-live-scale: claim 5795 — FOUR live user programs at the 7-slot budget, $BOOTS boot(s) ==="
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

# The counter (permanent occupant) + three short programs fill the pool to
# 7/7; the procs + addrspaces snapshots catch all four live; the FIFTH
# exec is the capacity gate; then the shell check.
printf 'ls\nexec COUNTER.BIN\nexec USER.BIN\nexec USER.BIN\nexec USER.BIN\nprocs\naddrspaces\nexec USER.BIN\necho rx-scale-ok\n' > "$SCRIPT"

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
        loaded_user=0 four_running=0 distinct_tasks=0 distinct_stacks=0 \
        hello=0 markers=0 interleave=0 pool_full=0 tables_headroom=0 \
        final_counter_running=0 echo_ok=0 fatal=0
    if [ -f artifacts/vm-serial.log ]; then
        bytes="$(wc -c < artifacts/vm-serial.log | tr -d ' ')"
        [ "$(grep -aFxc -- "DipshitOS kernel has seized control." artifacts/vm-serial.log || true)" = 1 ] && banner=1
        grep -a -qE -- "^  COUNTER.BIN " artifacts/vm-serial.log && listed_counter=1
        grep -a -qE -- "^  USER.BIN " artifacts/vm-serial.log && listed_user=1
        loaded_counter="$(grep -aFc -- "exec: loaded COUNTER.BIN size=" artifacts/vm-serial.log || true)"
        loaded_user="$(grep -aFc -- "exec: loaded USER.BIN size=" artifacts/vm-serial.log || true)"

        # The procs snapshot: FOUR running user processes (one counter +
        # three USER.BINs) with FOUR distinct executor task ids + stack VAs.
        local rows
        rows="$(grep -aE -- "procs: id=[0-9]+ name=(COUNTER.BIN|USER.BIN) state=running" artifacts/vm-serial.log || true)"
        if [ -n "$rows" ]; then
            local running_rows
            running_rows="$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"
            [ "$running_rows" = 4 ] && four_running=1 || four_running=0
            local t1 t2 t3 t4
            t1="$(printf '%s\n' "$rows" | sed -n '1p' | sed -E 's/.*task=([0-9]+).*/\1/')"
            t2="$(printf '%s\n' "$rows" | sed -n '2p' | sed -E 's/.*task=([0-9]+).*/\1/')"
            t3="$(printf '%s\n' "$rows" | sed -n '3p' | sed -E 's/.*task=([0-9]+).*/\1/')"
            t4="$(printf '%s\n' "$rows" | sed -n '4p' | sed -E 's/.*task=([0-9]+).*/\1/')"
            [ -n "$t1" ] && [ -n "$t2" ] && [ -n "$t3" ] && [ -n "$t4" ] && \
                [ "$t1" != "$t2" ] && [ "$t1" != "$t3" ] && [ "$t1" != "$t4" ] && \
                [ "$t2" != "$t3" ] && [ "$t2" != "$t4" ] && [ "$t3" != "$t4" ] && distinct_tasks=1 || distinct_tasks=0
            local s1 s2 s3 s4
            s1="$(printf '%s\n' "$rows" | sed -n '1p' | sed -E 's/.*stack=0x([0-9a-f]{16}).*/\1/')"
            s2="$(printf '%s\n' "$rows" | sed -n '2p' | sed -E 's/.*stack=0x([0-9a-f]{16}).*/\1/')"
            s3="$(printf '%s\n' "$rows" | sed -n '3p' | sed -E 's/.*stack=0x([0-9a-f]{16}).*/\1/')"
            s4="$(printf '%s\n' "$rows" | sed -n '4p' | sed -E 's/.*stack=0x([0-9a-f]{16}).*/\1/')"
            [ -n "$s1" ] && [ -n "$s2" ] && [ -n "$s3" ] && [ -n "$s4" ] && \
                [ "$s1" != "$s2" ] && [ "$s1" != "$s3" ] && [ "$s1" != "$s4" ] && \
                [ "$s2" != "$s3" ] && [ "$s2" != "$s4" ] && [ "$s3" != "$s4" ] && distinct_stacks=1 || distinct_stacks=0
        fi

        # All three USER.BINs ran their usual flow, and the counter's
        # markers span the whole log. Interleaving: the worker's advances
        # land BETWEEN the counter's markers (the counter runs forever, so
        # its markers + the worker's advances alternate across the log —
        # with 4 user programs + shell + worker all in the ring).
        hello="$(grep -aFc -- "user: hello from the ESP" artifacts/vm-serial.log || true)"
        markers="$(grep -aFc -- "counter: alive" artifacts/vm-serial.log || true)"
        local first_marker last_marker mid
        first_marker="$(grep -anF -- "counter: alive" artifacts/vm-serial.log | head -1 | cut -d: -f1 || true)"
        last_marker="$(grep -anF -- "counter: alive" artifacts/vm-serial.log | tail -1 | cut -d: -f1 || true)"
        if [ -n "$first_marker" ] && [ -n "$last_marker" ] && [ "$first_marker" -lt "$last_marker" ]; then
            mid="$(sed -n "$((first_marker + 1)),$((last_marker - 1))p" artifacts/vm-serial.log)"
            [ "$(echo "$mid" | grep -cF -- "tasks worker advances=" || true)" -ge 1 ] && interleave=1 || interleave=0
        fi

        # 7/7 budget: the FIFTH exec is refused.
        [ "$(grep -aFc -- "$POOL_FULL_LINE" artifacts/vm-serial.log || true)" -ge 1 ] && pool_full=1 || true

        # The tables budget with the kernel root + FOUR user roots live:
        # NN/256 stays well inside the carve-out (observed 150/256 — the
        # kernel root + boot payload root + 4 user roots; 106 pages of
        # headroom, ~40% of the carve-out free).
        local tables
        tables="$(grep -aoE -- "addrspaces: tables=[0-9]+/256" artifacts/vm-serial.log | tail -1 || true)"
        if [ -n "$tables" ]; then
            local used cap
            used="$(printf '%s\n' "$tables" | sed -E 's/.*tables=([0-9]+)\/256.*/\1/')"
            cap=256
            # The 0826 budget survey asserted two roots stay well inside;
            # at FOUR roots the gate asserts the same shape: used stays
            # under 200/256 (>= 56 pages headroom).
            [ -n "$used" ] && [ "$used" -gt 0 ] && [ "$used" -lt "$cap" ] && \
                [ "$used" -le 200 ] && tables_headroom=1 || true
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
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner listed-counter=$listed_counter listed-user=$listed_user loaded-counter=$loaded_counter loaded-user=$loaded_user four-running=$four_running tasks-distinct=$distinct_tasks stacks-distinct=$distinct_stacks hello=$hello markers=$markers interleave=$interleave pool-full=$pool_full tables=$tables tables-headroom=$tables_headroom final-counter-running=$final_counter_running echo=$echo_ok fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$listed_counter" = 1 ] && [ "$listed_user" = 1 ] && \
        [ "$loaded_counter" = 1 ] && [ "$loaded_user" = 3 ] && \
        [ "$four_running" = 1 ] && [ "$distinct_tasks" = 1 ] && [ "$distinct_stacks" = 1 ] && \
        [ "$hello" = 3 ] && [ "$markers" -ge 3 ] && [ "$interleave" = 1 ] && \
        [ "$pool_full" = 1 ] && [ "$tables_headroom" = 1 ] && \
        [ "$final_counter_running" = 1 ] && [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live pool-scale gate (claim 5795) — FOUR live user programs at the 7-slot budget on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $(cat "$SCRIPT" | tr '\n' '|')"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
    echo "COUNTER.BIN (never exits) + three USER.BINs fill the pool to 7/7"
    echo "(shell + worker + 4 users + idle); the procs snapshot shows FOUR"
    echo "running user processes with distinct tasks + stack VAs; a FIFTH exec"
    echo "is pool_full; addrspaces tables=NN/256 stays inside the carve-out."
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
    echo "verify-live-scale: PASS — FOUR live user programs (counter + 3 USER.BINs) ran simultaneously with distinct tasks and stacks, the pool filled to 7/7, a fifth exec was pool_full, and the tables budget stayed inside the carve-out ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-scale: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
