#!/usr/bin/env bash
#
# verify-live-wait.sh -- claim 9946 (milestone-four follow-on 4, card 4c)
# class-B gate: exit-status propagation to a peer on real VZ hardware.
#
# The strongest remaining "real OS" proof after card 4a (a process-level
# view FROM EL0) is a deeper IPC flow: a process BLOCKS on another
# process's exit and reads its status back. This gate runs the third
# program STATUS43.BIN (pid 1) and COUNTER.BIN exec'd with the wait target
# in its argv (`exec COUNTER.BIN 0 1`): the counter's FIRST iteration
# prints "ipc: waiting pid=1" and blocks in sys_wait (slot 8) until pid 1
# exits; STATUS43.BIN sleeps 6 scheduler ticks first (a multi-second
# window), so the counter's blocked state is DETERMINISTICALLY observable
# while the target is still alive; then STATUS43 exits with status 43, the
# kernel's exit path wakes the counter and patches 43 into its saved SVC
# frame, and the counter prints "ipc: saw pid=1 status=43" — the EL0-side
# proof of the propagation. The kernel's own exit record ("tasks user-exec
# exited status=43") agrees.
#
# Script phases (the claim-4613 multi-phase runner):
#   Phase 1 (forwarded after the boot payload exits, so slots 3+4 and pids
#   1+2 are free):
#     ls | exec STATUS43.BIN | exec COUNTER.BIN 0 1 | procs | echo rx-wait-phase1
#   Phase 2 (forwarded once "ipc: waiting pid=1" appears — the counter has
#   just blocked; STATUS43 is still in its 6-tick sleep):
#     tasks | procs | echo rx-wait-ok
#
# All asserted in vm-serial.log:
#   1. Both programs load ("exec: loaded STATUS43.BIN size=" and "exec:
#      loaded COUNTER.BIN size=").
#   2. STATUS43.BIN runs: its "status43: alive" marker lands, then its
#      "status43: exiting" marker right before sys_exit.
#   3. The counter blocks: "ipc: waiting pid=1" appears, the phase-2
#      `tasks` snapshot shows TWO `state=blocked` user-exec rows (the
#      sleeping STATUS43 + the waiting counter), and the phase-2 `procs`
#      snapshot still shows `name=STATUS43.BIN state=running` — the target
#      is ALIVE while the waiter is blocked (the blocking proof).
#   4. The propagation: the kernel records the target's exit BOTH ways
#      ("tasks user-exec exited status=43" and "procs STATUS43.BIN exited
#      status=43", the task- and process-level exit reports) and the
#      counter's "ipc: saw pid=1 status=43" agrees with them — the same
#      number, observed from EL0. (The ring resumes the counter DIRECTLY
#      after the target's exit — its slot is next — so the EL0 observation
#      can precede the shell's report drain in the log; the ordering
#      asserted is waiting marker < target still running < observed status.)
#   5. The lifecycle close: "tasks user-exec reaped" (the idle task reaped
#      the exited executor slot).
#   6. The shell stays responsive (both echo replies); no exception park.
#
# The runner runs with --script-expect "tasks user-exec reaped": the reap
# line is the LAST of the shell's report drain (exits, then process exits,
# then reaps), so its appearance guarantees both kernel exit records are
# already in the log. Evidence saved under artifacts/: live-wait-gate.txt,
# live-wait-report.txt, live-wait-run-<NN>.txt, live-wait-serial-<NN>.log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-wait-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-wait-report.txt"
SCRIPT1="artifacts/live-wait-script1.txt"
SCRIPT2="artifacts/live-wait-script2.txt"
# The static claim-8215 payload's exit line: the runner forwards phase 1
# only after it appears, so the boot payload's slot and pid are free.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
# The counter's wait marker: the phase-2 snapshot runs while it is blocked
# (STATUS43 sleeps 6 ticks — a multi-second window).
WAIT_MARKER="ipc: waiting pid=1"
# The observed status line: the counter read the propagated status back
# from EL0. It lands as soon as the ring resumes the counter — the slot
# right after the target's, so the observation precedes the shell's next
# report drain.
SAW_MARKER="ipc: saw pid=1 status=43"
# The kernel's own records of the target's exit (the task-level report and
# the process-level report, both drained by the shell idle loop).
EXIT_LINE="tasks user-exec exited status=43"
PROCS_EXIT_LINE="procs STATUS43.BIN exited status=43"
# The lifecycle close: the idle task reaped the exited executor slot. The
# shell's drain prints it LAST (exits, then process exits, then reaps), so
# its appearance guarantees BOTH kernel exit records are already in the log
# — and it is the runner's --script-expect terminal line.
REAP_LINE="tasks user-exec reaped"

echo "=== verify-live-wait: claim 9946 — a process observes a peer's exit status via sys_wait (slot 8), $BOOTS boot(s) ==="
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

# Phase 1: the target (pid 1) + the observer (argv[0]=0 keeps the IPC path
# silent, argv[1]=1 is the wait target) + an early snapshot + shell check.
printf 'ls\nexec STATUS43.BIN\nexec COUNTER.BIN 0 1\nprocs\necho rx-wait-phase1\n' > "$SCRIPT1"
# Phase 2: the blocked-snapshot (tasks) + target-alive snapshot (procs) +
# the shell check — forwarded while the counter is still blocked.
printf 'tasks\nprocs\necho rx-wait-ok\n' > "$SCRIPT2"

