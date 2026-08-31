#!/usr/bin/env bash
#
# verify-live-concurrent.sh -- claim 0826 (milestone-four follow-on)
# class-B gate: TWO live user processes on real VZ hardware.
#
# The old exec gate (`scheduler.user_root_in_use`) forced ONE live user
# program: a second `exec` was refused until the first exited AND its task
# slot was reaped. Claim 0826 gives every process its OWN TTBR0 root +
# allocator-backed text/user-stack/EL1-stack pages + per-task syscall
# regions, so the gate is capacity (the fixed pool), not exclusivity.
# The chain, all asserted in vm-serial.log:
#
#   1. `exec USER.BIN` runs TWICE back to back — no exit in between —
#      and both loads succeed (`exec: loaded USER.BIN size=` x2); the
#      second exec would have hit `user_busy` before claim 0826.
#   2. The `procs` read that follows shows TWO `name=USER.BIN
#      state=running` rows with DISTINCT executor task ids and DISTINCT
#      per-process stack VAs — two live user address spaces, one table
#      (the shell consumes scripted lines before either program's first
#      quantum, the ordering observed in live-exec's serial logs).
#   3. Both programs actually execute at EL0: every sys_write marker lands
#      TWICE (`user: hello from the ESP`, `user: exec ok`, `user: sleeping
#      2 ticks`, `user: awake`), and the runs interleave — the worker
#      task's advance lines appear between the last sleep marker and the
#      first wake marker (with a 1 s scheduler tick, the two programs are
#      simultaneously mid-flight while other tasks run, not executed
#      one-then-the-other).    #   4. Both programs reach the exit syscall and are reaped: `user:
    #      awake` (the last marker before sys_exit) lands TWICE — the
    #      completion proof — and the exit/reap reports print EXACTLY
    #      TWICE each (card 3d, claim 1014: the reports are bounded FIFOs
    #      drained in order, so two exits in one idle-loop window print
    #      two `tasks user-exec exited status=43` / two `procs USER.BIN
    #      exited status=43` / two `tasks user-exec reaped` lines).
    #   5. The shell stays responsive (echo reply), no exception park.
#
# The runner runs WITHOUT --script-expect: the 1 s tick makes a USER.BIN
# program's full lifetime ~10 s, so the gate captures the COMPLETE window
# (timeout) instead of tearing down at the first reap. The runner exits
# success on timeout when no expect is configured; the assertions below
# are the gate.
#
# Evidence saved under artifacts/: live-concurrent-gate.txt,
# live-concurrent-report.txt, live-concurrent-run-<NN>.txt,
# live-concurrent-serial-<NN>.log.

# Run isolation (#523 item 2 / issue #528, claim 5069): every boot attaches
# a private DiskImageKit stacked disk (read-only base + throwaway ASIF
# overlay), a private EFI var store (recreated fresh per boot, as the
# pre-isolation gate did), and a private serial log under $RUN_DIR — two
# concurrent instances cannot clobber each other's disks, NVRAM, or
# evidence. Set VIRELAI_GATE_SUFFIX=_alt to give this instance its own
# canonical evidence names (two simultaneous instances MUST differ), and
# VIRELAI_KEEP_RUN=1 to keep the scratch dir.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-concurrent-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-concurrent-report.txt)"
# The static claim-8215 payload's exit line: the runner forwards the script
# only after it appears, so the user root is free when `exec` runs.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "=== verify-live-concurrent: claim 0826 — two live user processes (exec gate relaxed to capacity), $BOOTS boot(s) ==="

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

# --- per-run isolation -------------------------------------------------------------
# Private scratch dir + pristine-boot overlay for EVERY boot.
# See tools/lib/gate-run.sh.
gate_begin live-concurrent
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

# Two execs back to back, then the procs snapshot, then the shell check.
printf 'ls\nexec USER.BIN\nexec USER.BIN\nprocs\necho rx-concurrent-ok\n' > "$SCRIPT"

