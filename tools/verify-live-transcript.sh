#!/usr/bin/env bash
#
# verify-live-transcript.sh -- claim 6684 class-B gate: live RX. Host
# scripted keystrokes reach the kernel end to end through the polled virtio
# receive queue (queue 0), and the exact `dipshit>` transcript lands in
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
# the live transcript in vm-serial.log: the takeover banner, the `dipshit>`
# prompt with the echoed keystrokes, the command outputs, and the echo reply.
#
# Per boot this reports:
#   rc              the runner's exit code (0 iff the expected reply appeared)
#   serial-bytes    vm-serial.log size
#   banner / prompt / help / version / mem / echo   per-assertion flags
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
# (runner output), live-transcript-serial-<NN>.log (vm-serial.log copy),
# live-transcript-script.txt (the forwarded keystrokes).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-transcript-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-transcript-report.txt"
SCRIPT="artifacts/live-transcript-script.txt"

echo "=== verify-live-transcript: claim 6684 — live RX (host keystrokes -> kernel -> vm-serial.log), $BOOTS boot(s) ==="

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
version
mem
echo rx-live-ok
EOF

# --- THE GATE: per-boot live RX run, fresh variable store each --------------
run_one() {
    local tag="$1"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" --script-expect "rx-live-ok" --timeout 40 \
        > "artifacts/live-transcript-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-transcript-serial-$tag.log" || true

    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log 2>/dev/null | tr -d ' ')
    local BANNER=0 PROMPT=0 HELP=0 VERSION=0 MEM=0 ECHO=0
    [ -f artifacts/vm-serial.log ] || { SERIAL_BYTES=0; }
    if [ -f artifacts/vm-serial.log ]; then
        grep -qF -- "DipshitOS kernel has seized control." artifacts/vm-serial.log && BANNER=1
        grep -qF -- "dipshit> help" artifacts/vm-serial.log && PROMPT=1
        grep -qF -- "available commands:" artifacts/vm-serial.log && HELP=1
        grep -qF -- "dipshit-kernel" artifacts/vm-serial.log && VERSION=1
        grep -qF -- "mem: descriptors=" artifacts/vm-serial.log && MEM=1
        grep -qF -- "rx-live-ok" artifacts/vm-serial.log && ECHO=1
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
    echo "DIPSHITOS live-transcript gate (claim 6684) — live RX on real VZ hardware"
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
    echo "verify-live-transcript: PASS — live RX confirmed: host keystrokes reached the kernel end to end and the live dipshit> transcript is in vm-serial.log ($PASS/$BOOTS boot(s))."
    echo "PASS: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-transcript: FAILED — $PASS/$BOOTS boot(s) passed; see artifacts/live-transcript-report.txt and the per-boot serial logs."
    echo "FAIL: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
