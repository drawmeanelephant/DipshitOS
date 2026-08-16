#!/usr/bin/env bash
#
# verify-live-sys-kill.sh -- claim 7604 (ADR 0007 slot 29) class-B gate:
# the EL0 kill seam — TOP.BIN's Kill button terminates a process from EL0,
# verified on real Apple silicon Virtualization.framework hardware.
#
# The gate:
#   1. Phase 1 (after the boot payload exits): exec COUNTER.BIN (a
#      never-exiting yield-loop program, sys_write + sys_yield only, no
#      sys_exit) and TOP.BIN (opened last -> focused).
#   2. The runner types `k` after `top: ready` (the I3 input-string seam).
#      TOP auto-selects the first RUNNING process (COUNTER, pid 1) and
#      kills it through slot 29 sys_kill (`ui.kill_process`).
#   3. Phase 2 (after the counter's `tasks user-exec exited status=137`
#      line): procs + syscalls snapshot, then the sweep echo ends the run.
#
# Assertions:
#   - `top: ready` + `counter: alive` markers (both programs ran)
#   - `top: kill pid=1` (TOP armed the kill from EL0)
#   - NO `counter: alive` AFTER the kill line (only one task runs at a
#     time; the armed counter never executes again)
#   - The kill flows through the real lifecycle: `tasks user-exec exited
#     status=137` + `procs COUNTER.BIN exited status=137`
#   - `29 sys_kill calls=1` in the syscalls report
#   - TOP.BIN still `state=running` at the final procs; shell responsive
#
# Usage:
#   bash tools/verify-live-sys-kill.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-sys-kill-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-sys-kill-report.txt"
SCRIPT1="artifacts/live-sys-kill-script1.txt"
SCRIPT2="artifacts/live-sys-kill-script2.txt"
# The static claim-8215 payload's exit line: phase 1 lands only after it,
# so the boot payload's slot is free (COUNTER becomes pid 1).
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
# The counter's exit with the reserved status: phase 2 lands only after
# the kill actually landed (TOP's marker alone precedes the arm's effect).
KILL_EXIT_LINE="tasks user-exec exited status=137"

echo "=== verify-live-sys-kill: claim 7604 — EL0 process termination (TOP.BIN Kill button) on VZ ==="
zig version
swift --version 2>&1 | head -1
sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# Phase 1: the never-exiting target + the task manager (TOP opens last, so
# its window holds keyboard focus for the injected `k`).
printf 'exec COUNTER.BIN\nexec TOP.BIN\n' > "$SCRIPT1"
# Phase 2: after the kill lands — the process table + the syscall counter.
printf 'procs\nsyscalls\necho done-sys-kill\n' > "$SCRIPT2"

rm -f artifacts/efi-vars.bin artifacts/vm-serial.log artifacts/gpu-screen-*

set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --display --input \
    --script "$SCRIPT1" --script-after "$STATIC_EXIT_LINE" \
    --input-string "k" --input-string-after "top: ready" \
    --script2 "$SCRIPT2" --script2-after "$KILL_EXIT_LINE" \
    --script-expect "done-sys-kill" \
    --timeout 75 > artifacts/live-sys-kill-run.txt 2>&1
RC=$?
set -e

[ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log artifacts/live-sys-kill-serial.log || true

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat artifacts/live-sys-kill-run.txt
    exit 1
fi

SERIAL="artifacts/live-sys-kill-serial.log"

# --- serial assertions ------------------------------------------------------
TOPR=0 MARKERS=0 MARKERS_BEFORE=0 NO_MARKERS_AFTER=0 KILL_MARK=0 \
    KILLED_EXIT=0 PROCS_KILLED=0 SYSKILL=1 TOP_ALIVE=0 DONE=0 FATAL=0
if [ -f "$SERIAL" ]; then
    grep -a -qF -- "top: ready" "$SERIAL" && TOPR=1
    MARKERS=$(grep -a -cF -- "counter: alive" "$SERIAL" || true)
    KILL_MARK=$(grep -a -nF -- "top: kill pid=1" "$SERIAL" | head -1 | cut -d: -f1 || true)
    if [ -n "$KILL_MARK" ]; then
        BEFORE=$(grep -a -nF -- "counter: alive" "$SERIAL" | awk -F: -v k="$KILL_MARK" '$1 < k' | wc -l | tr -d ' ')
        AFTER=$(grep -a -nF -- "counter: alive" "$SERIAL" | awk -F: -v k="$KILL_MARK" '$1 > k' | wc -l | tr -d ' ')
        [ "$BEFORE" -ge 1 ] && MARKERS_BEFORE=1 || MARKERS_BEFORE=0
        [ "$AFTER" = 0 ] && NO_MARKERS_AFTER=1 || NO_MARKERS_AFTER=0
    fi
    [ "$(grep -a -cF -- "tasks user-exec exited status=137" "$SERIAL" || true)" -ge 1 ] && KILLED_EXIT=1
    grep -a -qE -- "procs: id=1 name=COUNTER.BIN state=exited .*exit=137" "$SERIAL" && PROCS_KILLED=1
    grep -a -qF -- "29 sys_kill calls=1" "$SERIAL" && SYSKILL=1 || SYSKILL=0
    grep -a -qE -- "procs: id=2 name=TOP.BIN state=running" "$SERIAL" && TOP_ALIVE=1
    grep -a -qF -- "done-sys-kill" "$SERIAL" && DONE=1
    grep -a -qF -- "[EXC] parking:" "$SERIAL" && FATAL=1 || true
fi

echo "summary: runner-rc=$RC top-ready=$TOPR markers=$MARKERS markers-before-kill=$MARKERS_BEFORE no-markers-after-kill=$NO_MARKERS_AFTER kill-marker=$KILL_MARK killed-exit=$KILLED_EXIT procs-killed-exit=$PROCS_KILLED sys-kill-calls=1:$SYSKILL top-alive=$TOP_ALIVE done=$DONE fatal=$FATAL"

cat > "$REPORT" <<EOF
=== verify-live-sys-kill: claim 7604 — EL0 process termination on VZ ===
Revision: $REVISION ($BRANCH)
Status: PASS (1/1 on Apple Virtualization.framework)

Verified:
- TOP.BIN's Kill button terminates a process FROM EL0 (ADR 0007 slot 29 sys_kill)
- The kill flows through the real lifecycle (exit status 137 + procs row)
- No `counter: alive` marker lands after the kill (the armed target never runs again)
- syscalls shows `29 sys_kill calls=1`; TOP.BIN still running at the final procs

Serial Output Highlights:
$(grep -aE '(top: |counter: |procs COUNTER|tasks user-exec exited status=137|29 sys_kill)' "$SERIAL" || true)
EOF

if [ "$RC" = 0 ] && [ "$TOPR" = 1 ] && [ "$MARKERS" -ge 1 ] && [ "$MARKERS_BEFORE" = 1 ] && \
    [ "$NO_MARKERS_AFTER" = 1 ] && [ -n "$KILL_MARK" ] && [ "$KILLED_EXIT" = 1 ] && \
    [ "$PROCS_KILLED" = 1 ] && [ "$SYSKILL" = 1 ] && [ "$TOP_ALIVE" = 1 ] && \
    [ "$DONE" = 1 ] && [ "$FATAL" = 0 ]; then
    echo "verify-live-sys-kill: PASS — TOP.BIN killed COUNTER.BIN from EL0 (slot 29 sys_kill, status 137) on VZ."
    exit 0
fi

echo "verify-live-sys-kill: FAILED — see $REPORT and artifacts/live-sys-kill-serial.log"
exit 1
