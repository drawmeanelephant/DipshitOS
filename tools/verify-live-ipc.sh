#!/usr/bin/env bash
#
# verify-live-ipc.sh -- claim 5965 (milestone-four follow-on 3, card 3f)
# class-B gate: TWO live processes EXCHANGE DATA on real VZ hardware.
#
# Coexistence is proven (claims 0826/4613), but two live processes could
# not COMMUNICATE. This gate proves end-to-end data flow through the
# kernel's bounded per-process mailbox: COUNTER.BIN (the never-exiting
# sender) and PEER.BIN (the never-exiting receiver) are exec'd back to
# back, the counter sends "ping <d>" bytes through sys_ipc_send (slot 5,
# target pid parsed from its argv — card 3e's entry contract), and the
# peer recv-loops through sys_ipc_recv (slot 6) echoing each received
# message verbatim ("peer: got ping <d>"). The serial log therefore shows
# the two marker families INTERLEAVED — the peer's echoes track the
# counter's sends, byte for byte.
#
# Script phases (the claim-4613 multi-phase runner):
#   Phase 1 (forwarded after the boot payload exits + is reaped, so slots
#   2+3 and pids 1+2 are free):
#     ls | exec PEER.BIN | exec COUNTER.BIN 1 | procs | echo rx-ipc-phase1
#   Phase 2 (forwarded once "peer: got ping 1" appears — the flow is
#   established and the first message has already round-tripped):
#     mbox | procs | exec USER.BIN | echo rx-ipc-ok
#
# All asserted in vm-serial.log:
#   1. Both programs load ("exec: loaded PEER.BIN size=" and "exec: loaded
#      COUNTER.BIN size=").
#   2. The phase-1 procs read shows `name=PEER.BIN state=running` AND
#      `name=COUNTER.BIN state=running` with DISTINCT executor task ids
#      and DISTINCT per-process stack VAs (two live user processes).
#   3. Data flow: >= 3 "ipc: ping <d>" sends AND >= 3 "peer: got ping
#      <d>" echoes; every echoed number was actually sent (echoes track
#      sends), every send except possibly the LAST in the window has its
#      echo (the peer drains each message within a round; only the final
#      in-flight send can miss the window), and the FIRST echo lands after
#      the FIRST send (no echo without a send).
#   4. The phase-2 `mbox` snapshot is the bounded-ring drain proof: the
#      peer's row shows pending <= 1 (the ring is DRAINED, never
#      accumulating) and sent - recv == pending (the mailbox invariant —
#      every sent message is either still in flight or received); the
#      counter's row shows pending=0 sent=0 recv=0 (nobody sends to it).
#   5. The final procs read shows BOTH processes still running, and
#      neither ever exits (no "name=PEER.BIN state=exited" /
#      "name=COUNTER.BIN state=exited" anywhere in the log).
#   6. With counter + peer + shell + worker + idle the 5-slot pool is
#      5/5: a third exec is refused with "exec: no free scheduler pool
#      slot" (the capacity proof, reused under IPC; no spare).
#   7. The shell stays responsive (both echo replies); no exception park.
#
# The runner runs WITHOUT --script-expect: the never-exiting programs need
# the full window (the runner exits success on timeout when no expect is
# configured; the assertions below are the gate). Evidence saved under
# artifacts/: live-ipc-gate.txt, live-ipc-report.txt,
# live-ipc-run-<NN>.txt, live-ipc-serial-<NN>.log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-ipc-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-ipc-report.txt"
SCRIPT1="artifacts/live-ipc-script1.txt"
SCRIPT2="artifacts/live-ipc-script2.txt"
# The static claim-8215 payload's exit line: the runner forwards phase 1
# only after it appears, so the boot payload's slot and pid are free.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
# The first echoed message: the flow is established (the peer received
# what the counter sent) before the mbox drain snapshot runs.
FLOW_MARKER="peer: got ping 1"
# The refused third exec (5/5 pool, no spare).
POOL_FULL_LINE="exec: no free scheduler pool slot"

echo "=== verify-live-ipc: claim 5965 — two live processes exchange data through the kernel mailbox, $BOOTS boot(s) ==="
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

# Phase 1: list + the two execs (the counter's target pid is argv[0] — pid
# 1 is deterministically PEER.BIN, since the boot payload's pid 0 stays an
# exited registry row) + the two-running snapshot + the shell check.
printf 'ls\nexec PEER.BIN\nexec COUNTER.BIN 1\nprocs\necho rx-ipc-phase1\n' > "$SCRIPT1"
# Phase 2: the drained-ring snapshot + both-still-running + the 5/5
# refusal + the shell check.
printf 'mbox\nprocs\nexec USER.BIN\necho rx-ipc-ok\n' > "$SCRIPT2"

