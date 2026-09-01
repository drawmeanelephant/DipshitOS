#!/usr/bin/env bash
#
# verify-live-procs-syscall.sh -- claim 5799 (milestone-four follow-on 4,
# card 4a) class-B gate: the process table read FROM EL0 on real VZ
# hardware.
#
# The chain, all asserted in vm-serial.log:
#   1. `exec PEER.BIN` (pid 1) then `exec COUNTER.BIN 1` (pid 2, the IPC
#      sender targeting the peer — card 3e's argv contract).
#   2. PEER.BIN's phase-1 loop calls sys_procs (slot 7) once per quantum
#      until the snapshot shows a RUNNING process other than itself (the
#      counter is exec'd after the peer, so the first snapshots only show
#      the peer + the exited boot payload), then prints one
#      `peer: sees <pid> <name> <state>` line per snapshot row. The
#      counter's `peer: sees 2 COUNTER.BIN running` row is the proof that
#      a process-level view of the process table is reachable FROM EL0 —
#      distinct from the EL1h monitor's own `procs` read.
#   3. The snapshot also carries the peer's own row (`peer: sees ...
#      PEER.BIN running`) and the exited boot payload's row
#      (`peer: sees 0 user-el0 exited`) — the honest table, not just the
#      live set.
#   4. After the snapshot the peer enters its existing recv loop: the
#      counter's `ipc: ping N` sends still echo back as `peer: got ping N`
#      (the IPC flow is unaffected by the phase-1 read).
#   5. The monitor's `procs` read shows both programs state=running
#      (distinct from the EL0 view), neither ever exits, and the shell
#      stays responsive.
#
# The runner runs WITHOUT --script-expect: the never-exiting programs need
# the full window (the runner exits success on timeout when no expect is
# configured; the assertions below are the gate). Evidence saved under
# artifacts/: live-procs-syscall-gate.txt, live-procs-syscall-report.txt,
# live-procs-syscall-run-<NN>.txt, live-procs-syscall-serial-<NN>.log.

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

GATE_LOG="$(art live-procs-syscall-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-procs-syscall-report.txt)"
# The static claim-8215 payload's exit line: the runner forwards the
# script only after it appears, so the boot payload's slot and pid are
# free when the execs run.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
# The first echoed message: the peer reached its recv loop after the
# snapshot (the IPC flow is unaffected by the phase-1 read).
FLOW_MARKER="peer: got ping 1"

echo "=== verify-live-procs-syscall: claim 5799 — the process table read FROM EL0 via sys_procs (slot 7), $BOOTS boot(s) ==="

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
gate_begin live-procs-syscall
gate_seed_share
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

# Phase 1: the two execs (the peer polls sys_procs until it sees the
# counter) + the monitor's own read + the shell check. Phase 2 (after the
# first echo — the peer is in its recv loop): the final procs + the shell
# check.
printf 'ls\nexec PEER.BIN\nexec COUNTER.BIN 1\nprocs\necho rx-procs-syscall-ok\n' > "$SCRIPT"
printf 'procs\necho rx-procs-syscall-ok2\n' > "$(art live-procs-syscall-script2.txt)"

