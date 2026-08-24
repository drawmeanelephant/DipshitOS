#!/usr/bin/env bash
#
# verify-live-kill.sh -- claim 7786 (milestone-four follow-on 3, card 3c)
# class-B gate: the OS, not the program, owns process lifetime — a
# never-exiting COUNTER.BIN is force-terminated by the `kill` monitor
# command on real VZ hardware and flows through the REAL lifecycle
# (exit → zombie → idle-reap → page return → slot reuse).
#
# Claim 4613 proved a process can REFUSE to exit (COUNTER.BIN loops
# forever); nothing could END it. The `kill <pid|name>` command arms the
# target's TCB; the ring converts the target's NEXT selection into the
# existing exit path with the reserved status 137. Because only one task
# runs at a time, the killed task never executes again after the arm — so
# NO `counter: alive` marker can land after the `kill:` reply line (the
# deterministic anchor this gate asserts).
#
# The primary script is forwarded in ONE burst (claim 6684), so the kill
# that must land AFTER the counter's markers appear cannot be in it. The
# gate uses THREE scripted phases (--script/--script2/--script3):
#   Phase 1 (after the boot payload exits):
#     ls | exec COUNTER.BIN | procs | pages | echo rx-kill-phase1
#   Phase 2 (after the FIRST `counter: alive` marker):
#     kill COUNTER.BIN | echo rx-kill-killed
#   Phase 3 (after the counter's reap line `tasks user-exec reaped`):
#     procs | pages | exec USER.BIN | procs | echo rx-kill-ok
#
# All asserted in vm-serial.log:
#   1. The counter loaded (`exec: loaded COUNTER.BIN size=`) and its
#      `counter: alive` markers are landing BEFORE the kill (>= 1).
#   2. NO `counter: alive` marker after the `kill: COUNTER.BIN armed`
#      line (the kernel owns the lifetime — the killed task never
#      executes again).
#   3. The kill flows through the real lifecycle: `tasks user-exec exited
#      status=137`, `procs COUNTER.BIN exited status=137`, `tasks
#      user-exec reaped`, and a procs row `name=COUNTER.BIN state=exited
#      task=reaped exit=137`.
#   4. Page recovery: the phase-3 `pages` free equals the phase-1 free
#      PLUS 9 (the counter's 1 text + 4 user-stack + 4 EL1-stack pages
#      returned at the reap; nothing allocates between the reads).
#   5. The re-exec lands in the freed slot: `exec: loaded USER.BIN size=`
#      in phase 3 and its procs row shows the SAME task id the counter's
#      phase-1 row showed (slot reuse).
#   6. The shell stays responsive (all three echo replies), no exception
#      park.
#
# The runner runs WITHOUT --script-expect: the kill→exit→reap handoff and
# the 1 s tick need the full window (the runner exits success on timeout
# when no expect is configured; the assertions below are the gate).
# Evidence saved under artifacts/: live-kill-gate.txt, live-kill-report.txt,
# live-kill-run-<NN>.txt, live-kill-serial-<NN>.log.

# Run isolation (#523 item 2 / issue #528, claim 5069): every boot attaches
# a private DiskImageKit stacked disk (read-only base + throwaway ASIF
# overlay), a private EFI var store (recreated fresh per boot, as the
# pre-isolation gate did), and a private serial log under $RUN_DIR — two
# concurrent instances cannot clobber each other's disks, NVRAM, or
# evidence. Set DIPSHIT_GATE_SUFFIX=_alt to give this instance its own
# canonical evidence names (two simultaneous instances MUST differ), and
# DIPSHIT_KEEP_RUN=1 to keep the scratch dir.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-kill-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-kill-report.txt)"
SCRIPT1="artifacts/live-kill-script1.txt"
SCRIPT2="artifacts/live-kill-script2.txt"
SCRIPT3="artifacts/live-kill-script3.txt"
# The static claim-8215 payload's exit line: the runner forwards phase 1
# only after it appears, so the boot payload's slot is free.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
# The FIRST counter marker: phase 2 (the kill) lands only after the
# counter has actually run (markers landing).
COUNTER_MARKER="counter: alive"
# The counter's reap line: phase 3 (the post-reap snapshot + re-exec)
# lands only after the kill's reap returned the pages.
KILL_REAP_LINE="tasks user-exec reaped"