run_one() {
    local tag="$1"
    local run_log="artifacts/live-ipc-run-$tag.txt"
    local serial_copy="artifacts/live-ipc-serial-$tag.log"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log

    set +e
    # No --script-expect: capture the full window (the runner exits 0 on
    # timeout when no expect is configured).
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT1" --script-after "$STATIC_EXIT_LINE" \
        --script2 "$SCRIPT2" --script2-after "$FLOW_MARKER" \
        --timeout 60 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "$serial_copy" || true

    local bytes=0 banner=0 peer_listed=0 peer_loaded=0 counter_loaded=0 \
        peer_running=0 counter_running=0 distinct_tasks=0 distinct_stacks=0 \
        sends=0 echoes=0 echo_tracks=0 sends_echoed=0 order=0 \
        mbox_peer=0 mbox_counter=0 final_running=0 never_exited=0 \
        pool_full=0 echo1=0 echo2=0 fatal=0
    if [ -f artifacts/vm-serial.log ]; then
        bytes="$(wc -c < artifacts/vm-serial.log | tr -d ' ')"
        [ "$(grep -aFxc -- "DipshitOS kernel has seized control." artifacts/vm-serial.log || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "PEER.BIN" artifacts/vm-serial.log || true)" -ge 2 ] && peer_listed=1
        [ "$(grep -aFc -- "exec: loaded PEER.BIN size=" artifacts/vm-serial.log || true)" -ge 1 ] && peer_loaded=1
        [ "$(grep -aFc -- "exec: loaded COUNTER.BIN size=" artifacts/vm-serial.log || true)" -ge 1 ] && counter_loaded=1

        # Two live processes at the phase-1 procs snapshot: distinct task
        # ids and distinct stack VAs.
        local peer_rows counter_rows
        peer_rows="$(grep -aE -- "procs: id=[0-9]+ name=PEER.BIN state=running" artifacts/vm-serial.log || true)"
        counter_rows="$(grep -aE -- "procs: id=[0-9]+ name=COUNTER.BIN state=running" artifacts/vm-serial.log || true)"
        [ -n "$peer_rows" ] && [ -n "$counter_rows" ] && peer_running=1 && counter_running=1 || true
        if [ -n "$peer_rows" ] && [ -n "$counter_rows" ]; then
            local pt1 ct1 ps1 cs1
            pt1="$(printf '%s\n' "$peer_rows" | head -1 | sed -E 's/.*task=([0-9]+).*/\1/')"
            ct1="$(printf '%s\n' "$counter_rows" | head -1 | sed -E 's/.*task=([0-9]+).*/\1/')"
            ps1="$(printf '%s\n' "$peer_rows" | head -1 | sed -E 's/.*stack=0x([0-9a-f]{16}).*/\1/')"
            cs1="$(printf '%s\n' "$counter_rows" | head -1 | sed -E 's/.*stack=0x([0-9a-f]{16}).*/\1/')"
            [ -n "$pt1" ] && [ -n "$ct1" ] && [ "$pt1" != "$ct1" ] && distinct_tasks=1 || true
            [ -n "$ps1" ] && [ -n "$cs1" ] && [ "$ps1" != "$cs1" ] && distinct_stacks=1 || true
        fi

        # Data flow across the whole log: the counter's sends and the
        # peer's byte-exact echoes.
        sends="$(grep -aoE -- "ipc: ping [0-9]+" artifacts/vm-serial.log | sed -E 's/.*ping //' | sort -n -u || true)"
        echoes="$(grep -aoE -- "peer: got ping [0-9]+" artifacts/vm-serial.log | sed -E 's/.*ping //' | sort -n -u || true)"
        local nsends nechoes
        nsends="$(printf '%s\n' "$sends" | grep -c . || true)"
        nechoes="$(printf '%s\n' "$echoes" | grep -c . || true)"
        # Every echo was actually sent (echoes track sends).
        if [ -n "$sends" ] && [ -n "$echoes" ]; then
            if [ -z "$(comm -23 <(printf '%s\n' "$echoes") <(printf '%s\n' "$sends") || true)" ]; then
                echo_tracks=1
            fi
            # Every send except possibly the LAST in the window has its
            # echo (only the final in-flight send can miss the teardown).
            local last_send rest
            last_send="$(printf '%s\n' "$sends" | tail -1)"
            rest="$(printf '%s\n' "$sends" | grep -vx "$last_send" || true)"
            if [ -z "$(comm -23 <(printf '%s\n' "$rest") <(printf '%s\n' "$echoes") || true)" ]; then
                sends_echoed=1
            fi
            # The first echo lands AFTER the first send (no echo without a
            # send first).
            local first_send_ln first_echo_ln
            first_send_ln="$(grep -an -- "ipc: ping " artifacts/vm-serial.log | head -1 | cut -d: -f1)"
            first_echo_ln="$(grep -an -- "peer: got ping " artifacts/vm-serial.log | head -1 | cut -d: -f1)"
            [ -n "$first_send_ln" ] && [ -n "$first_echo_ln" ] && [ "$first_send_ln" -lt "$first_echo_ln" ] && order=1 || true
        fi

        # The mbox drain snapshot (phase 2): the peer's bounded ring is
        # drained (pending <= 1) and the mailbox invariant holds (sent -
        # recv == pending); the counter's ring is empty (nobody sends to
        # it).
        local mbox_peer mbox_counter
        mbox_peer="$(grep -aE -- "mbox: id=[0-9]+ name=PEER.BIN" artifacts/vm-serial.log | tail -1 || true)"
        mbox_counter="$(grep -aE -- "mbox: id=[0-9]+ name=COUNTER.BIN" artifacts/vm-serial.log | tail -1 || true)"
        if [ -n "$mbox_peer" ]; then
            local pp ps pr
            pp="$(printf '%s\n' "$mbox_peer" | sed -E 's/.*pending=([0-9]+) .*/\1/')"
            ps="$(printf '%s\n' "$mbox_peer" | sed -E 's/.*sent=([0-9]+) .*/\1/')"
            pr="$(printf '%s\n' "$mbox_peer" | sed -E 's/.*recv=([0-9]+).*/\1/')"
            [ "$pp" -le 1 ] && [ $((ps - pr)) -eq "$pp" ] && mbox_peer=1 || true
        fi
        if [ -n "$mbox_counter" ]; then
            local cp cs cr
            cp="$(printf '%s\n' "$mbox_counter" | sed -E 's/.*pending=([0-9]+) .*/\1/')"
            cs="$(printf '%s\n' "$mbox_counter" | sed -E 's/.*sent=([0-9]+) .*/\1/')"
            cr="$(printf '%s\n' "$mbox_counter" | sed -E 's/.*recv=([0-9]+).*/\1/')"
            [ "$cp" = 0 ] && [ "$cs" = 0 ] && [ "$cr" = 0 ] && mbox_counter=1 || true
        fi

        # Both processes STILL running at the final procs read, and
        # neither ever exits.
        local peer_final counter_final
        peer_final="$(grep -aE -- "procs: id=[0-9]+ name=PEER.BIN state=running" artifacts/vm-serial.log | tail -1 || true)"
        counter_final="$(grep -aE -- "procs: id=[0-9]+ name=COUNTER.BIN state=running" artifacts/vm-serial.log | tail -1 || true)"
        [ -n "$peer_final" ] && [ -n "$counter_final" ] && final_running=1 || true
        [ "$(grep -aFc -- "name=PEER.BIN state=exited" artifacts/vm-serial.log || true)" = 0 ] && \
            [ "$(grep -aFc -- "name=COUNTER.BIN state=exited" artifacts/vm-serial.log || true)" = 0 ] && never_exited=1 || true

        # 5/5 pool: the third exec is refused.
        [ "$(grep -aFc -- "$POOL_FULL_LINE" artifacts/vm-serial.log || true)" -ge 1 ] && pool_full=1 || true
        [ "$(grep -aFxc -- "rx-ipc-phase1" artifacts/vm-serial.log || true)" = 1 ] && echo1=1 || true
        [ "$(grep -aFxc -- "rx-ipc-ok" artifacts/vm-serial.log || true)" = 1 ] && echo2=1 || true
        grep -qF -- "[EXC] parking:" artifacts/vm-serial.log && fatal=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner peer_listed=$peer_listed peer_loaded=$peer_loaded counter_loaded=$counter_loaded peer_running=$peer_running counter_running=$counter_running tasks=$distinct_tasks stacks=$distinct_stacks sends=$nsends echoes=$nechoes echo_tracks=$echo_tracks sends_echoed=$sends_echoed order=$order mbox_peer=$mbox_peer mbox_counter=$mbox_counter final_running=$final_running never_exited=$never_exited pool_full=$pool_full echo1=$echo1 echo2=$echo2 fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$peer_listed" = 1 ] && [ "$peer_loaded" = 1 ] && \
        [ "$counter_loaded" = 1 ] && [ "$peer_running" = 1 ] && [ "$counter_running" = 1 ] && \
        [ "$distinct_tasks" = 1 ] && [ "$distinct_stacks" = 1 ] && [ "$nsends" -ge 3 ] && \
        [ "$nechoes" -ge 3 ] && [ "$echo_tracks" = 1 ] && [ "$sends_echoed" = 1 ] && \
        [ "$order" = 1 ] && [ "$mbox_peer" = 1 ] && [ "$mbox_counter" = 1 ] && \
        [ "$final_running" = 1 ] && [ "$never_exited" = 1 ] && [ "$pool_full" = 1 ] && \
        [ "$echo1" = 1 ] && [ "$echo2" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live IPC gate (claim 5965) — two live processes exchange data through the kernel mailbox"
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
    echo "=== live-ipc boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-ipc: PASS — COUNTER.BIN's sys_ipc_send bytes flowed through the kernel mailbox into PEER.BIN's sys_ipc_recv and came back byte-exact in the serial log ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-ipc: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