run_one() {
    local tag="$1"
    local run_log="$(art live-procs-syscall-run-$tag.txt)"
    local serial_copy="$(art live-procs-syscall-serial-$tag.log)"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"

    set +e
    # No --script-expect: capture the full window (the runner exits 0 on
    # timeout when no expect is configured).
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-after "$STATIC_EXIT_LINE" \
        --script2 "$(art live-procs-syscall-script2.txt)" --script2-after "$FLOW_MARKER" \
        --timeout 60 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-procs-syscall-serial-$tag.log)" || true
    local SER="$serial_copy"

    local bytes=0 banner=0 peer_listed=0 peer_loaded=0 counter_loaded=0 \
        sees_counter=0 sees_peer=0 sees_boot=0 sees_state=0 \
        peer_running=0 counter_running=0 distinct_tasks=0 distinct_stacks=0 \
        flow=0 final_running=0 never_exited=0 echo1=0 echo2=0 fatal=0
    if [ -f "$SER" ]; then
        bytes="$(wc -c < "$SER" | tr -d ' ')"
        [ "$(grep -aFxc -- "VirelaiOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "PEER.BIN" "$SER" || true)" -ge 2 ] && peer_listed=1
        [ "$(grep -aFc -- "exec: loaded PEER.BIN size=" "$SER" || true)" -ge 1 ] && peer_loaded=1
        [ "$(grep -aFc -- "exec: loaded COUNTER.BIN size=" "$SER" || true)" -ge 1 ] && counter_loaded=1

        # The EL0 read (card 4a): PEER.BIN printed one `peer: sees` line
        # per snapshot row. The counter's RUNNING row read from EL0 is
        # the gate's headline; the peer's own running row and the exited
        # boot payload's row prove the snapshot is the honest table.
        grep -aqE -- "peer: sees [0-9]+ COUNTER.BIN running" "$SER" && sees_counter=1 || true
        grep -aqE -- "peer: sees [0-9]+ PEER.BIN running" "$SER" && sees_peer=1 || true
        grep -aqE -- "peer: sees [0-9]+ user-el0 exited" "$SER" && sees_boot=1 || true
        grep -aqE -- "peer: sees [0-9]+ [^ ]+ (created|running|exited)" "$SER" && sees_state=1 || true

        # The monitor's own read: both programs running with distinct
        # task ids + stack VAs (the EL1h view, distinct from the EL0 one).
        local peer_rows counter_rows
        peer_rows="$(grep -aE -- "procs: id=[0-9]+ name=PEER.BIN state=running" "$SER" || true)"
        counter_rows="$(grep -aE -- "procs: id=[0-9]+ name=COUNTER.BIN state=running" "$SER" || true)"
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

        # The IPC flow still works after the snapshot read (the peer
        # entered its recv loop): sends echo back byte-exact.
        local sends echoes
        sends="$(grep -aoE -- "ipc: ping [0-9]+" "$SER" | sed -E 's/.*ping //' | sort -n -u || true)"
        echoes="$(grep -aoE -- "peer: got ping [0-9]+" "$SER" | sed -E 's/.*ping //' | sort -n -u || true)"
        local nsends nechoes
        nsends="$(printf '%s\n' "$sends" | grep -c . || true)"
        nechoes="$(printf '%s\n' "$echoes" | grep -c . || true)"
        [ -n "$sends" ] && [ -n "$echoes" ] && [ "$nechoes" -ge 2 ] && [ -z "$(comm -23 <(printf '%s\n' "$echoes") <(printf '%s\n' "$sends") || true)" ] && flow=1 || true

        # Both processes still running at the final procs, neither exits.
        local peer_final counter_final
        peer_final="$(grep -aE -- "procs: id=[0-9]+ name=PEER.BIN state=running" "$SER" | tail -1 || true)"
        counter_final="$(grep -aE -- "procs: id=[0-9]+ name=COUNTER.BIN state=running" "$SER" | tail -1 || true)"
        [ -n "$peer_final" ] && [ -n "$counter_final" ] && final_running=1 || true
        [ "$(grep -aFc -- "name=PEER.BIN state=exited" "$SER" || true)" = 0 ] && \
            [ "$(grep -aFc -- "name=COUNTER.BIN state=exited" "$SER" || true)" = 0 ] && never_exited=1 || true
        [ "$(grep -aFxc -- "rx-procs-syscall-ok" "$SER" || true)" = 1 ] && echo1=1 || true
        [ "$(grep -aFxc -- "rx-procs-syscall-ok2" "$SER" || true)" = 1 ] && echo2=1 || true
        grep -qF -- "[EXC] parking:" "$SER" && fatal=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner peer_listed=$peer_listed peer_loaded=$peer_loaded counter_loaded=$counter_loaded sees_counter=$sees_counter sees_peer=$sees_peer sees_boot=$sees_boot sees_state=$sees_state peer_running=$peer_running counter_running=$counter_running tasks=$distinct_tasks stacks=$distinct_stacks flow=$flow final_running=$final_running never_exited=$never_exited echo1=$echo1 echo2=$echo2 fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$peer_listed" = 1 ] && [ "$peer_loaded" = 1 ] && \
        [ "$counter_loaded" = 1 ] && [ "$sees_counter" = 1 ] && [ "$sees_peer" = 1 ] && \
        [ "$sees_boot" = 1 ] && [ "$sees_state" = 1 ] && [ "$peer_running" = 1 ] && \
        [ "$counter_running" = 1 ] && [ "$distinct_tasks" = 1 ] && [ "$distinct_stacks" = 1 ] && \
        [ "$flow" = 1 ] && [ "$final_running" = 1 ] && [ "$never_exited" = 1 ] && \
        [ "$echo1" = 1 ] && [ "$echo2" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "VIRELAIOS live procs-syscall gate (claim 5799) — the process table read FROM EL0 via sys_procs (slot 7)"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $(cat "$SCRIPT" | tr '\n' '|')"
    echo "script2: $(cat "$(art live-procs-syscall-script2.txt)" | tr '\n' '|')"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

pass=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-procs-syscall boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-procs-syscall: PASS — PEER.BIN read the process table from EL0 via sys_procs: its 'peer: sees 2 COUNTER.BIN running' row proves the counter is visible FROM EL0 (distinct from the monitor's procs read); the ipc flow still echoes ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-procs-syscall: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
