#!/usr/bin/env bash
#
# verify-live-args.sh -- claim 4636 (milestone-four follow-on 3, card 3e)
# class-B gate: exec arguments reach EL0 on real VZ hardware.
#
# A program's identity today is its image only — the same binary cannot
# distinguish itself per exec. Card 3e packs a bounded argv block (8 args
# x 32 B) into the process's OWN text page (a read-only leaf — no extra
# page, W^X preserved) and extends the ENTRY contract (not a syscall, ADR
# 0007 frozen): _start receives argc in x0 and the block VA in x1. USER.BIN
# prints one "user: arg=<n>" line per argument BEFORE its existing markers.
#
# The chain, all asserted in vm-serial.log:
#   1. `exec USER.BIN alpha` and `exec USER.BIN beta` back to back — the
#      SAME binary loads twice (`exec: loaded USER.BIN size=` x2).
#   2. The `procs` read shows TWO `name=USER.BIN state=running` rows with
#      DISTINCT executor task ids and DISTINCT stack VAs (two live
#      processes, as in the claim-0826 gate).
#   3. The DISTINCT markers prove which invocation is which: exactly one
#      `user: arg=alpha` and exactly one `user: arg=beta` — the same image,
#      distinguished by its argv. The programs then run their usual flow
#      (hello/pings/yield/sleep/awake), interleaving with the worker.
#   4. Both complete: `user: awake` x2 and the exit/reap reports EXACTLY
#      twice each (card 3d, claim 1014 FIFOs).
#   5. Milestone sixteen C3 (claim 0339): the pool now holds EIGHT live
#      programs (11/11). The capacity-ending pool_full refusal lives in the
#      scale gate and the new resources gate; this gate keeps only its argv
#      purpose (four distinct args), so no pool_full is asserted here.
#   6. The shell stays responsive (echo reply), no exception park.
#
# The runner runs WITHOUT --script-expect: the 1 s tick makes a USER.BIN
# program's full lifetime ~10 s, so the gate captures the COMPLETE window
# (timeout) instead of tearing down at the first reap.
#
# Evidence saved under artifacts/: live-args-gate.txt,
# live-args-report.txt, live-args-run-<NN>.txt, live-args-serial-<NN>.log.

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

GATE_LOG="$(art live-args-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-args-report.txt)"
# The static claim-8215 payload's exit line: the runner forwards the script
# only after it appears, so the user root is free when `exec` runs.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "=== verify-live-args: claim 4636 — exec arguments to EL0 (same binary, distinct argv), $BOOTS boot(s) ==="

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
# Private scratch dir for EVERY boot. See tools/lib/gate-run.sh.
# This gate boots the canonical read-only artifacts/disk.img via
# gate_begin's --overlay-base + per-run ASIF overlay (M34 HF6, issue
# #740), keeping main's exact runner code path while still isolating
# concurrent gates.
gate_begin live-args
gate_seed_share
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

# Four execs with DISTINCT args back to back, the procs snapshot, then
# the shell check (the capacity ending lives in the scale/resources gates).
printf 'ls\nexec USER.BIN alpha\nexec USER.BIN beta\nexec USER.BIN gamma\nexec USER.BIN delta\nprocs\necho rx-args-ok\n' > "$SCRIPT"

