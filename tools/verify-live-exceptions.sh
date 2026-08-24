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

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-exceptions-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-exceptions-report.txt)"

echo "=== verify-live-exceptions: claim 9746 — live exception vectors (VBAR_EL1 + sync handler), $BOOTS boot(s) ==="

# --- per-run isolation -------------------------------------------------------------
# Private scratch dir + pristine-boot overlay for EVERY boot.
# See tools/lib/gate-run.sh.
gate_begin live-exceptions
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
help
fault
echo rx-exc-ok
EOF

# --- THE GATE: per-boot live run, fresh variable store each -----------------
run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-expect "rx-exc-ok" --timeout 40 \
        > "$(art live-exceptions-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-exceptions-serial-$tag.log)" || true
    local SER="$(art live-exceptions-serial-$tag.log)"

    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
    local BANNER=0 HELP=0 TRIGGER=0 EXC_SYNC=0 EXC_EC=0 EXC_RESUME=0 RESUMED=0 ECHO=0
    [ -f "$SER" ] || { SERIAL_BYTES=0; }
    if [ -f "$SER" ]; then
        grep -qF -- "DipshitOS kernel has seized control." "$SER" && BANNER=1
        grep -qF -- "available commands:" "$SER" && HELP=1
        grep -qF -- "fault: triggering udf (synchronous exception)..." "$SER" && TRIGGER=1
        grep -qF -- "[EXC] sync from EL1" "$SER" && EXC_SYNC=1
        grep -qF -- "ec=0x00 unknown-reason" "$SER" && EXC_EC=1
        grep -qF -- "[EXC] resume-armed: skipping faulting instruction" "$SER" && EXC_RESUME=1
        grep -qF -- "fault: handled, resumed after faulting instruction" "$SER" && RESUMED=1
        grep -qF -- "rx-exc-ok" "$SER" && ECHO=1
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
