#!/usr/bin/env bash
#
# verify-live-tasks.sh -- claim 5275 class-B gate: the tick-driven
# round-robin kernel task scheduler on real VZ hardware. The production
# image boots with the claim-9746 vectors, the claim-9187 GIC + CNTP timer
# (a real periodic PPI entering the EL1 IRQ vector), and the scheduler
# armed with three tasks: the EL1h shell/main task, an EL1h demo worker,
# and the claim-8215 EL0t task. This regression gate keeps proving its
# original shell+worker contract inside that larger round-robin pool.
#
# The gate proves BOTH tasks advance across ticks:
#   * the worker runs and bumps its advance counter — reported from the
#     shell idle loop as `tasks worker advances=N` (main-context console,
#     claim 9187 discipline; N >= 1 proves a worker quantum completed, and
#     the line only exists after a full worker quantum, the EL0 quantum,
#     and a shell idle loop, i.e. >= 3 real context switches);
#   * the shell survives repeated preemptions — it still executes the
#     scripted `tasks` + `echo` commands (echo reply `rx-tasks-ok`), so its
#     saved/restored context is intact. (The `tasks` command output is
#     captured inside the shell's FIRST quantum — the runner forwards
#     keystrokes ~0.5 s after the terminal state — so its switches/advances
#     fields are diagnostic only; the report line is the live proof.)
#
# Mechanism: the runner's non-interactive scripted-input mode (claim 6684,
# --script / --script-expect) forwards keystrokes into the serial
# attachment; guest output is teed to vm-serial.log; the runner exits 0
# iff the expected transcript appears. The success signal is the worker
# report line — it only appears after a full worker quantum, the EL0 quantum,
# and a shell idle loop, i.e. after at least three real context switches,
# so the runner cannot exit before both tasks have demonstrably run.
#
# Per boot this reports:
#   rc              the runner's exit code (0 iff the worker report appeared)
#   serial-bytes    vm-serial.log size
#   banner / interrupts / tasks-cmd / shell-row / worker-row / worker-adv /
#   echo / heartbeat  per-assertion flags
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
#   bash tools/verify-live-tasks.sh          # BOOTS boots (default 1)
#   BOOTS=3 bash tools/verify-live-tasks.sh
#
# Evidence saved under artifacts/: live-tasks-gate.txt (full output),
# live-tasks-report.txt (per-boot detail), live-tasks-run-<NN>.txt (runner
# output), live-tasks-serial-<NN>.log (vm-serial.log copy),
# live-tasks-script.txt (the forwarded keystrokes).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-tasks-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-tasks-report.txt)"

echo "=== verify-live-tasks: claim 5275 — tick-driven round-robin tasks (shell + worker advance across ticks), $BOOTS boot(s) ==="

# --- per-run isolation -------------------------------------------------------------
# Private scratch dir + pristine-boot overlay for EVERY boot.
# See tools/lib/gate-run.sh.
gate_begin live-tasks
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
cat > "$SCRIPT" <<'EOF'
tasks
echo rx-tasks-ok
EOF

# --- THE GATE: per-boot live run, fresh variable store each -----------------
run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    # --script-expect waits for the worker's first report line, written
    # only after a full worker quantum, the EL0 quantum, and a shell idle
    # loop (>= 3 real context switches); the runner exits 0
    # as soon as it appears in the serial log.
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-expect "tasks worker advances=" --timeout 60 \
        > "$(art live-tasks-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "artifacts/live-tasks-serial-$tag.log" || true
    local SER="$(art live-tasks-serial-$tag.log)"

    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
    local BANNER=0 INTERRUPTS=0 CMD=0 SHELL_ROW=0 WORKER_ROW=0 WORKER_ADV=0 WORKER_REPORT=0 ECHO=0 HEARTBEAT=0 SWITCHES=0
    [ -f "$SER" ] || { SERIAL_BYTES=0; }
    if [ -f "$SER" ]; then
        grep -qF -- "DipshitOS kernel has seized control." "$SER" && BANNER=1
        grep -qF -- "interrupts: gic=" "$SER" && INTERRUPTS=1
        grep -qF -- "tasks: enabled=1" "$SER" && CMD=1
        grep -qE -- "shell +saves=[0-9]+ resumes=[0-9]+ advances=0" "$SER" && SHELL_ROW=1
        grep -qE -- "worker +saves=[0-9]+ resumes=[0-9]+ advances=[0-9]+" "$SER" && WORKER_ROW=1
        grep -qE -- "worker +saves=[0-9]+ resumes=[0-9]+ advances=[1-9][0-9]*" "$SER" && WORKER_ADV=1
        grep -qE -- "tasks worker advances=[1-9][0-9]*" "$SER" && WORKER_REPORT=1
        grep -qF -- "rx-tasks-ok" "$SER" && ECHO=1
        grep -qF -- "timer heartbeat ticks=5 irq=5 poll=0" "$SER" && HEARTBEAT=1
        grep -qE -- "tasks: enabled=1 current=[0-4] switches=[1-9][0-9]*" "$SER" && SWITCHES=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER interrupts=$INTERRUPTS cmd=$CMD shell-row=$SHELL_ROW worker-row=$WORKER_ROW worker-adv=$WORKER_ADV worker-report=$WORKER_REPORT echo=$ECHO heartbeat=$HEARTBEAT switches=$SWITCHES"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER interrupts=$INTERRUPTS cmd=$CMD shell-row=$SHELL_ROW worker-row=$WORKER_ROW worker-adv=$WORKER_ADV worker-report=$WORKER_REPORT echo=$ECHO heartbeat=$HEARTBEAT switches=$SWITCHES"
    # The gate passes iff the worker demonstrably advanced across ticks —
    # the runner's rc=0 requires its report line, which only appears after
    # a full worker quantum, the EL0 quantum, and a shell idle loop (>= 3
    # real context switches), so rc + worker-report already imply both tasks
    # ran; the
    # shell row + echo prove the shell's saved/restored context kept it
    # responsive. The `tasks` command output is captured before the first
    # switch (the runner forwards keystrokes ~0.5 s after the terminal
    # state, i.e. inside the shell's first quantum), so its switches/
    # advances fields are diagnostic only — the live proof is the report.
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$INTERRUPTS" = 1 ] && [ "$CMD" = 1 ] && [ "$SHELL_ROW" = 1 ] && [ "$WORKER_ROW" = 1 ] && [ "$WORKER_REPORT" = 1 ] && [ "$ECHO" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live-tasks gate (claim 5275) — tick-driven round-robin: shell + worker advance across timer ticks on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $SCRIPT (tasks / echo rx-tasks-ok; expect the worker report 'tasks worker advances=')"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-tasks boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-tasks: PASS — the timer PPI preempted the shell, the worker advanced (report + nonzero counter), and the shell resumed to execute commands across real context switches on VZ ($PASS/$BOOTS boot(s))."
    echo "PASS: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-tasks: FAILED — $PASS/$BOOTS boot(s) passed; see artifacts/live-tasks-report.txt and the per-boot serial logs."
    echo "FAIL: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
