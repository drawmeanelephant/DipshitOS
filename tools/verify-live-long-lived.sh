#!/usr/bin/env bash
#
# verify-live-long-lived.sh -- claim 4613 (milestone-four follow-on 2)
# class-B gate: a LONG-LIVED process among live peers (distinct programs)
# on real VZ hardware.
#
# Claim 0826 proved TWO live processes, but both were copies of the SAME
# program (USER.BIN) and both exited after a few ticks. This gate proves
# the machinery against DISTINCT programs and a PERMANENT occupant:
# COUNTER.BIN (user/src/counter.zig) loops forever writing its own
# `counter: alive` marker (sys_write + sys_yield only, NO sys_exit), while
# USER.BIN is exec'd, runs, exits, is reaped, and re-exec'd into its freed
# slot — with the pool's capacity gate exercised at the end.
#
# The runner forwards the primary script in ONE burst (claim 6684), so the
# re-exec that must land AFTER the first USER.BIN exits + is reaped (~10 s
# with the 1 s tick) cannot be timed from a single burst. The gate
# therefore uses the claim-4613 SECOND scripted phase (--script2 +
# --script2-after): phase 1 drives the counter + the short program, and
# phase 2 is forwarded once `tasks user-exec reaped` appears.
#
# Phase 1 (forwarded after the boot payload exits):
#   ls | exec COUNTER.BIN | exec USER.BIN | procs | pages | echo rx-long-lived-phase1
# Phase 2 (forwarded after the first USER.BIN's reap):
#   exec USER.BIN | procs | exec USER.BIN | pages | echo rx-long-lived-ok
#
# All asserted in vm-serial.log:
#   1. Both programs are listed AND load (`exec: loaded COUNTER.BIN size=`
#      and `exec: loaded USER.BIN size=` — the re-exec makes the USER.BIN
#      load appear TWICE).
#   2. The counter's `counter: alive` markers appear across the WHOLE log:
#      the first marker precedes the first USER.BIN exit line, markers are
#      still landing after the LAST one (the counter outlives both USER.BIN
#      runs), the count is >= 3, and the counter NEVER exits (no `procs
#      COUNTER.BIN exited` line anywhere).
#   3. A procs read shows COUNTER.BIN `state=running` AND USER.BIN
#      `state=running` with DISTINCT executor task ids (two live user
#      processes, distinct programs).    #   4. USER.BIN's lifecycle under the permanent occupant: exit + reap +
    #      the exited process row (`tasks user-exec exited status=43`, `procs
    #      USER.BIN exited status=43`, `tasks user-exec reaped`,
    #      `name=USER.BIN state=exited`). Card 3d (claim 1014): the exit/
    #      reap reports are bounded FIFOs, so the counts are EXACT — the
    #      phase-1 USER.BIN AND the phase-2 re-exec both exit, printing
    #      exactly TWO of each line, while the boot payload's own exit
    #      (`tasks user-el0 exited status=7`) stays its own distinct line.
#   5. The re-exec LANDS in the freed slot (the recycle-under-a-permanent-
#      occupant proof — the claim-0826 gate could never show this, because
#      both its programs exited).
#   6. With the counter + the re-exec'd program both live, the pool is
#      full: a subsequent exec reports `exec: no free scheduler pool slot`
#      (the capacity gate — `has_free_slot` still works, and the refused
#      path allocates nothing).
#   7. `pages` prints in BOTH phases; the phase-2 `free=` is >= the
#      phase-1 `free=` (the recycled USER.BIN's 5 pages returned to the
#      allocator; the re-exec re-allocated 5 — a leak would make the late
#      count lower).
#   8. The counter is STILL `state=running` at the FINAL procs read; the
#      shell stays responsive (both echo replies); no exception park.
#
# The runner runs WITHOUT --script-expect: the reap-then-re-exec handoff
# and the 1 s tick need the full window (the runner exits success on
# timeout when no expect is configured; the assertions below are the
# gate). Evidence saved under artifacts/: live-long-lived-gate.txt,
# live-long-lived-report.txt, live-long-lived-run-<NN>.txt,
# live-long-lived-serial-<NN>.log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-long-lived-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-long-lived-report.txt"
SCRIPT1="artifacts/live-long-lived-script1.txt"
SCRIPT2="artifacts/live-long-lived-script2.txt"
# The static claim-8215 payload's exit line: the runner forwards phase 1
# only after it appears, so the boot payload's slot is free.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
# The first USER.BIN's reap line: the runner forwards phase 2 only after
# it appears, so the re-exec finds the freed slot (claim 4613 second phase).
EXEC_REAP_LINE="tasks user-exec reaped"

echo "=== verify-live-long-lived: claim 4613 — a long-lived process among live peers (distinct programs), $BOOTS boot(s) ==="
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

