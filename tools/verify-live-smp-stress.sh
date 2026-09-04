#!/usr/bin/env bash
#
# verify-live-smp-stress.sh -- claim 907 / issue #858 class-B gate: the
# four-core four-domain payoff proof for the per-service-domain locks
# (claim 2792) and the per-core ready rings (#856/PR #904).
#
# The gate boots FOUR VCPUs (`--cpus 4`; the kernel brings up cores 1-3
# via the claim-907 PSCI sweep) and execs four user hammers, EACH PINNED
# TO ITS OWN CORE and each hammering a DIFFERENT service domain:
#
#   1. `exec -c1 SMPFILE.BIN` — the FILE hammer (slots 23-26, host file
#      channel): 24 open/read|write/close round trips of the planted
#      /host/STRESS.TXT fixture, one `smpfile: hb=<n>` line per ~1 s
#      heartbeat (each wake is a ring resume on core 1).
#   2. `exec -c2 SMPNET.BIN`  — the NET hammer (slots 9-11): 24 OWN-IP
#      UDP loopback round trips on port 7100 (dst 10.0.0.1 — no device
#      round trip, no host peer), `smpnet: hb=<n>` per heartbeat.
#   3. `exec -c3 SMPWIN.BIN`  — the WIN hammer (slots 12-15): one 96x96
#      kernel window, 12 fill+present rounds (the present dirties the
#      compositor state core 0's shell idle blits — cross-core WIN
#      traffic), `smpwin: hb=<n>` per heartbeat.
#   4. `exec -c0 SMPEV.BIN`   — the EV hammer (slots 40/21): 6 one-tick
#      app timers, each waited for through sys_poll_event — the tick's
#      own on_tick needs the same ev|kernel domain bits, so this doubles
#      as the try-take starvation probe (#858's failure mode), `smpev:
#      ev=<n>` per event.
#   while the shell idle loop runs its own net/win/ev brackets on core 0
#   and the reaper drains the four exits.
#
# Assertions (all in the serial log):
#   * `smp: cores=4 online=4` (four VCPUs, all online);
#   * four `exec: loaded SMP*.BIN` lines;
#   * all six heartbeats per hammer (`smpfile:/smpnet:/smpwin: hb=1..6`,
#     `smpev: ev=1..6`) — the interleaved progression proves all four
#     domains advanced CONCURRENTLY with no stall (a syscall holding a
#     second domain's lock, or a starved tick, breaks a cadence or the
#     bounded polls);
#   * the four done markers with exact op counts, EXACTLY once each;
#   * FOUR `tasks user-exec exited status=0` lines + one
#     `procs SMP<X>.BIN exited status=0` per hammer (no zombie regression
#     class);
#   * each hammer's name on a `smp: secondary runs=N task=SMP<X>.BIN`
#     line — the pin-exclusivity proof (only the pinned core can claim a
#     ring-c task, so each line attributes that hammer to ITS core);
#   * shell responsiveness (`echo rx-smpst-ok`) and zero `[EXC]` / fault
#     lines.
#
# Evidence under artifacts/: live-smp-stress-gate.txt,
# live-smp-stress-report.txt, live-smp-stress-run-<NN>.txt,
# live-smp-stress-serial-<NN>.log.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-smp-stress-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-smp-stress-report.txt)"
# The static claim-8215 payload's exit line: the runner forwards the script
# only after it appears, so the boot probe is gone before `exec` runs.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
# The fixture the FILE hammer reads (40 bytes, no newline — the hammer's
# read-length assertion; see user/src/smpst_file.zig `fixture`).
FIXTURE="smpst stress fixture 0123456789abcdefghi"
# The hammer done markers (each EXACTLY once in the log).
FILE_DONE="smpfile: done ops=24"
NET_DONE="smpnet: done ops=24"
WIN_DONE="smpwin: done presents=12"
EV_DONE="smpev: done events=6"

