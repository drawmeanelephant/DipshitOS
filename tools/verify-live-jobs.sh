#!/usr/bin/env bash
#
# verify-live-jobs.sh -- milestone-nineteen card P7 class-B gate
# (issue #296): foreground/background jobs.
#
# Mechanism: boots the production image and drives the walk over serial:
#   exec COUNTER.BIN &    -> launch line "[1] running: COUNTER.BIN"; the
#                            shell keeps taking commands (the eternal child)
#   jobs                  -> "[1] Running: COUNTER.BIN"
#   exec STATUS43.BIN &   -> launch line "[2] running: STATUS43.BIN"
#   echo filler-1         -> gives the idle reaper poll cycles
#   echo filler-2
#   fg 1                  -> bounded wait (~5 s) then honest timeout:
#                            "fg: job 1 still running". STATUS43 sleeps
#                            6 scheduler ticks, so it exits during this
#                            window.
#   echo drain-a/b + fg 2 -> idle polls / a second bounded wait so the
#                            exit announcement lands whichever way the
#                            timing falls (if the reaper already freed
#                            slot 2, fg honestly reports `already done`)
#   echo jobs-done        -> completion marker
#
# The exit-status proof: exactly ONE exact "[2] Done: STATUS43.BIN
# (exit=43)" line may appear — printed by the reaper from the process
# registry's REAL exit status (whether it lands before `fg 1` or not is
# hardware timing, but it must appear and appear once).
#
# Class B — Apple silicon + VZ only.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-jobs-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-jobs-report.txt"
SCRIPT="artifacts/live-jobs-input.txt"

echo "=== verify-live-jobs: M19 P7 — background jobs on VZ, $BOOTS boot(s) ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

cat > "$SCRIPT" <<'EOF'
exec COUNTER.BIN &
jobs
exec STATUS43.BIN &
echo filler-1
echo filler-2
fg 1
echo drain-a
echo drain-b
fg 2
echo drain-c
echo jobs-done
EOF

run_one() {
    local tag="$1"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" --script-expect "jobs-done" --timeout 60 \
        > "artifacts/live-jobs-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-jobs-serial-$tag.log" || true

    local SERIAL_BYTES BANNER=0 LAUNCH1=0 LISTING=0 LAUNCH2=0 DONE43=0 STILLRUNNING=0 DONE=0
    SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log 2>/dev/null | tr -d ' ')
    if [ -f artifacts/vm-serial.log ]; then
        grep -qF "DipshitOS kernel" artifacts/vm-serial.log && BANNER=1
        # Launch confirmations with real tracked pids behind them.
        [ "$(grep -x -c '\[1\] running: COUNTER.BIN' artifacts/vm-serial.log | tr -d ' ')" = 1 ] && LAUNCH1=1
        [ "$(grep -x -c '\[2\] running: STATUS43.BIN' artifacts/vm-serial.log | tr -d ' ')" = 1 ] && LAUNCH2=1
        # `jobs` sees the eternal child as Running.
        [ "$(grep -x -c '\[1\] Running: COUNTER.BIN' artifacts/vm-serial.log | tr -d ' ')" = 1 ] && LISTING=1
        # Exactly one Done line, carrying the child's REAL registry status.
        [ "$(grep -x -c '\[2\] Done: STATUS43.BIN (exit=43)' artifacts/vm-serial.log | tr -d ' ')" = 1 ] && DONE43=1
        # fg on the eternal child honestly times out, leaving it tracked.
        grep -qF "fg: job 1 still running" artifacts/vm-serial.log && STILLRUNNING=1
        grep -qF "jobs-done" artifacts/vm-serial.log && DONE=1
    fi
    echo "$tag: rc=$RC bytes=$SERIAL_BYTES banner=$BANNER launch1=$LAUNCH1 listing=$LISTING launch2=$LAUNCH2 done43=$DONE43 stillrunning=$STILLRUNNING done=$DONE"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$LAUNCH1" = 1 ] && [ "$LAUNCH2" = 1 ] \
        && [ "$LISTING" = 1 ] && [ "$DONE43" = 1 ] && [ "$STILLRUNNING" = 1 ] && [ "$DONE" = 1 ]
}

PASS=0
for n in $(seq 1 "$BOOTS"); do
    echo "=== live-jobs boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then PASS=$((PASS + 1)); fi
done

if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-jobs: PASS ($PASS/$BOOTS)"
    echo "PASS: $PASS/$BOOTS" > "$REPORT"
    exit 0
else
    echo "verify-live-jobs: FAIL ($PASS/$BOOTS)"
    echo "FAIL: $PASS/$BOOTS" > "$REPORT"
    exit 1
fi
