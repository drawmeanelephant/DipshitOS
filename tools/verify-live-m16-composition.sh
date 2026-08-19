#!/usr/bin/env bash
#
# verify-live-m16-composition.sh -- claim 2714 (Milestone 16, Card C4)
# class-B gate: the composition capstone — ONE VM session proves C1+C2+C3
# together. The milestone's human-perceivable "kernel grew up" moment.
#
# Three cards in one boot:
#   C1 (claim 3805)  — the segmented image: GLOBALS.BIN (28 KiB text, past
#                      the OLD 16 KiB bound) with writable .data + zero-filled
#                      BSS globals, `globals: data bss ok`, exits 42.
#   C2 (claim 8403)  — the guard page: GUARD.BIN steps off its stack, takes a
#                      real EL0 data abort (EC 0x24), and is reaped 139 beside
#                      a persistent COUNTER.BIN neighbor that keeps running.
#   C3 (claim 0339)  — the grown pool: seven USER.BINs join the counter for
#                      EIGHT live user programs (`resources: tasks=11/11`) —
#                      the capacity the OLD 7-slot pool refused.
#
# C4 finding — the page-table carve-out grows too. The carve-out is a
# TOTAL-roots budget (table pages are never reclaimed), so the big app +
# hostile app + eight concurrent programs = 282 pages exceeded the OLD
# 256-page carve-out (the last two USER.BINs were refused with table_full).
# C4 grows it 256 → 512 pages (mmu.table_page_count) and this gate asserts
# the grown capacity (`resources: tables=NN/512`).
#
# Device-agnostic: the default VM (no sound/gfx/input flags) stays
# byte-identical; this gate drives the shell over serial only.
#
# The transient C1/C2 programs must be REAPED (their executor slots freed)
# before the C3 fill lands, or a zombie would oversubscribe the 8-slot
# budget. Three scripted phases (claim 6684/4613/7786) enforce the order:
#   Phase 1 (after the boot payload exits):    exec GLOBALS.BIN
#   Phase 2 (after GLOBALS is reaped):         exec COUNTER.BIN + GUARD.BIN
#   Phase 3 (after GUARD exits, +2 s settle):  exec USER.BIN x7 + resources
#                                              + procs + echo
#
# Evidence saved under artifacts/: live-m16-composition-gate.txt,
# live-m16-composition-report.txt, live-m16-composition-run-<NN>.txt,
# live-m16-composition-serial-<NN>.log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-m16-composition-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-m16-composition-report.txt"
SCRIPT1="artifacts/live-m16-composition-script1.txt"
SCRIPT2="artifacts/live-m16-composition-script2.txt"
SCRIPT3="artifacts/live-m16-composition-script3.txt"

# The static boot payload's exit line: phase 1 is forwarded only after it
# appears, so the boot payload's slot is free when GLOBALS.BIN execs.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
# Phase 2 fires on GLOBALS's reap — the ONLY "user-exec" reap at that point
# (the boot payload reaps as "user-el0", so this marker is unambiguous).
GLOBALS_REAP_LINE="tasks user-exec reaped"
# Phase 3 fires on GUARD's process-level exit (unique name/status). The
# 2 s settle covers the idle task's reap so the executor slot is free
# before the seven USER.BINs fill the pool.
GUARD_EXIT_LINE="procs GUARD.BIN exited status=139"

echo "=== verify-live-m16-composition: claim 2714 — M16 C4 capstone on VZ, $BOOTS boot(s) ==="
PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
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

# Phase 1: the C1 proof — the segmented image with writable globals.
printf 'exec GLOBALS.BIN\n' > "$SCRIPT1"
# Phase 2: the C2 proof — the hostile guard-page program beside a persistent
# neighbor (COUNTER.BIN stays running for the rest of the session).
printf 'exec COUNTER.BIN\nexec GUARD.BIN\n' > "$SCRIPT2"
# Phase 3: the C3 proof — seven USER.BINs join the counter (EIGHT live user
# programs), then the pool accounting + process table, then the echo.
printf 'exec USER.BIN\nexec USER.BIN\nexec USER.BIN\nexec USER.BIN\nexec USER.BIN\nexec USER.BIN\nexec USER.BIN\nresources\nprocs\necho m16-composition-live-ok\n' > "$SCRIPT3"

