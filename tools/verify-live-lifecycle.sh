#!/usr/bin/env bash
#
# verify-live-lifecycle.sh -- claim 6729 class-B gate: the user task
# lifecycle (spawn / exit / reap) with explicit task states and the
# scheduler-owned idle task, on real VZ hardware. The production image
# boots with the claim-9746 vectors, the claim-9187 timer, and the
# scheduler pool: shell + worker + the EL0t user task + one spawnable
# demo slot + the always-ready idle task.
#
# The gate proves the WHOLE lifecycle end to end:
#   * EXIT: the EL0 payload's `sys_exit(7)` (proven by claims 3594/5804)
#     turns the user task into a zombie; the shell loop prints
#     `tasks user-el0 exited status=7` (the scheduler owns the exit —
#     the SVC return lands in the ring's next ready task, never the
#     exited one).
#   * IDLE + REAP: the scheduler-owned idle task reaps one zombie per
#     iteration and the shell loop prints `tasks user-el0 reaped`; the
#     slot returns to the free pool (`pool=` shrinks).
#   * SPAWN: the scripted `spawn` command registers the lifecycle demo
#     task on its dedicated stack (`spawn: spawn-demo id=3`); the demo
#     task enters the ring, receives quanta, and its report line
#     `tasks spawn-demo advances=N` proves a runtime spawn schedules.
#   * EXPLICIT STATES: the `tasks` command reports each row's `state=`
#     and the pool/zombie counts in the header.
#   * SHELL SURVIVES: the `echo rx-lifecycle-ok` reply proves the shell
#     context round-tripped across all of the above switches.
#
# Mechanism: the runner's non-interactive scripted-input mode (claim
# 6684, --script) forwards keystrokes into the serial attachment; guest
# output is teed to vm-serial.log; the runner exits 0 iff the expected
# line appears. We expect the REAP line — it is guaranteed (the payload
# always exits; the idle task always reaps) and it is the LAST lifecycle
# event, so by the time the runner exits the log also holds the earlier
# spawn + exit evidence.
#
# Per boot this reports:
#   rc              the runner's exit code (0 iff the reap line appeared)
#   serial-bytes    vm-serial.log size
#   banner / spawn / demo-adv / exited / reaped / state-col / pool /
#   idle-row / echo  per-assertion flags
#
# Run isolation (#523 item 2 / issue #528, claim 5069): every boot attaches
# a private DiskImageKit stacked disk (read-only base + throwaway ASIF
# overlay), a private EFI var store (recreated fresh per boot, as the
# pre-isolation gate did), and a private serial log under $RUN_DIR — two
# concurrent instances cannot clobber each other's disks, NVRAM, or
# evidence. Set DIPSHIT_GATE_SUFFIX=_alt to give this instance its own
# canonical evidence names (two simultaneous instances MUST differ), and
# DIPSHIT_KEEP_RUN=1 to keep the scratch dir.
#
# Class B — Apple silicon + VZ only; boots a real VM. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-lifecycle.sh          # BOOTS boots (default 1)
#   BOOTS=3 bash tools/verify-live-lifecycle.sh
#
# Evidence saved under artifacts/: live-lifecycle-gate.txt (full output),
# live-lifecycle-report.txt (per-boot detail), live-lifecycle-run-<NN>.txt
# (runner output), live-lifecycle-serial-<NN>.log (vm-serial.log copy),
# live-lifecycle-script.txt (the forwarded keystrokes).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-lifecycle-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-lifecycle-report.txt)"

echo "=== verify-live-lifecycle: claim 6729 — user task lifecycle (spawn / exit / reap + idle task), $BOOTS boot(s) ==="

# --- per-run isolation -------------------------------------------------------------
# Private scratch dir + pristine-boot overlay for EVERY boot.
# See tools/lib/gate-run.sh.
gate_begin live-lifecycle
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

# --- tool versions + revision -----------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- the scripted keystrokes ------------------------------------------------
# `spawn` first (the pool's spare slot is free while the EL0 task is
# still alive; it exits ~2 s after boot), then `tasks` (explicit states +
# pool/zombie counts), then an echo to prove the shell survived.
cat > "$SCRIPT" <<'EOF'
spawn
tasks
echo rx-lifecycle-ok
EOF