# Phase 1: list, start the permanent occupant, exec the short program, and
# snapshot the two-live-processes table + the allocator free count.
printf 'ls\nexec COUNTER.BIN\nexec USER.BIN\nprocs\npages\necho rx-long-lived-phase1\n' > "$SCRIPT1"
# Phase 2: after the first USER.BIN is reaped — re-exec into the freed
# slot, snapshot again, then hit the capacity gate with both live, and
# re-read the free count.
printf 'exec USER.BIN\nprocs\nexec USER.BIN\npages\necho rx-long-lived-ok\n' > "$SCRIPT2"

run_one() {
    local tag="$1"
    local run_log="artifacts/live-long-lived-run-$tag.txt"
    local serial_copy="artifacts/live-long-lived-serial-$tag.log"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log

    set +e
    # No --script-expect: capture the full window so the reap-then-re-exec
    # handoff completes and the counter's markers keep landing (the runner
    # exits 0 on timeout when no expect is configured).
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT1" --script-after "$STATIC_EXIT_LINE" \
        --script2 "$SCRIPT2" --script2-after "$EXEC_REAP_LINE" --timeout 75 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "$serial_copy" || true

    local bytes=0 banner=0 listed=0 loaded_counter=0 loaded_user=0 markers=0 \
        never_exits=0 two_running=0 distinct_tasks=0 user_exited=0 \
        exited_row=0 user_reaped=0 procs_user_exited=0 reexec_landed=0 pool_full=0 \
        pages_reads=0 free_recovered=0 final_counter_running=0 \
        phase1_echo=0 echo_ok=0 fatal=0
    if [ -f artifacts/vm-serial.log ]; then
        bytes="$(wc -c < artifacts/vm-serial.log | tr -d ' ')"
        [ "$(grep -aFxc -- "DipshitOS kernel has seized control." artifacts/vm-serial.log || true)" = 1 ] && banner=1
        # 1. Both programs listed on the ESP + both exec replies present.
        grep -a -qE -- "^  COUNTER.BIN " artifacts/vm-serial.log && listed=1
        loaded_counter="$(grep -aFc -- "exec: loaded COUNTER.BIN size=" artifacts/vm-serial.log || true)"
        loaded_user="$(grep -aFc -- "exec: loaded USER.BIN size=" artifacts/vm-serial.log || true)"
        # 2. The counter's markers span the whole log; it never exits.
        markers="$(grep -aFc -- "counter: alive" artifacts/vm-serial.log || true)"
        [ "$(grep -aFc -- "procs COUNTER.BIN exited" artifacts/vm-serial.log || true)" = 0 ] && never_exits=1
        local first_marker last_marker first_user_exit last_user_exit
        first_marker="$(grep -anF -- "counter: alive" artifacts/vm-serial.log | head -1 | cut -d: -f1 || true)"
        last_marker="$(grep -anF -- "counter: alive" artifacts/vm-serial.log | tail -1 | cut -d: -f1 || true)"
        first_user_exit="$(grep -anE -- "tasks user-exec exited status=43|procs USER.BIN exited status=43" artifacts/vm-serial.log | head -1 | cut -d: -f1 || true)"
        last_user_exit="$(grep -anE -- "tasks user-exec exited status=43|procs USER.BIN exited status=43" artifacts/vm-serial.log | tail -1 | cut -d: -f1 || true)"
        if [ -n "$first_marker" ] && [ -n "$last_marker" ] && [ -n "$first_user_exit" ] && [ -n "$last_user_exit" ]; then
            [ "$first_marker" -lt "$first_user_exit" ] && [ "$last_marker" -gt "$last_user_exit" ] && never_exits=1 || never_exits=0
        fi
        # 3. A procs read shows BOTH programs running with distinct tasks.
        local counter_rows user_rows
        counter_rows="$(grep -aE -- "procs: id=[0-9]+ name=COUNTER.BIN state=running" artifacts/vm-serial.log || true)"
        user_rows="$(grep -aE -- "procs: id=[0-9]+ name=USER.BIN state=running" artifacts/vm-serial.log || true)"
        if [ -n "$counter_rows" ] && [ -n "$user_rows" ]; then
            two_running=1
            local t1 t2
            t1="$(printf '%s\n' "$counter_rows" | head -1 | sed -E 's/.*task=([0-9]+).*/\1/' || true)"
            t2="$(printf '%s\n' "$user_rows" | head -1 | sed -E 's/.*task=([0-9]+).*/\1/' || true)"
            [ -n "$t1" ] && [ -n "$t2" ] && [ "$t1" != "$t2" ] && distinct_tasks=1 || distinct_tasks=0
        fi
        # 4. USER.BIN's lifecycle under the permanent occupant. Card 3d:
        # the exit/reap reports are EXACT (both USER.BIN runs exit status
        # 43), and the boot payload's exit stays its own distinct line.
        local boot_exits
        user_exited="$(grep -aFc -- "tasks user-exec exited status=43" artifacts/vm-serial.log || true)"
        procs_user_exited="$(grep -aFc -- "procs USER.BIN exited status=43" artifacts/vm-serial.log || true)"
        user_reaped="$(grep -aFc -- "tasks user-exec reaped" artifacts/vm-serial.log || true)"
        grep -a -qF -- "name=USER.BIN state=exited" artifacts/vm-serial.log && exited_row=1 || exited_row=0
        boot_exits="$(grep -aFc -- "tasks user-el0 exited status=7" artifacts/vm-serial.log || true)"
        [ "$boot_exits" = 1 ] && boot_exited=1 || boot_exited=0
        # 5. The re-exec landed: exactly TWO successful USER.BIN loads
        # (phase 1 + the phase-2 re-exec into the freed slot).
        [ "$loaded_user" = 2 ] && reexec_landed=1
        # 6. The capacity gate: a third exec with both live is pool_full.
        [ "$(grep -aFc -- "exec: no free scheduler pool slot" artifacts/vm-serial.log || true)" -ge 1 ] && pool_full=1
        # 7. Both pages reads present; the late free count recovered.
        local pages_lines p1 p2
        pages_lines="$(grep -aF -- "pages: armed=1 total=" artifacts/vm-serial.log || true)"
        pages_reads="$(printf '%s\n' "$pages_lines" | grep -cF -- "pages: armed=1 total=" || true)"
        p1="$(printf '%s\n' "$pages_lines" | sed -n '1p' | sed -E 's/.*free=0x([0-9a-f]+).*/\1/' || true)"
        p2="$(printf '%s\n' "$pages_lines" | sed -n '2p' | sed -E 's/.*free=0x([0-9a-f]+).*/\1/' || true)"
        if [ -n "$p1" ] && [ -n "$p2" ]; then
            [ $((16#$p2)) -ge $((16#$p1)) ] && free_recovered=1 || free_recovered=0
        fi
        # 8. The counter is running at the FINAL procs read.
        local last_counter_row
        last_counter_row="$(grep -aE -- "procs: id=[0-9]+ name=COUNTER.BIN" artifacts/vm-serial.log | tail -1 || true)"
        if [ -n "$last_counter_row" ]; then
            printf '%s\n' "$last_counter_row" | grep -qF -- "state=running" && final_counter_running=1
        fi
        [ "$(grep -aFxc -- "rx-long-lived-phase1" artifacts/vm-serial.log || true)" = 1 ] && phase1_echo=1
        [ "$(grep -aFxc -- "rx-long-lived-ok" artifacts/vm-serial.log || true)" = 1 ] && echo_ok=1
        grep -qF -- "[EXC] parking:" artifacts/vm-serial.log && fatal=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner listed=$listed loaded-counter=$loaded_counter loaded-user=$loaded_user markers=$markers never-exits=$never_exits two-running=$two_running tasks-distinct=$distinct_tasks user-exited=$user_exited exited-row=$exited_row procs-user-exited=$procs_user_exited user-reaped=$user_reaped reexec-landed=$reexec_landed pool-full=$pool_full pages-reads=$pages_reads free-recovered=$free_recovered final-counter-running=$final_counter_running phase1-echo=$phase1_echo echo=$echo_ok fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$listed" = 1 ] && \
        [ "$loaded_counter" = 1 ] && [ "$loaded_user" = 2 ] && \
        [ "$markers" -ge 3 ] && [ "$never_exits" = 1 ] && \
        [ "$two_running" = 1 ] && [ "$distinct_tasks" = 1 ] && \
        [ "$user_exited" = 2 ] && [ "$exited_row" = 1 ] && [ "$procs_user_exited" = 2 ] && [ "$user_reaped" = 2 ] && [ "$boot_exited" = 1 ] && \
        [ "$reexec_landed" = 1 ] && [ "$pool_full" = 1 ] && \
        [ "$pages_reads" -ge 2 ] && [ "$free_recovered" = 1 ] && \
        [ "$final_counter_running" = 1 ] && [ "$phase1_echo" = 1 ] && \
        [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live long-lived-process gate (claim 4613) — a never-exiting COUNTER.BIN among live peers on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script1: $(cat "$SCRIPT1" | tr '\n' '|')"
    echo "script2: $(cat "$SCRIPT2" | tr '\n' '|')"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
    echo "COUNTER.BIN (distinct markers, sys_write + sys_yield only, no sys_exit)"
    echo "occupies its pool slot permanently while USER.BIN is exec'd, runs,"
    echo "exits, is reaped (pages returned), and re-exec'd into the freed slot;"
    echo "with both live a further exec is pool_full. The second scripted phase"
    echo "(--script2/--script2-after) forwards the re-exec after the first reap."
    echo
} | tee -a "$REPORT"

pass=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-long-lived boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-long-lived: PASS — COUNTER.BIN ran forever (distinct markers across the whole log) while USER.BIN exited, was reaped (pages returned), and re-exec'd into the freed slot; with both live a further exec was pool_full ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-long-lived: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
