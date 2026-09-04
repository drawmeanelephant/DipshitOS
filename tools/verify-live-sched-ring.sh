#!/usr/bin/env bash
#
# verify-live-sched-ring.sh -- claim 881 / issue #856 class-B gate: the
# per-core ready rings proven on real VZ hardware — TWO user programs
# doing tight-loop yield/sleep on/around core 1, with EXACT counts.
# Extended by issue #857 (claim 910): the generalized cross-core steal —
# every migration prints `smp: steal runs=N task=NAME from=RING`, and the
# gate asserts steals in BOTH directions.
#
# The #856 success criterion: two cores running tight-loop yield/sleep
# user tasks — no lost wakeups, no duplicate staging, resumes consistent
# with the ring's switches. The gate choreography:
#
#   1. `exec -c1 SCHEDRING.BIN` — the monitor flag pins the spawned task
#      to core 1 (home ring 1; never stolen — `steal_eligible` keeps
#      pinned tasks home).
#   2. `exec SCHEDRING.BIN` — a SECOND copy, unpinned (home ring 0): it
#      migrates between the cores in both directions (ring 0 -> core 1
#      via the WFE/tick steal, ring 1 -> core 0 via the issue-857
#      generalized steal when it is preempted onto ring 1) — so BOTH
#      cores rotate over the pair, and every ring transition (ring 0 <->
#      ring 1, steal, park, wake, exit) is exercised while both programs
#      are mid-flight.
#   3. Each program runs `sleep_count` x sys_sleep(1) then
#      `yield_count` x sys_yield in a tight loop, writes its exact-count
#      markers, and exits 0. The proof semantics:
#        - every wake is a ring resume — a LOST wakeup hangs the program
#          before its slept marker (gate timeout = fail);
#        - a DUPLICATE staging (two cores on one TCB) corrupts the shared
#          frame/counter — the exact-count greps fail or the VM faults;
#        - the yield-loop counter rides in x19 across every switch, so a
#          corrupt save/restore breaks `yielded=32`.
#      The markers must land EXACTLY TWICE each (once per process),
#      together with TWO exit/reap report pairs.
#   4. The shell auto-prints `smp: secondary runs=N task=SCHEDRING.BIN`
#      — the name-based proof that a SCHEDRING copy ran on core 1 — AND
#      `smp: steal runs=N task=SCHEDRING.BIN from=R` lines for every
#      cross-core migration. The gate asserts at least one steal FROM
#      ring 0 (core 1 pulled the floating copy) and at least one FROM
#      ring 1 (core 0 pulled it back — the issue-857 direction, impossible
#      under the old ring-0-only core-0 view).
#
# Evidence saved under artifacts/: live-sched-ring-gate.txt,
# live-sched-ring-report.txt, live-sched-ring-run-<NN>.txt,
# live-sched-ring-serial-<NN>.log.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-sched-ring-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-sched-ring-report.txt)"
# The static claim-8215 payload's exit line: the runner forwards the script
# only after it appears, so the boot probe is gone before `exec` runs.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "=== verify-live-sched-ring: claim 881/#856 — per-core ready rings, two yield/sleep programs on/around core 1, $BOOTS boot(s) ==="

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
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------------
# Private scratch dir + pristine-boot overlay for EVERY boot.
# See tools/lib/gate-run.sh.
gate_begin live-sched-ring
gate_seed_share
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

# One pinned exec + one floating exec, a procs snapshot (both programs
# mid-flight), the shell check.
printf 'ls\nexec -c1 SCHEDRING.BIN\nexec SCHEDRING.BIN\nprocs\necho rx-schedring-ok\n' > "$SCRIPT"