# --- THE GATE: per-boot live run, fresh variable store each -----------------
run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    # --script-expect waits for the REAP line: `tasks user-el0 reaped`
    # only appears after the EL0 task exited (zombie), the idle task ran
    # a quantum and reaped it, and the shell loop printed the report —
    # i.e. the whole exit/reap half of the lifecycle.
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-expect "tasks user-el0 reaped" --timeout 60 \
        > "$(art live-lifecycle-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "artifacts/live-lifecycle-serial-$tag.log" || true
    local SER="$(art live-lifecycle-serial-$tag.log)"

    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
    local BANNER=0 SPAWN=0 DEMO_ADV=0 EXITED=0 REAPED=0 STATE_COL=0 POOL=0 IDLE_ROW=0 ECHO=0
    [ -f "$SER" ] || { SERIAL_BYTES=0; }
    if [ -f "$SER" ]; then
        grep -qF -- "DipshitOS kernel has seized control." "$SER" && BANNER=1
        grep -qE -- "spawn: spawn-demo id=[0-9]+" "$SER" && SPAWN=1
        grep -qE -- "tasks spawn-demo advances=[1-9][0-9]*" "$SER" && DEMO_ADV=1
        grep -qF -- "tasks user-el0 exited status=7" "$SER" && EXITED=1
        grep -qF -- "tasks user-el0 reaped" "$SER" && REAPED=1
        grep -qE -- "saves=[0-9]+ resumes=[0-9]+ advances=[0-9]+ state=(ready|running|zombie)" "$SER" && STATE_COL=1
        # OBSERVED TODAY (2026-08-24, claim 5069): the task pool grew from
        # 7 to 11 slots (later user programs register more tasks — see
        # docs/march-m13.md APPS.TXT manifest) — serial bytes:
        # `tasks: enabled=1 current=0 switches=5 pool=5/11 zombies=0`.
        # The historical hard-coded /7 can never match again; pin only
        # the shape, not the capacity.
        grep -qE -- "tasks: enabled=1 current=[0-9]+ switches=[0-9]+ pool=[0-9]+/[0-9]+ zombies=[0-9]+" "$SER" && POOL=1
        grep -qE -- "idle +saves=[0-9]+ resumes=[0-9]+ advances=0 state=ready" "$SER" && IDLE_ROW=1
        grep -qF -- "rx-lifecycle-ok" "$SER" && ECHO=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER spawn=$SPAWN demo-adv=$DEMO_ADV exited=$EXITED reaped=$REAPED state-col=$STATE_COL pool=$POOL idle-row=$IDLE_ROW echo=$ECHO"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER spawn=$SPAWN demo-adv=$DEMO_ADV exited=$EXITED reaped=$REAPED state-col=$STATE_COL pool=$POOL idle-row=$IDLE_ROW echo=$ECHO"
    # The gate passes iff the full lifecycle is observed: rc=0 requires
    # the reap line (exit -> zombie -> idle reap -> report), spawn id +
    # the demo task's advance report prove a runtime spawn scheduled, the
    # state column + pool/zombie header prove the explicit states, and
    # the echo proves the shell survived every switch.
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$SPAWN" = 1 ] && [ "$DEMO_ADV" = 1 ] && [ "$EXITED" = 1 ] && [ "$REAPED" = 1 ] && [ "$STATE_COL" = 1 ] && [ "$POOL" = 1 ] && [ "$IDLE_ROW" = 1 ] && [ "$ECHO" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live-lifecycle gate (claim 6729) — user task lifecycle: spawn / exit / reap + idle task on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $SCRIPT (spawn / tasks / echo rx-lifecycle-ok; expect the reap 'tasks user-el0 reaped')"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-lifecycle boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-lifecycle: PASS — the EL0 task exited to a zombie, the idle task reaped it, a runtime-spawned demo task entered the ring and advanced, and the shell survived with explicit states reported on VZ ($PASS/$BOOTS boot(s))."
    echo "PASS: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-lifecycle: FAILED — $PASS/$BOOTS boot(s) passed; see artifacts/live-lifecycle-report.txt and the per-boot serial logs."
    echo "FAIL: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