run_one() {
    local tag="$1"
    local run_log="artifacts/live-m16-composition-run-$tag.txt"
    local serial_copy="artifacts/live-m16-composition-serial-$tag.log"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log

    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT1" --script-after "$STATIC_EXIT_LINE" \
        --script2 "$SCRIPT2" --script2-after "$GLOBALS_REAP_LINE" \
        --script3 "$SCRIPT3" --script3-after "$GUARD_EXIT_LINE" --script3-delay 2 \
        --script-expect "m16-composition-live-ok" \
        --timeout 120 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "$serial_copy" || true

    local bytes=0 banner=0 globals_loaded=0 globals_data=0 globals_ok=0 \
        globals_exit=0 guard_alive=0 guard_fault=0 guard_exit=0 counter_alive=0 \
        counter_loaded=0 user_loaded=0 eight_running=0 distinct_tasks=0 \
        distinct_stacks=0 tasks_full=0 procs_full=0 tables_grown=0 globals_row=0 \
        guard_row=0 echo_ok=0 fatal=0
    if [ -f artifacts/vm-serial.log ]; then
        bytes="$(wc -c < artifacts/vm-serial.log | tr -d ' ')"
        [ "$(grep -aFxc -- "DipshitOS kernel has seized control." artifacts/vm-serial.log || true)" = 1 ] && banner=1

        # C1: the bigger app with real globals — 28 KiB image (past the old
        # 16 KiB bound), exact data-page accounting, the success marker, exit 42.
        [ "$(grep -aFc -- "exec: loaded GLOBALS.BIN size=0x0000000000007000" artifacts/vm-serial.log || true)" = 1 ] && globals_loaded=1
        grep -a -qF -- "data=0x0000000000001010 datapages=2" artifacts/vm-serial.log && globals_data=1
        # Substring match (the marker can land right after the "dipshit> "
        # prompt on the same serial line).
        [ "$(grep -aFc -- "globals: data bss ok" artifacts/vm-serial.log || true)" -ge 1 ] && globals_ok=1
        grep -a -qE -- "procs: id=[0-9]+ name=GLOBALS.BIN state=exited .*exit=42" artifacts/vm-serial.log && globals_exit=1

        # C2: the hostile program faulted (EC 0x24) and was reaped 139; the
        # benign neighbor actually ran.
        [ "$(grep -aFc -- "guard: stepping off" artifacts/vm-serial.log || true)" -ge 1 ] && guard_alive=1
        grep -a -qE -- "fault: GUARD.BIN far=0x[0-9a-f]+ ec=0x24" artifacts/vm-serial.log && guard_fault=1
        grep -a -qE -- "procs: id=[0-9]+ name=GUARD.BIN state=exited .*exit=139" artifacts/vm-serial.log && guard_exit=1
        [ "$(grep -aFc -- "counter: alive" artifacts/vm-serial.log || true)" -ge 1 ] && counter_alive=1

        # C3: the grown pool — one counter + seven USER.BINs = EIGHT live
        # user programs; the pool accounting pins the grown budget.
        counter_loaded="$(grep -aFc -- "exec: loaded COUNTER.BIN size=" artifacts/vm-serial.log || true)"
        user_loaded="$(grep -aFc -- "exec: loaded USER.BIN size=" artifacts/vm-serial.log || true)"
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
        # The grown pool is fully occupied by the eight live users, no
        # zombies remain (both transients reaped), and the process registry
        # holds boot + globals + guard + counter + seven users = 11.
        grep -a -qF -- "resources: tasks=11/11 zombies=0" artifacts/vm-serial.log && tasks_full=1
        grep -a -qF -- "resources: procs=11/16" artifacts/vm-serial.log && procs_full=1
        # The page-table carve-out grew 256 → 512 to fit this composition
        # (the big app + hostile app + eight concurrent roots total 282 pages
        # — the OLD 256-page carve-out refused the last two USER.BINs with
        # table_full). The audit pins the grown capacity.
        grep -a -qE -- "resources: tables=[0-9]+/512" artifacts/vm-serial.log && tables_grown=1
        # The two transient programs' rows survive in the process table
        # beside the running eight.
        grep -a -qE -- "procs: id=[0-9]+ name=GLOBALS.BIN state=exited" artifacts/vm-serial.log && globals_row=1
        grep -a -qE -- "procs: id=[0-9]+ name=GUARD.BIN state=exited" artifacts/vm-serial.log && guard_row=1

        [ "$(grep -aFxc -- "m16-composition-live-ok" artifacts/vm-serial.log || true)" = 1 ] && echo_ok=1
        grep -qF -- "[EXC] parking:" artifacts/vm-serial.log && fatal=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner globals-loaded=$globals_loaded globals-data=$globals_data globals-ok=$globals_ok globals-exit=$globals_exit guard-alive=$guard_alive guard-fault=$guard_fault guard-exit=$guard_exit counter-alive=$counter_alive counter-loaded=$counter_loaded user-loaded=$user_loaded eight-running=$eight_running tasks-distinct=$distinct_tasks stacks-distinct=$distinct_stacks tasks-full=$tasks_full procs-full=$procs_full tables-grown=$tables_grown globals-row=$globals_row guard-row=$guard_row echo=$echo_ok fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$globals_loaded" = 1 ] && \
        [ "$globals_data" = 1 ] && [ "$globals_ok" = 1 ] && [ "$globals_exit" = 1 ] && \
        [ "$guard_alive" = 1 ] && [ "$guard_fault" = 1 ] && [ "$guard_exit" = 1 ] && \
        [ "$counter_alive" = 1 ] && [ "$counter_loaded" = 1 ] && [ "$user_loaded" = 7 ] && \
        [ "$eight_running" = 1 ] && [ "$distinct_tasks" = 1 ] && [ "$distinct_stacks" = 1 ] && \
        [ "$tasks_full" = 1 ] && [ "$procs_full" = 1 ] && [ "$tables_grown" = 1 ] && \
        [ "$globals_row" = 1 ] && [ "$guard_row" = 1 ] && [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live M16 composition gate (claim 2714) — the 'kernel grew up' capstone on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script1: $(cat "$SCRIPT1" | tr '\n' '|')"
    echo "script2: $(cat "$SCRIPT2" | tr '\n' '|')"
    echo "script3: $(cat "$SCRIPT3" | tr '\n' '|')"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
    echo "One session: GLOBALS.BIN (C1, segmented image + writable globals, exit 42)"
    echo "runs, then GUARD.BIN (C2, guard-page fault reaped 139) beside a persistent"
    echo "COUNTER.BIN neighbor, then seven USER.BINs join the counter for EIGHT live"
    echo "user programs (C3, tasks=11/11) — the old 7-slot pool would have refused."
    echo
} >> "$REPORT"

pass=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-m16-composition boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-m16-composition: PASS — GLOBALS.BIN (globals, exit 42) + GUARD.BIN (fault reaped 139) + eight concurrent programs (tasks=11/11) in ONE session on VZ ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-m16-composition: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot serial logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
