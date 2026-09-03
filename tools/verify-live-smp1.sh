#!/usr/bin/env bash
#
# verify-live-smp1.sh -- claim 2369 class-B gate: a USER program runs on a
# SECONDARY core (core 1) through the locked console TX.
#
# The PE-0 tick gate was lifted (claim 9408) and the scheduler state is
# per-core (claim 8477), but user tasks still had to stay on core 0:
# their sys_writes hit the polled virtio TX, which had no lock — two cores
# printing concurrently could interleave bytes and corrupt lines. This
# gate proves the whole chain, end to end, on real VZ hardware:
#
#   1. `exec -c1 SMP1.BIN` — the monitor flag pins the spawned task to
#      core 1 (pin_core + secondary_ok; core 0's pick skips it outright).
#   2. SMP1.BIN's first sys_write runs ON CORE 1: the hello marker lands
#      byte-exact even though core 0 prints heartbeats/reports
#      concurrently (the locked TX holds the whole line).
#   3. sys_sleep parks core 1 back on its WFE loop (the claim-2369 park
#      path — no eligible successor on the secondary core), core 0's tick
#      wakes the task, and core 1's next tick resumes it from its saved
#      SVC frame.
#   4. The second marker + sys_exit(0) also run on core 1; the exit parks
#      core 1 again, the zombie is reaped by core 0, and the exit/reap
#      reports print.
#   5. The shell auto-prints `smp: secondary runs=N task=SMP1.BIN` (the
#      claim-9408 evidence line, now with the task name) — the name-based
#      proof that the SECONDARY-core run was THIS user program, not the
#      kernel worker.
#
# The exact-line marker greps double as the anti-interleaving assertion:
# any byte-level mixing between core 1's writes and core 0's output would
# break them.
#
# Evidence saved under artifacts/: live-smp1-gate.txt,
# live-smp1-report.txt, live-smp1-run-<NN>.txt, live-smp1-serial-<NN>.log.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-smp1-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-smp1-report.txt)"
# The static claim-8215 payload's exit line: the runner forwards the script
# only after it appears, so the boot probe is gone before `exec` runs.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "=== verify-live-smp1: claim 2369 — a USER program on core 1 (locked console TX), $BOOTS boot(s) ==="

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
gate_begin live-smp1
gate_seed_share
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

# The pinned exec, a procs snapshot (the program mid-flight), the shell check.
printf 'ls\nexec -c1 SMP1.BIN\nprocs\necho rx-smp1-ok\n' > "$SCRIPT"

run_one() {
    local tag="$1"
    local run_log="$(art live-smp1-run-$tag.txt)"
    local serial_copy="$(art live-smp1-serial-$tag.log)"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"

    set +e
    # No --script-expect: capture the full window so the program completes
    # (the runner exits 0 on timeout when no expect is configured).
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-after "$STATIC_EXIT_LINE" --timeout 45 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-smp1-serial-$tag.log)" || true
    local SER="$serial_copy"

    local bytes=0 banner=0 listed=0 loaded=0 hello=0 exiting=0 exited=0 \
        procs_exited=0 reaped=0 secondary=0 echo_ok=0 fatal=0
    if [ -f "$SER" ]; then
        bytes="$(wc -c < "$SER" | tr -d ' ')"
        [ "$(grep -aFxc -- "VirelaiOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "SMP1.BIN" "$SER" || true)" -ge 1 ] && listed=1
        [ "$(grep -aFc -- "exec: loaded SMP1.BIN size=" "$SER" || true)" -ge 1 ] && loaded=1
        # The markers — byte-exact lines, so any interleaved output between
        # core 1's writes and core 0's concurrent prints breaks the grep.
        [ "$(grep -aFxc -- "smp1: hello from core-1 userland" "$SER" || true)" = 1 ] && hello=1
        [ "$(grep -aFxc -- "smp1: exiting from core 1" "$SER" || true)" = 1 ] && exiting=1
        [ "$(grep -aFxc -- "tasks user-exec exited status=0" "$SER" || true)" = 1 ] && exited=1
        [ "$(grep -aFxc -- "procs SMP1.BIN exited status=0" "$SER" || true)" = 1 ] && procs_exited=1
        [ "$(grep -aFxc -- "tasks user-exec reaped" "$SER" || true)" = 1 ] && reaped=1
        # The name-based proof that THIS user program ran on a secondary
        # core (the evidence line prints the process name of the last
        # secondary-core run — "worker" would fail this grep).
        grep -aEq -- "smp: secondary runs=[0-9]+ task=SMP1.BIN" "$SER" && secondary=1 || true
        [ "$(grep -aFxc -- "rx-smp1-ok" "$SER" || true)" = 1 ] && echo_ok=1
        grep -qF -- "[EXC] parking:" "$SER" && fatal=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner listed=$listed loaded=$loaded hello=$hello exiting=$exiting exited=$exited procs-exited=$procs_exited reaped=$reaped secondary=$secondary echo=$echo_ok fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$listed" = 1 ] && [ "$loaded" = 1 ] && \
        [ "$hello" = 1 ] && [ "$exiting" = 1 ] && [ "$exited" = 1 ] && [ "$procs_exited" = 1 ] && \
        [ "$reaped" = 1 ] && [ "$secondary" = 1 ] && [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "VIRELAIOS live SMP gate (claim 2369) — a USER program on core 1 via the locked console TX"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $(cat "$SCRIPT" | tr '\n' '|')"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
    echo "exec -c1 SMP1.BIN pins the task to core 1; the serial TX lock makes"
    echo "its sys_writes safe while core 0 prints concurrently. The sleep parks"
    echo "core 1 on its WFE loop (claim-2369 park path) and the wake resumes it;"
    echo "the evidence line names SMP1.BIN as the secondary-core run."
    echo
} | tee -a "$REPORT"

pass=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    tag="$(printf '%02d' "$n")"
    echo "=== live-smp1 boot $tag ==="
    if run_one "$tag"; then
        pass=$((pass + 1))
    fi
    n=$((n + 1))
done

echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-smp1: PASS — SMP1.BIN ran on core 1 under plain exec: byte-exact markers (locked TX), sleep park + wake, clean exit + reap, evidence names the task ($pass/$BOOTS boot(s))."
    exit 0
else
    echo "verify-live-smp1: FAIL — $pass/$BOOTS boot(s) passed; see $REPORT and artifacts/live-smp1-serial-*.log"
    exit 1
fi