echo "=== verify-live-smp-stress: claim 907/#858 — four cores x four domains (FILE/NET/WIN/EV hammers, one pinned task per core), $BOOTS boot(s) ==="

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
gate_begin live-smp-stress
gate_seed_share
# The FILE hammer's fixture (the READ side of its round trips).
printf '%s' "$FIXTURE" > "$SHARE/STRESS.TXT"
echo "run dir: $RUN_DIR (fixture planted: $(wc -c < "$SHARE/STRESS.TXT") bytes)"
SCRIPT="$RUN_DIR/script.txt"

# The four pinned execs (core 0 gets the EV hammer via the claim-907 -c0
# explicit pin), then the shell check.
printf 'smp\nnet ip 10.0.0.1\nexec -c1 SMPFILE.BIN\nexec -c2 SMPNET.BIN\nexec -c3 SMPWIN.BIN\nexec -c0 SMPEV.BIN\necho rx-smpst-ok\n' > "$SCRIPT"

run_one() {
    local tag="$1"
    local run_log="$(art live-smp-stress-run-$tag.txt)"
    local serial_copy="$(art live-smp-stress-serial-$tag.log)"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    # M21 W11 / M37 DQ3 (issue #839): the shell persists live windows to
    # WINDOWS.SAV ~1/s and restores them at boot, so boot 0's WIN hammer
    # session would otherwise leak into boots 1+ of this multi-boot gate
    # (SMPWIN's first open returns id 3 instead of 2 -> exit 131). Same
    # per-boot reset as the TABHOLD/snap-guides/tokens desktop gates.
    gate_reset_share_state

    set +e
    # No --script-expect: capture the FULL window so all four hammers
    # complete (the runner exits 0 on timeout when no expect is set).
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-after "$STATIC_EXIT_LINE" --timeout 60 \
        --cpus 4 \
        --screen "$RUN_DIR/screen" \
        --net "$RUN_DIR/cap.bin" \
        > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-smp-stress-serial-$tag.log)" || true
    local SER="$serial_copy"

    local bytes=0 banner=0 cores4=0 net_ip=0 loaded_file=0 loaded_net=0 \
        loaded_win=0 loaded_ev=0 fhb=0 nhb=0 whb=0 ehb=0 \
        fdone=0 ndone=0 wdone=0 edone=0 exits0=0 reaped=0 \
        sec_file=0 sec_net=0 sec_win=0 echo_ok=0 fatal=0 faults=0
    if [ -f "$SER" ]; then
        bytes="$(wc -c < "$SER" | tr -d ' ')"
        [ "$(grep -aFxc -- "VirelaiOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        grep -aEq -- "smp: cores=4 online=4" "$SER" && cores4=1 || true
        grep -aEq -- "net ip: ip=10.0.0.1" "$SER" && net_ip=1 || true
        [ "$(grep -aFc -- "exec: loaded SMPFILE.BIN size=" "$SER" || true)" = 1 ] && loaded_file=1
        [ "$(grep -aFc -- "exec: loaded SMPNET.BIN size=" "$SER" || true)" = 1 ] && loaded_net=1
        [ "$(grep -aFc -- "exec: loaded SMPWIN.BIN size=" "$SER" || true)" = 1 ] && loaded_win=1
        [ "$(grep -aFc -- "exec: loaded SMPEV.BIN size=" "$SER" || true)" = 1 ] && loaded_ev=1
        # Every heartbeat: 6 per hammer. A missing hb = a stall or a
        # lost wakeup somewhere on that core.
        [ "$(grep -aFc -- "smpfile: hb=" "$SER" || true)" = 6 ] && fhb=1
        [ "$(grep -aFc -- "smpnet: hb=" "$SER" || true)" = 6 ] && nhb=1
        [ "$(grep -aFc -- "smpwin: hb=" "$SER" || true)" = 6 ] && whb=1
        [ "$(grep -aFc -- "smpev: ev=" "$SER" || true)" = 6 ] && ehb=1
        # The exact-count done markers — EXACTLY ONCE each.
        [ "$(grep -aFxc -- "$FILE_DONE" "$SER" || true)" = 1 ] && fdone=1
        [ "$(grep -aFxc -- "$NET_DONE" "$SER" || true)" = 1 ] && ndone=1
        [ "$(grep -aFxc -- "$WIN_DONE" "$SER" || true)" = 1 ] && wdone=1
        [ "$(grep -aFxc -- "$EV_DONE" "$SER" || true)" = 1 ] && edone=1
        # Four clean exits + reaps (one per hammer; the boot probe exits 7).
        [ "$(grep -aFxc -- "tasks user-exec exited status=0" "$SER" || true)" = 4 ] && exits0=1
        [ "$(grep -aFxc -- "tasks user-exec reaped" "$SER" || true)" = 4 ] && reaped=1
        # The pin-exclusivity proof: each hammer was staged by ITS pinned
        # core (only that core can claim a ring-c task), so each name on a
        # secondary-runs line attributes the hammer to its core.
        grep -aqE -- "smp: secondary runs=[0-9]+ task=SMPFILE.BIN" "$SER" && sec_file=1 || true
        grep -aqE -- "smp: secondary runs=[0-9]+ task=SMPNET.BIN" "$SER" && sec_net=1 || true
        grep -aqE -- "smp: secondary runs=[0-9]+ task=SMPWIN.BIN" "$SER" && sec_win=1 || true
        [ "$(grep -aFxc -- "rx-smpst-ok" "$SER" || true)" -ge 1 ] && echo_ok=1
        grep -qF -- "[EXC] parking:" "$SER" && fatal=1 || true
        grep -aqE -- "fault: .* ec=" "$SER" && faults=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner cores4=$cores4 net-ip=$net_ip loaded(f/n/w/e)=$loaded_file/$loaded_net/$loaded_win/$loaded_ev hb(f/n/w/e)=$fhb/$nhb/$whb/$ehb done(f/n/w/e)=$fdone/$ndone/$wdone/$edone exits0=$exits0 reaped=$reaped secondary(f/n/w)=$sec_file/$sec_net/$sec_win echo=$echo_ok fatal=$fatal faults=$faults" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$cores4" = 1 ] && [ "$net_ip" = 1 ] && \
        [ "$loaded_file" = 1 ] && [ "$loaded_net" = 1 ] && [ "$loaded_win" = 1 ] && [ "$loaded_ev" = 1 ] && \
        [ "$fhb" = 1 ] && [ "$nhb" = 1 ] && [ "$whb" = 1 ] && [ "$ehb" = 1 ] && \
        [ "$fdone" = 1 ] && [ "$ndone" = 1 ] && [ "$wdone" = 1 ] && [ "$edone" = 1 ] && \
        [ "$exits0" = 1 ] && [ "$reaped" = 1 ] && \
        [ "$sec_file" = 1 ] && [ "$sec_net" = 1 ] && [ "$sec_win" = 1 ] && \
        [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ] && [ "$faults" = 0 ]
}