run_one() {
    local tag="$1"
    local run_log="artifacts/live-wait-run-$tag.txt"
    local serial_copy="artifacts/live-wait-serial-$tag.log"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log

    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT1" --script-after "$STATIC_EXIT_LINE" \
        --script2 "$SCRIPT2" --script2-after "$WAIT_MARKER" \
        --script-expect "$REAP_LINE" --timeout 60 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "$serial_copy" || true

    local bytes=0 banner=0 listed=0 target_loaded=0 counter_loaded=0 \
        alive=0 exiting=0 waiting=0 blocked=0 target_alive=0 \
        exit_record=0 procs_exit=0 reaped=0 saw=0 order=0 echo1=0 echo2=0 fatal=0
    if [ -f artifacts/vm-serial.log ]; then
        bytes="$(wc -c < artifacts/vm-serial.log | tr -d ' ')"
        [ "$(grep -aFxc -- "DipshitOS kernel has seized control." artifacts/vm-serial.log || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "STATUS43.BIN" artifacts/vm-serial.log || true)" -ge 2 ] && listed=1
        [ "$(grep -aFc -- "exec: loaded STATUS43.BIN size=" artifacts/vm-serial.log || true)" -ge 1 ] && target_loaded=1
        [ "$(grep -aFc -- "exec: loaded COUNTER.BIN size=" artifacts/vm-serial.log || true)" -ge 1 ] && counter_loaded=1
        [ "$(grep -aFc -- "status43: alive" artifacts/vm-serial.log || true)" -ge 1 ] && alive=1
        [ "$(grep -aFc -- "status43: exiting" artifacts/vm-serial.log || true)" -ge 1 ] && exiting=1
        [ "$(grep -aFc -- "$WAIT_MARKER" artifacts/vm-serial.log || true)" -ge 1 ] && waiting=1
        # The blocking proof: the phase-2 tasks snapshot shows the waiting
        # counter AND the sleeping STATUS43 as blocked user-exec task rows
        # (the boot payload's row is "user-el0", a different name).
        [ "$(grep -acE -- "user-exec.*state=blocked" artifacts/vm-serial.log || true)" -ge 2 ] && blocked=1
        # The target is STILL ALIVE (its process row reads running) while
        # the waiter is blocked — a STATUS43 running row between the
        # waiting marker and the observed status.
        local target_row target_row_ln
        target_row="$(grep -aE -- "procs: id=[0-9]+ name=STATUS43.BIN state=running" artifacts/vm-serial.log | tail -1 || true)"
        [ -n "$target_row" ] && target_alive=1 || true
        target_row_ln="$(grep -anE -- "procs: id=[0-9]+ name=STATUS43.BIN state=running" artifacts/vm-serial.log | tail -1 | cut -d: -f1 || true)"
        [ "$(grep -aFc -- "$EXIT_LINE" artifacts/vm-serial.log || true)" -ge 1 ] && exit_record=1
        [ "$(grep -aFc -- "$PROCS_EXIT_LINE" artifacts/vm-serial.log || true)" -ge 1 ] && procs_exit=1
        [ "$(grep -aFc -- "$REAP_LINE" artifacts/vm-serial.log || true)" -ge 1 ] && reaped=1
        [ "$(grep -aFc -- "$SAW_MARKER" artifacts/vm-serial.log || true)" -ge 1 ] && saw=1
        # Ordering: waiting marker < target still running < observed status
        # — the counter blocked while the target was alive and only woke
        # after it exited. (The kernel's exit records are asserted
        # separately above; the ring resumes the counter DIRECTLY after the
        # target's exit — its slot is next — so the observation can precede
        # the shell's report drain in the log.)
        local wait_ln saw_ln
        wait_ln="$(grep -anF -- "$WAIT_MARKER" artifacts/vm-serial.log | head -1 | cut -d: -f1)"
        saw_ln="$(grep -anF -- "$SAW_MARKER" artifacts/vm-serial.log | head -1 | cut -d: -f1)"
        [ -n "$wait_ln" ] && [ -n "$target_row_ln" ] && [ -n "$saw_ln" ] && \
            [ "$wait_ln" -lt "$target_row_ln" ] && [ "$target_row_ln" -lt "$saw_ln" ] && order=1 || true
        [ "$(grep -aFxc -- "rx-wait-phase1" artifacts/vm-serial.log || true)" = 1 ] && echo1=1
        [ "$(grep -aFxc -- "rx-wait-ok" artifacts/vm-serial.log || true)" = 1 ] && echo2=1
        grep -qF -- "[EXC] parking:" artifacts/vm-serial.log && fatal=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner listed=$listed target_loaded=$target_loaded counter_loaded=$counter_loaded alive=$alive exiting=$exiting waiting=$waiting blocked=$blocked target_alive=$target_alive exit_record=$exit_record procs_exit=$procs_exit reaped=$reaped saw=$saw order=$order echo1=$echo1 echo2=$echo2 fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$listed" = 1 ] && [ "$target_loaded" = 1 ] && \
        [ "$counter_loaded" = 1 ] && [ "$alive" = 1 ] && [ "$exiting" = 1 ] && \
        [ "$waiting" = 1 ] && [ "$blocked" = 1 ] && [ "$target_alive" = 1 ] && \
        [ "$exit_record" = 1 ] && [ "$procs_exit" = 1 ] && [ "$reaped" = 1 ] && \
        [ "$saw" = 1 ] && [ "$order" = 1 ] && \
        [ "$echo1" = 1 ] && [ "$echo2" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live wait gate (claim 9946) — a process blocks in sys_wait until a peer exits, then reads its status"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script1: $(cat "$SCRIPT1" | tr '\n' '|')"
    echo "script2: $(cat "$SCRIPT2" | tr '\n' '|')"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

pass=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-wait boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-wait: PASS — STATUS43.BIN exited status 43 and COUNTER.BIN, blocked in sys_wait (slot 8) while the target was still running, woke and read the propagated status back from EL0 ('ipc: saw pid=1 status=43'), the kernel's own exit record agreeing ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-wait: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