run_one() {
    local tag="$1"
    local run_log="$(art live-sched-ring-run-$tag.txt)"
    local serial_copy="$(art live-sched-ring-serial-$tag.log)"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"

    set +e
    # No --script-expect: capture the full window so BOTH programs
    # complete (the runner exits 0 on timeout when no expect is set).
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-after "$STATIC_EXIT_LINE" --timeout 90 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-sched-ring-serial-$tag.log)" || true
    local SER="$serial_copy"

    local bytes=0 banner=0 listed=0 loaded=0 two_running=0 slept=0 yielded=0 \
        done=0 exited=0 procs_exited=0 reaped=0 secondary=0 steal0=0 steal1=0 echo_ok=0 fatal=0
    if [ -f "$SER" ]; then
        bytes="$(wc -c < "$SER" | tr -d ' ')"
        [ "$(grep -aFxc -- "VirelaiOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "SCHEDRING.BIN" "$SER" || true)" -ge 1 ] && listed=1
        # Both execs loaded.
        loaded="$(grep -aFc -- "exec: loaded SCHEDRING.BIN size=" "$SER" || true)"
        # The procs snapshot: exactly TWO running SCHEDRING.BIN rows with
        # distinct executor task ids (the two pool slots).
        local rows=""
        rows="$(grep -aE -- "procs: id=[0-9]+ name=SCHEDRING.BIN state=running" "$SER" || true)"
        if [ -n "$rows" ]; then
            local running_rows t1 t2
            running_rows="$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"
            [ "$running_rows" = 2 ] && two_running=1 || two_running=0
            t1="$(printf '%s\n' "$rows" | sed -n '1p' | sed -E 's/.*task=([0-9]+).*/\1/')"
            t2="$(printf '%s\n' "$rows" | sed -n '2p' | sed -E 's/.*task=([0-9]+).*/\1/')"
            [ -n "$t1" ] && [ -n "$t2" ] && [ "$t1" != "$t2" ] || two_running=0
        fi
        # The exact-count markers — EXACTLY TWICE each (one per process).
        # Any byte-level interleaving between the two programs' writes
        # (and core 0's concurrent output) breaks the byte-exact greps.
        [ "$(grep -aFxc -- "schedring: slept=4" "$SER" || true)" = 2 ] && slept=1
        [ "$(grep -aFxc -- "schedring: yielded=32" "$SER" || true)" = 2 ] && yielded=1
        [ "$(grep -aFxc -- "schedring: done" "$SER" || true)" = 2 ] && done=1
        [ "$(grep -aFxc -- "tasks user-exec exited status=0" "$SER" || true)" = 2 ] && exited=1
        [ "$(grep -aFxc -- "procs SCHEDRING.BIN exited status=0" "$SER" || true)" = 2 ] && procs_exited=1
        [ "$(grep -aFxc -- "tasks user-exec reaped" "$SER" || true)" = 2 ] && reaped=1
        # The name-based proof that a SCHEDRING copy ran on a secondary
        # core (the evidence line prints the process name of the last
        # secondary-core run).
        grep -aEq -- "smp: secondary runs=[0-9]+ task=SCHEDRING.BIN" "$SER" && secondary=1 || true
        # Issue #857: migration in BOTH directions — at least one steal
        # of the floating copy FROM ring 0 (core 1 pulled it) and at
        # least one FROM ring 1 (core 0 pulled it back).
        grep -aEq -- "smp: steal runs=[0-9]+ task=SCHEDRING.BIN from=0" "$SER" && steal0=1 || true
        grep -aEq -- "smp: steal runs=[0-9]+ task=SCHEDRING.BIN from=1" "$SER" && steal1=1 || true
        [ "$(grep -aFxc -- "rx-schedring-ok" "$SER" || true)" = 1 ] && echo_ok=1
        grep -qF -- "[EXC] parking:" "$SER" && fatal=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner listed=$listed loaded=$loaded two-running=$two_running slept=$slept yielded=$yielded done=$done exited=$exited procs-exited=$procs_exited reaped=$reaped secondary=$secondary steal0=$steal0 steal1=$steal1 echo=$echo_ok fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$listed" = 1 ] && [ "$loaded" = 2 ] && \
        [ "$two_running" = 1 ] && [ "$slept" = 1 ] && [ "$yielded" = 1 ] && [ "$done" = 1 ] && \
        [ "$exited" = 1 ] && [ "$procs_exited" = 1 ] && [ "$reaped" = 1 ] && \
        [ "$secondary" = 1 ] && [ "$steal0" = 1 ] && [ "$steal1" = 1 ] && [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "VIRELAIOS live sched-ring gate (claim 881 / #856 slice 4) — per-core ready rings under two yield/sleep programs"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $(cat "$SCRIPT" | tr '\n' '|')"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
    echo "One SCHEDRING.BIN is pinned to core 1 (home ring 1, never"
    echo "stolen), one floats (home ring 0, migrating both directions);"
    echo "each runs 4 x sys_sleep(1) + 32 x sys_yield and prints exact-count"
    echo "markers. A lost wakeup hangs before 'slept=4', a duplicate staging"
    echo "or corrupt save/restore breaks the exact counts or faults the VM."
    echo "At least one 'smp: steal ... from=0' AND one 'from=1' line prove"
    echo "the issue-857 bidirectional migration."
    echo
} | tee -a "$REPORT"

pass=0
for ((i = 0; i < BOOTS; i++)); do
    tag="$(printf '%02d' "$i")"
    echo
    echo "=== live-sched-ring boot $i ==="
    if run_one "$tag"; then
        pass=$((pass + 1))
    fi
done

echo
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-sched-ring: PASS — per-core ready rings hold under two yield/sleep programs (exact sleep/yield counts, clean exits + reaps, secondary evidence, bidirectional steal) ($pass/$BOOTS boot(s))."
    exit 0
else
    echo "verify-live-sched-ring: FAIL — $pass/$BOOTS boot(s) passed; see artifacts/live-sched-ring-report.txt and artifacts/live-sched-ring-serial-*.log"
    exit 1
fi