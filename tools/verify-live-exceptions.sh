#!/usr/bin/env bash
#
# verify-live-exceptions.sh -- claim 9746 class-B gate: live exception
# vectors. The production image boots on real VZ hardware with the VBAR_EL1
# vector table installed; host scripted keystrokes drive `dipshit> fault`,
# which deliberately triggers a synchronous exception (`udf`). The kernel's
# exception handler emits the `[EXC]` report (ESR/FAR/ELR/SPSR + x0/x30),
# skips the faulting instruction, and the shell resumes. The gate asserts
# the report and the resume in vm-serial.log, plus a follow-up command to
# prove the shell is still alive after the exception.
#
# Mechanism: the runner's non-interactive scripted-input mode (claim 6684,
# --script / --script-expect) forwards keystrokes into the serial
# attachment; guest output is teed to vm-serial.log; the runner exits 0 iff
# the expected reply appears.
#
# The script drives: help (live listing), fault (the exception), and echo
# (the runner's success signal). Per boot this reports:
#   rc              the runner's exit code (0 iff the expected reply appeared)
#   serial-bytes    vm-serial.log size
#   banner/help/fault-trigger/exc-sync/exc-ec/exc-resume/resumed/echo   flags
#
# Class B — Apple silicon + VZ only; boots a real VM. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-exceptions.sh          # BOOTS boots (default 1)
#   BOOTS=3 bash tools/verify-live-exceptions.sh
#
# Evidence saved under artifacts/: live-exceptions-gate.txt (full output),
# live-exceptions-report.txt (per-boot detail), live-exceptions-run-<NN>.txt
# (runner output), live-exceptions-serial-<NN>.log (vm-serial.log copy),
# live-exceptions-script.txt (the forwarded keystrokes).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-exceptions-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-exceptions-report.txt"
SCRIPT="artifacts/live-exceptions-script.txt"

echo "=== verify-live-exceptions: claim 9746 — live exception vectors (VBAR_EL1 + sync handler), $BOOTS boot(s) ==="

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
help
fault
echo rx-exc-ok
EOF

# --- THE GATE: per-boot live run, fresh variable store each -----------------
run_one() {
    local tag="$1"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" --script-expect "rx-exc-ok" --timeout 40 \
        > "artifacts/live-exceptions-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-exceptions-serial-$tag.log" || true

    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log 2>/dev/null | tr -d ' ')
    local BANNER=0 HELP=0 TRIGGER=0 EXC_SYNC=0 EXC_EC=0 EXC_RESUME=0 RESUMED=0 ECHO=0
    [ -f artifacts/vm-serial.log ] || { SERIAL_BYTES=0; }
    if [ -f artifacts/vm-serial.log ]; then
        grep -qF -- "DipshitOS kernel has seized control." artifacts/vm-serial.log && BANNER=1
        grep -qF -- "available commands:" artifacts/vm-serial.log && HELP=1
        grep -qF -- "fault: triggering udf (synchronous exception)..." artifacts/vm-serial.log && TRIGGER=1
        grep -qF -- "[EXC] sync from EL1" artifacts/vm-serial.log && EXC_SYNC=1
        grep -qF -- "ec=0x00 unknown-reason" artifacts/vm-serial.log && EXC_EC=1
        grep -qF -- "[EXC] resume-armed: skipping faulting instruction" artifacts/vm-serial.log && EXC_RESUME=1
        grep -qF -- "fault: handled, resumed after faulting instruction" artifacts/vm-serial.log && RESUMED=1
        grep -qF -- "rx-exc-ok" artifacts/vm-serial.log && ECHO=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER help=$HELP trigger=$TRIGGER exc-sync=$EXC_SYNC exc-ec=$EXC_EC exc-resume=$EXC_RESUME resumed=$RESUMED echo=$ECHO"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER help=$HELP trigger=$TRIGGER exc-sync=$EXC_SYNC exc-ec=$EXC_EC exc-resume=$EXC_RESUME resumed=$RESUMED echo=$ECHO"
    # The gate passes iff the runner saw the echo reply AND every live
    # exception-vector assertion held.
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$HELP" = 1 ] && [ "$TRIGGER" = 1 ] && [ "$EXC_SYNC" = 1 ] && [ "$EXC_EC" = 1 ] && [ "$EXC_RESUME" = 1 ] && [ "$RESUMED" = 1 ] && [ "$ECHO" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live-exceptions gate (claim 9746) — VBAR_EL1 vectors + sync handler on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $SCRIPT (help/fault/echo rx-exc-ok)"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-exceptions boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-exceptions: PASS — VBAR_EL1 vectors installed; a real synchronous exception was reported and resumed on VZ ($PASS/$BOOTS boot(s))."
    echo "PASS: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-exceptions: FAILED — $PASS/$BOOTS boot(s) passed; see artifacts/live-exceptions-report.txt and the per-boot serial logs."
    echo "FAIL: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