run_one() {
    local tag="$1"
    local run_log="$(art live-concurrent-run-$tag.txt)"
    local serial_copy="$(art live-concurrent-serial-$tag.log)"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"

    set +e
    # No --script-expect: capture the full window so BOTH programs complete
    # (the runner exits 0 on timeout when no expect is configured).
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-after "$STATIC_EXIT_LINE" --timeout 60 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-concurrent-serial-$tag.log)" || true
    local SER="$serial_copy"

    local bytes=0 banner=0 listed=0 loaded=0 two_running=0 distinct_tasks=0 \
        distinct_stacks=0 boot_exited=0 hello=0 ok=0 sleeping=0 awake=0 \
        interleave=0 exited=0 procs_exited=0 reaped=0 echo_ok=0 fatal=0
    if [ -f "$SER" ]; then
        bytes="$(wc -c < "$SER" | tr -d ' ')"
        [ "$(grep -aFxc -- "VirelaiOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "USER.BIN" "$SER" || true)" -ge 2 ] && listed=1
        # Both execs loaded (the second one would have been `user_busy`
        # before the relaxed gate).
        loaded="$(grep -aFc -- "exec: loaded USER.BIN size=" "$SER" || true)"
        # The procs snapshot: exactly TWO running USER.BIN rows.
        local rows=""
        rows="$(grep -aE -- "procs: id=[0-9]+ name=USER.BIN state=running" "$SER" || true)"
        if [ -n "$rows" ]; then
            local running_rows
            running_rows="$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"
            [ "$running_rows" = 2 ] && two_running=1 || two_running=0
            # Distinct executor task ids (the two pool slots).
            local t1 t2
            t1="$(printf '%s\n' "$rows" | sed -n '1p' | sed -E 's/.*task=([0-9]+).*/\1/')"
            t2="$(printf '%s\n' "$rows" | sed -n '2p' | sed -E 's/.*task=([0-9]+).*/\1/')"
            [ -n "$t1" ] && [ -n "$t2" ] && [ "$t1" != "$t2" ] && distinct_tasks=1 || distinct_tasks=0
            # Distinct per-process stack VAs (per-process ASLR).
            local s1 s2
            s1="$(printf '%s\n' "$rows" | sed -n '1p' | sed -E 's/.*stack=0x([0-9a-f]{16}).*/\1/')"
            s2="$(printf '%s\n' "$rows" | sed -n '2p' | sed -E 's/.*stack=0x([0-9a-f]{16}).*/\1/')"
            [ -n "$s1" ] && [ -n "$s2" ] && [ "$s1" != "$s2" ] && distinct_stacks=1 || distinct_stacks=0
        fi
        # The boot payload's process is still exited (not yet reaped) when
        # procs runs — the same row the claim-3848 gate asserts.
        grep -a -qF -- "name=user-el0 state=exited" "$SER" && boot_exited=1 || true
        # Both programs executed at EL0: every marker twice.
        hello="$(grep -aFc -- "user: hello from the ESP" "$SER" || true)"
        ok="$(grep -aFc -- "user: exec ok" "$SER" || true)"
        sleeping="$(grep -aFc -- "user: sleeping 2 ticks" "$SER" || true)"
        awake="$(grep -aFc -- "user: awake" "$SER" || true)"
        # Interleaving: other tasks (worker) ran between the last sleep
        # marker and the first wake marker — the two programs were
        # simultaneously mid-flight, not executed one-then-the-other.
        # OBSERVED TODAY (2026-08-24, claim 5069): with two programs in the
        # ring the sleeps/awakes interleave on serial (`sleeping`@111,
        # `awake`@119, `sleeping`@120, `awake`@127), so "between the LAST
        # sleep and the FIRST awake" is empty by construction. The intent —
        # the worker advanced while a program was mid-sleep-cycle — is
        # checked as an advances= report strictly between the FIRST sleep
        # and the LAST wake (observed: advances=6720 between them).
        local first_sleep last_awake mid
        first_sleep="$(grep -anF -- "user: sleeping 2 ticks" "$SER" | head -1 | cut -d: -f1 || true)"
        last_awake="$(grep -anF -- "user: awake" "$SER" | tail -1 | cut -d: -f1 || true)"
        if [ -n "$first_sleep" ] && [ -n "$last_awake" ] && [ "$first_sleep" -lt "$last_awake" ]; then
            mid="$(sed -n "$((first_sleep + 1)),$((last_awake - 1))p" "$SER")"
            [ "$(echo "$mid" | grep -cF -- "tasks worker advances=" || true)" -ge 1 ] && interleave=1 || interleave=0
        fi
        # Both programs completed: `user: awake` x2 (the last marker before
        # sys_exit) is the strong proof; the exit/reap reports are bounded
        # FIFOs (card 3d, claim 1014), so the counts are EXACT — two
        # USER.BIN exits print exactly two of each line.
        exited="$(grep -aFc -- "tasks user-exec exited status=43" "$SER" || true)"
        procs_exited="$(grep -aFc -- "procs USER.BIN exited status=43" "$SER" || true)"
        reaped="$(grep -aFc -- "tasks user-exec reaped" "$SER" || true)"
        [ "$(grep -aFxc -- "rx-concurrent-ok" "$SER" || true)" = 1 ] && echo_ok=1
        grep -qF -- "[EXC] parking:" "$SER" && fatal=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner listed=$listed loaded=$loaded two-running=$two_running tasks-distinct=$distinct_tasks stacks-distinct=$distinct_stacks boot-exited=$boot_exited hello=$hello ok=$ok sleeping=$sleeping awake=$awake interleave=$interleave exited=$exited procs-exited=$procs_exited reaped=$reaped echo=$echo_ok fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$listed" = 1 ] && [ "$loaded" = 2 ] && \
        [ "$two_running" = 1 ] && [ "$distinct_tasks" = 1 ] && [ "$distinct_stacks" = 1 ] && \
        [ "$boot_exited" = 1 ] && [ "$hello" = 2 ] && [ "$ok" = 2 ] && [ "$sleeping" = 2 ] && [ "$awake" = 2 ] && \
        [ "$interleave" = 1 ] && [ "$exited" = 2 ] && [ "$procs_exited" = 2 ] && [ "$reaped" = 2 ] && \
        [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "VIRELAIOS live concurrent-processes gate (claim 0826) — two live user address spaces on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $(cat "$SCRIPT" | tr '\n' '|')"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
    echo "The old exec gate (one user program at a time) is gone: two USER.BIN"
    echo "programs load and run CONCURRENTLY, each with its own root, stack,"
    echo "and executor task; the procs snapshot shows both state=running."
    echo
} | tee -a "$REPORT"

pass=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-concurrent boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-concurrent: PASS — two live user processes, each with its own root/stack/task, loaded and running concurrently ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-concurrent: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