run_one() {
    local tag="$1"
    local run_log="$(art live-args-run-$tag.txt)"
    local serial_copy="$(art live-args-serial-$tag.log)"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"

    set +e
    # No --script-expect: capture the full window so BOTH programs complete.
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-after "$STATIC_EXIT_LINE" --timeout 60 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-args-serial-$tag.log)" || true
    local SER="$serial_copy"

    local bytes=0 banner=0 listed=0 loaded=0 four_running=0 distinct_tasks=0 \
        distinct_stacks=0 arg_alpha=0 arg_beta=0 arg_gamma=0 arg_delta=0 \
        hello=0 awake=0 interleave=0 exited=0 procs_exited=0 \
        reaped=0 echo_ok=0 fatal=0
    if [ -f "$SER" ]; then
        bytes="$(wc -c < "$SER" | tr -d ' ')"
        [ "$(grep -aFxc -- "VirelaiOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "USER.BIN" "$SER" || true)" -ge 3 ] && listed=1
        # Both execs loaded.
        loaded="$(grep -aFc -- "exec: loaded USER.BIN size=" "$SER" || true)"
        # The procs snapshot: exactly FOUR running USER.BIN rows with
        # distinct executor task ids + stack VAs (the grown C3 pool holds
        # shell + worker + 8 users + idle).
        local rows=""
        rows="$(grep -aE -- "procs: id=[0-9]+ name=USER.BIN state=running" "$SER" || true)"
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
        # The DISTINCT markers: the SAME binary, distinguished by its argv.
        # Substring match (not exact line): the first program's marker can
        # land on the shell's trailing prompt line (`virelai> user:
        # arg=alpha`) — the same line-merge the concurrent gate's markers
        # tolerate. Each marker still appears EXACTLY once.
        [ "$(grep -aFc -- "user: arg=alpha" "$SER" || true)" = 1 ] && arg_alpha=1
        [ "$(grep -aFc -- "user: arg=beta" "$SER" || true)" = 1 ] && arg_beta=1
        [ "$(grep -aFc -- "user: arg=gamma" "$SER" || true)" = 1 ] && arg_gamma=1
        [ "$(grep -aFc -- "user: arg=delta" "$SER" || true)" = 1 ] && arg_delta=1
        # All four programs ran their usual EL0 flow and completed.
        hello="$(grep -aFc -- "user: hello from the ESP" "$SER" || true)"
        awake="$(grep -aFc -- "user: awake" "$SER" || true)"
        # Interleaving: the worker advanced while user programs were mid
        # sleep/wake cycle — an `advances=` report strictly between the
        # FIRST sleep marker and the LAST wake marker.
        # OBSERVED TODAY (2026-08-24, claim 5069): four concurrent USER.BINs
        # print sleeps/awakes INTERLEAVED (`sleeping`@109, `awake`@125,
        # `sleeping`@126…), so the historical "between the LAST sleep and
        # the FIRST wake" window is empty by construction — the last sleep
        # always lands after the first wake once two programs' cycles
        # overlap on serial. The window is flipped to first-sleep..
        # last-wake; the intent (the worker ran during the EL0 sleep
        # window) is unchanged.
        local first_sleep last_awake mid
        first_sleep="$(grep -anF -- "user: sleeping 2 ticks" "$SER" | head -1 | cut -d: -f1 || true)"
        last_awake="$(grep -anF -- "user: awake" "$SER" | tail -1 | cut -d: -f1 || true)"
        if [ -n "$first_sleep" ] && [ -n "$last_awake" ] && [ "$first_sleep" -lt "$last_awake" ]; then
            mid="$(sed -n "$((first_sleep + 1)),$((last_awake - 1))p" "$SER")"
            [ "$(echo "$mid" | grep -cF -- "tasks worker advances=" || true)" -ge 1 ] && interleave=1 || interleave=0
        fi
        # All four programs exited + were reaped: the FIFO reports print
        # EXACTLY four times each (card 3d, claim 1014).
        exited="$(grep -aFc -- "tasks user-exec exited status=43" "$SER" || true)"
        procs_exited="$(grep -aFc -- "procs USER.BIN exited status=43" "$SER" || true)"
        reaped="$(grep -aFc -- "tasks user-exec reaped" "$SER" || true)"
        [ "$(grep -aFxc -- "rx-args-ok" "$SER" || true)" = 1 ] && echo_ok=1
        grep -qF -- "[EXC] parking:" "$SER" && fatal=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner listed=$listed loaded=$loaded four-running=$four_running tasks-distinct=$distinct_tasks stacks-distinct=$distinct_stacks arg-alpha=$arg_alpha arg-beta=$arg_beta arg-gamma=$arg_gamma arg-delta=$arg_delta hello=$hello awake=$awake interleave=$interleave exited=$exited procs-exited=$procs_exited reaped=$reaped echo=$echo_ok fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$listed" = 1 ] && [ "$loaded" = 4 ] && \
        [ "$four_running" = 1 ] && [ "$distinct_tasks" = 1 ] && [ "$distinct_stacks" = 1 ] && \
        [ "$arg_alpha" = 1 ] && [ "$arg_beta" = 1 ] && [ "$arg_gamma" = 1 ] && [ "$arg_delta" = 1 ] && \
        [ "$hello" = 4 ] && [ "$awake" = 4 ] && \
        [ "$interleave" = 1 ] && [ "$exited" = 4 ] && [ "$procs_exited" = 4 ] && \
        [ "$reaped" = 4 ] && [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "VIRELAIOS live exec-args gate (claim 4636) — the SAME binary, distinguished by its argv, on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $(cat "$SCRIPT" | tr '\n' '|')"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
    echo "exec USER.BIN alpha / beta / gamma / delta: all four load and run live, and"
    echo "each prints its OWN marker (user: arg=<name>) — the argv block is a read-only"
    echo "leaf in the process's text page (no extra page, W^X preserved). The pool"
    echo "now holds EIGHT live programs (C3); the capacity ending lives in the"
    echo "scale + resources gates."
    echo
} >> "$REPORT"

pass=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-args boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-args: PASS — the same USER.BIN distinguished itself per exec (arg=alpha / arg=beta / arg=gamma / arg=delta) and all four programs ran live to completion at the grown C3 pool ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-args: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
