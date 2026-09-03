#!/usr/bin/env bash
#
# verify-live-transcript.sh -- claim 6684 class-B gate: live RX. Host
# scripted keystrokes reach the kernel end to end through the polled virtio
# receive queue (queue 0), and the exact `virelai>` transcript lands in
# vm-serial.log on a real VZ run.
#
# Mechanism: the production image is booted with the runner's non-interactive
# scripted-input mode (--script / --script-expect, claim 6684): the runner
# waits for the guest's takeover terminal state, forwards the scripted
# keystrokes into the serial attachment (the guest's virtio RX buffer was
# supplied pre-exit), tees guest output to vm-serial.log, and exits 0 iff the
# expected transcript substring appears.
#
# The script drives real commands: help, version, mem, and an echo whose
# reply ("rx-live-ok") is the runner's success signal. The gate then asserts
# the live transcript in vm-serial.log: the takeover banner, the `virelai>`
# prompt with the echoed keystrokes, the command outputs, and the echo reply.
#
# Per boot this reports:
#   rc              the runner's exit code (0 iff the expected reply appeared)
#   serial-bytes    vm-serial.log size
#   banner / prompt / help / version / mem / echo   per-assertion flags
#
# Run isolation (#523 item 2 / issue #528, claim 5069): every boot attaches
# a private DiskImageKit stacked disk (read-only base + throwaway ASIF
# overlay), a private EFI var store (recreated fresh per boot, as the
# pre-isolation gate did), and a private serial log under $RUN_DIR — two
# concurrent instances cannot clobber each other's disks, NVRAM, or
# evidence. Set VIRELAI_GATE_SUFFIX=_alt to give this instance its own
# canonical evidence names (two simultaneous instances MUST differ), and
# VIRELAI_KEEP_RUN=1 to keep the scratch dir.
#
# Class B — Apple silicon + VZ only; boots a real VM. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-transcript.sh          # BOOTS boots (default 1)
#   BOOTS=3 bash tools/verify-live-transcript.sh
#
# Evidence saved under artifacts/: live-transcript-gate.txt (full output),
# live-transcript-report.txt (per-boot detail), live-transcript-run-<NN>.txt
# (runner output), live-transcript-serial-<NN>.log (vm-serial.log copy).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-transcript-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-transcript-report.txt)"

echo "=== verify-live-transcript: claim 6684 — live RX (host keystrokes -> kernel -> vm-serial.log), $BOOTS boot(s) ==="


# --- tool versions + revision -----------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
gate_fmt_check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
gate_build_runner

# --- per-run isolation -------------------------------------------------------
gate_begin live-transcript
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

# --- the scripted keystrokes ------------------------------------------------
cat > "$SCRIPT" <<'EOF'
help
version
mem
echo rx-live-ok
EOF

# --- THE GATE: per-boot live RX run, fresh variable store each --------------
run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-expect "rx-live-ok" --timeout 40 \
        > "$(art live-transcript-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    local SER="$(art live-transcript-serial-$tag.log)"
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$SER" || true

    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
    local BANNER=0 PROMPT=0 HELP=0 VERSION=0 MEM=0 ECHO=0
    [ -f "$SER" ] || { SERIAL_BYTES=0; }
    if [ -f "$SER" ]; then
        grep -qF -- "VirelaiOS kernel has seized control." "$SER" && BANNER=1
        # PROMPT: the interactive shell rendered AND echoed a typed command.
        # Anchored on `version` (the SECOND scripted command): the first
        # command (`help`) can legitimately echo plain when it lands while
        # the boot-log tail collides with the first prompt render (first CI
        # census, issue #896), and the colored echo form only exists once the
        # shell has settled. gate_serial_has_echo accepts both the colored
        # and plain forms; the help/version/mem/echo OUTPUT checks below
        # prove live RX independently.
        gate_serial_has_echo "$SER" version && PROMPT=1
        grep -qF -- "available commands:" "$SER" && HELP=1
        grep -qF -- "virelai-kernel" "$SER" && VERSION=1
        grep -qF -- "mem: descriptors=" "$SER" && MEM=1
        grep -qF -- "rx-live-ok" "$SER" && ECHO=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER prompt=$PROMPT help=$HELP version=$VERSION mem=$MEM echo=$ECHO"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER prompt=$PROMPT help=$HELP version=$VERSION mem=$MEM echo=$ECHO"
    # The gate passes iff the runner saw the echo reply AND every live
    # transcript assertion held.
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$PROMPT" = 1 ] && [ "$HELP" = 1 ] && [ "$VERSION" = 1 ] && [ "$MEM" = 1 ] && [ "$ECHO" = 1 ]
}

: > "$REPORT"
{
    echo "VIRELAIOS live-transcript gate (claim 6684) — live RX on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $SCRIPT (help/version/mem/echo rx-live-ok)"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-RX boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-transcript: PASS — live RX confirmed: host keystrokes reached the kernel end to end and the live virelai> transcript is in the serial log ($PASS/$BOOTS boot(s))."
    echo "PASS: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-transcript: FAILED — $PASS/$BOOTS boot(s) passed; see $(art live-transcript-report.txt) and the per-boot serial logs."
    echo "FAIL: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