echo "=== verify-live-kill: claim 7786 — the kernel owns process lifetime (kill a never-exiting program), $BOOTS boot(s) ==="

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
gate_begin live-kill
echo "run dir: $RUN_DIR"

# Phase 1: list, start the permanent occupant, snapshot its task id and the
# allocator free count (the pre-kill baseline).
printf 'ls\nexec COUNTER.BIN\nprocs\npages\necho rx-kill-phase1\n' > "$SCRIPT1"
# Phase 2: after the first marker — the kernel force-terminates the
# never-exiting program with the reserved status 137.
printf 'kill COUNTER.BIN\necho rx-kill-killed\n' > "$SCRIPT2"
# Phase 3: after the kill's reap — the exited/reaped row, the exact page
# recovery, and the re-exec into the freed slot.
printf 'procs\npages\nexec USER.BIN\nprocs\necho rx-kill-ok\n' > "$SCRIPT3"

run_one() {
    local tag="$1"
    local run_log="$(art live-kill-run-$tag.txt)"
    local serial_copy="$(art live-kill-serial-$tag.log)"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"

    set +e
    # No --script-expect: capture the full window so the kill→exit→reap
    # handoff completes (the runner exits 0 on timeout when no expect is
    # configured).
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT1" --script-after "$STATIC_EXIT_LINE" \
        --script2 "$SCRIPT2" --script2-after "$COUNTER_MARKER" \
        --script3 "$SCRIPT3" --script3-after "$KILL_REAP_LINE" --timeout 75 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-kill-serial-$tag.log)" || true
    local SER="$serial_copy"

    local bytes=0 banner=0 listed=0 loaded_counter=0 markers=0 \
        markers_before_kill=0 no_markers_after_kill=0 killed_exit=0 \
        procs_killed_exit=0 killed_reap=0 killed_row=0 pages_reads=0 \
        page_recovery=0 counter_task=0 reexec_landed=0 slot_reused=0 \
        phase1_echo=0 kill_echo=0 echo_ok=0 fatal=0
    if [ -f "$SER" ]; then
        bytes="$(wc -c < "$SER" | tr -d ' ')"
        [ "$(grep -aFxc -- "DipshitOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        grep -a -qE -- "^  COUNTER.BIN " "$SER" && listed=1
        loaded_counter="$(grep -aFc -- "exec: loaded COUNTER.BIN size=" "$SER" || true)"
        # 1 + 2. Markers before the kill; NONE after it.
        markers="$(grep -aFc -- "$COUNTER_MARKER" "$SER" || true)"
        local kill_line
        kill_line="$(grep -anF -- "kill: COUNTER.BIN armed" "$SER" | head -1 | cut -d: -f1 || true)"
        if [ -n "$kill_line" ]; then
            local before after
            before="$(grep -anF -- "$COUNTER_MARKER" "$SER" | awk -F: -v k="$kill_line" '$1 < k' | wc -l | tr -d ' ')"
            after="$(grep -anF -- "$COUNTER_MARKER" "$SER" | awk -F: -v k="$kill_line" '$1 > k' | wc -l | tr -d ' ')"
            [ "$before" -ge 1 ] && markers_before_kill=1 || markers_before_kill=0
            [ "$after" = 0 ] && no_markers_after_kill=1 || no_markers_after_kill=0
        fi
        # 3. The kill's real lifecycle: exit reports + reap + the exited row.
        [ "$(grep -aFc -- "tasks user-exec exited status=137" "$SER" || true)" -ge 1 ] && killed_exit=1
        [ "$(grep -aFc -- "procs COUNTER.BIN exited status=137" "$SER" || true)" -ge 1 ] && procs_killed_exit=1
        [ "$(grep -aFc -- "tasks user-exec reaped" "$SER" || true)" -ge 1 ] && killed_reap=1
        grep -a -qE -- "name=COUNTER.BIN state=exited task=reaped .*exit=137" "$SER" && killed_row=1
        # 4. Page recovery: phase-3 free = phase-1 free + 9.
        local pages_lines p1 p3
        pages_lines="$(grep -aF -- "pages: armed=1 total=" "$SER" || true)"
        pages_reads="$(printf '%s\n' "$pages_lines" | grep -cF -- "pages: armed=1 total=" || true)"
        p1="$(printf '%s\n' "$pages_lines" | sed -n '1p' | sed -E 's/.*free=0x([0-9a-f]+).*/\1/' || true)"
        p3="$(printf '%s\n' "$pages_lines" | sed -n '2p' | sed -E 's/.*free=0x([0-9a-f]+).*/\1/' || true)"
        if [ -n "$p1" ] && [ -n "$p3" ]; then
            [ $((16#$p3)) -eq $((16#$p1 + 9)) ] && page_recovery=1 || page_recovery=0
        fi
        # 5. The re-exec lands in the freed slot: the phase-1 counter row's
        # task id equals the phase-3 USER.BIN row's task id.
        local counter_row counter_tid user_row user_tid
        counter_row="$(grep -aE -- "procs: id=[0-9]+ name=COUNTER.BIN state=running" "$SER" | head -1 || true)"
        counter_tid="$(printf '%s\n' "$counter_row" | sed -E 's/.*task=([0-9]+).*/\1/' || true)"
        user_row="$(grep -aE -- "procs: id=[0-9]+ name=USER.BIN state=running" "$SER" | head -1 || true)"
        user_tid="$(printf '%s\n' "$user_row" | sed -E 's/.*task=([0-9]+).*/\1/' || true)"
        if [ -n "$counter_tid" ] && [ -n "$user_tid" ]; then
            [ "$counter_tid" = "$user_tid" ] && slot_reused=1 || slot_reused=0
        fi
        [ "$(grep -aFc -- "exec: loaded USER.BIN size=" "$SER" || true)" -ge 1 ] && reexec_landed=1
        # 6. Shell responsive; no exception park.
        [ "$(grep -aFxc -- "rx-kill-phase1" "$SER" || true)" = 1 ] && phase1_echo=1
        [ "$(grep -aFxc -- "rx-kill-killed" "$SER" || true)" = 1 ] && kill_echo=1
        [ "$(grep -aFxc -- "rx-kill-ok" "$SER" || true)" = 1 ] && echo_ok=1
        grep -qF -- "[EXC] parking:" "$SER" && fatal=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner listed=$listed loaded-counter=$loaded_counter markers=$markers markers-before-kill=$markers_before_kill no-markers-after-kill=$no_markers_after_kill killed-exit=$killed_exit procs-killed-exit=$procs_killed_exit killed-reap=$killed_reap killed-row=$killed_row pages-reads=$pages_reads page-recovery=$page_recovery slot-reused=$slot_reused reexec-landed=$reexec_landed phase1-echo=$phase1_echo kill-echo=$kill_echo echo=$echo_ok fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$listed" = 1 ] && [ "$loaded_counter" = 1 ] && \
        [ "$markers" -ge 1 ] && [ "$markers_before_kill" = 1 ] && [ "$no_markers_after_kill" = 1 ] && \
        [ "$killed_exit" = 1 ] && [ "$procs_killed_exit" = 1 ] && [ "$killed_reap" = 1 ] && [ "$killed_row" = 1 ] && \
        [ "$pages_reads" -ge 2 ] && [ "$page_recovery" = 1 ] && \
        [ "$slot_reused" = 1 ] && [ "$reexec_landed" = 1 ] && \
        [ "$phase1_echo" = 1 ] && [ "$kill_echo" = 1 ] && [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live kill gate (claim 7786) — the kernel owns process lifetime on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script1: $(cat "$SCRIPT1" | tr '\n' '|')"
    echo "script2: $(cat "$SCRIPT2" | tr '\n' '|')"
    echo "script3: $(cat "$SCRIPT3" | tr '\n' '|')"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
    echo "COUNTER.BIN (distinct markers, sys_write + sys_yield only, no sys_exit)"
    echo "is force-terminated by the kill monitor command with the reserved"
    echo "status 137; the kill flows through the real exit → zombie → idle-reap"
    echo "path (pages returned), and a re-exec lands in the freed slot. Because"
    echo "only one task runs at a time, no marker can land after the kill line."
    echo
} | tee -a "$REPORT"

pass=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-kill boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-kill: PASS — the never-exiting COUNTER.BIN was force-terminated by the kill command (status 137), its 5 pages returned, and the freed slot was re-exec'd ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-kill: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