: > "$REPORT"
{
    echo "VIRELAIOS live smp-stress gate (claim 907 / issue #858) — four cores x four domains, one pinned task per core"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $(cat "$SCRIPT" | tr '\n' '|')"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
    echo "SMPFILE.BIN (core 1) hammers FILE; SMPNET.BIN (core 2) hammers NET;"
    echo "SMPWIN.BIN (core 3) hammers WIN; SMPEV.BIN (core 0, the -c0 pin) hammers"
    echo "EV. Each runs 6 ~1 s heartbeats of its domain's syscalls with EXACT"
    echo "counts. A cross-domain lock hold, a lost wakeup, a starved tick, or a"
    echo "duplicate staging breaks a heartbeat cadence, a done marker, or the"
    echo "four clean reaps."
    echo
} | tee -a "$REPORT"

pass=0
for ((i = 0; i < BOOTS; i++)); do
    tag="$(printf '%02d' "$i")"
    echo
    echo "=== live-smp-stress boot $i ==="
    if run_one "$tag"; then
        pass=$((pass + 1))
    fi
done

echo
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-smp-stress: PASS — four cores x four domains: all four pinned hammers completed their exact-count heartbeats and done markers with four clean exits + reaps and per-core secondary evidence ($pass/$BOOTS boot(s))."
    exit 0
else
    echo "verify-live-smp-stress: FAIL — $pass/$BOOTS boot(s) passed; see artifacts/live-smp-stress-report.txt and artifacts/live-smp-stress-serial-*.log"
    exit 1
fi
